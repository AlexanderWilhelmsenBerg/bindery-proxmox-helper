#!/usr/bin/env bash
set -Eeuo pipefail

# Live compatibility check for the same upstream release contract used by the
# generated installer. This does not emulate Proxmox, but it proves that the
# current Linux release can be resolved, checksum-verified, extracted, started
# with the helper's environment, and reached through both health-check paths.

REPO="vavallee/bindery"
TMP=$(mktemp -d)
PID=""

cleanup() {
  local ec=$?
  trap - EXIT
  if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
    kill -TERM "$PID" 2>/dev/null || true
    for _ in $(seq 1 10); do
      kill -0 "$PID" 2>/dev/null || break
      sleep 1
    done
    kill -KILL "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
  rm -rf -- "$TMP"
  exit "$ec"
}
trap cleanup EXIT

case "$(uname -m)" in
  x86_64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  armv7l) ARCH="armv7" ;;
  armv6l) ARCH="armv6" ;;
  *) echo "Unsupported test architecture: $(uname -m)" >&2; exit 1 ;;
esac

curl_headers=(
  -H 'Accept: application/vnd.github+json'
  -H 'X-GitHub-Api-Version: 2022-11-28'
)
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  curl_headers+=(-H "Authorization: Bearer $GITHUB_TOKEN")
fi

JSON=$(curl -fsSL --retry 3 --connect-timeout 10 \
  "${curl_headers[@]}" \
  "https://api.github.com/repos/${REPO}/releases/latest")
TAG=$(jq -r '.tag_name // empty' <<<"$JSON")
[[ "$TAG" =~ ^v?[[:alnum:]][[:alnum:].+_-]*$ ]] || {
  echo "Latest release returned an unsafe or empty tag: $TAG" >&2
  exit 1
}
VERSION=${TAG#v}
ARCHIVE_NAME="bindery_${VERSION}_linux_${ARCH}.tar.gz"
CHECKSUM_NAME="bindery_${VERSION}_checksums.txt"
ARCHIVE_URL=$(jq -r --arg n "$ARCHIVE_NAME" \
  '.assets[] | select(.name==$n) | .browser_download_url' <<<"$JSON" | head -n1)
CHECKSUM_URL=$(jq -r --arg n "$CHECKSUM_NAME" \
  '.assets[] | select(.name==$n) | .browser_download_url' <<<"$JSON" | head -n1)
[[ -n "$ARCHIVE_URL" && "$ARCHIVE_URL" != null ]] || {
  echo "Latest release is missing $ARCHIVE_NAME" >&2
  exit 1
}
[[ -n "$CHECKSUM_URL" && "$CHECKSUM_URL" != null ]] || {
  echo "Latest release is missing $CHECKSUM_NAME" >&2
  exit 1
}

curl -fL --retry 3 "$ARCHIVE_URL" -o "$TMP/$ARCHIVE_NAME"
curl -fL --retry 3 "$CHECKSUM_URL" -o "$TMP/$CHECKSUM_NAME"
EXPECTED=$(awk -v f="$ARCHIVE_NAME" '$2==f || $2=="*"f {print $1; exit}' \
  "$TMP/$CHECKSUM_NAME")
ACTUAL=$(sha256sum "$TMP/$ARCHIVE_NAME" | awk '{print $1}')
[[ -n "$EXPECTED" && "$EXPECTED" == "$ACTUAL" ]] || {
  echo "Release checksum verification failed for $ARCHIVE_NAME" >&2
  exit 1
}

mkdir -p "$TMP/release" "$TMP/data" "$TMP/downloads" "$TMP/library" "$TMP/audiobooks"
tar -tzf "$TMP/$ARCHIVE_NAME" >/dev/null
tar -xzf "$TMP/$ARCHIVE_NAME" -C "$TMP/release" --no-same-owner --no-same-permissions
BINARY=$(find "$TMP/release" -maxdepth 3 -type f -name bindery -print -quit)
[[ -n "$BINARY" ]] || { echo "Extracted release contains no Bindery binary" >&2; exit 1; }
chmod 0755 "$BINARY"

PORT=18787
bindery_env=(
  "BINDERY_PORT=$PORT"
  "BINDERY_DB_PATH=$TMP/data/bindery.db"
  "BINDERY_DATA_DIR=$TMP/data"
  "BINDERY_DOWNLOAD_DIR=$TMP/downloads"
  "BINDERY_AUDIOBOOK_DOWNLOAD_DIR=$TMP/downloads"
  "BINDERY_LIBRARY_DIR=$TMP/library"
  "BINDERY_AUDIOBOOK_DIR=$TMP/audiobooks"
  "BINDERY_PUID=$(id -u)"
  "BINDERY_PGID=$(id -g)"
  "BINDERY_TELEMETRY_DISABLED=true"
  "BINDERY_SHUTDOWN_GRACE=1s"
  "BINDERY_JOBS_DRAIN_GRACE=1s"
)

env "${bindery_env[@]}" "$BINARY" >"$TMP/bindery.log" 2>&1 &
PID=$!
healthy=0
for _ in $(seq 1 30); do
  if ! kill -0 "$PID" 2>/dev/null; then
    break
  fi
  if curl -fsS --connect-timeout 2 --max-time 5 \
      "http://127.0.0.1:${PORT}/api/v1/health" >/dev/null \
      && env "${bindery_env[@]}" "$BINARY" healthcheck >/dev/null 2>&1; then
    healthy=1
    break
  fi
  sleep 1
done
if (( healthy == 0 )); then
  echo "Bindery $TAG did not become healthy under the helper environment" >&2
  sed -n '1,160p' "$TMP/bindery.log" >&2 || true
  exit 1
fi
[[ -s "$TMP/data/bindery.db" ]] || {
  echo "Bindery became healthy but did not create its configured SQLite database" >&2
  exit 1
}

kill -TERM "$PID"
wait "$PID"
PID=""
grep -Fq '"msg":"starting bindery"' "$TMP/bindery.log" || {
  echo "Bindery log did not confirm application startup" >&2
  exit 1
}

printf 'Live Bindery contract passed: %s (%s)\n' "$TAG" "$ARCHIVE_NAME"
