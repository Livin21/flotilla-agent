#!/bin/bash
DIR="/usr/local/emhttp/plugins/flotilla-agent/scripts"
# stdout/stderr must be redirected before backgrounding: if Unraid's hook runner
# captures output through a pipe, an unredirected fd held open by the child blocks
# the reader until it exits, defeating the backgrounding.
bash "$DIR/send-event.sh" "Flotilla array" "Array started" "The array came up." "normal" "/Main" >/dev/null 2>&1 &
exit 0
