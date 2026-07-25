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
HEARTBEAT_TIMEOUT=2 STATE="going-down" bash "$DIR/heartbeat.sh"

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
