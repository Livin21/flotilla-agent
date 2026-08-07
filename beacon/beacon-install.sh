#!/bin/bash
# Usage: FLOTILLA_SECRET=<secret-b64url> FLOTILLA_KEY=<key-b64url> \
#          beacon-install.sh <relay-url> <pairing-id>
#
# Canonical invocation — this is exactly the form the iOS app renders for the
# user to paste (see PROTOCOL.md). This script is fetched straight from this
# repo's GitHub raw URL, not from the relay:
#   curl -fsSL https://raw.githubusercontent.com/Livin21/flotilla-agent/main/beacon/beacon-install.sh | FLOTILLA_SECRET=<s> FLOTILLA_KEY=<k> bash -s -- <relay> <pairingID>
#
# The bearer secret and E2E key are read from FLOTILLA_SECRET/FLOTILLA_KEY env
# vars, never as positional args: argv is world-readable via
# /proc/<pid>/cmdline (and lands in shell history), while env vars land in
# /proc/<pid>/environ, which only root can read. Same fix as flotilla-seal's
# FLOTILLA_SEAL_KEY (commit 22a54a9); only <relay-url> and <pairing-id> — both
# non-secret — remain positional.
#
# Env override for dev: FLOTILLA_BEACON_BIN=/path/to/binary skips the release
# download and installs that file instead.
#
# Other optional env vars:
#   FLOTILLA_LISTEN=<host:port>  where the beacon listens, and therefore the URL the
#                                PVE webhook target is pointed at. Default 127.0.0.1:8799.
#   FLOTILLA_SKIP_PVE=1          install the service but don't touch PVE's notification
#                                config; the exact manual values are printed instead.
#   FLOTILLA_PVE_TARGET=<name>   name of the PVE notification target/matcher pair to
#                                create. Default "flotilla".
#
# Idempotent: safe to re-run. Every artifact (binary, config, unit file) is
# rewritten unconditionally, and the service is *restarted* (not just
# `enable --now`, which is a no-op on a unit that's already running) so a
# re-run actually picks up a new binary/config/pairing.
set -euo pipefail
[ $# -eq 2 ] || {
  echo "usage: FLOTILLA_SECRET=<secret-b64url> FLOTILLA_KEY=<key-b64url> $0 <relay> <pairing>"
  echo "  optional: FLOTILLA_BEACON_BIN=<path-to-local-binary> installs that binary instead of"
  echo "  downloading a GitHub release -- for testing before a release is published."
  echo "  optional: FLOTILLA_LISTEN=<host:port> (default 127.0.0.1:8799)"
  echo "  optional: FLOTILLA_SKIP_PVE=1 to print the PVE notification config instead of applying it"
  echo "  optional: FLOTILLA_PVE_TARGET=<name> (default flotilla)"
  exit 1
}

BIN=/usr/local/bin/flotilla-beacon
CONF=/etc/flotilla-beacon.conf
UNIT=/etc/systemd/system/flotilla-beacon.service
LISTEN="${FLOTILLA_LISTEN:-127.0.0.1:8799}"
PVE_TARGET="${FLOTILLA_PVE_TARGET:-flotilla}"

# The PVE notification target this script creates has to match what handleWebhook (and
# authorized()) in cmd/flotilla-beacon/main.go actually expect, so both halves are derived
# here from a single set of values rather than documented twice and drifting.
#
# PVE stores webhook header and body values base64-encoded, so both are encoded here.
# The body template is PVE's own handlebars-ish syntax: `{{ json <field> }}` emits a
# correctly-quoted/escaped JSON string, which is what lets arbitrary notification text
# through unmangled.
WEBHOOK_URL="http://$LISTEN/"
WEBHOOK_BODY='{"severity":{{ json severity }},"title":{{ json title }},"message":{{ json message }}}'

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
#
# The trailing `return 0` matters: bash uses the exit status of the *last
# command run in an EXIT trap* as the process's own exit status whenever
# that command doesn't itself succeed — even overriding an explicit `exit N`
# that already ran before the trap fired. Without it, `[ -n "$TMP_CONF" ] &&
# rm -f "$TMP_CONF"` is false on every successful run (TMP_CONF is "" by
# then), so every successful install — fresh or re-install — silently exited
# 1. Confirmed empirically: even `exit 7` upstream got overridden to 1.
TMP_BIN=""
TMP_CONF=""
cleanup() {
  [ -n "$TMP_BIN" ] && rm -f "$TMP_BIN"
  [ -n "$TMP_CONF" ] && rm -f "$TMP_CONF"
  return 0
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
  # --remove-on-error so a failing transfer doesn't leave a zero-byte file behind for the
  # size/ELF checks below to have to catch.
  TMP_BIN=$(mktemp "${BIN}.XXXXXX")
  curl -fsSL --remove-on-error "https://github.com/Livin21/flotilla-agent/releases/latest/download/flotilla-beacon-linux-$A" -o "$TMP_BIN"
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
listen=$LISTEN
EOF
mv -f "$TMP_CONF" "$CONF"
TMP_CONF=""

# The unit is embedded rather than fetched. It used to be downloaded from
# raw.githubusercontent.com with `|| cp "$(dirname "$0")/flotilla-beacon.service"` as a
# fallback -- which can never fire usefully under the documented `curl ... | bash -s -- ...`
# invocation, because $0 is then "bash" and dirname "$0" is ".". A download failure therefore
# aborted under `set -e` AFTER $BIN and $CONF (holding S and K) had already been written,
# leaving the host with a binary, a secret-bearing config, no unit, and possibly a zero-byte
# $UNIT that `curl -o` had already created. Embedding removes the second network dependency
# entirely. test/agent_test.sh asserts this heredoc stays byte-identical to
# beacon/flotilla-beacon.service, so the two cannot drift.
cat > "$UNIT" <<'FLOTILLA_UNIT'
[Unit]
Description=Flotilla beacon (PVE push companion)
After=network-online.target
Wants=network-online.target
# I11: with Restart=on-failure and RestartSec=5, systemd's own defaults
# (StartLimitIntervalSec=10s, StartLimitBurst=5) are never reached -- 5-second
# spacing is only two starts per 10s window -- so a permanently broken install
# restarted every 5 seconds forever. Both realistic causes log.Fatal at startup:
# /etc/flotilla-beacon.conf missing or malformed, and the listen port already
# bound. That wrote to the journal indefinitely and never surfaced as a failed
# unit an operator would notice in `systemctl status`. A 60s window with the same
# burst of 5 gives up after ~25s and lands the unit in `failed` instead.
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
ExecStart=/usr/local/bin/flotilla-beacon
Restart=on-failure
RestartSec=5
# The SIGTERM handler pre-empts (cancels) any periodic "ok" heartbeat still
# in flight rather than waiting it out, then sends going-down with its own
# ~3s budget (goingDownTimeout in cmd/flotilla-beacon/main.go) before
# closing the listener — so the relay's dead-man switch doesn't page on a
# planned reboot/stop. An earlier version serialized sends behind a mutex
# held across the network call instead: a stuck "ok" and a stuck going-down
# could compound to ~10s, at the edge of (and occasionally past) a 10s
# TimeoutStopSec, letting systemd SIGKILL before going-down ever reached the
# relay. 15s gives real margin above the ~3s worst case (going-down's own
# timeout; the pre-empted "ok" no longer contributes meaningfully) and the
# process's own exit, without letting a genuinely stuck shutdown stall the
# rest of the host's stop sequence — systemd SIGKILLs once this elapses.
TimeoutStopSec=15

# I11: the beacon runs as root with a listening socket and had no hardening at all.
# It reads exactly one file (/etc/flotilla-beacon.conf), writes nothing anywhere, and
# needs only a loopback bind plus outbound HTTPS to the relay — so the standard set
# costs it nothing. ProtectSystem=strict with no ReadWritePaths= makes the entire
# filesystem read-only to the service; reads (the conf, /etc/resolv.conf, the CA
# bundle) are unaffected.
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
RestrictRealtime=yes
LockPersonality=yes
# AF_NETLINK is included deliberately: Go's pure-Go resolver and net package can
# consult netlink for interface/route information on Linux, and a DNS failure here
# would break every relay POST while looking like a network outage. AF_UNIX is needed
# to reach journald.
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK

[Install]
WantedBy=multi-user.target
FLOTILLA_UNIT

systemctl daemon-reload
systemctl enable flotilla-beacon
systemctl restart flotilla-beacon

# --- Proxmox notification target ------------------------------------------------------------
# I4: this step did not exist. The installer wrote the binary, the config and the unit, and
# stopped -- so heartbeats flowed (the app showed the server online and healthy) while PVE was
# never told to send anything to the beacon and ZERO events ever reached the phone. Silent from
# both ends, and nothing in the repo documented the URL, the bearer header or the body template
# a hand-configured target would need. README.md claimed this step happened.
#
# Two matching pieces are required, and PVE will not deliver anything with only one of them:
#   * a webhook *target* (endpoint) saying where and how to POST, and
#   * a *matcher* saying which notifications go to that target.
# The matcher is restricted to warning+error so the beacon (and the user's phone) doesn't see
# every routine info-level PVE notification. It is additive: PVE's stock default-matcher, which
# routes everything to mail-to-root, is left completely alone.
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

print_pve_manual() {
  cat <<EOM

Configure Proxmox to notify the beacon (Datacenter -> Notifications -> Add -> Webhook):
  Name:   $PVE_TARGET
  Method: POST
  URL:    $WEBHOOK_URL
  Header: Authorization: Bearer <the 'secret' value in $CONF>
  Body:   $WEBHOOK_BODY
...then add a Notification Matcher targeting "$PVE_TARGET" with severity warning and error.

Or from a shell on this node:
  pvesh create /cluster/notifications/endpoints/webhook --name $PVE_TARGET --method post \\
    --url '$WEBHOOK_URL' --header "name=Authorization,value=\$(printf 'Bearer %s' "\$SECRET" | base64 -w0)" \\
    --body '$(b64 "$WEBHOOK_BODY")'
  pvesh create /cluster/notifications/matchers --name $PVE_TARGET --target $PVE_TARGET \\
    --mode all --match-severity warning --match-severity error
  # ...where \$SECRET is the 'secret=' line in $CONF.

Send a test notification once configured (PVE 8.4+):
  pvesh create /cluster/notifications/targets/$PVE_TARGET/test
EOM
}

configure_pve() {
  # Delete in the reverse of create order: PVE refuses to remove a target a matcher still
  # references. Both deletes are best-effort -- on a first install neither exists.
  pvesh delete "/cluster/notifications/matchers/$PVE_TARGET" >/dev/null 2>&1 || true
  pvesh delete "/cluster/notifications/endpoints/webhook/$PVE_TARGET" >/dev/null 2>&1 || true

  pvesh create /cluster/notifications/endpoints/webhook \
    --name "$PVE_TARGET" \
    --method post \
    --url "$WEBHOOK_URL" \
    --header "name=Authorization,value=$(b64 "Bearer $FLOTILLA_SECRET")" \
    --body "$(b64 "$WEBHOOK_BODY")" \
    --comment "Flotilla Push (flotilla-beacon)" >/dev/null 2>&1 || return 1

  # match-severity is a list-typed parameter. Whether PVE's CLI wants it repeated or
  # comma-separated has varied across versions, so try both rather than guess.
  pvesh create /cluster/notifications/matchers \
    --name "$PVE_TARGET" --target "$PVE_TARGET" --mode all \
    --match-severity warning --match-severity error \
    --comment "Flotilla Push: warnings and errors" >/dev/null 2>&1 \
  || pvesh create /cluster/notifications/matchers \
    --name "$PVE_TARGET" --target "$PVE_TARGET" --mode all \
    --match-severity warning,error \
    --comment "Flotilla Push: warnings and errors" >/dev/null 2>&1 \
  || return 1

  # `create` returning 0 is not proof the config is readable back, so verify both halves.
  pvesh get "/cluster/notifications/endpoints/webhook/$PVE_TARGET" >/dev/null 2>&1 || return 1
  pvesh get "/cluster/notifications/matchers/$PVE_TARGET" >/dev/null 2>&1 || return 1
}

echo "flotilla-beacon installed (listening on $LISTEN)."
if [ "${FLOTILLA_SKIP_PVE:-}" = "1" ]; then
  echo "FLOTILLA_SKIP_PVE=1: PVE's notification config was left untouched."
  print_pve_manual
elif ! command -v pvesh >/dev/null 2>&1; then
  echo "WARNING: pvesh not found -- this does not look like a Proxmox VE node, so PVE's"
  echo "notification config was NOT changed. The beacon is running but will receive nothing."
  print_pve_manual
elif configure_pve; then
  echo "Proxmox notification target and matcher '$PVE_TARGET' configured (severity: warning, error)."
  echo "Send a test notification with: pvesh create /cluster/notifications/targets/$PVE_TARGET/test"
else
  echo "WARNING: could not configure PVE's notification target automatically."
  echo "The beacon is installed and running, but NO PVE events will reach your phone until a"
  echo "webhook target and a matcher exist. Configure them by hand:"
  print_pve_manual
fi
echo
echo "Uninstall: systemctl disable --now flotilla-beacon; rm $BIN $CONF $UNIT"
echo "           pvesh delete /cluster/notifications/matchers/$PVE_TARGET"
echo "           pvesh delete /cluster/notifications/endpoints/webhook/$PVE_TARGET"
