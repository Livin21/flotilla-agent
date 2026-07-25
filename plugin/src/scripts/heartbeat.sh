#!/bin/bash
# Cron: every minute. STATE=going-down supported for the stopping_array hook.
CFG="${FLOTILLA_CFG:-/boot/config/plugins/flotilla-agent/flotilla-agent.cfg}"
[ -r "$CFG" ] || exit 0
source "$CFG"
[ -n "$PAIRING_ID" ] && [ -n "$SECRET" ] || exit 0
# Overridable so the stopping_array hook can pass a tighter budget (e.g. 2s)
# for the going-down heartbeat, which it sends synchronously before teardown.
TIMEOUT="${HEARTBEAT_TIMEOUT:-5}"
jq -cn --arg p "$PAIRING_ID" --arg s "${STATE:-ok}" '{pairingID:$p,state:$s}' | \
  curl -s -m "$TIMEOUT" -X POST -H "Authorization: Bearer $SECRET" -H "Content-Type: application/json" \
       -d @- "$RELAY/v1/heartbeat" >/dev/null 2>&1
exit 0
