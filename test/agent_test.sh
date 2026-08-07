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
# I9: every send-event.sh/heartbeat.sh invocation below gets an explicit, tmp-isolated
# FLOTILLA_QUEUE so none of them ever touch the real default path (/var/local/...) -- mirrors
# how FLOTILLA_CFG/FLOTILLA_HEADERS are already always overridden in this file. Shared across
# most tests here since none of them assert on queue contents; the dedicated I9 tests further
# down use their own separate queue file instead.
QDEFAULT="$TMP/queue-default.jsonl"

# I6: agent.sh now DETACHES send-event.sh instead of exec'ing it, so it returns before the
# send has happened (that's the point -- Unraid's notify hot path must never block on a slow
# or black-holed relay). Every assertion below that inspects the capture file or the queue
# therefore has to wait for that detached child first. settle() polls for it rather than
# sleeping a fixed amount, so the suite stays fast when the relay is local and correct when
# it isn't. Degrades to a plain short sleep if pgrep is unavailable.
settle() {
  local i=0
  while [ "$i" -lt 100 ]; do
    pgrep -f 'scripts/send-event.sh' >/dev/null 2>&1 || break
    sleep 0.1; i=$((i + 1))
  done
  sleep 0.2
}

run() { FLOTILLA_CFG="$CFG" FLOTILLA_SEAL=/tmp/flotilla-seal FLOTILLA_QUEUE="$QDEFAULT" \
  EVENT="$1" SUBJECT="$2" DESCRIPTION="$3" IMPORTANCE="$4" CONTENT="" LINK="/Main" \
  bash plugin/src/scripts/agent.sh; settle; }

# I7: realistic Unraid-shaped values throughout -- EVENT is Unraid's own generic wrapper
# string (carries no temperature/SMART/array signal at all); the actual classifying words
# live in SUBJECT. A synthetic EVENT crafted to already contain the keyword (the old harness
# did this) would make a category-filter test pass even if send-event.sh classified on the
# wrong variable -- self-fulfilling, and exactly how the real bug (I7) went unnoticed.
NAME="warning event is sent and decrypts to the right payload"
run "Unraid Disk 1 message" "Warning [TOWER] - Disk 1 is hot (46 C)" "WDC (sdb)" "warning"
sleep 0.3
SEALED=$(tail -1 "$CAP" | jq -r '.body | fromjson | .sealed')
PLAIN=$(echo "$SEALED" | /tmp/flotilla-seal open --key "$K")
t [ "$(echo "$PLAIN" | jq -r .subject)" = "Warning [TOWER] - Disk 1 is hot (46 C)" ]
NAME="auth bearer carries S"; t [ "$(tail -1 "$CAP" | jq -r .auth)" = "Bearer $S" ]
NAME="level maps warning→active"; t [ "$(tail -1 "$CAP" | jq -r '.body | fromjson | .level')" = "active" ]

NAME="normal filtered under warning threshold"
N=$(wc -l < "$CAP"); run "Unraid status" "Notice [TOWER] - all good" "" "normal"; sleep 0.3
t [ "$(wc -l < "$CAP")" -eq "$N" ]

# I7: EVENT alone ("Unraid Disk 1 message") carries no classifying keyword at all -- only
# SUBJECT does ("... is hot ..."). Before the fix, send-event.sh classified on EVENT only, so
# this exact realistic pair fell through to CAT_OTHER and CAT_DISKS=no would NOT have
# suppressed it (the bug I7 describes). Proves both directions: CAT_DISKS=no suppresses it,
# and (further down) CAT_OTHER=no does NOT suppress it -- i.e. it's correctly bucketed as a
# disk event, not accidentally landing in "everything else".
NAME="category toggle filters a realistic disk event (subject-only signal)"
sed -i.bak 's/CAT_DISKS="yes"/CAT_DISKS="no"/' "$CFG"
N=$(wc -l < "$CAP"); run "Unraid Disk 1 message" "Warning [TOWER] - Disk 1 is hot (46 C)" "" "alert"; sleep 0.3
t [ "$(wc -l < "$CAP")" -eq "$N" ]
sed -i.bak 's/CAT_DISKS="no"/CAT_DISKS="yes"/' "$CFG"

NAME="a realistic disk event is NOT gated by CAT_OTHER (correctly bucketed as CAT_DISKS, not CAT_OTHER)"
sed -i.bak 's/CAT_OTHER="yes"/CAT_OTHER="no"/' "$CFG"
N=$(wc -l < "$CAP"); run "Unraid Disk 1 message" "Warning [TOWER] - Disk 1 is hot (46 C)" "" "alert"; sleep 0.3
t [ "$(wc -l < "$CAP")" -gt "$N" ]
sed -i.bak 's/CAT_OTHER="no"/CAT_OTHER="yes"/' "$CFG"

# I7 extended: all 8 real Unraid notification cases, validating both disk and non-disk classification
# Uses real EVENT/SUBJECT pairs captured from live Unraid 7.3.2 box.

NAME="case 1: disk temp alert (EVENT=temperature, SUBJECT=is hot) — classified as disk, gated by CAT_DISKS=yes"
N=$(wc -l < "$CAP"); run "Unraid Disk 1 temperature" "Warning [Tower] - Disk 1 is hot (46 C)" "" "alert"; sleep 0.3
t [ "$(wc -l < "$CAP")" -gt "$N" ]

NAME="case 1b: disk temp alert blocked by CAT_DISKS=no"
sed -i.bak 's/CAT_DISKS="yes"/CAT_DISKS="no"/' "$CFG"
N=$(wc -l < "$CAP"); run "Unraid Disk 1 temperature" "Warning [Tower] - Disk 1 is hot (46 C)" "" "alert"; sleep 0.3
t [ "$(wc -l < "$CAP")" -eq "$N" ]
sed -i.bak 's/CAT_DISKS="no"/CAT_DISKS="yes"/' "$CFG"

NAME="case 2: disk temp recovery (EVENT=message, SUBJECT=temperature) — classified as disk by SUBJECT keyword"
N=$(wc -l < "$CAP"); run "Unraid Disk 1 message" "Notice [Tower] - Disk 1 returned to normal temperature" "" "warning"; sleep 0.3
t [ "$(wc -l < "$CAP")" -gt "$N" ]

NAME="case 2b: disk temp recovery blocked by CAT_DISKS=no"
sed -i.bak 's/CAT_DISKS="yes"/CAT_DISKS="no"/' "$CFG"
N=$(wc -l < "$CAP"); run "Unraid Disk 1 message" "Notice [Tower] - Disk 1 returned to normal temperature" "" "warning"; sleep 0.3
t [ "$(wc -l < "$CAP")" -eq "$N" ]
sed -i.bak 's/CAT_DISKS="no"/CAT_DISKS="yes"/' "$CFG"

NAME="case 3: disk SMART alert (EVENT=SMART health, SUBJECT carries keyword) — classified as disk"
N=$(wc -l < "$CAP"); run "Unraid Disk 1 SMART health [5]" "Warning [Tower] - Reallocated sector count is 8" "" "alert"; sleep 0.3
t [ "$(wc -l < "$CAP")" -gt "$N" ]

NAME="case 3b: disk SMART alert blocked by CAT_DISKS=no"
sed -i.bak 's/CAT_DISKS="yes"/CAT_DISKS="no"/' "$CFG"
N=$(wc -l < "$CAP"); run "Unraid Disk 1 SMART health [5]" "Warning [Tower] - Reallocated sector count is 8" "" "alert"; sleep 0.3
t [ "$(wc -l < "$CAP")" -eq "$N" ]
sed -i.bak 's/CAT_DISKS="no"/CAT_DISKS="yes"/' "$CFG"

NAME="case 4: disk SMART recovery (EVENT=SMART message, SUBJECT generic) — classified as disk by EVENT keyword"
N=$(wc -l < "$CAP"); run "Unraid Disk 1 SMART message [5]" "Notice [Tower] - Reallocated sector count returned to normal value" "" "warning"; sleep 0.3
t [ "$(wc -l < "$CAP")" -gt "$N" ]

NAME="case 4b: disk SMART recovery blocked by CAT_DISKS=no"
sed -i.bak 's/CAT_DISKS="yes"/CAT_DISKS="no"/' "$CFG"
N=$(wc -l < "$CAP"); run "Unraid Disk 1 SMART message [5]" "Notice [Tower] - Reallocated sector count returned to normal value" "" "warning"; sleep 0.3
t [ "$(wc -l < "$CAP")" -eq "$N" ]
sed -i.bak 's/CAT_DISKS="no"/CAT_DISKS="yes"/' "$CFG"

NAME="case 5: disk utilization alert (EVENT=disk utilization, SUBJECT carries keyword) — classified as disk"
N=$(wc -l < "$CAP"); run "Unraid Disk 1 disk utilization" "Warning [Tower] - Disk 1 is low on space (91%)" "" "alert"; sleep 0.3
t [ "$(wc -l < "$CAP")" -gt "$N" ]

NAME="case 5b: disk utilization alert blocked by CAT_DISKS=no"
sed -i.bak 's/CAT_DISKS="yes"/CAT_DISKS="no"/' "$CFG"
N=$(wc -l < "$CAP"); run "Unraid Disk 1 disk utilization" "Warning [Tower] - Disk 1 is low on space (91%)" "" "alert"; sleep 0.3
t [ "$(wc -l < "$CAP")" -eq "$N" ]
sed -i.bak 's/CAT_DISKS="no"/CAT_DISKS="yes"/' "$CFG"

NAME="case 6: disk utilization recovery (EVENT=message, SUBJECT=utilization) — classified as disk by SUBJECT keyword"
N=$(wc -l < "$CAP"); run "Unraid Disk 1 message" "Notice [Tower] - Disk 1 returned to normal utilization" "" "warning"; sleep 0.3
t [ "$(wc -l < "$CAP")" -gt "$N" ]

NAME="case 6b: disk utilization recovery blocked by CAT_DISKS=no"
sed -i.bak 's/CAT_DISKS="yes"/CAT_DISKS="no"/' "$CFG"
N=$(wc -l < "$CAP"); run "Unraid Disk 1 message" "Notice [Tower] - Disk 1 returned to normal utilization" "" "warning"; sleep 0.3
t [ "$(wc -l < "$CAP")" -eq "$N" ]
sed -i.bak 's/CAT_DISKS="no"/CAT_DISKS="yes"/' "$CFG"

NAME="case 7: unrelated Server Health event — NOT classified as disk, goes to CAT_OTHER"
N=$(wc -l < "$CAP"); run "Server Health" "Tower: 1 health issue(s)" "" "alert"; sleep 0.3
t [ "$(wc -l < "$CAP")" -gt "$N" ]

NAME="case 7b: Server Health blocked by CAT_OTHER=no"
sed -i.bak 's/CAT_OTHER="yes"/CAT_OTHER="no"/' "$CFG"
N=$(wc -l < "$CAP"); run "Server Health" "Tower: 1 health issue(s)" "" "alert"; sleep 0.3
t [ "$(wc -l < "$CAP")" -eq "$N" ]
sed -i.bak 's/CAT_OTHER="no"/CAT_OTHER="yes"/' "$CFG"

NAME="case 8: unrelated photo event (contains 'photos' substring) — NOT classified as disk, goes to CAT_OTHER (BUG FIX: *hot* would have matched inside 'photos')"
N=$(wc -l < "$CAP"); run "Docker" "Tower: immich photos backup finished" "" "warning"; sleep 0.3
t [ "$(wc -l < "$CAP")" -gt "$N" ]

NAME="case 8b: photo event NOT gated by CAT_DISKS=no (proves it's in CAT_OTHER, not CAT_DISKS)"
sed -i.bak 's/CAT_DISKS="yes"/CAT_DISKS="no"/' "$CFG"
N=$(wc -l < "$CAP"); run "Docker" "Tower: immich photos backup finished" "" "warning"; sleep 0.3
t [ "$(wc -l < "$CAP")" -gt "$N" ]
sed -i.bak 's/CAT_DISKS="no"/CAT_DISKS="yes"/' "$CFG"

NAME="case 8c: photo event blocked by CAT_OTHER=no (proves it lands in CAT_OTHER)"
sed -i.bak 's/CAT_OTHER="yes"/CAT_OTHER="no"/' "$CFG"
N=$(wc -l < "$CAP"); run "Docker" "Tower: immich photos backup finished" "" "warning"; sleep 0.3
t [ "$(wc -l < "$CAP")" -eq "$N" ]
sed -i.bak 's/CAT_OTHER="no"/CAT_OTHER="yes"/' "$CFG"

NAME="heartbeat posts ok state"
FLOTILLA_CFG="$CFG" FLOTILLA_QUEUE="$QDEFAULT" bash plugin/src/scripts/heartbeat.sh; sleep 0.3
t [ "$(tail -1 "$CAP" | jq -r '.path')" = "/v1/heartbeat" ]
NAME="heartbeat body state is ok"
t [ "$(tail -1 "$CAP" | jq -r '.body | fromjson | .state')" = "ok" ]

NAME="heartbeat STATE=going-down posts going-down state"
STATE="going-down" FLOTILLA_CFG="$CFG" FLOTILLA_QUEUE="$QDEFAULT" bash plugin/src/scripts/heartbeat.sh; sleep 0.3
t [ "$(tail -1 "$CAP" | jq -r '.body | fromjson | .state')" = "going-down" ]

# Task 13 §8: heartbeat.sh captures the relay's X-Min-Agent response header so
# FlotillaAgent.page can warn about a stale agent. capture_server.py sends that header
# on every response (mirroring flotilla-relay), so this proves the -D capture actually
# lands, then proves the capture is never allowed to endanger heartbeat delivery itself.
NAME="heartbeat captures relay's X-Min-Agent response header"
HDR="$TMP/headers.txt"; rm -f "$HDR"
FLOTILLA_CFG="$CFG" FLOTILLA_HEADERS="$HDR" FLOTILLA_QUEUE="$QDEFAULT" bash plugin/src/scripts/heartbeat.sh; sleep 0.3
t [ "$(grep -i '^X-Min-Agent:' "$HDR" | tr -d '\r\n' | awk '{print $2}')" = "1.0.0" ]

NAME="heartbeat still delivers when the header directory can't be created (never blocks on capture)"
N=$(wc -l < "$CAP")
RC=0
FLOTILLA_CFG="$CFG" FLOTILLA_HEADERS="/flotilla_test_readonly_$$/headers.txt" FLOTILLA_QUEUE="$QDEFAULT" \
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
FLOTILLA_CFG="$BHCFG" FLOTILLA_QUEUE="$QDEFAULT" bash plugin/src/scripts/heartbeat.sh
ELAPSED=$(( $(date +%s) - START ))
IN_RANGE=0; [ "$ELAPSED" -ge 4 ] && [ "$ELAPSED" -le 8 ] && IN_RANGE=1
t [ "$IN_RANGE" -eq 1 ]

NAME="HEARTBEAT_TIMEOUT=2 reaches curl -m, bounding the going-down heartbeat to ~2s"
START=$(date +%s)
HEARTBEAT_TIMEOUT=2 STATE="going-down" FLOTILLA_CFG="$BHCFG" FLOTILLA_QUEUE="$QDEFAULT" bash plugin/src/scripts/heartbeat.sh
ELAPSED=$(( $(date +%s) - START ))
IN_RANGE=0; [ "$ELAPSED" -ge 1 ] && [ "$ELAPSED" -le 4 ] && IN_RANGE=1
t [ "$IN_RANGE" -eq 1 ]

NAME="relay connection-refused: agent exits 0 fast (never blocks notify)"
START=$(date +%s)
FLOTILLA_CFG="$CFG" FLOTILLA_SEAL=/tmp/flotilla-seal FLOTILLA_QUEUE="$QDEFAULT" RELAY_OVERRIDE="http://127.0.0.1:1" \
  EVENT="x" SUBJECT="y" DESCRIPTION="" IMPORTANCE="alert" CONTENT="" LINK="" bash plugin/src/scripts/agent.sh
t [ $(( $(date +%s) - START )) -le 2 ]

# 10.255.255.1 is unrouted private space on this box: the SYN is silently dropped
# (black hole) instead of getting an instant RST like 127.0.0.1:<closed-port> above.
# That makes this the case that actually proves the notify hot path is genuinely
# non-blocking -- the connection-refused case above would still pass even if agent.sh
# ran send-event.sh synchronously, since refusal is instant either way. Verified
# directly on this machine: `curl -s -m 5 ... http://10.255.255.1:1/...` hangs for the
# full ~5.0s then exits 28. If 10.255.255.1 answers instantly on some other network
# (some ISPs/VPNs RST unroutable space), swap in an address that genuinely black-holes
# there and note it here.
#
# I6: this assertion is deliberately the INVERSE of what it used to be. It previously
# required agent.sh to take 4-8s, i.e. it pinned the blocking behaviour as correct.
# Unraid's notify must never be slowed by us, so what has to hold now is: agent.sh
# returns essentially immediately, AND the work still actually happens afterwards in
# the detached child (proven by the retry queue below -- a fire-and-forget that quietly
# dropped the event would otherwise pass the timing half of this test).
BHQUEUE="$TMP/queue-blackhole.jsonl"; rm -f "$BHQUEUE"
NAME="relay black-holed: agent returns immediately (notify is never blocked by a hung relay)"
START=$(date +%s)
FLOTILLA_CFG="$CFG" FLOTILLA_SEAL=/tmp/flotilla-seal FLOTILLA_QUEUE="$BHQUEUE" RELAY_OVERRIDE="http://10.255.255.1:1" \
  EVENT="x" SUBJECT="y" DESCRIPTION="" IMPORTANCE="alert" CONTENT="" LINK="" bash plugin/src/scripts/agent.sh
ELAPSED=$(( $(date +%s) - START ))
t [ "$ELAPSED" -le 2 ]

NAME="relay black-holed: the detached child still runs to completion and queues the event"
settle
t [ -s "$BHQUEUE" ]

# I2: S must never reach curl's argv. /proc/<pid>/cmdline is world-readable on Linux (Unraid
# sets no hidepid), so a container run with --pid=host -- which needs no root -- could poll it
# and lift the bearer secret, then silence the dead-man switch with a forged going-down, delete
# the pairing, or spam the phone. This samples every process's argv while a real send is in
# flight against the black-holed relay, which holds the curl open for the full 5s window.
# Deliberately no `grep -q` here: it exits as soon as it matches, which SIGPIPEs `ps` and (under
# this file's `set -o pipefail`) would abort the whole suite with 141. A case glob over the
# snapshot has no pipeline to break, and $S is base64url (A-Za-z0-9-_) so it can contain no glob
# metacharacter.
leak_check() { # -> prints "leak" if $S appears in any process's argv
  local snap
  snap=$(ps -ww -o args= -ax 2>/dev/null || true)
  case "$snap" in *"$S"*) echo leak;; esac
}
# Waits (bounded) for any secret currently on a command line to go away, so one test's argv
# can't pollute the next one's assertion.
leak_clear() { local i=0; while [ "$i" -lt 60 ]; do [ -z "$(leak_check)" ] && return 0; sleep 0.2; i=$((i+1)); done; }

NAME="sanity: the argv sampler can actually detect a secret on a command line"
( curl -s -m 3 -H "Authorization: Bearer $S" http://10.255.255.1:1/ >/dev/null 2>&1 & )
CTRL=""
for _ in $(seq 1 20); do CTRL=$(leak_check); [ -n "$CTRL" ] && break; sleep 0.2; done
t [ "$CTRL" = "leak" ]
leak_clear

EMPTYQ="$TMP/queue-empty.jsonl"; rm -f "$EMPTYQ"

NAME="the bearer secret never appears on any process's argv (send-event.sh)"
rm -f "$BHQUEUE"
FLOTILLA_CFG="$CFG" FLOTILLA_SEAL=/tmp/flotilla-seal FLOTILLA_QUEUE="$BHQUEUE" RELAY_OVERRIDE="http://10.255.255.1:1" \
  EVENT="x" SUBJECT="y" DESCRIPTION="" IMPORTANCE="alert" CONTENT="" LINK="" bash plugin/src/scripts/agent.sh
LEAK=""
for _ in $(seq 1 20); do LEAK=$(leak_check); [ -n "$LEAK" ] && break; sleep 0.2; done
t [ -z "$LEAK" ]
settle

NAME="the bearer secret never appears on any process's argv (heartbeat.sh)"
FLOTILLA_CFG="$BHCFG" FLOTILLA_QUEUE="$EMPTYQ" bash plugin/src/scripts/heartbeat.sh &
HBPID=$!
LEAK=""
for _ in $(seq 1 20); do LEAK=$(leak_check); [ -n "$LEAK" ] && break; sleep 0.2; done
wait "$HBPID" 2>/dev/null || true
t [ -z "$LEAK" ]

NAME="the bearer secret never appears on any process's argv (revoke.sh)"
FLOTILLA_CFG="$BHCFG" bash plugin/src/scripts/revoke.sh &
RVPID=$!
LEAK=""
for _ in $(seq 1 20); do LEAK=$(leak_check); [ -n "$LEAK" ] && break; sleep 0.2; done
wait "$RVPID" 2>/dev/null || true
t [ -z "$LEAK" ]

# Static backstop: catches a future refactor that reintroduces the argv form even in a code
# path this suite doesn't happen to exercise. Comment lines are excluded on purpose -- the
# scripts' own comments quote the old, forbidden form to explain why it was removed.
NAME="no script passes the bearer secret as a curl -H argument"
BADAUTH=$(awk '!/^[[:space:]]*#/ && /Authorization: Bearer \$SECRET/ {print FILENAME": "$0}' plugin/src/scripts/*.sh)
t [ -z "$BADAUTH" ]

# I2 (second half): the request body carried pairingID and the sealed ciphertext on argv too.
NAME="the request body is not on argv either (sealed payload goes via stdin)"
BADBODY=$(awk '!/^[[:space:]]*#/ && /-d "\$(BODY|LINE)"/ {print FILENAME": "$0}' plugin/src/scripts/*.sh)
t [ -z "$BADBODY" ]

# I9: send-event.sh's on-disk retry queue. A brief relay blip must not lose the alert outright
# (the pre-I9 behavior) -- a failed send is queued, bounded to 10 entries, and heartbeat.sh
# drains it on its next run. Uses its own dedicated queue file (not $QDEFAULT) so it starts
# from a known-empty state regardless of what earlier tests above did to $QDEFAULT.
IQUEUE="$TMP/queue-i9.jsonl"; rm -f "$IQUEUE"

NAME="a send that fails against an unreachable relay is queued, not lost"
FLOTILLA_CFG="$CFG" FLOTILLA_SEAL=/tmp/flotilla-seal FLOTILLA_QUEUE="$IQUEUE" RELAY_OVERRIDE="http://127.0.0.1:1" \
  EVENT="Unraid Disk 1 message" SUBJECT="Warning [TOWER] - Disk 1 is hot (46 C)" DESCRIPTION="" IMPORTANCE="warning" CONTENT="" LINK="/Main" \
  bash plugin/src/scripts/agent.sh
settle
t [ -s "$IQUEUE" ]
NAME="the queued entry has the pairingID and a sealed payload, ready to re-POST verbatim"
t [ "$(tail -1 "$IQUEUE" | jq -r '.pairingID')" = "11111111-1111-4111-8111-111111111111" ]

NAME="the drain delivers the queued entry once the relay is reachable again, and empties the queue"
N=$(wc -l < "$CAP")
FLOTILLA_CFG="$CFG" FLOTILLA_QUEUE="$IQUEUE" bash plugin/src/scripts/heartbeat.sh
sleep 0.3
# heartbeat.sh's own heartbeat POST lands first, THEN the drained push -- two new lines total.
t [ "$(tail -1 "$CAP" | jq -r '.path')" = "/v1/push" ]
NAME="drain delivered exactly one new push (plus heartbeat.sh's own heartbeat)"
t [ "$(tail -n +"$((N + 1))" "$CAP" | jq -r '.path' | grep -c '^/v1/push$')" -eq 1 ]
NAME="queue file is gone after a full drain"; t [ ! -s "$IQUEUE" ]

rm -f "$IQUEUE"
CAP401="$TMP/cap-401.jsonl"
python3 test/capture_server.py 18402 "$CAP401" 401 & SRV401=$!; disown "$SRV401" 2>/dev/null || true; sleep 0.3
CFG401="$TMP/flotilla-agent-401.cfg"
sed 's#^RELAY=.*#RELAY="http://127.0.0.1:18402"#' "$CFG" > "$CFG401"
FLOTILLA_CFG="$CFG401" FLOTILLA_SEAL=/tmp/flotilla-seal FLOTILLA_QUEUE="$IQUEUE" \
  EVENT="Unraid Disk 1 message" SUBJECT="Warning [TOWER] - Disk 1 is hot (46 C)" DESCRIPTION="" IMPORTANCE="warning" CONTENT="" LINK="/Main" \
  bash plugin/src/scripts/agent.sh
settle
kill "$SRV401" 2>/dev/null || true
NAME="sanity: the 401 fixture server was genuinely hit (the request was really attempted)"
t [ -s "$CAP401" ]
NAME="a 4xx relay response is never queued (retrying a rejection forever would be pointless)"
t [ ! -s "$IQUEUE" ]

NAME="the queue never exceeds 10 entries even after many consecutive failures"
rm -f "$IQUEUE"
for i in $(seq 1 14); do
  FLOTILLA_CFG="$CFG" FLOTILLA_SEAL=/tmp/flotilla-seal FLOTILLA_QUEUE="$IQUEUE" RELAY_OVERRIDE="http://127.0.0.1:1" \
    EVENT="Unraid Disk 1 message" SUBJECT="Warning [TOWER] - Disk 1 is hot (46 C) #$i" DESCRIPTION="" IMPORTANCE="warning" CONTENT="" LINK="/Main" \
    bash plugin/src/scripts/agent.sh
  # Must settle between iterations: the sends are detached now, and the queue's read-modify-write
  # is not concurrency-safe (nor does it need to be -- real notifications don't arrive in bursts).
  settle
done
t [ "$(wc -l < "$IQUEUE")" -eq 10 ]
NAME="the queue keeps the NEWEST entries, not the oldest, once capped"
t [ "$(tail -1 "$IQUEUE" | jq -r '.pairingID')" = "11111111-1111-4111-8111-111111111111" ]

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

# I3: the shutdown path must be genuinely bounded, not just the heartbeat inside it.
# event-stopping-array.sh documents a "<=2s stall on Stop Array" budget and passes
# HEARTBEAT_TIMEOUT=2 -- but that only ever bounded the heartbeat POST. heartbeat.sh then
# drained the retry queue synchronously with its own separate per-entry timeout, so a full
# 10-entry queue plus an unreachable relay meant the going-down send really cost ~5s (and up
# to ~32s against a slow-but-answering relay) inside Unraid's stopping_array hook, which also
# runs as a step in Reboot/Shutdown. The drain is now skipped whenever STATE isn't "ok".
SQUEUE="$TMP/queue-shutdown.jsonl"
: > "$SQUEUE"
for i in $(seq 1 10); do
  jq -cn --arg p "11111111-1111-4111-8111-111111111111" --arg x "AAAA" --arg lv active \
    '{pairingID:$p,sealed:$x,level:$lv}' >> "$SQUEUE"
done
NAME="sanity: the shutdown-budget fixture queue really has 10 entries to drain"
t [ "$(wc -l < "$SQUEUE")" -eq 10 ]

NAME="STATE=going-down against a black-holed relay stays inside its ~2s budget with a full queue"
START=$(date +%s)
HEARTBEAT_TIMEOUT=2 STATE="going-down" FLOTILLA_CFG="$BHCFG" FLOTILLA_QUEUE="$SQUEUE" \
  bash plugin/src/scripts/heartbeat.sh
ELAPSED=$(( $(date +%s) - START ))
t [ "$ELAPSED" -le 4 ]

NAME="going-down leaves the queue intact for the next boot's cron rather than draining it"
t [ "$(wc -l < "$SQUEUE")" -eq 10 ]

# ...and the skip really is conditional on the state: the ordinary per-minute (STATE=ok) run
# must still drain. Without this, "bounded" could be silently achieved by never draining at all.
NAME="the ordinary STATE=ok run still drains the queue (the skip is state-conditional)"
FLOTILLA_CFG="$CFG" FLOTILLA_QUEUE="$SQUEUE" bash plugin/src/scripts/heartbeat.sh
sleep 0.3
t [ ! -s "$SQUEUE" ]

# I8: a permanently-rejected entry used to pin itself at the queue head forever. The realistic
# path: an event is queued during an outage, then the user hits "Reset pairing" -- the queued
# body carries the OLD pairingID but the drain sends it with the NEW secret, so it 401s every
# minute, forever, and every deliverable entry behind it is stuck behind it. send-event.sh's
# eviction can't clear it either (that only fires on NEW failures, which stop once the relay is
# healthy). The drain now drops a 4xx instead of treating it as retryable, mirroring
# send-event.sh's own "never queue a 4xx" rule.
CAP401B="$TMP/cap-401b.jsonl"
python3 test/capture_server.py 18403 "$CAP401B" 401 & SRV401B=$!; disown "$SRV401B" 2>/dev/null || true; sleep 0.3
CFG401B="$TMP/flotilla-agent-401b.cfg"
sed 's#^RELAY=.*#RELAY="http://127.0.0.1:18403"#' "$CFG" > "$CFG401B"
RQUEUE="$TMP/queue-rejected.jsonl"
: > "$RQUEUE"
for i in 1 2 3; do
  jq -cn --arg p "old-pairing-id" --arg x "AAAA" --arg lv active '{pairingID:$p,sealed:$x,level:$lv}' >> "$RQUEUE"
done
FLOTILLA_CFG="$CFG401B" FLOTILLA_QUEUE="$RQUEUE" bash plugin/src/scripts/heartbeat.sh
sleep 0.3
kill "$SRV401B" 2>/dev/null || true
NAME="sanity: the drain really did POST the rejected entries at the 401 fixture"
t [ "$(grep -c '"path": "/v1/push"' "$CAP401B")" -ge 1 ]
NAME="a permanently-rejected (4xx) queue entry is dropped, not left blocking the queue head"
t [ ! -s "$RQUEUE" ]

# I18: the stated #1 risk for this release is arbitrary notification text reaching root-run
# shell scripts. The code handles it correctly today (argv + jq --arg + quoted expansions, no
# eval), but every other case in this file uses benign Unraid-shaped strings, so nothing here
# would catch a future refactor that reintroduced an eval or an unquoted expansion. This case
# pushes every metacharacter that matters through the whole pipeline -- agent.sh's env vars,
# send-event.sh's argv, jq, flotilla-seal, curl -- and asserts two things: the plaintext comes
# back byte-identical on the other side of the seal, and none of the embedded commands ran.
CANARY="$TMP/injection-canary"
rm -f "$CANARY"
NASTY_SUBJ='Warning [TOWER] - $(touch '"$CANARY"') `touch '"$CANARY"'` "dq" '"'"'sq'"'"' \back $HOME ${IFS} ; | & > <'
NASTY_DESC=$(printf 'first $(touch %s)\nsecond `id` "x" \\ %%s %%q ${PATH} end' "$CANARY")
N=$(wc -l < "$CAP")
run "Unraid message" "$NASTY_SUBJ" "$NASTY_DESC" "warning"
sleep 0.3
NAME="notification text full of shell metacharacters is still delivered (not dropped or mangled)"
t [ "$(wc -l < "$CAP")" -gt "$N" ]
PLAIN=$(tail -1 "$CAP" | jq -r '.body | fromjson | .sealed' | /tmp/flotilla-seal open --key "$K")
NAME="the subject decrypts back to exactly the bytes that went in (no shell interpretation)"
t [ "$(printf '%s' "$PLAIN" | jq -r .subject)" = "$NASTY_SUBJ" ]
NAME="the description decrypts back byte-identically, embedded newline and backslash included"
t [ "$(printf '%s' "$PLAIN" | jq -r .description)" = "$NASTY_DESC" ]
NAME="no embedded command executed: the injection canary file does not exist"
t [ ! -e "$CANARY" ]

exit $FAIL
