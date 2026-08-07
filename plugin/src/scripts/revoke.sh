#!/bin/bash
# Revokes the current pairing at the relay (DELETE /v1/pairing). Called from
# settings.php's flotilla_pair() on the "Reset pairing" path, BEFORE new
# pairing values are generated -- while the old PAIRING_ID/SECRET are still
# known. Without this, resetting locally silently orphans the relay-side
# Durable Object (its device tokens stay registered and the dead-man switch
# still fires one final "Server unreachable" push).
#
# Same discipline as heartbeat.sh/send-event.sh: 5s timeout, silent on every
# failure, ALWAYS exit 0 -- a relay that's unreachable must never block a
# local reset.
CFG="${FLOTILLA_CFG:-/boot/config/plugins/flotilla-agent/flotilla-agent.cfg}"
[ -r "$CFG" ] || exit 0
source "$CFG"
RELAY="${RELAY_OVERRIDE:-$RELAY}"
[ -n "$PAIRING_ID" ] && [ -n "$SECRET" ] || exit 0

# I2: S goes to curl via a config file on a process-substituted fd, never as an argv `-H`
# header (/proc/<pid>/cmdline is world-readable). See send-event.sh's full comment.
jq -cn --arg p "$PAIRING_ID" '{pairingID:$p}' | \
  curl -s -m 5 -X DELETE \
       -K <(printf 'header = "Authorization: Bearer %s"\n' "$SECRET") \
       -H "Content-Type: application/json" \
       -d @- "$RELAY/v1/pairing" >/dev/null 2>&1
exit 0
