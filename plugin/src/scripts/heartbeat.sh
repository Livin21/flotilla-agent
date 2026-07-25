#!/bin/bash
# Cron: every minute. STATE=going-down supported for the stopping_array hook.
CFG="${FLOTILLA_CFG:-/boot/config/plugins/flotilla-agent/flotilla-agent.cfg}"
[ -r "$CFG" ] || exit 0
source "$CFG"
[ -n "$PAIRING_ID" ] && [ -n "$SECRET" ] || exit 0
# Overridable so the stopping_array hook can pass a tighter budget (e.g. 2s)
# for the going-down heartbeat, which it sends synchronously before teardown.
TIMEOUT="${HEARTBEAT_TIMEOUT:-5}"

# Task 13 §8: capture the relay's response headers (X-Min-Agent) once per beat, so
# FlotillaAgent.page can warn when the relay requires a newer agent than installed.
# This must NEVER be able to block or drop the actual heartbeat delivery -- a curl
# `-D <path>` whose parent directory doesn't exist (or isn't writable) fails the
# *entire* request (verified: curl exits 23 and the server never even sees it), which
# would turn a cosmetic version-nag feature into a dead-man-switch false positive.
# So header capture is opt-in per beat: only pass -D when the directory is confirmed
# writable (after a best-effort mkdir -p); otherwise the heartbeat still sends,
# just without refreshing the header file that beat.
HDR_FILE="${FLOTILLA_HEADERS:-/var/local/flotilla-agent.headers}"
HDR_DIR=$(dirname "$HDR_FILE")
mkdir -p "$HDR_DIR" 2>/dev/null
DUMP_ARGS=()
[ -w "$HDR_DIR" ] && DUMP_ARGS=(-D "$HDR_FILE")

jq -cn --arg p "$PAIRING_ID" --arg s "${STATE:-ok}" '{pairingID:$p,state:$s}' | \
  curl -s -m "$TIMEOUT" "${DUMP_ARGS[@]}" -X POST -H "Authorization: Bearer $SECRET" -H "Content-Type: application/json" \
       -d @- "$RELAY/v1/heartbeat" >/dev/null 2>&1
exit 0
