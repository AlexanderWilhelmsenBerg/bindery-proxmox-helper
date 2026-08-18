#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT/bindery-lxc.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok - %s\n' "$*"; }

[[ -f "$SCRIPT" ]] || fail "missing bindery-lxc.sh"
bash -n "$SCRIPT"
ok "main helper parses with bash -n"

python3 - "$SCRIPT" "$TMP" <<'PY'
from pathlib import Path
import sys

src = Path(sys.argv[1]).read_text()
out = Path(sys.argv[2])
blocks = {
    "bindery-update": ("<<'UPDATER_EOF'\n", "\nUPDATER_EOF"),
    "bindery-backup": ("<<'BACKUP_EOF'\n", "\nBACKUP_EOF"),
    "bindery.service": ("<<'SERVICE_EOF'\n", "\nSERVICE_EOF"),
    "motd": ("<<'MOTD_EOF'\n", "\nMOTD_EOF"),
    "install-inner.sh": ("<<'INSTALL_EOF'\n", "\nINSTALL_EOF"),
    "media-mount-guard": ("<<'GUARD'\n", "\nGUARD"),
}
prefixes = {
    # The real generated guard gets this preamble immediately before the
    # heredoc. Preserve its shell identity when linting the extracted body.
    "media-mount-guard": "#!/bin/bash\n",
}
for name, (start_marker, end_marker) in blocks.items():
    try:
        start = src.index(start_marker) + len(start_marker)
        end = src.index(end_marker, start)
    except ValueError as exc:
        raise SystemExit(f"cannot extract {name}: {exc}")
    (out / name).write_text(prefixes.get(name, "") + src[start:end] + "\n")
PY

bash -n "$TMP/bindery-update"
bash -n "$TMP/bindery-backup"
bash -n "$TMP/motd"
bash -n "$TMP/install-inner.sh"
bash -n "$TMP/media-mount-guard"
ok "embedded shell scripts parse with bash -n"

# Load only definitions before the interactive wizard's main entry point.
awk '/^# ---------- main ----------/ {exit} {print}' "$SCRIPT" > "$TMP/definitions.sh"
# install_new lives below that marker but is still safe to load as a function;
# include it so the common default/advanced orchestration can be exercised.
awk '/^install_new\(\) \{/{capture=1} capture{print} capture && /^}/{exit}' "$SCRIPT" >> "$TMP/definitions.sh"
# shellcheck disable=SC1090
source "$TMP/definitions.sh"
trap - ERR
# Sourcing the definitions installs the helper's EXIT trap. Compose it with
# the test-suite cleanup. Guard the top-level cleanup because Bash can run an
# inherited EXIT trap inside command substitutions used by the helpers.
SAFE_TEST_ROOT=""
smoke_cleanup() {
  local ec=$?
  (( BASH_SUBSHELL == 0 )) || return "$ec"
  cleanup || true
  [[ -z "$SAFE_TEST_ROOT" ]] || rm -rf -- "$SAFE_TEST_ROOT" || true
  rm -rf -- "$TMP" || true
  return "$ec"
}
trap smoke_cleanup EXIT

# Media-path tests cannot live below /tmp because temporary host trees are
# deliberately protected. Keep a disposable test tree beside the checkout.
SAFE_TEST_ROOT=$(mktemp -d "$ROOT/.smoke-work.XXXXXX")
cleanup_files+=("$SAFE_TEST_ROOT")
mkdir -p \
  "$SAFE_TEST_ROOT/media=library" \
  "$SAFE_TEST_ROOT/mock-drive/downloads" \
  "$SAFE_TEST_ROOT/mock-drive/audiobooks" \
  "$SAFE_TEST_ROOT/mock-drive/nested/books" \
  "$SAFE_TEST_ROOT/acl-media/normal" \
  "$SAFE_TEST_ROOT/acl-media/nested-device/hidden"
: > "$SAFE_TEST_ROOT/acl-media/normal/book.m4b"
: > "$SAFE_TEST_ROOT/acl-media/nested-device/hidden/must-not-change.m4b"

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck --severity=error \
    "$SCRIPT" \
    "$TMP/bindery-update" \
    "$TMP/bindery-backup" \
    "$TMP/motd" \
    "$TMP/install-inner.sh" \
    "$TMP/media-mount-guard"
  ok "main and embedded shell scripts pass ShellCheck error-level analysis"
fi

if command -v systemd-analyze >/dev/null 2>&1; then
  mkdir -p "$TMP/systemd"
  # Verify the unit grammar without requiring Bindery's runtime user, files,
  # or executable to exist on the generic CI runner.
  sed -E \
    -e '/^(User|Group|WorkingDirectory)=/d' \
    -e 's#^EnvironmentFile=.*#EnvironmentFile=-/dev/null#' \
    -e 's#^ExecStartPre=.*#ExecStartPre=/bin/true#' \
    -e 's#^ExecStart=.*#ExecStart=/bin/true#' \
    "$TMP/bindery.service" > "$TMP/systemd/bindery.service"
  systemd-analyze --man=no verify "$TMP/systemd/bindery.service"
  ok "embedded systemd service passes systemd-analyze verify"
fi

for good in 192.168.40.45/24 10.0.0.1/8 203.0.113.254/32; do
  valid_ipv4_cidr "$good" || fail "valid IPv4/CIDR rejected: $good"
done
for bad in 999.1.1.1/24 192.168.1.1/33 192.168.1/24 010.0.0.1/24 1.02.3.4/24 0.0.0.0/0 255.255.255.255/32; do
  if valid_ipv4_cidr "$bad"; then fail "invalid IPv4/CIDR accepted: $bad"; fi
done
for bad_gateway in 0.0.0.0 255.255.255.255; do
  if valid_ipv4 "$bad_gateway"; then fail "invalid static IPv4 endpoint accepted: $bad_gateway"; fi
done
for good in bindery bindery-1 bindery.media bindery-1.media; do
  valid_hostname "$good" || fail "valid hostname rejected: $good"
done
for bad in '-bindery' 'bindery-' 'bindery..media' 'bad_name'; do
  if valid_hostname "$bad"; then fail "invalid hostname accepted: $bad"; fi
done
ok "IPv4/CIDR and hostname validation"

whiptail() { printf '%s\n' "$MOCK_TELEMETRY_CHOICE" >&2; }
MOCK_TELEMETRY_CHOICE=disabled
select_telemetry || fail "disabled telemetry choice was rejected"
(( TELEMETRY_DISABLED == 1 )) || fail "disabled telemetry choice was not retained"
MOCK_TELEMETRY_CHOICE=enabled
select_telemetry || fail "enabled telemetry choice was rejected"
(( TELEMETRY_DISABLED == 0 )) || fail "enabled telemetry choice was not retained"
unset -f whiptail

INNER_DIR="$TMP/telemetry-env"
mkdir -p "$INNER_DIR"
DOWNLOAD_PATH_REMAP=""
DOWNLOAD_CT="/data/downloads"
AUDIOBOOK_CT="/data/audiobooks"
LIBRARY_CT="$AUDIOBOOK_CT"
TELEMETRY_DISABLED=1
make_env_file
grep -Fxq 'BINDERY_TELEMETRY_DISABLED="true"' "$INNER_DIR/bindery.env" \
  || fail "zero-ping telemetry opt-out missing from generated environment"
TELEMETRY_DISABLED=0
make_env_file
grep -Fxq 'BINDERY_TELEMETRY_DISABLED="false"' "$INNER_DIR/bindery.env" \
  || fail "telemetry opt-in missing from generated environment"

disabled_choice_line=$(grep -nF '"disabled" "Disable before first start' "$SCRIPT" | head -n1 | cut -d: -f1)
enabled_choice_line=$(grep -nF '"enabled" "Allow Bindery' "$SCRIPT" | head -n1 | cut -d: -f1)
selection_line=$(grep -nF 'select_telemetry || return 0' "$SCRIPT" | head -n1 | cut -d: -f1)
creation_line=$(grep -nF 'create_lxc' "$SCRIPT" | tail -n1 | cut -d: -f1)
[[ -n "$disabled_choice_line" && -n "$enabled_choice_line" && -n "$selection_line" && -n "$creation_line" ]] \
  || fail "could not locate telemetry wizard ordering"
(( disabled_choice_line < enabled_choice_line && selection_line < creation_line )) \
  || fail "telemetry is not privacy-first or is selected after creation"
default_settings_body=$(awk '/^default_settings\(\) \{/{capture=1} capture{print} capture && /^}/{exit}' "$SCRIPT")
grep -Fq 'TELEMETRY_DISABLED=1' <<<"$default_settings_body" || fail "default setup does not disable telemetry"

env_install_line=$(grep -nF 'install -m 0644 /tmp/bindery.env /etc/bindery/bindery.env' "$TMP/install-inner.sh" | head -n1 | cut -d: -f1)
first_service_start_line=$(grep -nF 'systemctl start bindery' "$TMP/install-inner.sh" | head -n1 | cut -d: -f1)
[[ -n "$env_install_line" && -n "$first_service_start_line" ]] || fail "could not locate first-start environment ordering"
(( env_install_line < first_service_start_line )) || fail "telemetry environment is installed after Bindery first starts"
ok "telemetry choice and pre-first-start environment"

# Drive the common install flow with both setup modes stubbed. This proves the
# IPv6 selector is not limited to Advanced mode and always precedes creation.
INSTALL_EVENTS="$TMP/install-events"
record_install_event() { printf '%s\n' "$1" >> "$INSTALL_EVENTS"; }
whiptail() { printf '%s\n' "$MOCK_INSTALL_MODE" >&2; }
default_settings() { DISK=8; record_install_event default; }
advanced_settings() { DISK=8; record_install_event advanced; }
select_ipv6_mode() { record_install_event ipv6; }
select_rootfs_storage() { trap - EXIT; record_install_event root-storage; printf 'local-lvm\n'; }
wt_msg() { :; }
wt_yesno() { return 0; }
select_media_storage() { record_install_event media; }
select_permission_mode() { record_install_event permissions; }
select_telemetry() { record_install_event telemetry; }
summary_and_confirm() { record_install_event summary; }
create_lxc() { record_install_event create; }

for MOCK_INSTALL_MODE in default advanced; do
  : > "$INSTALL_EVENTS"
  install_new
  install_sequence=$(paste -sd, "$INSTALL_EVENTS")
  expected_sequence="$MOCK_INSTALL_MODE,ipv6,root-storage,media,permissions,telemetry,summary,create"
  [[ "$install_sequence" == "$expected_sequence" ]] \
    || fail "$MOCK_INSTALL_MODE install ordering: got '$install_sequence', expected '$expected_sequence'"
done
unset -f record_install_event whiptail default_settings advanced_settings select_ipv6_mode \
  select_rootfs_storage wt_msg wt_yesno select_media_storage select_permission_mode \
  select_telemetry summary_and_confirm create_lxc
unset INSTALL_EVENTS MOCK_INSTALL_MODE
[[ -d "$SAFE_TEST_ROOT" ]] || fail "install-flow subshell removed the safe test tree"
ok "both setup modes select IPv6 before container creation"

[[ $(common_ancestor '/mnt/media/downloads' '/mnt/media/audiobooks') == '/mnt/media' ]] || fail "common ancestor calculation"
[[ -d "$SAFE_TEST_ROOT" ]] || fail "safe test root removed by common_ancestor substitution"
[[ $(relative_to '/mnt/media' '/mnt/media/audiobooks') == 'audiobooks' ]] || fail "relative path calculation"
[[ -d "$SAFE_TEST_ROOT" ]] || fail "safe test root removed by relative_to substitution"
path_is_under '/mnt/media' '/mnt/media/books' || fail "path_is_under positive case"
if path_is_under '/mnt/media' '/mnt/media2/books'; then fail "path_is_under prefix escape"; fi
[[ -d "$SAFE_TEST_ROOT" ]] || fail "safe test root removed by path_is_under"
ok "path relationship helpers"

for protected in / /etc /var /tmp /tmp/example /var/tmp /var/tmp/example /mnt /media /srv /mnt/pve /var/lib/vz; do
  path_is_protected_host_path "$protected" || fail "protected host path accepted: $protected"
done
[[ -d "$SAFE_TEST_ROOT" ]] || fail "safe test root removed by protected-path classifier"
if path_is_protected_host_path '/mnt/media/books'; then fail "dedicated media path was marked protected"; fi
for protected_final in / /etc /var /tmp /var/tmp; do
  [[ -d "$protected_final" ]] || continue
  if validate_bind_mount_path "$protected_final"; then fail "protected final media path accepted: $protected_final"; fi
done
[[ -d "$SAFE_TEST_ROOT" ]] || fail "safe test root removed by final-path validation"

equals_path_allowed=0
if validate_bind_mount_path "$SAFE_TEST_ROOT/media=library"; then
  equals_path_allowed=1
fi
ok "host root and protected media paths are rejected"

# Mock findmnt JSON to prove spaces survive and control/comma/protected mounts are filtered.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/findmnt" <<'MOCK'
#!/usr/bin/env bash
python3 - <<'PY'
import json
print(json.dumps({"filesystems": [
  {"target": "/", "source": "/dev/mapper/pve-root", "fstype": "ext4"},
  {"target": "/mnt/media library", "source": "/dev/disk by label/media", "fstype": "ext4"},
  {"target": "/mnt/tab\tname", "source": "/dev/sdb1", "fstype": "ext4"},
  {"target": "/mnt/bad,name", "source": "/dev/sdc1", "fstype": "ext4"},
  {"target": "/etc/pve", "source": "fuse", "fstype": "fuse"},
  {"target": "/var/lib/vz", "source": "/dev/mapper/pve-root", "fstype": "ext4"},
  {"target": "/run/test", "source": "tmpfs", "fstype": "tmpfs"}
]}))
PY
MOCK
chmod +x "$TMP/bin/findmnt"
MOUNTS=$(PATH="$TMP/bin:$PATH" list_eligible_mounts)
grep -Fq $'/mnt/media library\t/dev/disk by label/media\text4' <<<"$MOUNTS" || fail "space-containing mount was not preserved"
! grep -Fq '/mnt/tab' <<<"$MOUNTS" || fail "tab-containing mount was not filtered"
! grep -Fq '/mnt/bad,name' <<<"$MOUNTS" || fail "comma-containing mount was not filtered"
! grep -Fq '/etc/pve' <<<"$MOUNTS" || fail "protected Proxmox mount was not filtered"
! grep -Fq $'/\t' <<<"$MOUNTS" || fail "host root mount was not filtered"
! grep -Fq '/var/lib/vz' <<<"$MOUNTS" || fail "protected Proxmox storage path was not filtered"
ok "mount discovery preserves spaces and filters unsafe paths"

# Mock mount identities to prove that a selected folder must remain on the
# exact mount chosen in the wizard, and that nested/replaced mounts fail.
MOCK_DRIVE="$SAFE_TEST_ROOT/mock-drive"
MOCK_NESTED="$MOCK_DRIVE/nested"
cat > "$TMP/bin/findmnt" <<'MOCK'
#!/usr/bin/env bash
set -eu
mode="" path=""
while (( $# > 0 )); do
  case "$1" in
    -M|-T)
      mode="$1"
      path="$2"
      shift 2
      ;;
    *) shift ;;
  esac
done
[[ -n "$mode" && -n "$path" ]]
if [[ "$mode" == "-M" && "$path" != "$MOCK_DRIVE" ]]; then
  exit 1
fi
mount_id=${MOCK_MOUNT_ID:-42}
target="$MOCK_DRIVE"
source="/dev/mock-media"
uuid="mock-media-uuid"
if [[ "$path" == "$MOCK_NESTED" || "$path" == "$MOCK_NESTED/"* ]]; then
  mount_id=99
  target="$MOCK_NESTED"
  source="/dev/mock-nested"
  uuid="mock-nested-uuid"
fi
MSYS2_ARG_CONV_EXCL='*' python3 - "$mount_id" "$target" "$source" "$uuid" <<'PY'
import json
import sys

mount_id, target, source, uuid = sys.argv[1:]
print(json.dumps({"filesystems": [{
    "id": int(mount_id),
    "target": target,
    "source": source,
    "fstype": "ext4",
    "uuid": uuid,
}]}))
PY
MOCK
chmod +x "$TMP/bin/findmnt"
export MOCK_DRIVE MOCK_NESTED

PATH="$TMP/bin:$PATH" capture_selected_mount TEST "$MOCK_DRIVE" "$MOCK_DRIVE/downloads" \
  || fail "same-mount media folder was rejected"
[[ "$TEST_MOUNT_ID" == 42 && "$TEST_MOUNT_TARGET" == "$MOCK_DRIVE" ]] \
  || fail "selected mount identity was not captured"
if PATH="$TMP/bin:$PATH" capture_selected_mount NESTED "$MOCK_DRIVE" "$MOCK_NESTED/books"; then
  fail "folder on a nested mount was accepted as part of the selected mount"
fi
MOCK_MOUNT_ID=77
export MOCK_MOUNT_ID
if PATH="$TMP/bin:$PATH" revalidate_selected_mount TEST "$MOCK_DRIVE" "$MOCK_DRIVE/downloads"; then
  fail "changed mount identity passed revalidation"
fi
unset MOCK_MOUNT_ID MOCK_DRIVE MOCK_NESTED

[[ $(common_ancestor "$SAFE_TEST_ROOT/mock-drive/downloads" "$SAFE_TEST_ROOT/mock-drive/audiobooks") == "$SAFE_TEST_ROOT/mock-drive" ]] \
  || fail "safe same-mount common ancestor rejected"
unsafe_common=$(common_ancestor '/mnt/one/downloads' '/srv/two/audiobooks')
[[ "$unsafe_common" == / ]] || fail "unexpected cross-tree common ancestor: $unsafe_common"
if validate_bind_mount_path "$unsafe_common"; then fail "protected common ancestor was accepted"; fi
grep -Fq '[[ "$MOUNT_INFO_ID" == "$DOWNLOAD_MOUNT_ID" && "$MOUNT_INFO_TARGET" == "$DOWNLOAD_MOUNT_TARGET" ]]' "$SCRIPT" \
  || fail "single-mount common ancestor identity guard missing"
ok "mount identity, nested-mount and common-ancestor guards"

# GNU find -xdev still emits the root of a nested mount, even though it does
# not descend into it. Model that behavior and a changed st_dev, then prove
# the nested mount root itself never reaches setfacl.
ACL_MEDIA="$SAFE_TEST_ROOT/acl-media"
ACL_NORMAL="$ACL_MEDIA/normal"
ACL_NESTED="$ACL_MEDIA/nested-device"
mkdir -p "$TMP/acl-bin"
SETFACL_LOG="$TMP/acl-setfacl.log"
FIND_LOG="$TMP/acl-find.log"
export ACL_MEDIA ACL_NORMAL ACL_NESTED SETFACL_LOG FIND_LOG
cat > "$TMP/acl-bin/setfacl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SETFACL_LOG"
exit 0
MOCK
cat > "$TMP/acl-bin/find" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIND_LOG"
case " $* " in
  *' -type d '*) printf '%s\0' "$ACL_MEDIA" "$ACL_NORMAL" "$ACL_NESTED" ;;
  *' -type f '*) printf '%s\0' "$ACL_NORMAL/book.m4b" ;;
  *) exit 2 ;;
esac
MOCK
# Report the selected filesystem itself only. The find/stat doubles below then
# model a different-device mount appearing after this initial mount inventory,
# which exercises the per-entry device filter as defense in depth.
cat > "$TMP/acl-bin/findmnt" <<'MOCK'
#!/usr/bin/env bash
if [[ ${ACL_REPORT_NESTED:-0} == 1 ]]; then
  printf '{"filesystems":[{"target":"%s"},{"target":"%s"}]}\n' "$ACL_MEDIA" "$ACL_NESTED"
else
  printf '{"filesystems":[{"target":"%s"}]}\n' "$ACL_MEDIA"
fi
MOCK
cat > "$TMP/acl-bin/stat" <<'MOCK'
#!/usr/bin/env bash
path=${!#}
case "$path" in
  *nested-device*) printf '202\n' ;;
  *) printf '101\n' ;;
esac
MOCK
chmod +x "$TMP/acl-bin/setfacl" "$TMP/acl-bin/find" "$TMP/acl-bin/findmnt" "$TMP/acl-bin/stat"

# Primary defense: a known nested mount aborts before even the selected path
# or its traverse ancestors are mutated.
ACL_REPORT_NESTED=1
export ACL_REPORT_NESTED
if PATH="$TMP/acl-bin:$PATH" apply_acl_to_path "$ACL_MEDIA" "$ACL_MEDIA" 101000 1; then
  fail "recursive ACL accepted a known nested mount"
fi
[[ ! -s "$SETFACL_LOG" ]] || fail "ACL mutation occurred before nested-mount preflight completed"

# Defense in depth: model a nested mount appearing after the inventory. find
# emits its root, but the changed st_dev filter must keep it from setfacl.
ACL_REPORT_NESTED=0
: > "$SETFACL_LOG"
PATH="$TMP/acl-bin:$PATH" apply_acl_to_path "$ACL_MEDIA" "$ACL_MEDIA" 101000 1 \
  || fail "recursive ACL helper failed with command doubles"
grep -Fq "$ACL_MEDIA -xdev -type d" "$FIND_LOG" || fail "recursive directory ACL lacks filesystem boundary"
grep -Fq "$ACL_MEDIA -xdev -type f" "$FIND_LOG" || fail "recursive file ACL lacks filesystem boundary"
grep -Fq "$ACL_NORMAL" "$SETFACL_LOG" || fail "same-device child directory did not receive its ACL"
grep -Fq "$ACL_NORMAL/book.m4b" "$SETFACL_LOG" || fail "same-device file did not receive its ACL"
if grep -Fq "$ACL_NESTED" "$SETFACL_LOG"; then
  fail "different-device nested mount root was sent to setfacl"
fi
unset ACL_MEDIA ACL_NORMAL ACL_NESTED SETFACL_LOG FIND_LOG ACL_REPORT_NESTED
ok "recursive ACL preflights and filters different-device nested mounts"

# Structural assertions for safety-critical flows.
grep -Fq 'pvesm status --content rootdir' "$SCRIPT" || fail "rootdir storage picker missing"
grep -Fq 'backup=0' "$SCRIPT" || fail "media mount backup exclusion missing"
grep -Fq 'BINDERY_AUDIOBOOK_DOWNLOAD_DIR=' "$SCRIPT" || fail "audiobook download env missing"
grep -Fq '/api/v1/health' "$SCRIPT" || fail "Bindery health endpoint check missing"
grep -Fq '[[ -n "$reported" ]] || reported="/"' "$SCRIPT" || fail "root remap edge case missing"
if grep -Fq 'source "$ENV_FILE"' "$SCRIPT"; then fail "systemd EnvironmentFile is sourced as shell"; fi
if grep -Eq 'pct exec .*bindery-helper\.conf.*DOWNLOAD_(CT|PATH)' "$SCRIPT"; then fail "media path interpolated into pct exec shell"; fi

if (( equals_path_allowed == 1 )); then
  grep -Fq '"volume=${MEDIA_HOST_BASE},mp=/data,backup=0"' "$SCRIPT" \
    || fail "equals-containing single media path lacks explicit Proxmox volume= syntax"
  grep -Fq '"volume=${DOWNLOAD_PATH},mp=/data/downloads,backup=0"' "$SCRIPT" \
    || fail "equals-containing downloads path lacks explicit Proxmox volume= syntax"
  grep -Fq '"volume=${AUDIOBOOK_PATH},mp=/data/audiobooks,backup=0"' "$SCRIPT" \
    || fail "equals-containing audiobook path lacks explicit Proxmox volume= syntax"
fi

grep -Fq 'find "$path" -xdev -type "$file_type"' "$SCRIPT" \
  || fail "recursive ACL traversal is not filesystem-bound with -xdev"
grep -Fq 'apply_acl_batch_on_device "$path" "$start_dev" d' "$SCRIPT" \
  || fail "recursive directory ACLs do not use the filesystem-bound batch helper"
grep -Fq 'apply_acl_batch_on_device "$path" "$start_dev" f' "$SCRIPT" \
  || fail "recursive file ACLs do not use the filesystem-bound batch helper"
ok "basic safety invariants and filesystem-bound ACL traversal"

updater_lock=$(sed -nE 's/^LOCK_FILE="([^"]+)"$/\1/p' "$TMP/bindery-update" | head -n1)
backup_lock=$(sed -nE 's/^LOCK_FILE="([^"]+)"$/\1/p' "$TMP/bindery-backup" | head -n1)
[[ -n "$updater_lock" && "$updater_lock" == "$backup_lock" ]] \
  || fail "updater and backup do not share one maintenance lock"
for maintenance_script in "$TMP/bindery-update" "$TMP/bindery-backup"; do
  grep -Fq 'umask 0077' "$maintenance_script" || fail "restrictive maintenance umask missing: $maintenance_script"
  grep -Fq 'exec 9<>"$LOCK_FILE"' "$maintenance_script" || fail "maintenance lock descriptor missing: $maintenance_script"
  grep -Fq 'flock -n 9' "$maintenance_script" || fail "non-blocking maintenance lock missing: $maintenance_script"
done
ok "updater and manual backup share a restrictive maintenance lock"

# Tie the embedded updater to the live-release contract exercised by
# tests/live-bindery.sh. These exact names come from upstream GoReleaser.
grep -Fq '"https://api.github.com/repos/${REPO}/releases/latest"' "$TMP/bindery-update" \
  || fail "updater does not resolve the official latest-release endpoint"
grep -Fq 'ARCHIVE_NAME="bindery_${VERSION}_linux_${ARCH}.tar.gz"' "$TMP/bindery-update" \
  || fail "updater release archive contract changed"
grep -Fq 'CHECKSUM_NAME="bindery_${VERSION}_checksums.txt"' "$TMP/bindery-update" \
  || fail "updater checksum asset contract changed"
grep -Fq '[[ "$EXPECTED" == "$ACTUAL" ]]' "$TMP/bindery-update" \
  || fail "updater does not fail closed on a checksum mismatch"
grep -Fq 'ln -sfn "$TARGET" "$CURRENT_LINK"' "$TMP/bindery-update" \
  || fail "fresh install does not activate the verified release"
grep -Fq '/usr/local/sbin/bindery-update --install' "$TMP/install-inner.sh" \
  || fail "inner installer never invokes the official-release installer"
ok "embedded installer is linked to the live official-release contract"

# The upstream binary accepts BINDERY_URL_BASE as a bare path, absolute path,
# or full URL. Exercise the updater's isolated health-route normalizer so a
# valid reverse-proxy configuration cannot trigger a false rollback.
awk '/^normalize_health_url_base\(\) \{/{capture=1} capture{print} capture && /^}/{exit}' \
  "$TMP/bindery-update" >"$TMP/url-base-function.sh"
# shellcheck disable=SC1090
source "$TMP/url-base-function.sh"
[[ $(normalize_health_url_base '/bindery/') == '/bindery' ]] \
  || fail "absolute URL base was not normalized"
[[ $(normalize_health_url_base 'bindery') == '/bindery' ]] \
  || fail "bare URL base was not normalized"
[[ $(normalize_health_url_base 'https://books.example/bindery/') == '/bindery' ]] \
  || fail "full URL base did not retain its path"
[[ -z $(normalize_health_url_base 'https://books.example') ]] \
  || fail "origin-only URL base did not normalize to root"
[[ -z $(normalize_health_url_base '/') ]] \
  || fail "root URL base did not normalize to empty"
grep -Fq '"http://127.0.0.1:${HEALTH_PORT}${HEALTH_URL_BASE}/api/v1/health"' "$TMP/bindery-update" \
  || fail "updater health probe does not use the normalized URL base"
ok "updater health probe normalizes every upstream-supported URL-base form"

grep -Fq 'BACKUP_TMP=$(mktemp "$BACKUP_ROOT/.pre-' "$TMP/bindery-update" || fail "staged update backup missing"
grep -Fq 'tar -tzf "$BACKUP_TMP" >/dev/null' "$TMP/bindery-update" || fail "update backup validation missing"
grep -Fq 'mv -- "$BACKUP_TMP" "$BACKUP"' "$TMP/bindery-update" || fail "atomic update backup publication missing"
grep -Fq 'TMP_ARCHIVE=$(mktemp "$BACKUP_ROOT/.manual-' "$TMP/bindery-backup" || fail "staged manual backup missing"
grep -Fq 'tar -tzf "$TMP_ARCHIVE" >/dev/null' "$TMP/bindery-backup" || fail "manual backup validation missing"
grep -Fq 'mv -- "$TMP_ARCHIVE" "$DEST"' "$TMP/bindery-backup" || fail "atomic manual backup publication missing"

grep -Fq 'RESTORE_STAGE=$(mktemp -d "$data_parent/.bindery-restore.' "$TMP/bindery-update" || fail "staged rollback extraction missing"
grep -Fq 'tar --extract --gzip --file="$BACKUP" --directory="$RESTORE_STAGE" --no-same-owner' "$TMP/bindery-update" \
  || fail "rollback backup is not extracted into staging"
grep -Fq "sqlite3 -batch \"\$RESTORE_STAGE/bindery.db\" 'PRAGMA quick_check;'" "$TMP/bindery-update" \
  || fail "staged rollback database integrity check missing"
grep -Fq 'mv -- "$DATA_DIR" "$RESTORE_OLD"' "$TMP/bindery-update" || fail "migrated data preservation missing"
grep -Fq 'mv -- "$RESTORE_STAGE" "$DATA_DIR"' "$TMP/bindery-update" || fail "staged rollback activation missing"
if grep -Fq 'tar -C "$DATA_DIR" -xzf "$BACKUP"' "$TMP/bindery-update"; then
  fail "rollback still extracts directly over live data"
fi
grep -Fq 'FAIL_SENTINEL="$FAIL_STATE_ROOT/rollback-failed"' "$TMP/bindery-update" || fail "persistent fail-closed sentinel missing"
grep -Fq 'ConditionPathExists=!%s' "$TMP/bindery-update" || fail "fail-closed systemd condition missing"
grep -Fq 'systemctl disable bindery.service' "$TMP/bindery-update" || fail "persistent fail-closed disable missing"
grep -Fq 'systemctl mask --runtime bindery.service' "$TMP/bindery-update" || fail "fail-closed runtime mask missing"
grep -Fq 'bindery-rollback-verify-$$.service' "$TMP/bindery-update" || fail "isolated rollback verification unit missing"
grep -Fq 'clear_fail_closed' "$TMP/bindery-update" || fail "verified rollback cannot clear fail-closed state"
arm_line=$(grep -nF 'arm_fail_closed "Rollback transaction in progress; verification has not completed."' "$TMP/bindery-update" | head -n1 | cut -d: -f1)
preserve_line=$(grep -nF 'mv -- "$DATA_DIR" "$RESTORE_OLD"' "$TMP/bindery-update" | head -n1 | cut -d: -f1)
[[ -n "$arm_line" && -n "$preserve_line" ]] || fail "could not locate rollback transaction ordering"
(( arm_line < preserve_line )) || fail "fail-closed guard is armed after live data mutation"
ok "backups and rollback are staged, validated, atomic and fail closed"

grep -Fq 'install_media_mount_guard()' "$SCRIPT" || fail "host media pre-start guard installer missing"
grep -Fq 'lxc.hook.pre-start:' "$SCRIPT" || fail "LXC media pre-start hook configuration missing"
grep -Fq 'revalidate_media_mounts' "$SCRIPT" || fail "media mounts are not revalidated immediately before attachment"
guard_installer_body=$(awk '/^install_media_mount_guard\(\) \{/{capture=1} capture{print} capture && /^}/{exit}' "$SCRIPT")
grep -Fq 'candidate_paths=("$MEDIA_HOST_BASE" "$DOWNLOAD_PATH" "$AUDIOBOOK_PATH")' <<<"$guard_installer_body" \
  || fail "single-layout guard does not watch the common base and both selected leaves"
grep -Fq 'for existing_path in "${guard_paths[@]}"; do' <<<"$guard_installer_body" \
  || fail "single-layout guard paths are not deduplicated"
grep -Fq 'guard_paths+=("$candidate_path")' <<<"$guard_installer_body" \
  || fail "single-layout selected paths are not emitted into the generated guard"
grep -Fq 'guard_load_identity "$path" target' "$TMP/media-mount-guard" \
  || fail "generated media guard does not detect a replacement mount at a selected leaf"
ok "media mount availability and LXC pre-start guards"

create_lxc_body=$(awk '/^create_lxc\(\) \{/{capture=1} capture{print} capture && /^}/{exit}' "$SCRIPT")
[[ -n "$create_lxc_body" ]] || fail "could not extract create_lxc"
grep -Fq 'case "$IPV6_MODE" in' <<<"$create_lxc_body" || fail "IPv6 mode is not applied during LXC creation"
grep -Fq 'ip6=auto' <<<"$create_lxc_body" || fail "IPv6 SLAAC option missing"
grep -Fq 'ip6=dhcp' <<<"$create_lxc_body" || fail "DHCPv6 option missing"
grep -Fq 'manual)' <<<"$create_lxc_body" || fail "explicit no-automatic-IPv6 option missing"
if grep -Fq -- '--password' <<<"$create_lxc_body"; then fail "root password is passed on the pct create command line"; fi
grep -Fq 'getent ahosts github.com' <<<"$create_lxc_body" || fail "network readiness lacks DNS/address resolution"
grep -Fq 'https://api.github.com/' <<<"$create_lxc_body" || fail "network readiness lacks a real HTTPS request"
grep -Fq 'https_client_ready == 1' <<<"$create_lxc_body" || fail "HTTPS success is not gated on client setup"
if grep -Eq 'ping .*1\.1\.1\.1.*\|\||getent (hosts|ahosts) github\.com.*\|\|' <<<"$create_lxc_body"; then
  fail "network readiness still accepts an IP-or-DNS shortcut"
fi
ok "IPv6 choice, command-line password safety and DNS/HTTPS readiness"

printf '\nAll smoke tests passed.\n'
