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

NAME="relay down: agent exits 0 fast (never blocks notify)"
START=$(date +%s)
FLOTILLA_CFG="$CFG" RELAY_OVERRIDE="http://127.0.0.1:1" \
  EVENT="x" SUBJECT="y" DESCRIPTION="" IMPORTANCE="alert" CONTENT="" LINK="" bash plugin/src/scripts/agent.sh
t [ $(( $(date +%s) - START )) -le 7 ]

exit $FAIL
