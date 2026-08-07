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

# I2: S goes to curl via a config file on a process-substituted fd, never as an argv `-H`
# header -- /proc/<pid>/cmdline is world-readable, and this is the call site an attacker can
# rely on catching, since it fires every 60s from cron. See send-event.sh's full comment.
jq -cn --arg p "$PAIRING_ID" --arg s "${STATE:-ok}" '{pairingID:$p,state:$s}' | \
  curl -s -m "$TIMEOUT" "${DUMP_ARGS[@]}" -X POST \
       -K <(printf 'header = "Authorization: Bearer %s"\n' "$SECRET") \
       -H "Content-Type: application/json" \
       -d @- "$RELAY/v1/heartbeat" >/dev/null 2>&1

# I9: drain send-event.sh's on-disk retry queue (bounded to 10 entries there). Best-effort,
# oldest first; stops at the first retryable failure rather than burning this cron minute
# retrying every remaining entry against a relay that's almost certainly still down for all of
# them -- whatever's left just waits for the next heartbeat tick. Never blocks the heartbeat
# send above (runs after it, and the whole drain is itself best-effort/silent).
#
# I3: the drain is SKIPPED ENTIRELY on the shutdown path. event-stopping-array.sh calls this
# script with HEARTBEAT_TIMEOUT=2 STATE=going-down and documents a "<=2s stall on Stop Array"
# budget for it -- but HEARTBEAT_TIMEOUT bounded only the heartbeat above. The drain then ran
# synchronously anyway with its own separate per-entry timeout, so the real worst case inside
# Unraid's stopping_array hook (which also fires as a step in Reboot/Shutdown) was ~5s with the
# relay unreachable and ~32s with a slow-but-answering relay and a full queue. Draining during
# a shutdown is pointless regardless: the box is going away, and the queue is picked back up by
# the per-minute cron on the next boot.
#
# The remaining ok-path drain is bounded twice over: per request by $DRAIN_TIMEOUT, and in
# total wall clock by $DRAIN_BUDGET, so it can never run past its own cron minute into the next
# invocation no matter how the entry cap or the timeouts are tuned later. Both are overridable
# purely for testability, like every other path/knob in this script.
QUEUE="${FLOTILLA_QUEUE:-/var/local/flotilla-agent.queue}"
DRAIN_TIMEOUT="${FLOTILLA_DRAIN_TIMEOUT:-3}"
DRAIN_BUDGET="${FLOTILLA_DRAIN_BUDGET:-30}"
if [ "${STATE:-ok}" = "ok" ] && [ -s "$QUEUE" ] 2>/dev/null; then
  PENDING=()
  FAILED=0
  DRAIN_START=$SECONDS
  while IFS= read -r LINE || [ -n "$LINE" ]; do
    [ -n "$LINE" ] || continue
    if [ "$FAILED" -eq 1 ]; then PENDING+=("$LINE"); continue; fi
    if [ $(( SECONDS - DRAIN_START )) -ge "$DRAIN_BUDGET" ]; then FAILED=1; PENDING+=("$LINE"); continue; fi
    CODE=$(printf '%s' "$LINE" | curl -s -m "$DRAIN_TIMEOUT" -o /dev/null -w '%{http_code}' -X POST \
      -K <(printf 'header = "Authorization: Bearer %s"\n' "$SECRET") \
      -H "Content-Type: application/json" \
      -d @- "$RELAY/v1/push" 2>/dev/null)
    case "$CODE" in
      2??) ;; # delivered -- drop it from the queue
      # I8: a 4xx is permanent, so drop the entry instead of re-queueing it -- mirroring
      # send-event.sh's "never queue a 4xx" rule, which this loop used to contradict. Without
      # this, one entry that can never succeed (the realistic case: an event queued during an
      # outage, then "Reset pairing" -- the queued body carries the OLD pairingID but the drain
      # sends it with the NEW secret, so it 401s forever) pinned itself at the queue head and
      # blocked every deliverable entry behind it, permanently, once a minute. send-event.sh's
      # eviction couldn't clear it either: that only fires on NEW failures, which stop happening
      # as soon as the relay is healthy again.
      4??) ;;
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
