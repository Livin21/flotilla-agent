#!/bin/bash
DIR="/usr/local/emhttp/plugins/flotilla-agent/scripts"
bash "$DIR/send-event.sh" "Flotilla array" "Array stopping" "The array is stopping." "warning" "/Main"
STATE="going-down" bash "$DIR/heartbeat.sh"
exit 0
