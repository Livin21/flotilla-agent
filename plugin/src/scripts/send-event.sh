#!/bin/bash
# send-event.sh <event> <subject> <description> <importance> <link>
# Seals and posts one event to the relay. Silent on all failures; 5s budget.
CFG="${FLOTILLA_CFG:-/boot/config/plugins/flotilla-agent/flotilla-agent.cfg}"
SEAL="${FLOTILLA_SEAL:-/usr/local/emhttp/plugins/flotilla-agent/flotilla-seal}"
[ -r "$CFG" ] || exit 0
source "$CFG"
RELAY="${RELAY_OVERRIDE:-$RELAY}"
[ -n "$PAIRING_ID" ] && [ -n "$SECRET" ] && [ -n "$KEY" ] || exit 0

EV="$1"; SUBJ="$2"; DESC="$3"; IMP="${4:-normal}"; LNK="$5"
case "$IMP" in alert) RANK=2; LEVEL="time-sensitive";; warning) RANK=1; LEVEL="active";; *) IMP="normal"; RANK=0; LEVEL="passive";; esac
case "${LEVEL_MIN:-warning}" in alert) MIN=2;; warning) MIN=1;; *) MIN=0;; esac
[ "$RANK" -ge "$MIN" ] || exit 0
case "$EV" in
  *temperature*|*SMART*|*utilization*) [ "${CAT_DISKS:-yes}" = "yes" ] || exit 0;;
  *array*|*parity*|*pool*)             [ "${CAT_ARRAY:-yes}" = "yes" ] || exit 0;;
  *)                                   [ "${CAT_OTHER:-yes}" = "yes" ] || exit 0;;
esac

PAYLOAD=$(jq -cn --arg e "$EV" --arg s "$SUBJ" --arg d "$DESC" --arg i "$IMP" --arg l "$LNK" \
  '{v:1,event:$e,subject:$s,description:$d,importance:$i,link:$l,ts:(now|floor)}') || exit 0
SEALED=$(printf '%s' "$PAYLOAD" | "$SEAL" seal --key "$KEY" 2>/dev/null) || exit 0
jq -cn --arg p "$PAIRING_ID" --arg x "$SEALED" --arg lv "$LEVEL" '{pairingID:$p,sealed:$x,level:$lv}' | \
  curl -s -m 5 -X POST -H "Authorization: Bearer $SECRET" -H "Content-Type: application/json" \
       -d @- "$RELAY/v1/push" >/dev/null 2>&1
exit 0
