#!/bin/bash
# send-event.sh <event> <subject> <description> <importance> <link>
# Seals and posts one event to the relay. Silent on all failures; 5s budget.
# I9: a transient failure (network error, timeout, or 5xx -- never a 4xx, which retrying
# would never fix and could re-trip the same rate cap) is queued to a small on-disk retry
# queue (bounded to 10 entries, oldest dropped) instead of the alert being lost outright.
# heartbeat.sh drains this queue on its next per-minute run -- see its own comment.
CFG="${FLOTILLA_CFG:-/boot/config/plugins/flotilla-agent/flotilla-agent.cfg}"
SEAL="${FLOTILLA_SEAL:-/usr/local/emhttp/plugins/flotilla-agent/flotilla-seal}"
QUEUE="${FLOTILLA_QUEUE:-/var/local/flotilla-agent.queue}"
[ -r "$CFG" ] || exit 0
source "$CFG"
RELAY="${RELAY_OVERRIDE:-$RELAY}"
[ -n "$PAIRING_ID" ] && [ -n "$SECRET" ] && [ -n "$KEY" ] || exit 0

EV="$1"; SUBJ="$2"; DESC="$3"; IMP="${4:-normal}"; LNK="$5"
case "$IMP" in alert) RANK=2; LEVEL="time-sensitive";; warning) RANK=1; LEVEL="active";; *) IMP="normal"; RANK=0; LEVEL="passive";; esac
case "${LEVEL_MIN:-warning}" in alert) MIN=2;; warning) MIN=1;; *) MIN=0;; esac
[ "$RANK" -ge "$MIN" ] || exit 0
# I7: classify on EVENT *and* SUBJECT together. Unraid's own EVENT string for a real disk
# alert is a generic wrapper (e.g. "Unraid Disk 1 message") -- the actual
# temperature/SMART/utilization signal lives in SUBJECT (e.g. "Warning [TOWER] - Disk 1 is
# hot (46 C)"), so classifying on EVENT alone let every real disk alert fall through to
# CAT_OTHER regardless of the "Disk events" toggle. Case-insensitive: Unraid's own casing of
# these words in the subject line isn't a documented contract.
CLASSIFY="$EV $SUBJ"
shopt -s nocasematch
case "$CLASSIFY" in
  *temperature*|*smart*|*utilization*|*hot*) [ "${CAT_DISKS:-yes}" = "yes" ] || exit 0;;
  *array*|*parity*|*pool*)                   [ "${CAT_ARRAY:-yes}" = "yes" ] || exit 0;;
  *)                                          [ "${CAT_OTHER:-yes}" = "yes" ] || exit 0;;
esac
shopt -u nocasematch

PAYLOAD=$(jq -cn --arg e "$EV" --arg s "$SUBJ" --arg d "$DESC" --arg i "$IMP" --arg l "$LNK" \
  '{v:1,event:$e,subject:$s,description:$d,importance:$i,link:$l,ts:(now|floor)}' 2>/dev/null) || exit 0
# Key goes via env, not argv --key: keeps it out of ps output (relevant for
# containers run with --pid=host).
SEALED=$(printf '%s' "$PAYLOAD" | FLOTILLA_SEAL_KEY="$KEY" "$SEAL" seal 2>/dev/null) || exit 0
BODY=$(jq -cn --arg p "$PAIRING_ID" --arg x "$SEALED" --arg lv "$LEVEL" '{pairingID:$p,sealed:$x,level:$lv}') || exit 0

HTTP=$(curl -s -m 5 -o /dev/null -w '%{http_code}' -X POST \
  -H "Authorization: Bearer $SECRET" -H "Content-Type: application/json" \
  -d "$BODY" "$RELAY/v1/push" 2>/dev/null)
RC=$?
if [ "$RC" -ne 0 ] || [ "${HTTP:0:1}" = "5" ] || [ -z "$HTTP" ]; then
  # Transient failure (curl itself failed -- timeout/refused/black-holed -- or the relay
  # answered 5xx): queue BODY for heartbeat.sh to retry, keeping only the newest 10 lines
  # (oldest dropped first) so a persistently-down relay can never grow this file unbounded.
  # A 4xx (bad auth, capped, entitlement) is deliberately NOT queued here -- retrying a
  # rejected request forever would be pointless and could re-trip the same cap.
  #
  # Same discipline as heartbeat.sh's header capture: mkdir -p is best-effort, and the write
  # only happens once the directory is confirmed to actually exist and be writable -- a queue
  # dir that can't be created (read-only /var, disk full, ...) must silently drop this one
  # event, never leak a "No such file or directory" from a doomed redirect into a would-be
  # 5s-budget notify hook, and never touch the exit code below either way.
  QDIR=$(dirname "$QUEUE")
  mkdir -p "$QDIR" 2>/dev/null
  if [ -d "$QDIR" ] && [ -w "$QDIR" ]; then
    { [ -f "$QUEUE" ] && cat "$QUEUE"; printf '%s\n' "$BODY"; } 2>/dev/null | tail -n 10 > "$QUEUE.tmp.$$" 2>/dev/null \
      && mv -f "$QUEUE.tmp.$$" "$QUEUE" 2>/dev/null
    rm -f "$QUEUE.tmp.$$" 2>/dev/null
  fi
fi
exit 0
