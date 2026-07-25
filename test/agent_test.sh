#!/bin/bash
# Tests send-event.sh + heartbeat.sh against a local capture server. Needs: jq, python3, go.
set -euo pipefail
cd "$(dirname "$0")/.."
FAIL=0; t() { if "$@"; then echo "ok: $NAME"; else echo "FAIL: $NAME"; FAIL=1; fi; }

go build -o /tmp/flotilla-seal ./cmd/flotilla-seal
K=$(/tmp/flotilla-seal keygen); S=$(/tmp/flotilla-seal keygen)
TMP=$(mktemp -d); CAP="$TMP/cap.jsonl"
python3 test/capture_server.py 18799 "$CAP" & SRV=$!; trap 'kill $SRV' EXIT; sleep 0.3

CFG="$TMP/flotilla-agent.cfg"
cat > "$CFG" <<EOF
RELAY="http://127.0.0.1:18799"
PAIRING_ID="11111111-1111-4111-8111-111111111111"
SECRET="$S"
KEY="$K"
LEVEL_MIN="warning"
CAT_DISKS="yes"
CAT_ARRAY="yes"
CAT_OTHER="yes"
EOF
run() { FLOTILLA_CFG="$CFG" FLOTILLA_SEAL=/tmp/flotilla-seal \
  EVENT="$1" SUBJECT="$2" DESCRIPTION="$3" IMPORTANCE="$4" CONTENT="" LINK="/Main" \
  bash plugin/src/scripts/agent.sh; }

NAME="warning event is sent and decrypts to the right payload"
run "Unraid disk temperature" "Warning [TOWER] - disk1 is hot (46 C)" "WDC (sdb)" "warning"
sleep 0.3
SEALED=$(tail -1 "$CAP" | jq -r '.body | fromjson | .sealed')
PLAIN=$(echo "$SEALED" | /tmp/flotilla-seal open --key "$K")
t [ "$(echo "$PLAIN" | jq -r .subject)" = "Warning [TOWER] - disk1 is hot (46 C)" ]
NAME="auth bearer carries S"; t [ "$(tail -1 "$CAP" | jq -r .auth)" = "Bearer $S" ]
NAME="level maps warning→active"; t [ "$(tail -1 "$CAP" | jq -r '.body | fromjson | .level')" = "active" ]

NAME="normal filtered under warning threshold"
N=$(wc -l < "$CAP"); run "Unraid status" "Notice [TOWER] - all good" "" "normal"; sleep 0.3
t [ "$(wc -l < "$CAP")" -eq "$N" ]

NAME="category toggle filters disk events"
sed -i.bak 's/CAT_DISKS="yes"/CAT_DISKS="no"/' "$CFG"
N=$(wc -l < "$CAP"); run "Unraid disk temperature" "Warning hot" "" "alert"; sleep 0.3
t [ "$(wc -l < "$CAP")" -eq "$N" ]
sed -i.bak 's/CAT_DISKS="no"/CAT_DISKS="yes"/' "$CFG"

NAME="heartbeat posts ok state"
FLOTILLA_CFG="$CFG" bash plugin/src/scripts/heartbeat.sh; sleep 0.3
t [ "$(tail -1 "$CAP" | jq -r '.path')" = "/v1/heartbeat" ]
NAME="heartbeat body state is ok"
t [ "$(tail -1 "$CAP" | jq -r '.body | fromjson | .state')" = "ok" ]

NAME="heartbeat STATE=going-down posts going-down state"
STATE="going-down" FLOTILLA_CFG="$CFG" bash plugin/src/scripts/heartbeat.sh; sleep 0.3
t [ "$(tail -1 "$CAP" | jq -r '.body | fromjson | .state')" = "going-down" ]

# Task 13 §8: heartbeat.sh captures the relay's X-Min-Agent response header so
# FlotillaAgent.page can warn about a stale agent. capture_server.py sends that header
# on every response (mirroring flotilla-relay), so this proves the -D capture actually
# lands, then proves the capture is never allowed to endanger heartbeat delivery itself.
NAME="heartbeat captures relay's X-Min-Agent response header"
HDR="$TMP/headers.txt"; rm -f "$HDR"
FLOTILLA_CFG="$CFG" FLOTILLA_HEADERS="$HDR" bash plugin/src/scripts/heartbeat.sh; sleep 0.3
t [ "$(grep -i '^X-Min-Agent:' "$HDR" | tr -d '\r\n' | awk '{print $2}')" = "1.0.0" ]

NAME="heartbeat still delivers when the header directory can't be created (never blocks on capture)"
N=$(wc -l < "$CAP")
RC=0
FLOTILLA_CFG="$CFG" FLOTILLA_HEADERS="/flotilla_test_readonly_$$/headers.txt" \
  bash plugin/src/scripts/heartbeat.sh || RC=$?
sleep 0.3
t [ "$(wc -l < "$CAP")" -gt "$N" ]
NAME="heartbeat exits 0 even when the header directory can't be created"
t [ "$RC" -eq 0 ]

# 10.255.255.1 black-holes (see note further down); reuse it here to prove
# HEARTBEAT_TIMEOUT actually reaches curl's -m flag. The stopping_array hook
# passes HEARTBEAT_TIMEOUT=2 for its synchronous going-down send, specifically
# so a planned reboot/shutdown can't stall past a couple of seconds waiting on
# an unreachable relay. Uncapped, heartbeat.sh keeps its normal 5s cron budget.
BHCFG="$TMP/flotilla-agent-blackhole.cfg"
sed 's#^RELAY=.*#RELAY="http://10.255.255.1:1"#' "$CFG" > "$BHCFG"

NAME="heartbeat default timeout (~5s) unaffected against a black-holed relay"
START=$(date +%s)
FLOTILLA_CFG="$BHCFG" bash plugin/src/scripts/heartbeat.sh
ELAPSED=$(( $(date +%s) - START ))
IN_RANGE=0; [ "$ELAPSED" -ge 4 ] && [ "$ELAPSED" -le 8 ] && IN_RANGE=1
t [ "$IN_RANGE" -eq 1 ]

NAME="HEARTBEAT_TIMEOUT=2 reaches curl -m, bounding the going-down heartbeat to ~2s"
START=$(date +%s)
HEARTBEAT_TIMEOUT=2 STATE="going-down" FLOTILLA_CFG="$BHCFG" bash plugin/src/scripts/heartbeat.sh
ELAPSED=$(( $(date +%s) - START ))
IN_RANGE=0; [ "$ELAPSED" -ge 1 ] && [ "$ELAPSED" -le 4 ] && IN_RANGE=1
t [ "$IN_RANGE" -eq 1 ]

NAME="relay connection-refused: agent exits 0 fast (never blocks notify)"
START=$(date +%s)
FLOTILLA_CFG="$CFG" FLOTILLA_SEAL=/tmp/flotilla-seal RELAY_OVERRIDE="http://127.0.0.1:1" \
  EVENT="x" SUBJECT="y" DESCRIPTION="" IMPORTANCE="alert" CONTENT="" LINK="" bash plugin/src/scripts/agent.sh
t [ $(( $(date +%s) - START )) -le 2 ]

# 10.255.255.1 is unrouted private space on this box: the SYN is silently dropped
# (black hole) instead of getting an instant RST like 127.0.0.1:<closed-port> above.
# That makes this the case that actually proves curl's `-m 5` timeout is what bounds
# send-event.sh's runtime -- the connection-refused case above would still pass even
# if `-m 5` were accidentally dropped from the script, since refusal is instant either
# way. Verified directly on this machine: `curl -s -m 5 ... http://10.255.255.1:1/...`
# hangs for the full ~5.0s then exits 28. If 10.255.255.1 answers instantly on some
# other network (some ISPs/VPNs RST unroutable space), swap in an address that
# genuinely black-holes there and note it here.
NAME="relay black-holed: agent exits 0 within the curl timeout window (proves -m 5 fires)"
START=$(date +%s)
FLOTILLA_CFG="$CFG" FLOTILLA_SEAL=/tmp/flotilla-seal RELAY_OVERRIDE="http://10.255.255.1:1" \
  EVENT="x" SUBJECT="y" DESCRIPTION="" IMPORTANCE="alert" CONTENT="" LINK="" bash plugin/src/scripts/agent.sh
ELAPSED=$(( $(date +%s) - START ))
IN_RANGE=0; [ "$ELAPSED" -ge 4 ] && [ "$ELAPSED" -le 8 ] && IN_RANGE=1
t [ "$IN_RANGE" -eq 1 ]

# Task 13: revoke.sh — called from settings.php's flotilla_pair() on the "Reset
# pairing" path, before new pairing values are generated, so the relay-side
# Durable Object doesn't get silently orphaned. Tested directly here (like
# heartbeat.sh/send-event.sh above), independent of the PHP wiring.
NAME="revoke posts DELETE /v1/pairing with the correct bearer and body"
FLOTILLA_CFG="$CFG" bash plugin/src/scripts/revoke.sh; sleep 0.3
t [ "$(tail -1 "$CAP" | jq -r '.method')" = "DELETE" ]
NAME="revoke path is /v1/pairing"; t [ "$(tail -1 "$CAP" | jq -r '.path')" = "/v1/pairing" ]
NAME="revoke auth bearer carries S"; t [ "$(tail -1 "$CAP" | jq -r '.auth')" = "Bearer $S" ]
NAME="revoke body carries the pairingID and nothing else"
t [ "$(tail -1 "$CAP" | jq -c '.body | fromjson')" = "$(jq -cn --arg p "11111111-1111-4111-8111-111111111111" '{pairingID:$p}')" ]

NAME="revoke exits 0 without a config (nothing to revoke yet, e.g. first pair)"
RC=0
FLOTILLA_CFG="$TMP/no-such.cfg" bash plugin/src/scripts/revoke.sh || RC=$?
t [ "$RC" -eq 0 ]

NAME="revoke exits 0 fast when the relay refuses the connection (a down relay never blocks reset)"
START=$(date +%s)
RC=0
FLOTILLA_CFG="$CFG" RELAY_OVERRIDE="http://127.0.0.1:1" bash plugin/src/scripts/revoke.sh || RC=$?
FAST=0; [ "$RC" -eq 0 ] && [ $(( $(date +%s) - START )) -le 2 ] && FAST=1
t [ "$FAST" -eq 1 ]

NAME="revoke exits 0 within its curl timeout window when the relay is black-holed (proves -m 5 fires)"
START=$(date +%s)
RC=0
FLOTILLA_CFG="$BHCFG" bash plugin/src/scripts/revoke.sh || RC=$?
ELAPSED=$(( $(date +%s) - START ))
IN_RANGE=0; [ "$RC" -eq 0 ] && [ "$ELAPSED" -ge 4 ] && [ "$ELAPSED" -le 8 ] && IN_RANGE=1
t [ "$IN_RANGE" -eq 1 ]

exit $FAIL
