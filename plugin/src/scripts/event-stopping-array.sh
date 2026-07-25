#!/bin/bash
DIR="/usr/local/emhttp/plugins/flotilla-agent/scripts"
# Backgrounded as one subshell (order preserved: event, then going-down heartbeat) so
# "Stop Array" never stalls waiting on the relay. Array stop doesn't power off the
# host, so letting this finish in the background is safe.
(
  bash "$DIR/send-event.sh" "Flotilla array" "Array stopping" "The array is stopping." "warning" "/Main"
  STATE="going-down" bash "$DIR/heartbeat.sh"
) >/dev/null 2>&1 &
exit 0
