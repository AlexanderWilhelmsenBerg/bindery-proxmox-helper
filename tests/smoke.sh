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
}
for name, (start_marker, end_marker) in blocks.items():
    try:
        start = src.index(start_marker) + len(start_marker)
        end = src.index(end_marker, start)
    except ValueError as exc:
        raise SystemExit(f"cannot extract {name}: {exc}")
    (out / name).write_text(src[start:end] + "\n")
PY

bash -n "$TMP/bindery-update"
bash -n "$TMP/bindery-backup"
bash -n "$TMP/motd"
bash -n "$TMP/install-inner.sh"
ok "embedded shell scripts parse with bash -n"

# Load only definitions before the interactive wizard's main entry point.
awk '/^# ---------- main ----------/ {exit} {print}' "$SCRIPT" > "$TMP/definitions.sh"
# shellcheck disable=SC1090
source "$TMP/definitions.sh"
trap - ERR

for good in 192.168.40.45/24 0.0.0.0/0 255.255.255.255/32; do
  valid_ipv4_cidr "$good" || fail "valid IPv4/CIDR rejected: $good"
done
for bad in 999.1.1.1/24 192.168.1.1/33 192.168.1/24 010.0.0.1/24 1.02.3.4/24; do
  if valid_ipv4_cidr "$bad"; then fail "invalid IPv4/CIDR accepted: $bad"; fi
done
for good in bindery bindery-1 bindery.media bindery-1.media; do
  valid_hostname "$good" || fail "valid hostname rejected: $good"
done
for bad in '-bindery' 'bindery-' 'bindery..media' 'bad_name'; do
  if valid_hostname "$bad"; then fail "invalid hostname accepted: $bad"; fi
done
ok "IPv4/CIDR and hostname validation"

[[ $(common_ancestor '/mnt/media/downloads' '/mnt/media/audiobooks') == '/mnt/media' ]] || fail "common ancestor calculation"
[[ $(relative_to '/mnt/media' '/mnt/media/audiobooks') == 'audiobooks' ]] || fail "relative path calculation"
path_is_under '/mnt/media' '/mnt/media/books' || fail "path_is_under positive case"
if path_is_under '/mnt/media' '/mnt/media2/books'; then fail "path_is_under prefix escape"; fi
ok "path relationship helpers"

# Mock findmnt JSON to prove spaces survive and control/comma/protected mounts are filtered.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/findmnt" <<'MOCK'
#!/usr/bin/env bash
python3 - <<'PY'
import json
print(json.dumps({"filesystems": [
  {"target": "/mnt/media library", "source": "/dev/disk by label/media", "fstype": "ext4"},
  {"target": "/mnt/tab\tname", "source": "/dev/sdb1", "fstype": "ext4"},
  {"target": "/mnt/bad,name", "source": "/dev/sdc1", "fstype": "ext4"},
  {"target": "/etc/pve", "source": "fuse", "fstype": "fuse"},
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
ok "mount discovery preserves spaces and filters unsafe paths"

# Structural assertions for safety-critical flows.
grep -Fq 'pvesm status --content rootdir' "$SCRIPT" || fail "rootdir storage picker missing"
grep -Fq 'backup=0' "$SCRIPT" || fail "media mount backup exclusion missing"
grep -Fq 'BINDERY_AUDIOBOOK_DOWNLOAD_DIR=' "$SCRIPT" || fail "audiobook download env missing"
grep -Fq 'bindery" healthcheck' "$SCRIPT" || fail "Bindery healthcheck missing"
grep -Fq 'restore_previous()' "$SCRIPT" || fail "updater rollback missing"
grep -Fq 'CRITICAL: rollback restore failed; Bindery has been left STOPPED' "$SCRIPT" || fail "fail-closed rollback missing"
grep -Fq '[[ -n "$reported" ]] || reported="/"' "$SCRIPT" || fail "root remap edge case missing"
if grep -Fq 'source "$ENV_FILE"' "$SCRIPT"; then fail "systemd EnvironmentFile is sourced as shell"; fi
if grep -Eq 'pct exec .*bindery-helper\.conf.*DOWNLOAD_(CT|PATH)' "$SCRIPT"; then fail "media path interpolated into pct exec shell"; fi
ok "safety-critical structural assertions"

printf '\nAll smoke tests passed.\n'
