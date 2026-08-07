#!/bin/bash
# Invoked by Unraid notify with EVENT/SUBJECT/DESCRIPTION/IMPORTANCE/CONTENT/LINK env vars.
DIR="$(dirname "$0")"
DESC="$DESCRIPTION"; [ -z "$DESC" ] && DESC="$CONTENT"

# I6: detach and return immediately. This used to `exec` send-event.sh, which blocks for up to
# curl's full 5s budget against a relay that black-holes rather than refuses (DNS blackhole,
# upstream drop, CDN outage) -- and this is the path Unraid runs for EVERY notification, on top
# of whatever other agents (Discord, Pushover, ...) the user has configured. Whether Unraid's
# own `notify` backgrounds its agent invocations is not something this repo can verify, and the
# hard constraint here is that Flotilla must never be able to slow down or break Unraid's own
# notifications; detaching removes the need to know either way, and costs nothing.
#
# Both array event hooks in this directory already do exactly this. setsid, where available
# (Unraid ships util-linux), also puts the child in its own process group so a caller that
# signals or reaps its group can't kill it mid-curl. stdout/stderr are redirected BEFORE
# backgrounding: if notify captures our output through a pipe, an unredirected fd held open by
# the child would block the reader until it exits, defeating the backgrounding entirely.
if command -v setsid >/dev/null 2>&1; then
  setsid bash "$DIR/send-event.sh" "$EVENT" "$SUBJECT" "$DESC" "$IMPORTANCE" "$LINK" >/dev/null 2>&1 &
else
  bash "$DIR/send-event.sh" "$EVENT" "$SUBJECT" "$DESC" "$IMPORTANCE" "$LINK" >/dev/null 2>&1 &
fi
exit 0
