#!/bin/bash
DIR="/usr/local/emhttp/plugins/flotilla-agent/scripts"
bash "$DIR/send-event.sh" "Flotilla array" "Array started" "The array came up." "normal" "/Main" &
exit 0
