#!/bin/bash
# Cron: every minute. STATE=going-down supported for the stopping_array hook.
CFG="${FLOTILLA_CFG:-/boot/config/plugins/flotilla-agent/flotilla-agent.cfg}"
[ -r "$CFG" ] || exit 0
source "$CFG"
[ -n "$PAIRING_ID" ] && [ -n "$SECRET" ] || exit 0
jq -cn --arg p "$PAIRING_ID" --arg s "${STATE:-ok}" '{pairingID:$p,state:$s}' | \
  curl -s -m 5 -X POST -H "Authorization: Bearer $SECRET" -H "Content-Type: application/json" \
       -d @- "$RELAY/v1/heartbeat" >/dev/null 2>&1
exit 0
