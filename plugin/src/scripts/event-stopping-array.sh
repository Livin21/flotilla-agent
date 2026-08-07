#!/bin/bash
DIR="/usr/local/emhttp/plugins/flotilla-agent/scripts"
# stopping_array fires both for the interactive "Stop Array" button AND as a step
# in Unraid's Reboot/Shutdown sequence, where the host powers off shortly after.
# That second case is exactly when the going-down heartbeat matters: without it,
# the relay's dead-man switch sees heartbeats stop and pushes a false "server
# unreachable" alert on every planned reboot. So send it FIRST and SYNCHRONOUSLY,
# with a short bounded timeout -- a <=2s stall on Stop Array is acceptable, but
# this call must get out before a teardown sequence can reap us. (Inverted from
# the previous event-then-heartbeat order on purpose.)
#
# I3: the budget is now enforced from BOTH ends. heartbeat.sh skips its retry-queue drain
# whenever STATE isn't "ok", so the going-down send really is the only work it does here; and
# `timeout` puts a hard ceiling on the whole invocation regardless, so no future addition to
# heartbeat.sh can quietly reintroduce an unbounded stall on the reboot/shutdown path. 4s
# leaves margin over the 2s curl budget for process startup and jq; -k 1 escalates to SIGKILL
# if a wedged curl ignores the SIGTERM. A timeout that fires is a silently-lost going-down
# heartbeat (worst case: one false "Server unreachable" push), never a stalled shutdown.
if command -v timeout >/dev/null 2>&1; then
  timeout -k 1 4 env HEARTBEAT_TIMEOUT=2 STATE="going-down" bash "$DIR/heartbeat.sh"
else
  HEARTBEAT_TIMEOUT=2 STATE="going-down" bash "$DIR/heartbeat.sh"
fi

# The "Array stopping" event is informational only, so it stays backgrounded.
# Detach it from the parent's process group with setsid when available (Unraid
# ships util-linux) so a teardown sequence that signals/reaps that group can't
# kill it mid-curl; a plain `(...) &` would still live in the parent's group and
# be vulnerable to exactly that. Fall back to plain backgrounding when setsid
# isn't present (e.g. the dev Mac).
if command -v setsid >/dev/null 2>&1; then
  setsid bash "$DIR/send-event.sh" "Flotilla array" "Array stopping" "The array is stopping." "warning" "/Main" >/dev/null 2>&1 &
else
  bash "$DIR/send-event.sh" "Flotilla array" "Array stopping" "The array is stopping." "warning" "/Main" >/dev/null 2>&1 &
fi
exit 0
