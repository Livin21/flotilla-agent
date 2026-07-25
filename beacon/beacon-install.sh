#!/bin/bash
# Usage: beacon-install.sh <relay-url> <pairing-id> <secret-b64url> <key-b64url>
# Env override for dev: FLOTILLA_BEACON_BIN=/path/to/binary skips the download
# and copies the local systemd unit instead of fetching it from GitHub.
#
# Idempotent: safe to re-run. Every artifact (binary, config, unit file) is
# rewritten unconditionally, and the service is *restarted* (not just
# `enable --now`, which is a no-op on a unit that's already running) so a
# re-run actually picks up a new binary/config/pairing.
set -euo pipefail
[ $# -eq 4 ] || { echo "usage: $0 <relay> <pairing> <secret> <key>"; exit 1; }

BIN=/usr/local/bin/flotilla-beacon
CONF=/etc/flotilla-beacon.conf
UNIT=/etc/systemd/system/flotilla-beacon.service

if [ -n "${FLOTILLA_BEACON_BIN:-}" ]; then
  install -m 755 "$FLOTILLA_BEACON_BIN" "$BIN"
else
  ARCH=$(uname -m); case "$ARCH" in x86_64) A=amd64;; aarch64) A=arm64;; *) echo "unsupported arch $ARCH"; exit 1;; esac
  curl -fsSL "https://github.com/Livin21/flotilla-agent/releases/latest/download/flotilla-beacon-linux-$A" -o "$BIN"
  chmod 755 "$BIN"
fi

# umask only governs newly-created files, so on its own it wouldn't fix the
# permissions of a conf left behind by an older/hand-edited version of this
# script. This file holds the E2E key and bearer secret in plaintext — always
# force it back to owner-only below regardless of any prior state.
umask 077
cat > "$CONF" <<EOF
relay=$1
pairing=$2
secret=$3
key=$4
EOF
chmod 600 "$CONF"

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
