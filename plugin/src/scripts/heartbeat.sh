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

# I9: drain send-event.sh's on-disk retry queue (bounded to 10 entries there). Best-effort,
# oldest first; stops at the first non-2xx response rather than burning this cron minute
# retrying every remaining entry against a relay that's almost certainly still down for all of
# them -- whatever's left just waits for the next heartbeat tick. Never blocks the heartbeat
# send above (runs after it, and the whole drain is itself best-effort/silent) and never
# grows or retries unbounded: queuing itself is what caps this at 10 (send-event.sh), and a
# permanently-undeliverable entry is eventually evicted there by newer failures.
QUEUE="${FLOTILLA_QUEUE:-/var/local/flotilla-agent.queue}"
if [ -s "$QUEUE" ] 2>/dev/null; then
  PENDING=()
  FAILED=0
  while IFS= read -r LINE || [ -n "$LINE" ]; do
    [ -n "$LINE" ] || continue
    if [ "$FAILED" -eq 1 ]; then PENDING+=("$LINE"); continue; fi
    CODE=$(curl -s -m 3 -o /dev/null -w '%{http_code}' -X POST \
      -H "Authorization: Bearer $SECRET" -H "Content-Type: application/json" \
      -d "$LINE" "$RELAY/v1/push" 2>/dev/null)
    case "$CODE" in
      2??) ;; # delivered -- drop it from the queue
      *) FAILED=1; PENDING+=("$LINE");;
    esac
  done < "$QUEUE"
  if [ "${#PENDING[@]}" -eq 0 ]; then
    rm -f "$QUEUE" 2>/dev/null
  elif [ -w "$(dirname "$QUEUE")" ]; then
    printf '%s\n' "${PENDING[@]}" > "$QUEUE.tmp.$$" 2>/dev/null && mv -f "$QUEUE.tmp.$$" "$QUEUE" 2>/dev/null
    rm -f "$QUEUE.tmp.$$" 2>/dev/null
  fi
fi
exit 0
