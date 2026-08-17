#!/usr/bin/env bash
# Bindery LXC Helper for Proxmox VE
# Community-Scripts-inspired standalone installer
# Source application: https://github.com/vavallee/bindery
# License for this helper: MIT
#
# Run on the Proxmox VE HOST as root.
#
# Features:
#   - Default / Advanced LXC creation wizard
#   - Debian 13 LXC, latest official Bindery binary
#   - Explicit Proxmox root-disk storage picker (separate from media)
#   - Host drive + folder browser for downloads and audiobooks
#   - Single-mount hardlink-optimized layout when both folders share a drive
#   - Optional qBittorrent/download-client path remap
#   - Unprivileged LXC by default with optional POSIX ACL setup
#   - systemd service, non-root Bindery user
#   - /usr/bin/update one-command updater with checksum verification and rollback
#   - Host-side manage menu for update, backup, status and shell

set -Eeuo pipefail
shopt -s extglob

APP="Bindery"
APP_SLUG="bindery"
APP_REPO="vavallee/bindery"
DEFAULT_CPU=1
DEFAULT_RAM=1024
DEFAULT_SWAP=512
DEFAULT_DISK=8
DEFAULT_HOSTNAME="bindery"
DEFAULT_BRIDGE="vmbr0"
DEFAULT_PORT=8787
DEFAULT_TAGS="media;books;bindery"
BINDERY_UID=1000
BINDERY_GID=1000

# ---------- UI ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

cleanup_files=()
cleanup() {
  local f
  for f in "${cleanup_files[@]:-}"; do
    [[ -e "$f" ]] && rm -rf -- "$f" || true
  done
}
trap cleanup EXIT

on_error() {
  local exit_code=$?
  local line_no=${BASH_LINENO[0]:-unknown}
  echo -e "\n${RED}${BOLD}[ERROR]${RESET} The helper stopped at line ${line_no} (exit ${exit_code})." >&2
  echo -e "${YELLOW}Nothing intentionally destructive is performed after a failed container creation; inspect the CT before deleting it.${RESET}" >&2
  exit "$exit_code"
}
trap on_error ERR

header() {
  clear 2>/dev/null || true
  cat <<'EOF'
    ____  _           __
   / __ )(_)___  ____/ /__  _______  __
  / __  / / __ \/ __  / _ \/ ___/ / / /
 / /_/ / / / / / /_/ /  __/ /  / /_/ /
/_____/_/_/ /_/\__,_/\___/_/   \__, /
                               /____/
EOF
  echo -e "${CYAN}${BOLD}        Proxmox VE LXC Helper${RESET}"
  echo -e "${BLUE}  Community-Scripts-inspired standalone installer${RESET}\n"
}

msg_info() { echo -e "${BLUE}ℹ${RESET}  $*"; }
msg_ok()   { echo -e "${GREEN}✔${RESET}  $*"; }
msg_warn() { echo -e "${YELLOW}⚠${RESET}  $*"; }
msg_err()  { echo -e "${RED}✖${RESET}  $*" >&2; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || return 1
}

ensure_whiptail() {
  if ! need_cmd whiptail; then
    msg_info "Installing whiptail on the Proxmox host"
    apt-get update -qq
    apt-get install -y -qq whiptail >/dev/null
    msg_ok "Installed whiptail"
  fi
}

wt_msg() {
  whiptail --backtitle "Bindery Proxmox VE Helper" --title "$1" --msgbox "$2" "${3:-18}" "${4:-78}"
}

wt_yesno() {
  whiptail --backtitle "Bindery Proxmox VE Helper" --title "$1" --yesno "$2" "${3:-14}" "${4:-78}"
}

wt_input() {
  local title="$1" text="$2" default="${3:-}"
  whiptail --backtitle "Bindery Proxmox VE Helper" --title "$title" --inputbox "$text" 12 78 "$default" 3>&1 1>&2 2>&3
}

wt_password() {
  local title="$1" text="$2"
  whiptail --backtitle "Bindery Proxmox VE Helper" --title "$title" --passwordbox "$text" 12 78 3>&1 1>&2 2>&3
}

# ---------- preflight ----------
preflight() {
  if [[ ${EUID} -ne 0 ]]; then
    msg_err "Run this script as root on the Proxmox VE host."
    exit 1
  fi
  if ! need_cmd pveversion || ! need_cmd pct || ! need_cmd pvesh || ! need_cmd pvesm; then
    msg_err "This does not appear to be a Proxmox VE host."
    exit 1
  fi
  ensure_whiptail
  local -a missing=()
  need_cmd curl || missing+=(curl)
  need_cmd jq || missing+=(jq)
  need_cmd findmnt || missing+=(util-linux)
  need_cmd realpath || missing+=(coreutils)
  if (( ${#missing[@]} > 0 )); then
    apt-get update -qq
    apt-get install -y -qq ca-certificates "${missing[@]}" >/dev/null
  fi
}

# ---------- generic selectors ----------
next_ctid() {
  pvesh get /cluster/nextid 2>/dev/null
}

validate_int_range() {
  local value="$1" min="$2" max="$3"
  [[ "$value" =~ ^[0-9]+$ ]] && (( value >= min && value <= max ))
}

valid_ipv4() {
  local ip="$1" a b c d extra octet
  IFS='.' read -r a b c d extra <<<"$ip"
  [[ -z "${extra:-}" && -n "$a" && -n "$b" && -n "$c" && -n "$d" ]] || return 1
  for octet in "$a" "$b" "$c" "$d"; do
    [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
    # Avoid ambiguous legacy octal-looking forms such as 010.0.0.1.
    [[ "$octet" == "0" || "$octet" != 0* ]] || return 1
    (( 10#$octet <= 255 )) || return 1
  done
}

valid_ipv4_cidr() {
  local value="$1" ip prefix
  [[ "$value" == */* ]] || return 1
  ip=${value%/*}
  prefix=${value##*/}
  valid_ipv4 "$ip" && validate_int_range "$prefix" 0 32
}

valid_hostname() {
  local hostname="$1" label
  [[ ${#hostname} -ge 1 && ${#hostname} -le 253 ]] || return 1
  IFS='.' read -r -a labels <<<"$hostname"
  for label in "${labels[@]}"; do
    [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || return 1
  done
}

select_rootfs_storage() {
  local -a opts=()
  local name type status total used avail pctused desc
  while read -r name type status total used avail pctused; do
    [[ "$name" == "Name" || -z "$name" ]] && continue
    [[ "$status" != "active" ]] && continue
    desc="$type | ${avail:-?} free"
    opts+=("$name" "$desc")
  done < <(pvesm status --content rootdir 2>/dev/null || true)

  if (( ${#opts[@]} == 0 )); then
    wt_msg "No LXC Root Storage" \
      "No active Proxmox storage configured for Container/rootdir content was found.

Configure a normal Proxmox storage backend first (for example local-lvm, ZFS, LVM-thin, or directory storage).

This is intentionally separate from the Downloads and Audiobook media folders."
    return 1
  fi

  whiptail --backtitle "Bindery Proxmox VE Helper" --title "LXC Root Disk Storage" \
    --menu "Choose the NORMAL PROXMOX STORAGE for Bindery's internal root disk.

This list comes from Proxmox storage configured for Container/rootdir content. It is NOT the Downloads or Audiobook storage; those are selected separately afterwards.

Root disk size: ${DISK:-$DEFAULT_DISK} GB" \
    24 100 12 "${opts[@]}" 3>&1 1>&2 2>&3
}

select_bridge() {
  local -a opts=()
  local br
  while read -r br; do
    [[ -z "$br" ]] && continue
    opts+=("$br" "Linux bridge")
  done < <(ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | cut -d'@' -f1 | sort -u)

  # Fallback to /etc/network/interfaces names.
  if (( ${#opts[@]} == 0 )); then
    while read -r br; do
      opts+=("$br" "Configured bridge")
    done < <(grep -hE '^iface[[:space:]]+vmbr[0-9]+' /etc/network/interfaces /etc/network/interfaces.d/* 2>/dev/null | awk '{print $2}' | sort -u)
  fi

  if (( ${#opts[@]} == 0 )); then
    wt_msg "No bridge" "No Linux bridge (for example vmbr0) could be detected."
    return 1
  fi

  whiptail --backtitle "Bindery Proxmox VE Helper" --title "Network Bridge" \
    --menu "Select the network bridge:" 18 78 8 "${opts[@]}" 3>&1 1>&2 2>&3
}

# ---------- host drive/folder browser ----------
# We intentionally present mounted filesystems rather than block devices. A raw
# drive that is not mounted cannot safely be bind-mounted into an LXC.
list_eligible_mounts() {
  # JSON output preserves spaces in mount paths. findmnt's raw/list output
  # escapes them, which otherwise makes valid media mounts disappear.
  findmnt -J -o TARGET,SOURCE,FSTYPE 2>/dev/null \
    | jq -r '.. | objects
        | select(.target? and .source? and .fstype?)
        # TSV is our internal transport, so reject pathological mount names
        # containing control characters that would make a row ambiguous.
        | select((.target | contains("\t") | not) and (.target | contains("\r") | not) and (.target | contains("\n") | not))
        | [.target, .source, .fstype]
        | @tsv' \
    | while IFS=$'\t' read -r target source fs; do
        [[ "$target" =~ ^/(proc|sys|dev|run)(/|$) ]] && continue
        [[ "$target" =~ ^/etc/pve(/|$) ]] && continue
        [[ "$fs" =~ ^(proc|sysfs|devtmpfs|devpts|tmpfs|cgroup|cgroup2|securityfs|pstore|debugfs|tracefs|configfs|fusectl|mqueue|hugetlbfs|rpc_pipefs|efivarfs)$ ]] && continue
        [[ "$target" == *','* ]] && continue  # comma is a pct mount-option delimiter
        printf '%s\t%s\t%s\n' "$target" "$source" "$fs"
      done \
    | awk -F '\t' '!seen[$1]++' \
    | sort -t $'\t' -k1,1
}

human_free() {
  df -hP -- "$1" 2>/dev/null | awk 'NR==2 {print $4}'
}

select_host_drive() {
  local purpose="$1"
  local -a opts=()
  local target source fs free desc
  while IFS=$'\t' read -r target source fs; do
    [[ -d "$target" ]] || continue
    free=$(human_free "$target")
    desc="$fs | ${free:-?} free | $source"
    [[ ${#desc} -gt 65 ]] && desc="${desc:0:62}..."
    opts+=("$target" "$desc")
  done < <(list_eligible_mounts)

  if (( ${#opts[@]} == 0 )); then
    wt_msg "Storage error" "No eligible mounted host filesystems were found. Mount the storage on the Proxmox host first."
    return 1
  fi

  whiptail --backtitle "Bindery Proxmox VE Helper" --title "$purpose - Drive / Mount" \
    --menu "Choose the mounted filesystem that contains the $purpose folder.\n\nThe helper will browse folders on this mount next." \
    22 100 12 "${opts[@]}" 3>&1 1>&2 2>&3
}

path_is_under() {
  local base target
  base=$(realpath -m -- "$1")
  target=$(realpath -m -- "$2")
  [[ "$target" == "$base" || "$target" == "$base/"* ]]
}

validate_bind_mount_path() {
  local path="$1" canonical
  [[ -d "$path" ]] || return 1
  [[ "$path" != *','* && "$path" != *$'\n'* && "$path" != *$'\r'* && "$path" != *$'\t'* ]] || return 1
  canonical=$(realpath -e -- "$path" 2>/dev/null) || return 1
  [[ "$canonical" == "$path" ]]
}

folder_browser() {
  local drive="$1" purpose="$2"
  local current choice name newname candidate manual
  drive=$(realpath -m -- "$drive")
  current="$drive"

  while true; do
    local -a opts=()
    local -A folder_map=()
    opts+=("__USE__" "Use this folder: $current")
    opts+=("__CREATE__" "Create a new folder here")
    opts+=("__MANUAL__" "Enter a path manually under $drive")
    if [[ "$current" != "$drive" ]]; then
      opts+=("__UP__" ".. (go to parent folder)")
    fi

    local count=0 tag
    while IFS= read -r -d '' candidate; do
      name=$(basename -- "$candidate")
      tag="__DIR_${count}__"
      folder_map["$tag"]="$candidate"
      opts+=("$tag" "$name/")
      ((count+=1))
      (( count >= 120 )) && break
    done < <(find "$current" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z)

    choice=$(whiptail --backtitle "Bindery Proxmox VE Helper" --title "$purpose - Folder" --notags \
      --menu "Drive: $drive\nCurrent: $current\n\nChoose a folder, create one, or use the current folder." \
      24 100 14 "${opts[@]}" 3>&1 1>&2 2>&3) || return 1

    case "$choice" in
      __USE__)
        echo "$current"
        return 0
        ;;
      __UP__)
        current=$(dirname -- "$current")
        path_is_under "$drive" "$current" || current="$drive"
        ;;
      __CREATE__)
        newname=$(wt_input "$purpose - Create Folder" "Enter a new folder name or relative path under:\n$current" "") || continue
        [[ -z "$newname" ]] && continue
        if [[ "$newname" == /* ]]; then
          candidate=$(realpath -m -- "$newname")
        else
          candidate=$(realpath -m -- "$current/$newname")
        fi
        if ! path_is_under "$drive" "$candidate"; then
          wt_msg "Invalid path" "The folder must remain underneath:\n$drive"
          continue
        fi
        if [[ ! -d "$candidate" ]]; then
          if wt_yesno "Create Folder" "Create this directory?\n\n$candidate"; then
            mkdir -p -- "$candidate"
          else
            continue
          fi
        fi
        current="$candidate"
        ;;
      __MANUAL__)
        manual=$(wt_input "$purpose - Manual Path" "Enter an absolute path under $drive, or a path relative to that mount:" "") || continue
        [[ -z "$manual" ]] && continue
        if [[ "$manual" == /* ]]; then
          candidate=$(realpath -m -- "$manual")
        else
          candidate=$(realpath -m -- "$drive/$manual")
        fi
        if ! path_is_under "$drive" "$candidate"; then
          wt_msg "Invalid path" "The path must remain underneath:\n$drive"
          continue
        fi
        if [[ ! -d "$candidate" ]]; then
          if wt_yesno "Create Folder" "The folder does not exist. Create it?\n\n$candidate"; then
            mkdir -p -- "$candidate"
          else
            continue
          fi
        fi
        echo "$candidate"
        return 0
        ;;
      *)
        candidate="${folder_map[$choice]:-}"
        [[ -n "$candidate" && -d "$candidate" ]] && current="$candidate"
        ;;
    esac
  done
}

relative_to() {
  local base="$1" target="$2"
  if [[ "$target" == "$base" ]]; then
    echo ""
  else
    echo "${target#"$base"/}"
  fi
}

common_ancestor() {
  local a b
  a=$(realpath -m -- "$1")
  b=$(realpath -m -- "$2")
  while [[ "$b" != "$a" && "$b" != "$a/"* ]]; do
    a=$(dirname -- "$a")
    [[ "$a" == "/" ]] && break
  done
  echo "$a"
}

select_media_storage() {
  DOWNLOAD_DRIVE=$(select_host_drive "Downloads") || return 1
  DOWNLOAD_PATH=$(folder_browser "$DOWNLOAD_DRIVE" "Downloads") || return 1

  AUDIOBOOK_DRIVE=$(select_host_drive "Audiobook Library") || return 1
  AUDIOBOOK_PATH=$(folder_browser "$AUDIOBOOK_DRIVE" "Audiobook Library") || return 1

  DOWNLOAD_DRIVE=$(realpath -m -- "$DOWNLOAD_DRIVE")
  DOWNLOAD_PATH=$(realpath -m -- "$DOWNLOAD_PATH")
  AUDIOBOOK_DRIVE=$(realpath -m -- "$AUDIOBOOK_DRIVE")
  AUDIOBOOK_PATH=$(realpath -m -- "$AUDIOBOOK_PATH")

  if ! validate_bind_mount_path "$DOWNLOAD_PATH" || ! validate_bind_mount_path "$AUDIOBOOK_PATH"; then
    wt_msg "Unsupported Media Path" \
      "The selected media paths must be real directories without commas or symlink components.\n\nProxmox bind-mount syntax uses commas as option separators and does not permit symlinks in bind-mount source paths.\n\nDownloads: $DOWNLOAD_PATH\nAudiobooks: $AUDIOBOOK_PATH" 20 92
    return 1
  fi

  local download_dev audiobook_dev
  download_dev=$(stat -Lc '%d' -- "$DOWNLOAD_PATH" 2>/dev/null || echo unknown-download)
  audiobook_dev=$(stat -Lc '%d' -- "$AUDIOBOOK_PATH" 2>/dev/null || echo unknown-audio)

  if [[ "$DOWNLOAD_DRIVE" == "$AUDIOBOOK_DRIVE" && "$download_dev" == "$audiobook_dev" ]]; then
    MEDIA_HOST_BASE=$(common_ancestor "$DOWNLOAD_PATH" "$AUDIOBOOK_PATH")
    # Never expose the Proxmox host root as a bind mount. If the only common
    # ancestor is /, use two narrow mounts instead.
    if [[ "$MEDIA_HOST_BASE" != "/" ]]; then
      MEDIA_LAYOUT="single"
      local drel arel
      drel=$(relative_to "$MEDIA_HOST_BASE" "$DOWNLOAD_PATH")
      arel=$(relative_to "$MEDIA_HOST_BASE" "$AUDIOBOOK_PATH")
      DOWNLOAD_CT="/data${drel:+/$drel}"
      AUDIOBOOK_CT="/data${arel:+/$arel}"
      HARDLINK_STATUS="YES - one LXC mount, hardlinks can work"
    else
      MEDIA_LAYOUT="split"
      MEDIA_HOST_BASE=""
      DOWNLOAD_CT="/data/downloads"
      AUDIOBOOK_CT="/data/audiobooks"
      HARDLINK_STATUS="NO - safe split mounts; host / is never exposed"
      wt_msg "Safe Storage Layout" \
        "Both folders are on the Proxmox root filesystem but their only common parent is /.\n\nThe helper will NOT expose the host root filesystem inside the LXC. It will use two narrow folder mounts instead, so Bindery will copy rather than hardlink between them." 18 86
    fi
  else
    MEDIA_LAYOUT="split"
    MEDIA_HOST_BASE=""
    DOWNLOAD_CT="/data/downloads"
    AUDIOBOOK_CT="/data/audiobooks"
    HARDLINK_STATUS="NO - separate LXC mounts; Bindery will fall back to copy"
    wt_msg "Separate filesystems" \
      "Downloads and audiobooks are on different mounted filesystems (or different selected mounts).\n\nThis is fully supported, but Bindery cannot hardlink between separate LXC mounts. Completed audiobooks will normally be copied into the library instead.\n\nFor zero-copy imports/seeding, keep both folders on one filesystem under one common parent mount." 19 86
  fi

  LIBRARY_CT="$AUDIOBOOK_CT"

  DOWNLOAD_PATH_REMAP=""
  if wt_yesno "Download Client Path" \
    "Does qBittorrent (or another download client) report a DIFFERENT path than Bindery will see?\n\nExample:\nqBittorrent reports: /downloads/audiobooks\nBindery sees:        $DOWNLOAD_CT\n\nChoose Yes to create a global path remap now." 18 84; then
    local reported
    reported=$(wt_input "Download Path Remap" \
      "Enter the download folder/prefix exactly as qBittorrent reports it.\n\nIt will map TO:\n$DOWNLOAD_CT\n\nExample: /downloads/audiobooks" "/downloads") || true
    if [[ -n "${reported:-}" ]]; then
      if [[ "$reported" != /* || "$reported" == *','* || "$reported" == *':'* || "$reported" == *$'\n'* || "$reported" == *$'\r'* || "$reported" == *$'\t'* ]]; then
        wt_msg "Invalid Remap Prefix" \
          "The reported download prefix must be an absolute Linux path and may not contain commas, colons, or newlines.\n\nFor unusual path syntax, leave this blank and configure a per-client remap in Bindery instead." 17 88
      elif [[ "$DOWNLOAD_CT" == *':'* ]]; then
        wt_msg "Remap Not Added" \
          "The selected Bindery download path contains a colon, which is ambiguous in Bindery's global from:to remap syntax.\n\nThe media mount itself is valid; leave the global remap unset and configure paths in the download-client settings instead." 17 88
      else
        reported="${reported%/}"
        [[ -n "$reported" ]] || reported="/"
        DOWNLOAD_PATH_REMAP="$reported:$DOWNLOAD_CT"
      fi
    fi
  fi
}

# ---------- container wizard ----------
default_settings() {
  CTID=$(next_ctid)
  HOSTNAME="$DEFAULT_HOSTNAME"
  CORES="$DEFAULT_CPU"
  RAM="$DEFAULT_RAM"
  SWAP="$DEFAULT_SWAP"
  DISK="$DEFAULT_DISK"
  ROOTFS_STORAGE=""
  BRIDGE="$DEFAULT_BRIDGE"
  if ! ip link show "$BRIDGE" >/dev/null 2>&1; then
    BRIDGE=$(select_bridge) || return 1
  fi
  VLAN=""
  IPV4_MODE="dhcp"
  IPV4_CIDR=""
  GATEWAY=""
  DNS=""
  ONBOOT=1
  UNPRIVILEGED=1
  ROOT_PASSWORD=""
  ENABLE_SSH=0
  TAGS="$DEFAULT_TAGS"
}

advanced_settings() {
  local value
  CTID=$(wt_input "Container ID" "Enter the LXC Container ID:" "$(next_ctid)") || exit 1
  if ! validate_int_range "$CTID" 100 999999999 || pct status "$CTID" >/dev/null 2>&1; then
    wt_msg "Invalid CT ID" "CT ID '$CTID' is invalid or already exists."
    return 1
  fi

  HOSTNAME=$(wt_input "Hostname" "Enter the container hostname:" "$DEFAULT_HOSTNAME") || exit 1
  if ! valid_hostname "$HOSTNAME"; then
    wt_msg "Invalid hostname" "Use a valid DNS-style hostname. Each label must start/end with a letter or number and may contain hyphens."
    return 1
  fi

  CORES=$(wt_input "CPU Cores" "CPU cores (1-128):" "$DEFAULT_CPU") || exit 1
  validate_int_range "$CORES" 1 128 || { wt_msg "Invalid CPU" "CPU cores must be 1-128."; return 1; }

  RAM=$(wt_input "Memory" "RAM in MB (256-65536):" "$DEFAULT_RAM") || exit 1
  validate_int_range "$RAM" 256 65536 || { wt_msg "Invalid RAM" "RAM must be 256-65536 MB."; return 1; }

  SWAP=$(wt_input "Swap" "Swap in MB (0-32768):" "$DEFAULT_SWAP") || exit 1
  validate_int_range "$SWAP" 0 32768 || { wt_msg "Invalid Swap" "Swap must be 0-32768 MB."; return 1; }

  DISK=$(wt_input "Root Disk" "LXC root disk size in GB (4-4096):" "$DEFAULT_DISK") || exit 1
  validate_int_range "$DISK" 4 4096 || { wt_msg "Invalid disk" "Disk size must be 4-4096 GB."; return 1; }

  ROOTFS_STORAGE=""
  BRIDGE=$(select_bridge) || exit 1

  VLAN=$(wt_input "VLAN" "Optional VLAN tag (blank for none, 1-4094):" "") || true
  if [[ -n "$VLAN" ]] && ! validate_int_range "$VLAN" 1 4094; then
    wt_msg "Invalid VLAN" "VLAN must be blank or 1-4094."
    return 1
  fi

  if wt_yesno "IPv4" "Use DHCP for IPv4?\n\nChoose No to configure a static address."; then
    IPV4_MODE="dhcp"
    IPV4_CIDR=""
    GATEWAY=""
  else
    IPV4_MODE="static"
    IPV4_CIDR=$(wt_input "Static IPv4" "IPv4 address with CIDR prefix, for example:\n192.168.40.45/24" "") || exit 1
    if ! valid_ipv4_cidr "$IPV4_CIDR"; then
      wt_msg "Invalid IPv4" "Enter a valid IPv4 address with a /0-/32 prefix, for example 192.168.40.45/24."
      return 1
    fi
    GATEWAY=$(wt_input "Gateway" "IPv4 gateway:" "") || exit 1
    if ! valid_ipv4 "$GATEWAY"; then
      wt_msg "Invalid gateway" "Enter a valid IPv4 gateway, for example 192.168.40.1."
      return 1
    fi
  fi

  DNS=$(wt_input "DNS" "Optional DNS server (blank = inherit Proxmox/default):" "") || true

  if wt_yesno "Start at Boot" "Start Bindery automatically when this Proxmox node boots?"; then ONBOOT=1; else ONBOOT=0; fi

  if wt_yesno "Container Security" "Use an UNPRIVILEGED LXC?\n\nRecommended for most setups. Choose No only if your media-storage permissions require a privileged container."; then
    UNPRIVILEGED=1
  else
    UNPRIVILEGED=0
  fi

  if wt_yesno "SSH Server" "Install OpenSSH server inside the LXC?\n\nYou can always use 'pct enter $CTID' from the Proxmox host without SSH."; then
    ENABLE_SSH=1
    ROOT_PASSWORD=$(wt_password "Root Password" "Set a root password for the container (required for the helper's SSH configuration):") || exit 1
    if [[ -z "$ROOT_PASSWORD" ]]; then
      wt_msg "Password required" "SSH was selected, so a root password is required."
      return 1
    fi
  else
    ENABLE_SSH=0
    ROOT_PASSWORD=""
  fi

  TAGS=$(wt_input "Tags" "Proxmox tags, separated by semicolons:" "$DEFAULT_TAGS") || TAGS="$DEFAULT_TAGS"
}

select_permission_mode() {
  local mapped_uid
  if (( UNPRIVILEGED == 1 )); then
    mapped_uid=$((100000 + BINDERY_UID))
  else
    mapped_uid=$BINDERY_UID
  fi

  PERMISSION_MODE=$(whiptail --backtitle "Bindery Proxmox VE Helper" --title "Media Permissions" \
    --menu "Bindery runs as UID $BINDERY_UID inside the LXC.\nOn the host this corresponds to UID $mapped_uid for this container type.\n\nHow should the helper handle the selected media folders?" \
    22 94 8 \
    "acl" "Add POSIX ACL access for Bindery (recommended for local Linux filesystems)" \
    "existing" "Do not alter host permissions; use my existing ACL/ownership setup" \
    3>&1 1>&2 2>&3) || return 1

  ACL_RECURSIVE=0
  if [[ "$PERMISSION_MODE" == "acl" ]]; then
    if wt_yesno "Existing Media" \
      "Apply Bindery's ACL to EXISTING files and subfolders too?\n\nYes is useful when importing/scanning an existing Audiobookshelf library.\nNo only updates the selected folder and default ACL for newly created content." 16 84; then
      ACL_RECURSIVE=1
    fi
  fi
}

summary_and_confirm() {
  local priv="Unprivileged" network media
  (( UNPRIVILEGED == 0 )) && priv="Privileged"
  if [[ "$IPV4_MODE" == "dhcp" ]]; then
    network="DHCP"
  else
    network="$IPV4_CIDR via $GATEWAY"
  fi
  if [[ "$MEDIA_LAYOUT" == "single" ]]; then
    media="ONE mount: $MEDIA_HOST_BASE -> /data"
  else
    media="TWO mounts: downloads + audiobooks"
  fi

  local remap="None"
  [[ -n "$DOWNLOAD_PATH_REMAP" ]] && remap="$DOWNLOAD_PATH_REMAP"

  wt_yesno "Ready to Create" \
"Bindery LXC configuration

CT ID:             $CTID
Hostname:          $HOSTNAME
Debian:            13
CPU / RAM / Swap:  $CORES core(s) / ${RAM} MB / ${SWAP} MB
Root disk:         ${DISK} GB on $ROOTFS_STORAGE
Container:         $priv
Network:           $BRIDGE | $network${VLAN:+ | VLAN $VLAN}
Start on boot:     $ONBOOT
SSH:               $ENABLE_SSH

Downloads host:    $DOWNLOAD_PATH
Audiobooks host:   $AUDIOBOOK_PATH
Media mount:       $media
Downloads in CT:   $DOWNLOAD_CT
Audiobooks in CT:  $AUDIOBOOK_CT
Hardlink capable:  $HARDLINK_STATUS
Path remap:        $remap
Permission mode:   $PERMISSION_MODE

Create the container now?" 34 104
}

# ---------- ACL handling ----------
ensure_acl_tool() {
  if ! need_cmd setfacl; then
    msg_info "Installing ACL utilities on Proxmox host"
    apt-get update -qq
    apt-get install -y -qq acl >/dev/null
    msg_ok "Installed ACL utilities"
  fi
}

grant_traverse_acl() {
  local base="$1" target="$2" uid="$3"
  local rel part cur
  setfacl -m "u:${uid}:rx" -- "$base" 2>/dev/null || return 1
  rel=$(relative_to "$base" "$target")
  [[ -z "$rel" ]] && return 0
  cur="$base"
  IFS='/' read -r -a parts <<<"$rel"
  for part in "${parts[@]}"; do
    cur="$cur/$part"
    [[ "$cur" == "$target" ]] && break
    setfacl -m "u:${uid}:rx" -- "$cur" 2>/dev/null || return 1
  done
}

apply_acl_to_path() {
  local bind_base="$1" path="$2" uid="$3" recursive="$4"
  grant_traverse_acl "$bind_base" "$path" "$uid" || return 1
  setfacl -m "u:${uid}:rwx,d:u:${uid}:rwx" -- "$path" || return 1

  if (( recursive == 1 )); then
    find "$path" -type d -print0 2>/dev/null | xargs -0 -r setfacl -m "u:${uid}:rwx,d:u:${uid}:rwx" --
    find "$path" -type f -print0 2>/dev/null | xargs -0 -r setfacl -m "u:${uid}:rw" --
  fi
}

configure_host_permissions() {
  [[ "$PERMISSION_MODE" == "acl" ]] || return 0
  ensure_acl_tool

  local host_uid
  if (( UNPRIVILEGED == 1 )); then host_uid=$((100000 + BINDERY_UID)); else host_uid=$BINDERY_UID; fi

  msg_info "Granting host ACL access to mapped Bindery UID $host_uid"
  local failed=0
  if [[ "$MEDIA_LAYOUT" == "single" ]]; then
    apply_acl_to_path "$MEDIA_HOST_BASE" "$DOWNLOAD_PATH" "$host_uid" "$ACL_RECURSIVE" || failed=1
    if [[ "$AUDIOBOOK_PATH" != "$DOWNLOAD_PATH" ]]; then
      apply_acl_to_path "$MEDIA_HOST_BASE" "$AUDIOBOOK_PATH" "$host_uid" "$ACL_RECURSIVE" || failed=1
    fi
  else
    apply_acl_to_path "$DOWNLOAD_PATH" "$DOWNLOAD_PATH" "$host_uid" "$ACL_RECURSIVE" || failed=1
    apply_acl_to_path "$AUDIOBOOK_PATH" "$AUDIOBOOK_PATH" "$host_uid" "$ACL_RECURSIVE" || failed=1
  fi

  if (( failed == 1 )); then
    msg_warn "The selected filesystem rejected one or more POSIX ACL operations. Existing mount permissions will be used instead."
    wt_msg "ACL warning" \
      "The filesystem did not accept the requested POSIX ACL cleanly. This is common with some CIFS/SMB, NFS, NTFS or exFAT mounts.\n\nThe install can continue, but verify from inside the LXC that UID $BINDERY_UID can read downloads and write the audiobook folder.\n\nThe helper does NOT chmod 777 or change ownership of your media." 20 88
  else
    msg_ok "Configured media ACLs"
  fi
}

# ---------- Debian template ----------
select_template_storage_auto() {
  local line
  line=$(pvesm status --content vztmpl 2>/dev/null | awk 'NR>1 && $3=="active" {print $1; exit}')
  [[ -n "$line" ]] && { echo "$line"; return; }
  # Directory storage named local is the common fallback.
  if pvesm status 2>/dev/null | awk 'NR>1 && $1=="local" && $3=="active" {found=1} END {exit !found}'; then
    echo "local"
  fi
}

get_debian13_template() {
  local tmpl_storage template_name
  tmpl_storage=$(select_template_storage_auto)
  if [[ -z "$tmpl_storage" ]]; then
    msg_err "No Proxmox storage supporting container templates (vztmpl) was found."
    return 1
  fi

  msg_info "Refreshing Proxmox appliance template index"
  pveam update >/dev/null

  template_name=$(pveam available --section system 2>/dev/null | awk '$2 ~ /^debian-13-standard_/ {print $2}' | sort -V | tail -n1)
  if [[ -z "$template_name" ]]; then
    msg_err "No Debian 13 standard LXC template is available from pveam."
    return 1
  fi

  if ! pveam list "$tmpl_storage" 2>/dev/null | grep -Fq "$template_name"; then
    msg_info "Downloading Debian 13 LXC template: $template_name"
    pveam download "$tmpl_storage" "$template_name" >/dev/null
    msg_ok "Downloaded Debian 13 template"
  else
    msg_ok "Debian 13 template is already available"
  fi

  TEMPLATE_VOLID="${tmpl_storage}:vztmpl/${template_name}"
}

# ---------- inner container files ----------
make_inner_files() {
  INNER_DIR=$(mktemp -d /tmp/bindery-helper.XXXXXX)
  cleanup_files+=("$INNER_DIR")

  cat >"$INNER_DIR/bindery-update" <<'UPDATER_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

REPO="vavallee/bindery"
INSTALL_ROOT="/opt/bindery"
RELEASE_ROOT="$INSTALL_ROOT/releases"
CURRENT_LINK="$INSTALL_ROOT/current"
DATA_DIR="/var/lib/bindery"
BACKUP_ROOT="/var/backups/bindery"
ENV_FILE="/etc/bindery/bindery.env"
KEEP_RELEASES=4
KEEP_BACKUPS=6

INSTALL_ONLY=0
case "${1:-}" in
  --install) INSTALL_ONLY=1 ;;
  "") ;;
  *) echo "Usage: update [--install]"; exit 2 ;;
esac

if [[ ${EUID} -ne 0 ]]; then
  echo "Run as root."
  exit 1
fi

case "$(uname -m)" in
  x86_64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  armv7l) ARCH="armv7" ;;
  armv6l) ARCH="armv6" ;;
  *) echo "Unsupported architecture: $(uname -m)"; exit 1 ;;
esac

mkdir -p "$RELEASE_ROOT" "$BACKUP_ROOT" "$DATA_DIR"

echo "[Bindery] Checking GitHub for the latest release..."
JSON=$(curl -fsSL --retry 3 --connect-timeout 10 \
  -H 'Accept: application/vnd.github+json' \
  -H 'X-GitHub-Api-Version: 2022-11-28' \
  "https://api.github.com/repos/${REPO}/releases/latest")
TAG=$(jq -r '.tag_name // empty' <<<"$JSON")
[[ -n "$TAG" ]] || { echo "Unable to determine latest release."; exit 1; }
VERSION="${TAG#v}"
TARGET="$RELEASE_ROOT/$TAG"

CURRENT_VERSION=""
PREVIOUS_TARGET=""
if [[ -L "$CURRENT_LINK" ]]; then
  PREVIOUS_TARGET=$(readlink -f "$CURRENT_LINK")
  CURRENT_VERSION=$(basename "$PREVIOUS_TARGET")
fi

if [[ "$CURRENT_VERSION" == "$TAG" ]]; then
  echo "[Bindery] $TAG is already installed."
  exit 0
fi

ARCHIVE_NAME="bindery_${VERSION}_linux_${ARCH}.tar.gz"
CHECKSUM_NAME="bindery_${VERSION}_checksums.txt"
ARCHIVE_URL=$(jq -r --arg n "$ARCHIVE_NAME" '.assets[] | select(.name==$n) | .browser_download_url' <<<"$JSON" | head -n1)
CHECKSUM_URL=$(jq -r --arg n "$CHECKSUM_NAME" '.assets[] | select(.name==$n) | .browser_download_url' <<<"$JSON" | head -n1)
[[ -n "$ARCHIVE_URL" && "$ARCHIVE_URL" != "null" ]] || { echo "Release asset not found: $ARCHIVE_NAME"; exit 1; }
[[ -n "$CHECKSUM_URL" && "$CHECKSUM_URL" != "null" ]] || { echo "Checksum asset not found: $CHECKSUM_NAME"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "[Bindery] Downloading $TAG for linux/$ARCH..."
curl -fL --retry 3 "$ARCHIVE_URL" -o "$TMP/$ARCHIVE_NAME"
curl -fL --retry 3 "$CHECKSUM_URL" -o "$TMP/$CHECKSUM_NAME"

EXPECTED=$(awk -v f="$ARCHIVE_NAME" '$2==f || $2=="*"f {print $1; exit}' "$TMP/$CHECKSUM_NAME")
if [[ -z "$EXPECTED" ]]; then
  # GoReleaser checksum files normally use "hash  filename"; this fallback
  # keeps the updater compatible if formatting changes slightly.
  EXPECTED=$(grep -F "$ARCHIVE_NAME" "$TMP/$CHECKSUM_NAME" | awk '{print $1}' | head -n1)
fi
[[ -n "$EXPECTED" ]] || { echo "Could not find archive checksum."; exit 1; }
ACTUAL=$(sha256sum "$TMP/$ARCHIVE_NAME" | awk '{print $1}')
[[ "$EXPECTED" == "$ACTUAL" ]] || { echo "SHA-256 verification FAILED."; exit 1; }
echo "[Bindery] SHA-256 verified."

rm -rf "$TARGET.new"
mkdir -p "$TARGET.new"
tar -xzf "$TMP/$ARCHIVE_NAME" -C "$TARGET.new"
[[ -x "$TARGET.new/bindery" || -f "$TARGET.new/bindery" ]] || {
  found=$(find "$TARGET.new" -maxdepth 3 -type f -name bindery | head -n1)
  [[ -n "$found" ]] || { echo "Bindery binary not found in archive."; exit 1; }
  cp -a "$found" "$TARGET.new/bindery"
}
chmod 0755 "$TARGET.new/bindery"
rm -rf "$TARGET"
mv "$TARGET.new" "$TARGET"

if (( INSTALL_ONLY == 1 )) && [[ -n "$PREVIOUS_TARGET" ]]; then
  echo "--install is only valid for a fresh installation." >&2
  exit 2
fi

if (( INSTALL_ONLY == 1 )) || [[ -z "$PREVIOUS_TARGET" ]]; then
  ln -sfn "$TARGET" "$CURRENT_LINK"
  echo "$TAG" > /opt/bindery/VERSION
  echo "[Bindery] Installed $TAG."
  exit 0
fi

BACKUP="$BACKUP_ROOT/pre-${TAG}-$(date +%Y%m%d-%H%M%S).tar.gz"
SERVICE_STOPPED=0
SWITCHED=0
BACKUP_READY=0

# Read only the numeric port we need from EnvironmentFile. Do not `source` a
# systemd EnvironmentFile as shell code: valid media paths can contain shell
# metacharacters and systemd's quoting rules are not Bash's quoting rules.
HEALTH_PORT=8787
if [[ -f "$ENV_FILE" ]]; then
  configured_port=$(sed -nE 's/^BINDERY_PORT="?([0-9]+)"?[[:space:]]*$/\1/p' "$ENV_FILE" | head -n1)
  if [[ "$configured_port" =~ ^[0-9]+$ ]] && (( configured_port >= 1 && configured_port <= 65535 )); then
    HEALTH_PORT="$configured_port"
  fi
fi

bindery_is_healthy() {
  systemctl is-active --quiet bindery \
    && runuser -u bindery -- env BINDERY_PORT="$HEALTH_PORT" \
      "$CURRENT_LINK/bindery" healthcheck >/dev/null 2>&1
}

restore_previous() {
  trap - ERR
  local failed=0
  echo "[Bindery] Restoring $CURRENT_VERSION..." >&2
  systemctl stop bindery >/dev/null 2>&1 || true

  # Restore data first. If this fails, fail closed: do not start either binary
  # against a database whose migration state is unknown.
  if (( BACKUP_READY == 1 )); then
    find "$DATA_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + || failed=1
    if (( failed == 0 )); then
      tar -C "$DATA_DIR" -xzf "$BACKUP" || failed=1
    fi
  fi

  if (( failed == 0 )); then
    ln -sfn "$PREVIOUS_TARGET" "$CURRENT_LINK" || failed=1
    echo "$CURRENT_VERSION" > /opt/bindery/VERSION || failed=1
  fi

  if (( failed != 0 )); then
    echo "[Bindery] CRITICAL: rollback restore failed; Bindery has been left STOPPED to protect its data." >&2
    echo "[Bindery] Backup: $BACKUP" >&2
    return 1
  fi

  systemctl start bindery || true
  for _ in $(seq 1 20); do
    if bindery_is_healthy; then
      echo "[Bindery] Rollback to $CURRENT_VERSION completed." >&2
      return 0
    fi
    sleep 1
  done
  systemctl stop bindery >/dev/null 2>&1 || true
  echo "[Bindery] Rollback service did not become healthy and has been left STOPPED. Check: journalctl -u bindery -n 100" >&2
  return 1
}

update_error() {
  local ec=$?
  trap - ERR
  echo "[Bindery] Update interrupted (exit $ec). Recovering the previous service state..." >&2
  if (( SWITCHED == 1 )); then
    restore_previous || true
  elif (( SERVICE_STOPPED == 1 )); then
    # No binary switch occurred. Restart the known-good service; a partial
    # backup archive, if any, is not used for recovery.
    [[ -f "$BACKUP" && $BACKUP_READY -eq 0 ]] && rm -f -- "$BACKUP" || true
    systemctl start bindery || true
  fi
  exit "$ec"
}
trap update_error ERR

echo "[Bindery] Stopping service cleanly..."
systemctl stop bindery
SERVICE_STOPPED=1

echo "[Bindery] Backing up application data to $BACKUP"
tar -C "$DATA_DIR" -czf "$BACKUP" .
BACKUP_READY=1

ln -sfn "$TARGET" "$CURRENT_LINK"
SWITCHED=1
echo "$TAG" > /opt/bindery/VERSION
# A failed start is handled by the health loop and rollback below.
systemctl start bindery || true

healthy=0
for _ in $(seq 1 30); do
  if bindery_is_healthy; then
    healthy=1
    break
  fi
  sleep 1
done

if (( healthy == 1 )); then
  SERVICE_STOPPED=0
  trap - ERR
  echo "[Bindery] Updated successfully: $CURRENT_VERSION -> $TAG"
else
  echo "[Bindery] New release failed Bindery's built-in healthcheck. Rolling back binary AND data..." >&2
  trap - ERR
  restore_previous || true
  exit 1
fi

# Keep recent releases; never delete the currently selected target.
CURRENT_REAL=$(readlink -f "$CURRENT_LINK")
mapfile -t OLD_RELEASES < <(find "$RELEASE_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' | sort -nr | awk -v keep="$KEEP_RELEASES" 'NR>keep {$1=""; sub(/^ /,""); print}')
for old in "${OLD_RELEASES[@]:-}"; do
  if [[ -n "$old" && "$old" != "$CURRENT_REAL" ]]; then
    rm -rf -- "$old" || echo "[Bindery] Warning: could not remove old release: $old" >&2
  fi
done

mapfile -t OLD_BACKUPS < <(find "$BACKUP_ROOT" -maxdepth 1 -type f -name 'pre-*.tar.gz' -printf '%T@ %p\n' | sort -nr | awk -v keep="$KEEP_BACKUPS" 'NR>keep {$1=""; sub(/^ /,""); print}')
for old in "${OLD_BACKUPS[@]:-}"; do
  if [[ -n "$old" ]]; then
    rm -f -- "$old" || echo "[Bindery] Warning: could not remove old backup: $old" >&2
  fi
done
UPDATER_EOF

  cat >"$INNER_DIR/bindery-backup" <<'BACKUP_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID} -eq 0 ]] || { echo "Run as root."; exit 1; }
DEST="/var/backups/bindery/manual-$(date +%Y%m%d-%H%M%S).tar.gz"
mkdir -p /var/backups/bindery
systemctl stop bindery
trap 'systemctl start bindery >/dev/null 2>&1 || true' EXIT
tar -C / -czf "$DEST" \
  var/lib/bindery \
  etc/bindery \
  etc/systemd/system/bindery.service \
  opt/bindery/VERSION 2>/dev/null
systemctl start bindery
trap - EXIT
echo "$DEST"
BACKUP_EOF

  cat >"$INNER_DIR/bindery.service" <<'SERVICE_EOF'
[Unit]
Description=Bindery Book and Audiobook Manager
Documentation=https://github.com/vavallee/bindery
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=bindery
Group=bindery
EnvironmentFile=/etc/bindery/bindery.env
WorkingDirectory=/var/lib/bindery
ExecStart=/opt/bindery/current/bindery
Restart=on-failure
RestartSec=5
TimeoutStopSec=45
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
SERVICE_EOF

  cat >"$INNER_DIR/motd" <<'MOTD_EOF'
#!/usr/bin/env bash
if [[ -t 1 ]]; then
  ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  ver=$(cat /opt/bindery/VERSION 2>/dev/null || echo unknown)
  printf '\nBindery %s\n' "$ver"
  printf '  Web UI : http://%s:8787\n' "${ip:-<container-ip>}"
  printf '  Update : update\n'
  printf '  Logs   : journalctl -u bindery -f\n\n'
fi
MOTD_EOF

  cat >"$INNER_DIR/install-inner.sh" <<'INSTALL_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

DOWNLOAD_DIR=${1:?missing downloads directory argument}
AUDIOBOOK_DIR=${2:?missing audiobook directory argument}

apt-get update
apt-get -y dist-upgrade
apt-get install -y --no-install-recommends \
  ca-certificates curl jq tar gzip sqlite3 nano less procps iproute2 util-linux

if ! getent group bindery >/dev/null; then
  groupadd --gid 1000 bindery
fi
if ! id bindery >/dev/null 2>&1; then
  useradd --uid 1000 --gid 1000 --system --home-dir /var/lib/bindery --shell /usr/sbin/nologin bindery
fi

mkdir -p /opt/bindery/releases /var/lib/bindery /var/backups/bindery /etc/bindery
chown -R bindery:bindery /var/lib/bindery
chmod 0750 /var/lib/bindery
install -m 0644 /tmp/bindery.env /etc/bindery/bindery.env

install -m 0755 /tmp/bindery-update /usr/local/sbin/bindery-update
ln -sfn /usr/local/sbin/bindery-update /usr/bin/update
install -m 0755 /tmp/bindery-backup /usr/local/sbin/bindery-backup
install -m 0644 /tmp/bindery.service /etc/systemd/system/bindery.service
install -m 0755 /tmp/bindery-motd /etc/profile.d/90-bindery.sh

/usr/local/sbin/bindery-update --install

systemctl daemon-reload
systemctl enable bindery

# Validate the two paths as the exact UID that Bindery will use. The host
# helper passes them as argv values, so paths with spaces/metacharacters remain
# data and are never evaluated as shell source.
if ! runuser -u bindery -- test -r "$DOWNLOAD_DIR" || ! runuser -u bindery -- test -x "$DOWNLOAD_DIR"; then
  echo "Bindery UID 1000 cannot read/traverse the downloads directory: $DOWNLOAD_DIR" >&2
  exit 1
fi
if ! runuser -u bindery -- test -r "$AUDIOBOOK_DIR" || ! runuser -u bindery -- test -w "$AUDIOBOOK_DIR" || ! runuser -u bindery -- test -x "$AUDIOBOOK_DIR"; then
  echo "Bindery UID 1000 cannot read/write/traverse the audiobook directory: $AUDIOBOOK_DIR" >&2
  exit 1
fi

systemctl start bindery || true
healthy=0
for _ in $(seq 1 30); do
  if systemctl is-active --quiet bindery && runuser -u bindery -- env BINDERY_PORT=8787 /opt/bindery/current/bindery healthcheck >/dev/null 2>&1; then
    healthy=1
    break
  fi
  sleep 1
done
if (( healthy == 0 )); then
  echo "Bindery did not pass its built-in healthcheck after installation." >&2
  journalctl -u bindery -n 80 --no-pager >&2 || true
  systemctl stop bindery >/dev/null 2>&1 || true
  exit 1
fi

apt-get autoremove -y
apt-get clean
rm -rf /var/lib/apt/lists/*
INSTALL_EOF

  chmod +x "$INNER_DIR/bindery-update" "$INNER_DIR/bindery-backup" "$INNER_DIR/install-inner.sh" "$INNER_DIR/motd"
}

systemd_env_escape() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '%s' "$s"
}

make_env_file() {
  local remap_line=""
  if [[ -n "$DOWNLOAD_PATH_REMAP" ]]; then
    remap_line="BINDERY_DOWNLOAD_PATH_REMAP=\"$(systemd_env_escape "$DOWNLOAD_PATH_REMAP")\""
  fi

  cat >"$INNER_DIR/bindery.env" <<EOF
BINDERY_PORT="$DEFAULT_PORT"
BINDERY_DATA_DIR="/var/lib/bindery"
BINDERY_DB_PATH="/var/lib/bindery/bindery.db"
BINDERY_LOG_LEVEL="info"
BINDERY_DOWNLOAD_DIR="$(systemd_env_escape "$DOWNLOAD_CT")"
BINDERY_AUDIOBOOK_DOWNLOAD_DIR="$(systemd_env_escape "$DOWNLOAD_CT")"
BINDERY_LIBRARY_DIR="$(systemd_env_escape "$LIBRARY_CT")"
BINDERY_AUDIOBOOK_DIR="$(systemd_env_escape "$AUDIOBOOK_CT")"
BINDERY_PUID="$BINDERY_UID"
BINDERY_PGID="$BINDERY_GID"
${remap_line}
EOF
}

# ---------- create LXC ----------
create_lxc() {
  local net0 timezone
  get_debian13_template
  timezone=$(timedatectl show -p Timezone --value 2>/dev/null || echo "Etc/UTC")

  net0="name=eth0,bridge=$BRIDGE"
  [[ -n "$VLAN" ]] && net0+=",tag=$VLAN"
  if [[ "$IPV4_MODE" == "dhcp" ]]; then
    net0+=",ip=dhcp"
  else
    net0+=",ip=$IPV4_CIDR,gw=$GATEWAY"
  fi
  net0+=",ip6=auto"

  msg_info "Creating Debian 13 LXC $CTID"
  local create_args=(
    "$CTID" "$TEMPLATE_VOLID"
    --hostname "$HOSTNAME"
    --ostype debian
    --cores "$CORES"
    --memory "$RAM"
    --swap "$SWAP"
    --rootfs "${ROOTFS_STORAGE}:${DISK}"
    --net0 "$net0"
    --unprivileged "$UNPRIVILEGED"
    --onboot "$ONBOOT"
    --tags "$TAGS"
  )
  [[ -n "$DNS" ]] && create_args+=(--nameserver "$DNS")
  [[ -n "$ROOT_PASSWORD" ]] && create_args+=(--password "$ROOT_PASSWORD")

  pct create "${create_args[@]}"
  msg_ok "Created LXC $CTID"

  if [[ "$MEDIA_LAYOUT" == "single" ]]; then
    pct set "$CTID" -mp0 "${MEDIA_HOST_BASE},mp=/data,backup=0" >/dev/null
  else
    pct set "$CTID" -mp0 "${DOWNLOAD_PATH},mp=/data/downloads,backup=0" >/dev/null
    pct set "$CTID" -mp1 "${AUDIOBOOK_PATH},mp=/data/audiobooks,backup=0" >/dev/null
  fi
  msg_ok "Attached media storage"

  pct set "$CTID" --description "Bindery audiobook/book manager - installed by Bindery LXC Helper" >/dev/null

  configure_host_permissions

  pct start "$CTID"
  msg_info "Waiting for the container network to initialize"
  local network_ok=0
  for _ in $(seq 1 40); do
    if pct exec "$CTID" -- ping -c1 -W1 1.1.1.1 >/dev/null 2>&1 || pct exec "$CTID" -- getent hosts github.com >/dev/null 2>&1; then
      network_ok=1
      break
    fi
    sleep 1
  done
  if (( network_ok == 0 )); then
    msg_warn "The LXC started, but internet/DNS is not ready. Enter it with 'pct enter $CTID' to check networking."
    return 1
  fi
  msg_ok "Container network is online"

  pct exec "$CTID" -- timedatectl set-timezone "$timezone" >/dev/null 2>&1 || true

  if (( ENABLE_SSH == 1 )); then
    msg_info "Installing OpenSSH server"
    pct exec "$CTID" -- bash -lc 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-server && systemctl enable --now ssh' >/dev/null
    # Root password authentication is explicitly enabled only when the user selected SSH.
    pct exec "$CTID" -- bash -lc "printf 'PermitRootLogin yes\\nPasswordAuthentication yes\\n' >/etc/ssh/sshd_config.d/99-bindery-helper.conf && systemctl restart ssh"
    msg_ok "Configured SSH"
  fi

  make_inner_files
  make_env_file

  pct push "$CTID" "$INNER_DIR/bindery-update" /tmp/bindery-update -perms 0755
  pct push "$CTID" "$INNER_DIR/bindery-backup" /tmp/bindery-backup -perms 0755
  pct push "$CTID" "$INNER_DIR/bindery.service" /tmp/bindery.service -perms 0644
  pct push "$CTID" "$INNER_DIR/motd" /tmp/bindery-motd -perms 0755
  pct push "$CTID" "$INNER_DIR/bindery.env" /tmp/bindery.env -perms 0644
  pct push "$CTID" "$INNER_DIR/install-inner.sh" /tmp/install-bindery.sh -perms 0755

  msg_info "Installing Bindery and dependencies inside LXC $CTID"
  pct exec "$CTID" -- bash /tmp/install-bindery.sh "$DOWNLOAD_CT" "$AUDIOBOOK_CT"
  msg_ok "Installed Bindery"

  # Marker used by the host-side manage menu. Write it as data on the host and
  # push it into the CT; do not interpolate media paths into `bash -lc`.
  {
    printf 'HELPER_VERSION=1\n'
    printf 'PORT=%s\n' "$DEFAULT_PORT"
    printf 'DOWNLOAD_DIR=%s\n' "$DOWNLOAD_CT"
    printf 'AUDIOBOOK_DIR=%s\n' "$AUDIOBOOK_CT"
    printf 'MEDIA_LAYOUT=%s\n' "$MEDIA_LAYOUT"
  } >"$INNER_DIR/bindery-helper.conf"
  pct push "$CTID" "$INNER_DIR/bindery-helper.conf" /etc/bindery-helper.conf -perms 0644

  local ip version
  ip=$(get_ct_ip "$CTID")
  version=$(pct exec "$CTID" -- cat /opt/bindery/VERSION 2>/dev/null || echo "latest")

  header
  echo -e "${GREEN}${BOLD}Bindery installation completed successfully.${RESET}\n"
  echo -e "  CT ID:       ${BOLD}$CTID${RESET}"
  echo -e "  Hostname:    ${BOLD}$HOSTNAME${RESET}"
  echo -e "  Version:     ${BOLD}$version${RESET}"
  echo -e "  Web UI:      ${BOLD}http://${ip:-<container-ip>}:$DEFAULT_PORT${RESET}"
  echo -e "  Downloads:   ${BOLD}$DOWNLOAD_CT${RESET}"
  echo -e "  Audiobooks:  ${BOLD}$AUDIOBOOK_CT${RESET}"
  echo -e "  Hardlinks:   ${BOLD}$HARDLINK_STATUS${RESET}\n"
  echo -e "Inside the LXC:"
  echo -e "  ${CYAN}update${RESET}                       Update Bindery"
  echo -e "  ${CYAN}bindery-backup${RESET}               Backup Bindery data/config"
  echo -e "  ${CYAN}journalctl -u bindery -f${RESET}     Follow logs"
  echo -e "  ${CYAN}systemctl status bindery${RESET}      Service status\n"

  if [[ -n "$DOWNLOAD_PATH_REMAP" ]]; then
    echo -e "Configured download-client remap: ${BOLD}$DOWNLOAD_PATH_REMAP${RESET}\n"
  else
    echo -e "${YELLOW}When adding qBittorrent, make sure the path it reports exists inside Bindery,"
    echo -e "or configure a per-client path remap under Bindery's download-client settings.${RESET}\n"
  fi
}

get_ct_ip() {
  local id="$1" ip=""
  ip=$(pct exec "$id" -- bash -lc "ip -4 -o addr show dev eth0 2>/dev/null | awk '{print \\$4}' | cut -d/ -f1 | head -n1" 2>/dev/null || true)
  echo "$ip"
}

# ---------- existing-container management ----------
find_bindery_cts() {
  local cfg id name status tags
  for cfg in /etc/pve/lxc/*.conf; do
    [[ -e "$cfg" ]] || continue
    id=$(basename "$cfg" .conf)
    name=$(awk -F': ' '$1=="hostname" {print $2; exit}' "$cfg")
    tags=$(awk -F': ' '$1=="tags" {print $2; exit}' "$cfg")
    status=$(pct status "$id" 2>/dev/null | awk '{print $2}')
    if [[ ";$tags;" == *";bindery;"* || "${name,,}" == *bindery* ]]; then
      echo "$id|${name:-unnamed}|${status:-unknown}"
    fi
  done
}

select_bindery_ct() {
  local -a opts=()
  local id name status
  while IFS='|' read -r id name status; do
    opts+=("$id" "$name | $status")
  done < <(find_bindery_cts)

  if (( ${#opts[@]} == 0 )); then
    wt_msg "No Bindery LXC" "No LXC tagged 'bindery' or named with 'bindery' was found."
    return 1
  fi

  whiptail --backtitle "Bindery Proxmox VE Helper" --title "Select Bindery LXC" \
    --menu "Choose a container:" 18 78 8 "${opts[@]}" 3>&1 1>&2 2>&3
}

ensure_ct_running() {
  local id="$1"
  if ! pct status "$id" 2>/dev/null | grep -q 'status: running'; then
    if wt_yesno "Start Container" "LXC $id is stopped. Start it now?"; then
      pct start "$id"
    else
      return 1
    fi
  fi
}

manage_existing() {
  local id action
  id=$(select_bindery_ct) || return 0

  action=$(whiptail --backtitle "Bindery Proxmox VE Helper" --title "Manage Bindery LXC $id" \
    --menu "Choose an action:" 21 82 10 \
    "update" "Update Bindery to the latest official GitHub release" \
    "backup" "Create a Bindery database/config backup" \
    "restart" "Restart the Bindery systemd service" \
    "status" "Show version, IP, mounts and service status" \
    "logs" "Show the latest Bindery service logs" \
    "shell" "Enter the LXC shell" \
    3>&1 1>&2 2>&3) || return 0

  ensure_ct_running "$id" || return 0

  case "$action" in
    update)
      header
      msg_info "Updating Bindery in LXC $id"
      pct exec "$id" -- /usr/local/sbin/bindery-update
      msg_ok "Update command completed"
      ;;
    backup)
      header
      msg_info "Creating Bindery backup in LXC $id"
      local dest
      dest=$(pct exec "$id" -- /usr/local/sbin/bindery-backup)
      msg_ok "Backup created: $dest"
      ;;
    restart)
      pct exec "$id" -- systemctl restart bindery
      wt_msg "Restarted" "Bindery was restarted in LXC $id."
      ;;
    status)
      header
      local ip ver
      ip=$(get_ct_ip "$id")
      ver=$(pct exec "$id" -- cat /opt/bindery/VERSION 2>/dev/null || echo unknown)
      echo -e "${BOLD}LXC:${RESET}      $id"
      echo -e "${BOLD}Version:${RESET}  $ver"
      echo -e "${BOLD}Web UI:${RESET}   http://${ip:-<unknown>}:$DEFAULT_PORT"
      echo -e "\n${BOLD}Mounts:${RESET}"
      pct config "$id" | grep -E '^mp[0-9]+:' || echo "  none"
      echo -e "\n${BOLD}Service:${RESET}"
      pct exec "$id" -- systemctl --no-pager --full status bindery || true
      ;;
    logs)
      header
      pct exec "$id" -- journalctl -u bindery -n 100 --no-pager || true
      ;;
    shell)
      echo "Type 'exit' to return to the Proxmox host."
      pct enter "$id"
      ;;
  esac

  echo
  read -r -p "Press Enter to continue..." _ || true
}

# ---------- main ----------
install_new() {
  local mode
  mode=$(whiptail --backtitle "Bindery Proxmox VE Helper" --title "Create Bindery LXC" \
    --menu "Choose the container setup mode.\n\nThe LXC root disk storage is selected separately from media storage in the next step. Downloads and audiobooks are selected afterwards from mounted host filesystems." \
    20 96 7 \
    "default" "Default resources/network; you still choose LXC root storage" \
    "advanced" "Advanced: CT ID, CPU/RAM, disk size, network, VLAN, SSH, privilege" \
    3>&1 1>&2 2>&3) || return 0

  if [[ "$mode" == "default" ]]; then
    default_settings || return 0
  else
    until advanced_settings; do :; done
  fi

  ROOTFS_STORAGE=$(select_rootfs_storage) || return 0

  wt_msg "Media Storage" \
    "Root disk selected:\n  ${ROOTFS_STORAGE}:${DISK} GB\n\nNext you will select Downloads and Audiobook folders. These are host bind mounts and are completely separate from the LXC root disk storage." 17 88

  while ! select_media_storage; do
    if ! wt_yesno "Media Storage" "The media selection was cancelled or invalid. Retry the Downloads/Audiobook storage wizard?" 12 78; then
      return 0
    fi
  done
  select_permission_mode || return 0

  if summary_and_confirm; then
    create_lxc
  else
    wt_msg "Cancelled" "No container was created."
  fi
}

main_menu() {
  while true; do
    header
    local choice
    choice=$(whiptail --backtitle "Bindery Proxmox VE Helper" --title "Main Menu" \
      --menu "Install or manage Bindery on Proxmox VE:" 18 82 8 \
      "install" "Create a new Bindery Debian 13 LXC" \
      "manage" "Update / backup / inspect an existing Bindery LXC" \
      "exit" "Exit" \
      3>&1 1>&2 2>&3) || exit 0

    case "$choice" in
      install) install_new; read -r -p "Press Enter to return to the menu..." _ || true ;;
      manage) manage_existing ;;
      exit) exit 0 ;;
    esac
  done
}

preflight
header
main_menu
