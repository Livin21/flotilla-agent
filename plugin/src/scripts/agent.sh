#!/bin/bash
# Invoked by Unraid notify with EVENT/SUBJECT/DESCRIPTION/IMPORTANCE/CONTENT/LINK env vars.
DIR="$(dirname "$0")"
DESC="$DESCRIPTION"; [ -z "$DESC" ] && DESC="$CONTENT"
exec bash "$DIR/send-event.sh" "$EVENT" "$SUBJECT" "$DESC" "$IMPORTANCE" "$LINK"
