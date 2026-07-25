#!/bin/bash
# Usage: FLOTILLA_SECRET=<secret-b64url> FLOTILLA_KEY=<key-b64url> \
#          beacon-install.sh <relay-url> <pairing-id>
#
# Canonical invocation — this is exactly the form the iOS app renders for the
# user to paste (see PROTOCOL.md):
#   curl -fsSL <relay>/beacon-install.sh | FLOTILLA_SECRET=<s> FLOTILLA_KEY=<k> bash -s -- <relay> <pairingID>
#
# The bearer secret and E2E key are read from FLOTILLA_SECRET/FLOTILLA_KEY env
# vars, never as positional args: argv is world-readable via
# /proc/<pid>/cmdline (and lands in shell history), while env vars land in
# /proc/<pid>/environ, which only root can read. Same fix as flotilla-seal's
# FLOTILLA_SEAL_KEY (commit 22a54a9); only <relay-url> and <pairing-id> — both
# non-secret — remain positional.
#
# Env override for dev: FLOTILLA_BEACON_BIN=/path/to/binary skips the download
# and copies the local systemd unit instead of fetching it from GitHub.
#
# Idempotent: safe to re-run. Every artifact (binary, config, unit file) is
# rewritten unconditionally, and the service is *restarted* (not just
# `enable --now`, which is a no-op on a unit that's already running) so a
# re-run actually picks up a new binary/config/pairing.
set -euo pipefail
[ $# -eq 2 ] || {
  echo "usage: FLOTILLA_SECRET=<secret-b64url> FLOTILLA_KEY=<key-b64url> $0 <relay> <pairing>"
  exit 1
}

BIN=/usr/local/bin/flotilla-beacon
CONF=/etc/flotilla-beacon.conf
UNIT=/etc/systemd/system/flotilla-beacon.service

# b64url_byte_len prints the decoded byte length of a base64url (no padding)
# string, or nothing if it doesn't decode at all — used below to validate
# FLOTILLA_SECRET/FLOTILLA_KEY are well-formed 32-byte values before they're
# ever written to disk, rather than silently installing a broken pairing.
b64url_byte_len() {
  local s="${1//-/+}"
  s="${s//_//}"
  case $(( ${#s} % 4 )) in
    2) s="${s}==" ;;
    3) s="${s}=" ;;
  esac
  printf '%s' "$s" | base64 -d 2>/dev/null | wc -c | tr -d ' '
}

[ -n "${FLOTILLA_SECRET:-}" ] || { echo "FLOTILLA_SECRET env var is required (32 random bytes, base64url — see PROTOCOL.md)"; exit 1; }
[ -n "${FLOTILLA_KEY:-}" ] || { echo "FLOTILLA_KEY env var is required (32 random bytes, base64url — see PROTOCOL.md)"; exit 1; }
[ "$(b64url_byte_len "$FLOTILLA_SECRET")" = 32 ] || { echo "FLOTILLA_SECRET is malformed: must decode to exactly 32 bytes as base64url"; exit 1; }
[ "$(b64url_byte_len "$FLOTILLA_KEY")" = 32 ] || { echo "FLOTILLA_KEY is malformed: must decode to exactly 32 bytes as base64url"; exit 1; }

# Cleans up any temp file left behind by an aborted download/write below (a
# `set -e` exit from curl, a validation failure, ...); harmless once the temp
# has already been moved into place (rm -f on a path that no longer exists).
TMP_BIN=""
TMP_CONF=""
cleanup() {
  [ -n "$TMP_BIN" ] && rm -f "$TMP_BIN"
  [ -n "$TMP_CONF" ] && rm -f "$TMP_CONF"
}
trap cleanup EXIT

if [ -n "${FLOTILLA_BEACON_BIN:-}" ]; then
  install -m 755 "$FLOTILLA_BEACON_BIN" "$BIN"
else
  ARCH=$(uname -m); case "$ARCH" in x86_64) A=amd64;; aarch64) A=arm64;; *) echo "unsupported arch $ARCH"; exit 1;; esac
  # Download to a temp file in the same directory as $BIN (so the final `mv`
  # is an atomic rename on the same filesystem), verify it looks like a real
  # binary, THEN replace $BIN. On the documented re-install path $BIN is the
  # binary systemd is about to restart — writing straight into it with
  # `curl -o` would leave a truncated, non-executable file in place after any
  # network hiccup, discovered only on the next reboot.
  TMP_BIN=$(mktemp "${BIN}.XXXXXX")
  curl -fsSL "https://github.com/Livin21/flotilla-agent/releases/latest/download/flotilla-beacon-linux-$A" -o "$TMP_BIN"
  SIZE=$(wc -c < "$TMP_BIN" | tr -d ' ')
  if [ "$SIZE" -lt 1000000 ]; then
    echo "downloaded binary looks truncated ($SIZE bytes) — aborting, $BIN left untouched"
    exit 1
  fi
  if [ "$(head -c4 "$TMP_BIN" | od -An -tx1 | tr -d ' \n')" != "7f454c46" ]; then
    echo "downloaded file is not an ELF binary — aborting, $BIN left untouched"
    exit 1
  fi
  chmod 755 "$TMP_BIN"
  mv -f "$TMP_BIN" "$BIN"
  TMP_BIN=""
fi

# umask only governs newly-created files, so on its own it wouldn't fix the
# permissions of a conf left behind by an older/hand-edited version of this
# script. Writing to a temp file (mode 600 from the start) and renaming into
# place both closes that permissions race on re-install (no window where a
# partially-written conf is readable at $CONF's final path with looser
# permissions) and keeps the write atomic — a re-run always replaces $CONF
# wholesale, never truncates it in place.
umask 077
TMP_CONF=$(mktemp "${CONF}.XXXXXX")
chmod 600 "$TMP_CONF"
cat > "$TMP_CONF" <<EOF
relay=$1
pairing=$2
secret=$FLOTILLA_SECRET
key=$FLOTILLA_KEY
EOF
mv -f "$TMP_CONF" "$CONF"
TMP_CONF=""

if [ -n "${FLOTILLA_BEACON_BIN:-}" ]; then
  cp "$(dirname "$0")/flotilla-beacon.service" "$UNIT"
else
  curl -fsSL "https://raw.githubusercontent.com/Livin21/flotilla-agent/main/beacon/flotilla-beacon.service" -o "$UNIT" \
    || cp "$(dirname "$0")/flotilla-beacon.service" "$UNIT"
fi

systemctl daemon-reload
systemctl enable flotilla-beacon
systemctl restart flotilla-beacon
echo "flotilla-beacon installed. Uninstall: systemctl disable --now flotilla-beacon; rm $BIN $CONF"
