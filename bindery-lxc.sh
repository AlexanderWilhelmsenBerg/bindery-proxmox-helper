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
  [[ "$ip" != "0.0.0.0" && "$ip" != "255.255.255.255" ]]
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
        path_is_protected_host_path "$target" && continue
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

mount_fstype_is_eligible() {
  [[ "$1" != "" && ! "$1" =~ ^(proc|sysfs|devtmpfs|devpts|tmpfs|cgroup|cgroup2|securityfs|pstore|debugfs|tracefs|configfs|fusectl|mqueue|hugetlbfs|rpc_pipefs|efivarfs)$ ]]
}

mount_target_is_eligible() {
  local target="$1"
  [[ "$target" =~ ^/(proc|sys|dev|run)(/|$) ]] && return 1
  [[ "$target" =~ ^/etc/pve(/|$) ]] && return 1
  return 0
}

# Return success when a canonical host path is too broad or contains host/PVE
# state that must never be exposed to the container. Purpose-built media
# directories below /mnt, /media, /srv, or /home remain supported.
path_is_protected_host_path() {
  local canonical
  canonical=$(realpath -m -- "$1")
  case "$canonical" in
    /|/bin|/bin/*|/boot|/boot/*|/dev|/dev/*|/etc|/etc/*|/lib|/lib/*|/lib32|/lib32/*|/lib64|/lib64/*|/opt|/opt/*|/proc|/proc/*|/root|/root/*|/run|/run/*|/sbin|/sbin/*|/sys|/sys/*|/tmp|/tmp/*|/usr|/usr/*)
      return 0
      ;;
    /var|/var/lib|/var/lib/*|/var/cache|/var/cache/*|/var/log|/var/log/*|/var/run|/var/run/*|/var/spool|/var/spool/*|/var/tmp|/var/tmp/*)
      return 0
      ;;
    /home|/media|/mnt|/mnt/pve|/srv|*/lost+found)
      return 0
      ;;
  esac
  return 1
}

validate_bind_mount_path() {
  local path="$1" canonical
  [[ -d "$path" ]] || return 1
  [[ "$path" != *','* && "$path" != *$'\n'* && "$path" != *$'\r'* && "$path" != *$'\t'* ]] || return 1
  canonical=$(realpath -e -- "$path" 2>/dev/null) || return 1
  [[ "$canonical" == "$path" ]] || return 1
  ! path_is_protected_host_path "$canonical"
}

# Load the kernel mount identity containing a path into MOUNT_INFO_* globals.
# "mountpoint" requires the path itself to be an active mount point; "target"
# resolves the deepest mount containing the path.
load_mount_identity() {
  local path="$1" lookup="${2:-target}" json value
  if [[ "$lookup" == "mountpoint" ]]; then
    json=$(findmnt -J -M "$path" -o ID,TARGET,SOURCE,FSTYPE,UUID 2>/dev/null) || return 1
  else
    json=$(findmnt -J -T "$path" -o ID,TARGET,SOURCE,FSTYPE,UUID 2>/dev/null) || return 1
  fi

  MOUNT_INFO_ID=$(jq -er '.filesystems[0].id | tostring' <<<"$json") || return 1
  MOUNT_INFO_TARGET=$(jq -er '.filesystems[0].target' <<<"$json") || return 1
  MOUNT_INFO_SOURCE=$(jq -er '.filesystems[0].source' <<<"$json") || return 1
  MOUNT_INFO_FSTYPE=$(jq -er '.filesystems[0].fstype' <<<"$json") || return 1
  MOUNT_INFO_UUID=$(jq -r '.filesystems[0].uuid // ""' <<<"$json") || return 1
  MOUNT_INFO_TARGET=$(realpath -e -- "$MOUNT_INFO_TARGET" 2>/dev/null) || return 1

  for value in "$MOUNT_INFO_TARGET" "$MOUNT_INFO_SOURCE" "$MOUNT_INFO_FSTYPE" "$MOUNT_INFO_UUID"; do
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* && "$value" != *$'\t'* ]] || return 1
  done
}

capture_selected_mount() {
  local prefix="$1" drive="$2" path="$3"
  local selected_id selected_target selected_source selected_fstype selected_uuid

  load_mount_identity "$drive" mountpoint || return 1
  mount_target_is_eligible "$MOUNT_INFO_TARGET" || return 1
  mount_fstype_is_eligible "$MOUNT_INFO_FSTYPE" || return 1
  [[ "$MOUNT_INFO_TARGET" == "$drive" ]] || return 1
  selected_id=$MOUNT_INFO_ID
  selected_target=$MOUNT_INFO_TARGET
  selected_source=$MOUNT_INFO_SOURCE
  selected_fstype=$MOUNT_INFO_FSTYPE
  selected_uuid=$MOUNT_INFO_UUID

  load_mount_identity "$path" target || return 1
  [[ "$MOUNT_INFO_ID" == "$selected_id" && "$MOUNT_INFO_TARGET" == "$selected_target" ]] || return 1

  printf -v "${prefix}_MOUNT_ID" '%s' "$selected_id"
  printf -v "${prefix}_MOUNT_TARGET" '%s' "$selected_target"
  printf -v "${prefix}_MOUNT_SOURCE" '%s' "$selected_source"
  printf -v "${prefix}_MOUNT_FSTYPE" '%s' "$selected_fstype"
  printf -v "${prefix}_MOUNT_UUID" '%s' "$selected_uuid"
}

revalidate_selected_mount() {
  local prefix="$1" drive="$2" path="$3"
  local name expected_id expected_target expected_source expected_fstype expected_uuid
  name="${prefix}_MOUNT_ID"; expected_id=${!name}
  name="${prefix}_MOUNT_TARGET"; expected_target=${!name}
  name="${prefix}_MOUNT_SOURCE"; expected_source=${!name}
  name="${prefix}_MOUNT_FSTYPE"; expected_fstype=${!name}
  name="${prefix}_MOUNT_UUID"; expected_uuid=${!name}

  [[ "$(realpath -e -- "$drive" 2>/dev/null)" == "$drive" ]] || return 1
  validate_bind_mount_path "$path" || return 1
  load_mount_identity "$drive" mountpoint || return 1
  [[ "$MOUNT_INFO_ID" == "$expected_id" && "$MOUNT_INFO_TARGET" == "$expected_target" \
      && "$MOUNT_INFO_SOURCE" == "$expected_source" && "$MOUNT_INFO_FSTYPE" == "$expected_fstype" \
      && "$MOUNT_INFO_UUID" == "$expected_uuid" ]] || return 1
  load_mount_identity "$path" target || return 1
  [[ "$MOUNT_INFO_ID" == "$expected_id" && "$MOUNT_INFO_TARGET" == "$expected_target" ]]
}

revalidate_media_mounts() {
  revalidate_selected_mount DOWNLOAD "$DOWNLOAD_DRIVE" "$DOWNLOAD_PATH" \
    && revalidate_selected_mount AUDIOBOOK "$AUDIOBOOK_DRIVE" "$AUDIOBOOK_PATH" \
    || return 1
  if [[ "$MEDIA_LAYOUT" == "single" ]]; then
    validate_bind_mount_path "$MEDIA_HOST_BASE" || return 1
    load_mount_identity "$MEDIA_HOST_BASE" target || return 1
    [[ "$MOUNT_INFO_ID" == "$DOWNLOAD_MOUNT_ID" && "$MOUNT_INFO_TARGET" == "$DOWNLOAD_MOUNT_TARGET" ]] || return 1
  fi
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
      "The selected media paths must be dedicated, canonical media directories without commas or symlink components. Host system/PVE paths and overly broad roots such as /, /var, /etc, /mnt, and /mnt/pve are never exposed.\n\nDownloads: $DOWNLOAD_PATH\nAudiobooks: $AUDIOBOOK_PATH" 21 96
    return 1
  fi

  if ! capture_selected_mount DOWNLOAD "$DOWNLOAD_DRIVE" "$DOWNLOAD_PATH" \
      || ! capture_selected_mount AUDIOBOOK "$AUDIOBOOK_DRIVE" "$AUDIOBOOK_PATH"; then
    wt_msg "Media Mount Changed" \
      "A selected folder is not on the exact eligible mount that you chose. This can happen when a network/disk mount went offline, a path crosses into a nested mount, or the mount changed during selection.\n\nNo bind mount will be created. Restore the host mount and select the folders again." 19 92
    return 1
  fi

  if [[ "$DOWNLOAD_MOUNT_ID" == "$AUDIOBOOK_MOUNT_ID" ]]; then
    MEDIA_HOST_BASE=$(common_ancestor "$DOWNLOAD_PATH" "$AUDIOBOOK_PATH")
    # The common path must be safe and resolve to the same live kernel mount as
    # both leaves. Otherwise a nested mount boundary could make the apparent
    # common ancestor unsafe for hardlinks or expose an underlying directory.
    local common_mount_ok=0
    if validate_bind_mount_path "$MEDIA_HOST_BASE" \
        && load_mount_identity "$MEDIA_HOST_BASE" target \
        && [[ "$MOUNT_INFO_ID" == "$DOWNLOAD_MOUNT_ID" && "$MOUNT_INFO_TARGET" == "$DOWNLOAD_MOUNT_TARGET" ]]; then
      common_mount_ok=1
    fi
    if (( common_mount_ok == 1 )); then
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
      HARDLINK_STATUS="NO - safe split mounts; common parent is protected or crosses a mount"
      wt_msg "Safe Storage Layout" \
        "The folders share a filesystem, but their common parent is protected or does not have the same live mount identity as both selected folders.\n\nThe helper will use two narrow folder mounts instead of exposing that parent. Bindery will copy rather than hardlink between them." 19 90
    fi
  else
    MEDIA_LAYOUT="split"
    MEDIA_HOST_BASE=""
    DOWNLOAD_CT="/data/downloads"
    AUDIOBOOK_CT="/data/audiobooks"
    HARDLINK_STATUS="NO - separate LXC mounts; Bindery will fall back to copy"
    wt_msg "Separate filesystems" \
      "Downloads and audiobooks have different live mount identities.\n\nThis is fully supported, but Bindery cannot hardlink between separate LXC mounts. Completed audiobooks will normally be copied into the library instead.\n\nFor zero-copy imports/seeding, keep both folders on one filesystem under one safe common parent mount." 19 88
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
select_ipv6_mode() {
  IPV6_MODE=$(whiptail --backtitle "Bindery Proxmox VE Helper" --title "IPv6" \
    --menu "Choose how Proxmox should configure IPv6 for this container:" \
    17 86 6 \
    "auto" "SLAAC/router advertisements (recommended when IPv6 is available)" \
    "dhcp" "Use DHCPv6" \
    "manual" "Do not configure an IPv6 address automatically" \
    3>&1 1>&2 2>&3) || return 1
}

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
  TELEMETRY_DISABLED=1
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

select_telemetry() {
  local choice
  choice=$(whiptail --backtitle "Bindery Proxmox VE Helper" --title "Bindery Telemetry" \
    --menu "Upstream Bindery release builds normally send a telemetry ping immediately on first start and then once per day to api.getbindery.dev. The report includes a persistent installation ID, version/platform/deployment details, feature and setup counts, and coarse error metrics.\n\nChoose before Bindery is installed:" \
    22 100 8 \
    "disabled" "Disable before first start (recommended; no telemetry ping)" \
    "enabled" "Allow Bindery's upstream anonymous usage telemetry" \
    3>&1 1>&2 2>&3) || return 1

  if [[ "$choice" == "enabled" ]]; then
    TELEMETRY_DISABLED=0
  else
    TELEMETRY_DISABLED=1
  fi
}

summary_and_confirm() {
  local priv="Unprivileged" network media ipv6 telemetry
  (( UNPRIVILEGED == 0 )) && priv="Privileged"
  if [[ "$IPV4_MODE" == "dhcp" ]]; then
    network="DHCP"
  else
    network="$IPV4_CIDR via $GATEWAY"
  fi
  case "$IPV6_MODE" in
    auto) ipv6="SLAAC / auto" ;;
    dhcp) ipv6="DHCPv6" ;;
    manual) ipv6="Manual / no automatic address" ;;
  esac
  if [[ "$MEDIA_LAYOUT" == "single" ]]; then
    media="ONE mount: $MEDIA_HOST_BASE -> /data"
  else
    media="TWO mounts: downloads + audiobooks"
  fi

  local remap="None"
  [[ -n "$DOWNLOAD_PATH_REMAP" ]] && remap="$DOWNLOAD_PATH_REMAP"
  if (( TELEMETRY_DISABLED == 1 )); then
    telemetry="Disabled before first start"
  else
    telemetry="Enabled for upstream Bindery"
  fi

  wt_yesno "Ready to Create" \
"Bindery LXC configuration

CT ID:             $CTID
Hostname:          $HOSTNAME
Debian:            13
CPU / RAM / Swap:  $CORES core(s) / ${RAM} MB / ${SWAP} MB
Root disk:         ${DISK} GB on $ROOTFS_STORAGE
Container:         $priv
Network:           $BRIDGE | $network${VLAN:+ | VLAN $VLAN}
IPv6:              $ipv6
Start on boot:     $ONBOOT
SSH:               $ENABLE_SSH

Downloads host:    $DOWNLOAD_PATH
Audiobooks host:   $AUDIOBOOK_PATH
Media mount:       $media
Mount liveness:    Host pre-start guard
Downloads in CT:   $DOWNLOAD_CT
Audiobooks in CT:  $AUDIOBOOK_CT
Hardlink capable:  $HARDLINK_STATUS
Path remap:        $remap
Permission mode:   $PERMISSION_MODE
Telemetry:         $telemetry

Create the container now?" 35 104
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

path_has_nested_mounts() {
  local path="$1" json target
  local -a targets=()
  path=$(realpath -e -- "$path" 2>/dev/null) || return 2
  json=$(findmnt -J -R -T "$path" -o TARGET 2>/dev/null) || return 2
  jq -e '[.. | objects | .target? // empty]
    | all(.[]; type == "string"
        and (contains("\n") | not)
        and (contains("\r") | not)
        and (contains("\t") | not))' <<<"$json" >/dev/null || return 2
  mapfile -t targets < <(jq -r '.. | objects | .target? // empty' <<<"$json")
  for target in "${targets[@]}"; do
    [[ "$target" == "$path" ]] && continue
    if path_is_under "$path" "$target"; then
      return 0
    fi
  done
  return 1
}

filter_acl_paths_on_device() {
  local expected_dev="$1" entry entry_dev
  while IFS= read -r -d '' entry; do
    entry_dev=$(stat -Lc '%d' -- "$entry") || return 1
    if [[ "$entry_dev" == "$expected_dev" ]]; then
      printf '%s\0' "$entry"
    fi
  done
  return 0
}

apply_acl_batch_on_device() {
  local path="$1" expected_dev="$2" file_type="$3" acl_spec="$4" tmp
  tmp=$(mktemp) || return 1
  cleanup_files+=("$tmp")
  if ! find "$path" -xdev -type "$file_type" -print0 2>/dev/null \
      | filter_acl_paths_on_device "$expected_dev" >"$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! xargs -0 -r setfacl -m "$acl_spec" -- <"$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  rm -f -- "$tmp"
}

apply_acl_to_path() {
  local bind_base="$1" path="$2" uid="$3" recursive="$4" start_dev nested_status
  if (( recursive == 1 )); then
    start_dev=$(stat -Lc '%d' -- "$path") || return 1
    if path_has_nested_mounts "$path"; then
      # Refuse the recursive operation altogether rather than touching a child
      # mount root. The caller warns and leaves existing permissions in place.
      return 1
    else
      nested_status=$?
      (( nested_status == 1 )) || return 1
    fi
  fi

  grant_traverse_acl "$bind_base" "$path" "$uid" || return 1
  setfacl -m "u:${uid}:rwx,d:u:${uid}:rwx" -- "$path" || return 1

  if (( recursive == 1 )); then
    apply_acl_batch_on_device "$path" "$start_dev" d "u:${uid}:rwx,d:u:${uid}:rwx" || return 1
    apply_acl_batch_on_device "$path" "$start_dev" f "u:${uid}:rw" || return 1
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
LOCK_FILE="/run/lock/bindery-maintenance.lock"
FAIL_STATE_ROOT="/var/lib/bindery-maintenance"
FAIL_SENTINEL="$FAIL_STATE_ROOT/rollback-failed"
FAIL_DROPIN_DIR="/etc/systemd/system/bindery.service.d"
FAIL_DROPIN="$FAIL_DROPIN_DIR/90-rollback-failed.conf"
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

umask 0077
install -d -m 0755 "$INSTALL_ROOT" "$RELEASE_ROOT"
install -d -m 0700 "$BACKUP_ROOT"
install -d -o bindery -g bindery -m 0750 "$DATA_DIR"

# Updating and backing up both stop Bindery and snapshot mutable state. Keep
# those operations mutually exclusive so neither can capture a half-restore.
exec 9<>"$LOCK_FILE"
chmod 0600 "$LOCK_FILE"
if ! flock -n 9; then
  echo "Another Bindery update or backup is already running." >&2
  exit 1
fi

case "$(uname -m)" in
  x86_64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  armv7l) ARCH="armv7" ;;
  armv6l) ARCH="armv6" ;;
  *) echo "Unsupported architecture: $(uname -m)"; exit 1 ;;
esac

echo "[Bindery] Checking GitHub for the latest release..."
JSON=$(curl -fsSL --retry 3 --connect-timeout 10 \
  -H 'Accept: application/vnd.github+json' \
  -H 'X-GitHub-Api-Version: 2022-11-28' \
  "https://api.github.com/repos/${REPO}/releases/latest")
TAG=$(jq -r '.tag_name // empty' <<<"$JSON")
[[ -n "$TAG" ]] || { echo "Unable to determine latest release."; exit 1; }
[[ "$TAG" =~ ^v?[[:alnum:]][[:alnum:].+_-]*$ ]] || {
  echo "Refusing unsafe release tag: $TAG" >&2
  exit 1
}
VERSION="${TAG#v}"
TARGET="$RELEASE_ROOT/$TAG"

CURRENT_VERSION=""
PREVIOUS_TARGET=""
if [[ -L "$CURRENT_LINK" ]]; then
  PREVIOUS_TARGET=$(readlink -f "$CURRENT_LINK")
  CURRENT_VERSION=$(basename "$PREVIOUS_TARGET")
fi

if (( INSTALL_ONLY == 1 )) && [[ -n "$PREVIOUS_TARGET" ]]; then
  echo "--install is only valid for a fresh installation." >&2
  exit 2
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

TMP=$(mktemp -d /tmp/bindery-update.XXXXXX)
BACKUP=""
BACKUP_TMP=""
RESTORE_STAGE=""
RESTORE_OLD=""
VERIFY_UNIT=""
VERIFY_UNIT_FILE=""

cleanup_update() {
  local ec=$?
  trap - EXIT
  if [[ -n "${VERIFY_UNIT:-}" ]]; then
    systemctl stop "$VERIFY_UNIT" >/dev/null 2>&1 || true
  fi
  [[ -z "${VERIFY_UNIT_FILE:-}" ]] || rm -f -- "$VERIFY_UNIT_FILE" || true
  if [[ -n "${VERIFY_UNIT:-}" ]]; then
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
  [[ -z "${BACKUP_TMP:-}" ]] || rm -f -- "$BACKUP_TMP" || true
  [[ -z "${RESTORE_STAGE:-}" ]] || rm -rf -- "$RESTORE_STAGE" || true
  rm -rf -- "$TMP" || true
  exit "$ec"
}
trap cleanup_update EXIT

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

RELEASE_STAGE="$TARGET.new"
rm -rf -- "$RELEASE_STAGE"
install -d -m 0755 "$RELEASE_STAGE"
tar -xzf "$TMP/$ARCHIVE_NAME" -C "$RELEASE_STAGE"
[[ -x "$RELEASE_STAGE/bindery" || -f "$RELEASE_STAGE/bindery" ]] || {
  found=$(find "$RELEASE_STAGE" -maxdepth 3 -type f -name bindery -print -quit)
  [[ -n "$found" ]] || { echo "Bindery binary not found in archive."; exit 1; }
  cp -a "$found" "$RELEASE_STAGE/bindery"
}
chmod 0755 "$RELEASE_STAGE" "$RELEASE_STAGE/bindery"
rm -rf -- "$TARGET"
mv -- "$RELEASE_STAGE" "$TARGET"

if (( INSTALL_ONLY == 1 )) || [[ -z "$PREVIOUS_TARGET" ]]; then
  ln -sfn "$TARGET" "$CURRENT_LINK"
  printf '%s\n' "$TAG" > /opt/bindery/VERSION
  chmod 0644 /opt/bindery/VERSION
  echo "[Bindery] Installed $TAG."
  exit 0
fi

SAFE_TAG=${TAG//[^[:alnum:]._-]/_}
SERVICE_WAS_ACTIVE=0
SERVICE_WAS_ENABLED=0
MAINTENANCE_STARTED=0
SWITCHED=0
BACKUP_READY=0

# Read only the numeric port we need from EnvironmentFile. Do not `source` a
# systemd EnvironmentFile as shell code: valid media paths can contain shell
# metacharacters and systemd's quoting rules are not Bash's quoting rules.
HEALTH_PORT=8787
HEALTH_URL_BASE=""
if [[ -f "$ENV_FILE" ]]; then
  configured_port=$(sed -nE 's/^BINDERY_PORT="?([0-9]+)"?[[:space:]]*$/\1/p' "$ENV_FILE")
  configured_port=${configured_port%%$'\n'*}
  if [[ "$configured_port" =~ ^[0-9]+$ ]] && (( configured_port >= 1 && configured_port <= 65535 )); then
    HEALTH_PORT="$configured_port"
  fi
  configured_url_base=$(sed -nE 's/^BINDERY_URL_BASE="?([^"[:space:]]*)"?[[:space:]]*$/\1/p' "$ENV_FILE")
  configured_url_base=${configured_url_base%%$'\n'*}
  if [[ -n "$configured_url_base" && "$configured_url_base" == /* ]]; then
    HEALTH_URL_BASE="$configured_url_base"
    while [[ "$HEALTH_URL_BASE" == */ ]]; do
      HEALTH_URL_BASE=${HEALTH_URL_BASE%/}
    done
  fi
fi

bindery_endpoint_is_healthy() {
  local status
  status=$(curl -sS --connect-timeout 2 --max-time 5 \
    --output /dev/null --write-out '%{http_code}' \
    "http://127.0.0.1:${HEALTH_PORT}${HEALTH_URL_BASE}/api/v1/health" \
    2>/dev/null) || return 1
  [[ "$status" == "200" ]]
}

bindery_is_healthy() {
  systemctl is-active --quiet bindery \
    && bindery_endpoint_is_healthy
}

arm_fail_closed() {
  local reason=$1
  local active_state="" marker_tmp="" dropin_tmp="" failed=0

  systemctl stop bindery >/dev/null 2>&1 || failed=1
  if active_state=$(systemctl show bindery.service --property=ActiveState --value 2>/dev/null); then
    [[ "$active_state" == "inactive" || "$active_state" == "failed" ]] || failed=1
  else
    failed=1
  fi
  # Disable first. Even if power is lost while the remaining guard files are
  # being installed, the failed release cannot be activated automatically.
  systemctl disable bindery.service >/dev/null 2>&1 || failed=1
  sync -f /etc/systemd/system >/dev/null 2>&1 || failed=1

  # The runtime mask prevents an accidental start now. The persistent marker
  # and condition keep the unit fail-closed after a reboot, while disable
  # removes its normal boot-time activation symlink.
  if install -d -m 0755 "$FAIL_DROPIN_DIR"; then
    if dropin_tmp=$(mktemp "$FAIL_DROPIN_DIR/.rollback-failed.XXXXXX"); then
      if printf '[Unit]\nConditionPathExists=!%s\n' "$FAIL_SENTINEL" >"$dropin_tmp"; then
        if chmod 0644 "$dropin_tmp" \
            && mv -f -- "$dropin_tmp" "$FAIL_DROPIN" \
            && sync -f "$FAIL_DROPIN" >/dev/null 2>&1; then
          dropin_tmp=""
        else
          failed=1
        fi
      else
        failed=1
      fi
      [[ -z "$dropin_tmp" ]] || rm -f -- "$dropin_tmp" || true
    else
      failed=1
    fi
  else
    failed=1
  fi

  # Publish the marker only after the condition that consumes it is durable.
  if install -d -m 0700 "$FAIL_STATE_ROOT"; then
    if marker_tmp=$(mktemp "$FAIL_STATE_ROOT/.rollback-failed.XXXXXX"); then
      if printf '%s\nBackup: %s\nPreserved data: %s\n' \
          "$reason" "${BACKUP:-unavailable}" "${RESTORE_OLD:-unavailable}" >"$marker_tmp" \
          && chmod 0600 "$marker_tmp" \
          && mv -f -- "$marker_tmp" "$FAIL_SENTINEL" \
          && sync -f "$FAIL_SENTINEL" >/dev/null 2>&1; then
        marker_tmp=""
      else
        failed=1
      fi
      [[ -z "$marker_tmp" ]] || rm -f -- "$marker_tmp" || true
    else
      failed=1
    fi
  else
    failed=1
  fi

  [[ -f "$FAIL_DROPIN" && ! -L "$FAIL_DROPIN" ]] || failed=1
  [[ -f "$FAIL_SENTINEL" && ! -L "$FAIL_SENTINEL" ]] || failed=1
  systemctl daemon-reload >/dev/null 2>&1 || failed=1
  systemctl mask --runtime bindery.service >/dev/null 2>&1 || failed=1

  (( failed == 0 ))
}

persist_fail_closed() {
  local reason=$1
  if ! arm_fail_closed "$reason"; then
    echo "[Bindery] WARNING: the persistent recovery guard could not be fully installed." >&2
  fi

  echo "[Bindery] CRITICAL: $reason" >&2
  echo "[Bindery] Bindery is disabled and masked; recovery details: $FAIL_SENTINEL" >&2
}

clear_fail_closed() {
  rm -f -- "$FAIL_SENTINEL" "$FAIL_DROPIN" || return 1
  systemctl unmask --runtime bindery.service >/dev/null 2>&1 || return 1
  systemctl daemon-reload >/dev/null 2>&1 || return 1
  if (( SERVICE_WAS_ENABLED == 1 )); then
    systemctl enable bindery.service >/dev/null 2>&1 || return 1
  else
    systemctl disable bindery.service >/dev/null 2>&1 || return 1
  fi
}

verify_guarded_rollback() {
  local healthy=0 cleanup_failed=0
  VERIFY_UNIT="bindery-rollback-verify-$$.service"
  VERIFY_UNIT_FILE="/run/systemd/system/$VERIFY_UNIT"

  if ! printf '%s\n' \
      '[Unit]' \
      'Description=Temporary Bindery rollback verification' \
      '[Service]' \
      'Type=simple' \
      'User=bindery' \
      'Group=bindery' \
      "EnvironmentFile=$ENV_FILE" \
      "WorkingDirectory=$DATA_DIR" \
      "ExecStart=$CURRENT_LINK/bindery" \
      'Restart=no' \
      'TimeoutStopSec=45' >"$VERIFY_UNIT_FILE"; then
    return 1
  fi
  chmod 0644 "$VERIFY_UNIT_FILE" || return 1
  systemctl daemon-reload >/dev/null 2>&1 || return 1

  if systemctl start "$VERIFY_UNIT"; then
    for _ in $(seq 1 20); do
      if systemctl is-active --quiet "$VERIFY_UNIT" && bindery_endpoint_is_healthy; then
        healthy=1
        break
      fi
      sleep 1
    done
  fi

  if ! systemctl stop "$VERIFY_UNIT" >/dev/null 2>&1; then
    cleanup_failed=1
  fi
  if ! rm -f -- "$VERIFY_UNIT_FILE"; then
    cleanup_failed=1
  fi
  if ! systemctl daemon-reload >/dev/null 2>&1; then
    cleanup_failed=1
  fi
  VERIFY_UNIT=""
  VERIFY_UNIT_FILE=""

  (( healthy == 1 && cleanup_failed == 0 ))
}

restore_previous() {
  local data_parent restore_old_template
  local quick_check="" reason="" rollback_healthy=0
  echo "[Bindery] Restoring $CURRENT_VERSION..." >&2
  systemctl stop bindery >/dev/null 2>&1 || true

  if (( BACKUP_READY != 1 )) || [[ ! -f "$BACKUP" ]]; then
    reason="Rollback backup is not available; live data was not replaced."
    persist_fail_closed "$reason"
    return 1
  fi

  # Validate and extract away from the live directory. A corrupt archive can
  # therefore never destroy the only live copy before recovery is known-good.
  if ! tar -tzf "$BACKUP" >/dev/null; then
    reason="Rollback archive validation failed; live data was not replaced."
    persist_fail_closed "$reason"
    return 1
  fi

  data_parent=$(dirname "$DATA_DIR")
  if ! RESTORE_STAGE=$(mktemp -d "$data_parent/.bindery-restore.XXXXXX"); then
    reason="Could not create a rollback staging directory; live data was not replaced."
    persist_fail_closed "$reason"
    return 1
  fi
  if ! chmod 0750 "$RESTORE_STAGE"; then
    reason="Could not secure the rollback staging directory; live data was not replaced."
    persist_fail_closed "$reason"
    return 1
  fi
  if ! tar --extract --gzip --file="$BACKUP" --directory="$RESTORE_STAGE" --no-same-owner; then
    reason="Rollback archive extraction failed; live data was not replaced."
    persist_fail_closed "$reason"
    return 1
  fi
  if [[ -e "$RESTORE_STAGE/bindery.db" ]]; then
    if [[ ! -f "$RESTORE_STAGE/bindery.db" || -L "$RESTORE_STAGE/bindery.db" ]]; then
      reason="The staged Bindery database is not a regular file; live data was not replaced."
      persist_fail_closed "$reason"
      return 1
    fi
    if ! quick_check=$(sqlite3 -batch "$RESTORE_STAGE/bindery.db" 'PRAGMA quick_check;' 2>&1) \
        || [[ "$quick_check" != "ok" ]]; then
      reason="SQLite quick_check rejected the staged Bindery database; live data was not replaced."
      persist_fail_closed "$reason"
      return 1
    fi
  fi
  if ! chown -R -- bindery:bindery "$RESTORE_STAGE" || ! chmod 0750 "$RESTORE_STAGE"; then
    reason="Rollback staging permissions could not be secured; live data was not replaced."
    persist_fail_closed "$reason"
    return 1
  fi

  if ! restore_old_template=$(mktemp -d "$data_parent/.bindery-pre-rollback.XXXXXX"); then
    reason="Could not reserve a path for the migrated live data."
    persist_fail_closed "$reason"
    return 1
  fi
  if ! rmdir -- "$restore_old_template"; then
    reason="Could not prepare the path that preserves migrated live data."
    persist_fail_closed "$reason"
    return 1
  fi
  RESTORE_OLD="$restore_old_template"

  # Establish the reboot-persistent guard before the first rename. The normal
  # unit remains disabled and masked until the restored binary and data have
  # passed a health probe under a temporary verification unit.
  if ! arm_fail_closed "Rollback transaction in progress; verification has not completed."; then
    reason="Could not establish the persistent rollback guard; live data was not replaced."
    persist_fail_closed "$reason"
    return 1
  fi
  if ! mv -- "$DATA_DIR" "$RESTORE_OLD"; then
    reason="Could not preserve the migrated live data before rollback."
    persist_fail_closed "$reason"
    return 1
  fi
  if ! mv -- "$RESTORE_STAGE" "$DATA_DIR"; then
    mv -- "$RESTORE_OLD" "$DATA_DIR" >/dev/null 2>&1 || true
    reason="Could not activate staged rollback data; the migrated data was preserved."
    persist_fail_closed "$reason"
    return 1
  fi
  RESTORE_STAGE=""

  if ! ln -sfn "$PREVIOUS_TARGET" "$CURRENT_LINK" \
      || ! printf '%s\n' "$CURRENT_VERSION" > /opt/bindery/VERSION \
      || ! chmod 0644 /opt/bindery/VERSION; then
    reason="Restored data could not be paired with the previous Bindery release."
    persist_fail_closed "$reason"
    return 1
  fi

  if ! verify_guarded_rollback; then
    reason="The restored release and data did not pass guarded health verification."
    persist_fail_closed "$reason"
    return 1
  fi

  # It is now safe for the ordinary unit to start after a reboot.
  if ! clear_fail_closed; then
    reason="Rollback verified, but the persistent recovery guard could not be cleared."
    persist_fail_closed "$reason"
    return 1
  fi

  if (( SERVICE_WAS_ACTIVE == 1 )); then
    systemctl start bindery || true
    for _ in $(seq 1 20); do
      if bindery_is_healthy; then
        rollback_healthy=1
        break
      fi
      sleep 1
    done
    if (( rollback_healthy == 0 )); then
      reason="The normal Bindery service failed after guarded rollback verification."
      persist_fail_closed "$reason"
      return 1
    fi
  else
    systemctl stop bindery >/dev/null 2>&1 || true
  fi

  if ! rm -rf -- "$RESTORE_OLD"; then
    echo "[Bindery] Warning: preserved migrated data remains at $RESTORE_OLD" >&2
  else
    RESTORE_OLD=""
  fi
  echo "[Bindery] Rollback to $CURRENT_VERSION completed." >&2
  return 0
}

restore_unswitched_state() {
  if (( SERVICE_WAS_ACTIVE == 1 )); then
    if ! systemctl start bindery; then
      persist_fail_closed "The previous release could not be restarted after an interrupted update."
      return 1
    fi
  else
    systemctl stop bindery >/dev/null 2>&1 || true
  fi
}

recover_after_abort() {
  if (( SWITCHED == 1 )); then
    restore_previous || true
  elif (( MAINTENANCE_STARTED == 1 )); then
    restore_unswitched_state || true
  fi
}

update_error() {
  local ec=$?
  trap - ERR
  trap '' INT TERM HUP
  echo "[Bindery] Update failed (exit $ec). Recovering the previous service state..." >&2
  recover_after_abort
  exit "$ec"
}

update_signal() {
  local signal=$1 ec=1
  case "$signal" in
    HUP) ec=129 ;;
    INT) ec=130 ;;
    TERM) ec=143 ;;
  esac
  trap - ERR
  trap '' INT TERM HUP
  echo "[Bindery] Update received $signal. Recovering the previous service state..." >&2
  recover_after_abort
  exit "$ec"
}

trap update_error ERR
trap 'update_signal HUP' HUP
trap 'update_signal INT' INT
trap 'update_signal TERM' TERM

if systemctl is-active --quiet bindery; then
  SERVICE_WAS_ACTIVE=1
fi
if systemctl is-enabled --quiet bindery.service; then
  SERVICE_WAS_ENABLED=1
fi

echo "[Bindery] Stopping service cleanly..."
MAINTENANCE_STARTED=1
systemctl stop bindery

backup_stamp=$(date +%Y%m%d-%H%M%S)
BACKUP_TMP=$(mktemp "$BACKUP_ROOT/.pre-${SAFE_TAG}-${backup_stamp}.XXXXXX")
backup_tmp_name=${BACKUP_TMP##*/}
BACKUP="$BACKUP_ROOT/${backup_tmp_name#.}.tar.gz"
echo "[Bindery] Backing up application data to $BACKUP"
tar -C "$DATA_DIR" -czf "$BACKUP_TMP" .
tar -tzf "$BACKUP_TMP" >/dev/null
chmod 0600 "$BACKUP_TMP"
mv -- "$BACKUP_TMP" "$BACKUP"
BACKUP_TMP=""
BACKUP_READY=1

SWITCHED=1
ln -sfn "$TARGET" "$CURRENT_LINK"
printf '%s\n' "$TAG" > /opt/bindery/VERSION
chmod 0644 /opt/bindery/VERSION
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
  if (( SERVICE_WAS_ACTIVE == 0 )); then
    systemctl stop bindery
  fi
  MAINTENANCE_STARTED=0
  trap - ERR INT TERM HUP
  echo "[Bindery] Updated successfully: $CURRENT_VERSION -> $TAG"
else
  echo "[Bindery] New release failed Bindery's built-in healthcheck. Rolling back binary AND data..." >&2
  trap - ERR
  trap '' INT TERM HUP
  if ! restore_previous; then
    exit 1
  fi
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

BACKUP_ROOT="/var/backups/bindery"
LOCK_FILE="/run/lock/bindery-maintenance.lock"
umask 0077
install -d -m 0700 "$BACKUP_ROOT"

exec 9<>"$LOCK_FILE"
chmod 0600 "$LOCK_FILE"
if ! flock -n 9; then
  echo "Another Bindery update or backup is already running." >&2
  exit 1
fi

archive_stamp=$(date +%Y%m%d-%H%M%S)
TMP_ARCHIVE=$(mktemp "$BACKUP_ROOT/.manual-${archive_stamp}.XXXXXX")
tmp_name=${TMP_ARCHIVE##*/}
DEST="$BACKUP_ROOT/${tmp_name#.}.tar.gz"
SERVICE_WAS_ACTIVE=0
if systemctl is-active --quiet bindery; then
  SERVICE_WAS_ACTIVE=1
fi

backup_cleanup() {
  local ec=$?
  trap - EXIT
  trap '' INT TERM HUP
  [[ -z "${TMP_ARCHIVE:-}" ]] || rm -f -- "$TMP_ARCHIVE" || true
  if (( SERVICE_WAS_ACTIVE == 1 )); then
    systemctl start bindery >/dev/null 2>&1 || \
      echo "Bindery could not be restarted; inspect journalctl -u bindery -n 100." >&2
  fi
  exit "$ec"
}

backup_signal() {
  local signal=$1 ec=1
  case "$signal" in
    HUP) ec=129 ;;
    INT) ec=130 ;;
    TERM) ec=143 ;;
  esac
  exit "$ec"
}

trap backup_cleanup EXIT
trap 'backup_signal HUP' HUP
trap 'backup_signal INT' INT
trap 'backup_signal TERM' TERM

if (( SERVICE_WAS_ACTIVE == 1 )); then
  systemctl stop bindery
fi
tar -C / -czf "$TMP_ARCHIVE" \
  var/lib/bindery \
  etc/bindery \
  etc/systemd/system/bindery.service \
  opt/bindery/VERSION 2>/dev/null
tar -tzf "$TMP_ARCHIVE" >/dev/null
chmod 0600 "$TMP_ARCHIVE"
mv -- "$TMP_ARCHIVE" "$DEST"
TMP_ARCHIVE=""

if (( SERVICE_WAS_ACTIVE == 1 )); then
  systemctl start bindery
  SERVICE_WAS_ACTIVE=0
fi
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
  local remap_line="" telemetry_value="true"
  if [[ -n "$DOWNLOAD_PATH_REMAP" ]]; then
    remap_line="BINDERY_DOWNLOAD_PATH_REMAP=\"$(systemd_env_escape "$DOWNLOAD_PATH_REMAP")\""
  fi
  (( TELEMETRY_DISABLED == 0 )) && telemetry_value="false"

  cat >"$INNER_DIR/bindery.env" <<EOF
BINDERY_PORT="$DEFAULT_PORT"
BINDERY_DATA_DIR="/var/lib/bindery"
BINDERY_DB_PATH="/var/lib/bindery/bindery.db"
BINDERY_LOG_LEVEL="info"
BINDERY_TELEMETRY_DISABLED="$telemetry_value"
BINDERY_DOWNLOAD_DIR="$(systemd_env_escape "$DOWNLOAD_CT")"
BINDERY_AUDIOBOOK_DOWNLOAD_DIR="$(systemd_env_escape "$DOWNLOAD_CT")"
BINDERY_LIBRARY_DIR="$(systemd_env_escape "$LIBRARY_CT")"
BINDERY_AUDIOBOOK_DIR="$(systemd_env_escape "$AUDIOBOOK_CT")"
BINDERY_PUID="$BINDERY_UID"
BINDERY_PGID="$BINDERY_GID"
${remap_line}
EOF
}

# Install a host-side LXC pre-start hook. Unlike the one-time check during the
# wizard, this guard runs for manual starts, restarts, and onboot starts. It
# refuses to expose an underlying directory if a selected disk/network mount is
# absent, replaced, or shadowed by a nested mount.
install_media_mount_guard() {
  local guard_dir="/usr/local/libexec/bindery-lxc"
  local guard_path="$guard_dir/media-mount-guard-$CTID.sh"
  local config_path="/etc/pve/lxc/$CTID.conf"
  local -a guard_labels guard_paths guard_targets guard_sources guard_fstypes guard_uuids
  local -a candidate_labels candidate_paths
  local candidate_index candidate_path existing_path duplicate

  if [[ "$MEDIA_LAYOUT" == "single" ]]; then
    # The common base proves that the selected filesystem is still mounted,
    # while both leaves prove that no later nested/replacement mount shadows a
    # selected folder. Deduplicate paths when a leaf is also the common base.
    candidate_labels=("combined media base" "downloads" "audiobooks")
    candidate_paths=("$MEDIA_HOST_BASE" "$DOWNLOAD_PATH" "$AUDIOBOOK_PATH")
    for candidate_index in "${!candidate_paths[@]}"; do
      candidate_path=${candidate_paths[$candidate_index]}
      duplicate=0
      for existing_path in "${guard_paths[@]}"; do
        if [[ "$existing_path" == "$candidate_path" ]]; then
          duplicate=1
          break
        fi
      done
      (( duplicate == 1 )) && continue
      guard_labels+=("${candidate_labels[$candidate_index]}")
      guard_paths+=("$candidate_path")
      guard_targets+=("$DOWNLOAD_MOUNT_TARGET")
      guard_sources+=("$DOWNLOAD_MOUNT_SOURCE")
      guard_fstypes+=("$DOWNLOAD_MOUNT_FSTYPE")
      guard_uuids+=("$DOWNLOAD_MOUNT_UUID")
    done
  else
    guard_labels=("downloads" "audiobooks")
    guard_paths=("$DOWNLOAD_PATH" "$AUDIOBOOK_PATH")
    guard_targets=("$DOWNLOAD_MOUNT_TARGET" "$AUDIOBOOK_MOUNT_TARGET")
    guard_sources=("$DOWNLOAD_MOUNT_SOURCE" "$AUDIOBOOK_MOUNT_SOURCE")
    guard_fstypes=("$DOWNLOAD_MOUNT_FSTYPE" "$AUDIOBOOK_MOUNT_FSTYPE")
    guard_uuids=("$DOWNLOAD_MOUNT_UUID" "$AUDIOBOOK_MOUNT_UUID")
  fi

  install -d -m 0755 -- "$guard_dir"
  # Until the hook is fully written and referenced by the CT configuration it
  # is temporary. The global EXIT trap removes it on an interrupted install.
  cleanup_files+=("$guard_path")
  {
    printf '#!/bin/bash\nset -Eeuo pipefail\nPATH=/usr/sbin:/usr/bin:/sbin:/bin\n'
    printf 'guard_labels=('; printf ' %q' "${guard_labels[@]}"; printf ' )\n'
    printf 'guard_paths=('; printf ' %q' "${guard_paths[@]}"; printf ' )\n'
    printf 'guard_targets=('; printf ' %q' "${guard_targets[@]}"; printf ' )\n'
    printf 'guard_sources=('; printf ' %q' "${guard_sources[@]}"; printf ' )\n'
    printf 'guard_fstypes=('; printf ' %q' "${guard_fstypes[@]}"; printf ' )\n'
    printf 'guard_uuids=('; printf ' %q' "${guard_uuids[@]}"; printf ' )\n'
    cat <<'GUARD'

guard_load_identity() {
  local path="$1" lookup="$2" json
  if [[ "$lookup" == "mountpoint" ]]; then
    json=$(findmnt -J -M "$path" -o ID,TARGET,SOURCE,FSTYPE,UUID 2>/dev/null) || return 1
  else
    json=$(findmnt -J -T "$path" -o ID,TARGET,SOURCE,FSTYPE,UUID 2>/dev/null) || return 1
  fi
  CURRENT_ID=$(jq -er '.filesystems[0].id | tostring' <<<"$json") || return 1
  CURRENT_TARGET=$(jq -er '.filesystems[0].target' <<<"$json") || return 1
  CURRENT_SOURCE=$(jq -er '.filesystems[0].source' <<<"$json") || return 1
  CURRENT_FSTYPE=$(jq -er '.filesystems[0].fstype' <<<"$json") || return 1
  CURRENT_UUID=$(jq -r '.filesystems[0].uuid // ""' <<<"$json") || return 1
  CURRENT_TARGET=$(realpath -e -- "$CURRENT_TARGET" 2>/dev/null) || return 1
}

guard_fail() {
  echo "[Bindery media guard] Refusing to start container ${LXC_NAME:-unknown}: $*" >&2
  exit 1
}

for i in "${!guard_paths[@]}"; do
  label=${guard_labels[$i]}
  path=${guard_paths[$i]}
  expected_target=${guard_targets[$i]}
  expected_source=${guard_sources[$i]}
  expected_fstype=${guard_fstypes[$i]}
  expected_uuid=${guard_uuids[$i]}

  [[ -d "$path" ]] || guard_fail "$label path is unavailable: $path"
  canonical=$(realpath -e -- "$path" 2>/dev/null) || guard_fail "$label path cannot be resolved: $path"
  [[ "$canonical" == "$path" ]] || guard_fail "$label path now contains a symlink: $path"

  guard_load_identity "$expected_target" mountpoint \
    || guard_fail "expected $label mount point is not mounted: $expected_target"
  mount_id=$CURRENT_ID
  mount_target=$CURRENT_TARGET
  [[ "$mount_target" == "$expected_target" && "$CURRENT_FSTYPE" == "$expected_fstype" ]] \
    || guard_fail "$label mount identity changed at $expected_target"
  if [[ -n "$expected_uuid" ]]; then
    [[ "$CURRENT_UUID" == "$expected_uuid" ]] \
      || guard_fail "$label filesystem UUID changed at $expected_target"
  else
    [[ "$CURRENT_SOURCE" == "$expected_source" ]] \
      || guard_fail "$label mount source changed at $expected_target"
  fi

  guard_load_identity "$path" target \
    || guard_fail "$label path is not on a mounted filesystem: $path"
  [[ "$CURRENT_ID" == "$mount_id" && "$CURRENT_TARGET" == "$mount_target" ]] \
    || guard_fail "$label path is no longer on its selected mount: $path"
done
GUARD
  } >"$guard_path"
  chmod 0755 -- "$guard_path"

  # Proxmox preserves low-level lxc.* entries and passes them to LXC. This hook
  # lives on the host and aborts every start before the guest can access media.
  printf 'lxc.hook.pre-start: %s\n' "$guard_path" >>"$config_path"
  local -a remaining_cleanup=()
  local cleanup_path
  for cleanup_path in "${cleanup_files[@]:-}"; do
    [[ "$cleanup_path" == "$guard_path" ]] || remaining_cleanup+=("$cleanup_path")
  done
  cleanup_files=("${remaining_cleanup[@]}")
  MEDIA_MOUNT_GUARD_PATH="$guard_path"
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
  case "$IPV6_MODE" in
    auto) net0+=",ip6=auto" ;;
    dhcp) net0+=",ip6=dhcp" ;;
    manual) net0+=",ip6=manual" ;;
    *) msg_err "Unsupported IPv6 mode: $IPV6_MODE"; return 1 ;;
  esac

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

  pct create "${create_args[@]}"
  msg_ok "Created LXC $CTID"

  # Re-resolve the exact kernel mount identities at the last possible moment.
  # If a NAS/disk disappeared during CT creation, do not attach the underlying
  # host directory in its place.
  if ! revalidate_media_mounts; then
    msg_err "A selected media mount changed or went offline before attachment. LXC $CTID was created without media mounts and was not started."
    return 1
  fi
  if [[ "$MEDIA_LAYOUT" == "single" ]]; then
    pct set "$CTID" --mp0 "volume=${MEDIA_HOST_BASE},mp=/data,backup=0" >/dev/null
  else
    pct set "$CTID" --mp0 "volume=${DOWNLOAD_PATH},mp=/data/downloads,backup=0" >/dev/null
    pct set "$CTID" --mp1 "volume=${AUDIOBOOK_PATH},mp=/data/audiobooks,backup=0" >/dev/null
  fi
  msg_ok "Attached media storage"

  pct set "$CTID" --description "Bindery audiobook/book manager - installed by Bindery LXC Helper" >/dev/null

  install_media_mount_guard
  revalidate_media_mounts || {
    msg_err "A selected media mount changed before permission setup. LXC $CTID was not started."
    return 1
  }
  configure_host_permissions

  pct start "$CTID"

  # Keep the password out of `pct create` and therefore out of the host process
  # list. chpasswd receives it only over pct exec's standard input, before SSH
  # is installed or password authentication is enabled.
  if (( ENABLE_SSH == 1 )); then
    if ! printf 'root:%s\n' "$ROOT_PASSWORD" | pct exec "$CTID" -- chpasswd; then
      ROOT_PASSWORD=""
      msg_err "Could not set the container root password. SSH was not installed."
      return 1
    fi
    ROOT_PASSWORD=""
  fi

  msg_info "Waiting for container DNS and HTTPS access"
  local network_ok=0 https_client_ready=0 attempt
  for ((attempt=1; attempt<=20; attempt++)); do
    if pct exec "$CTID" -- getent ahosts github.com >/dev/null 2>&1; then
      if (( https_client_ready == 0 )); then
        if pct exec "$CTID" -- bash -lc \
          'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates curl >/dev/null' \
          >/dev/null 2>&1; then
          https_client_ready=1
        fi
      fi
    fi
    if (( https_client_ready == 1 )) \
        && pct exec "$CTID" -- curl -fsSL --output /dev/null --connect-timeout 5 --max-time 15 https://api.github.com/ >/dev/null 2>&1; then
      network_ok=1
      break
    fi
    sleep 2
  done
  if (( network_ok == 0 )); then
    msg_warn "The LXC started, but DNS-verified HTTPS access is not ready. Enter it with 'pct enter $CTID' to check DNS, routing, and TLS."
    return 1
  fi
  msg_ok "Container DNS and HTTPS access are online"

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
    printf 'HELPER_VERSION=2\n'
    printf 'PORT=%s\n' "$DEFAULT_PORT"
    printf 'DOWNLOAD_DIR=%s\n' "$DOWNLOAD_CT"
    printf 'AUDIOBOOK_DIR=%s\n' "$AUDIOBOOK_CT"
    printf 'MEDIA_LAYOUT=%s\n' "$MEDIA_LAYOUT"
    printf 'MOUNT_GUARD=host-pre-start\n'
    printf 'IPV6_MODE=%s\n' "$IPV6_MODE"
    printf 'TELEMETRY_DISABLED=%s\n' "$TELEMETRY_DISABLED"
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
  select_ipv6_mode || return 0

  ROOTFS_STORAGE=$(select_rootfs_storage) || return 0

  wt_msg "Media Storage" \
    "Root disk selected:\n  ${ROOTFS_STORAGE}:${DISK} GB\n\nNext you will select Downloads and Audiobook folders. These are host bind mounts and are completely separate from the LXC root disk storage." 17 88

  while ! select_media_storage; do
    if ! wt_yesno "Media Storage" "The media selection was cancelled or invalid. Retry the Downloads/Audiobook storage wizard?" 12 78; then
      return 0
    fi
  done
  select_permission_mode || return 0
  select_telemetry || return 0

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
