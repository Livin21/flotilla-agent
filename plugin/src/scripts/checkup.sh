#!/bin/bash
# Server checks, run from cron. Reads only the status files Unraid already writes under
# var/local/emhttp and etc/cron.d/root. Never calls smartctl, the API or /mnt.
# bash 3.2 + BSD awk safe: no associative arrays, mapfile, ${v^}, |&.
# Overrides: FLOTILLA_ROOT, FLOTILLA_CFG, FLOTILLA_NOTIFY, FLOTILLA_DRY_RUN=1.
ROOT="${FLOTILLA_ROOT:-}"
CFG="${FLOTILLA_CFG:-$ROOT/boot/config/plugins/flotilla-agent/flotilla-agent.cfg}"
NOTIFY="${FLOTILLA_NOTIFY:-/usr/local/emhttp/webGui/scripts/notify}"
EMHTTP="$ROOT/var/local/emhttp"
VAR_INI="$EMHTTP/var.ini"
SHARES_INI="$EMHTTP/shares.ini"
DISKS_INI="$EMHTTP/disks.ini"
SMART_DIR="$EMHTTP/smart"
CRON_ROOT="$ROOT/etc/cron.d/root"
STATE_DIR="$ROOT/var/local/flotilla-agent"
STATE_FILE="$STATE_DIR/checkup.state"
DRY="${FLOTILLA_DRY_RUN:-}"
TAB=$(printf '\t')

# ini_sections FILE: section names, one per line.
ini_sections() {
  awk '/^\["/ { s = $0; sub(/^\["/, "", s); sub(/"\].*$/, "", s); print s }' "$1" 2>/dev/null
}

# ini_get FILE SECTION KEY: unquoted value, or nothing. Empty SECTION = keys before any section.
ini_get() {
  awk -v sec="$2" -v key="$3" '
    /^\["/ { s = $0; sub(/^\["/, "", s); sub(/"\].*$/, "", s); cur = s; insec = 1; next }
    {
      if (sec == "" ? insec : cur != sec) next
      i = index($0, "=")
      if (i == 0) next
      if (substr($0, 1, i - 1) != key) next
      v = substr($0, i + 1)
      sub(/\r$/, "", v)
      if (v ~ /^".*"$/) v = substr(v, 2, length(v) - 2)
      print v
      exit
    }' "$1" 2>/dev/null
}

# size_text BYTES: "under 1 GB", "99 GB", "1.5 TB"
size_text() {
  awk -v b="$1" 'BEGIN {
    if (b < 1e9) print "under 1 GB"
    else if (b < 999.5e9) printf "%.0f GB\n", b / 1e9
    else printf "%.1f TB\n", b / 1e12
  }'
}

# left_text BYTES: whole GB rounded down, "under 1 GB" below 1 GB
left_text() {
  awk -v b="$1" 'BEGIN {
    if (b < 1e9) print "under 1 GB"
    else printf "%.0f GB\n", int(b / 1e9)
  }'
}

# unraid_floor_text KIB: decimal steps of 1000 (KB, MB, GB, TB), 1 decimal, trailing .0 dropped
unraid_floor_text() {
  awk -v k="$1" 'BEGIN {
    split("KB MB GB TB", u, " ")
    v = k + 0; i = 1
    while (v >= 1000 && i < 4) { v = v / 1000; i++ }
    r = int(v * 10 + 0.5) / 10
    s = sprintf("%.1f", r)
    sub(/\.0$/, "", s)
    print s " " u[i]
  }'
}

# cap_first WORD
cap_first() {
  awk -v w="$1" 'BEGIN { print toupper(substr(w, 1, 1)) substr(w, 2) }'
}

# state_get KIND NAME: stored value; always empty in a dry run
state_get() {
  [ -n "$DRY" ] && return 0
  [ -r "$STATE_FILE" ] || return 0
  awk -F'\t' -v k="$1" -v n="$2" '$1 == k && $2 == n { print $3; exit }' "$STATE_FILE"
}

# state_set KIND NAME VALUE: a dry run writes nothing
state_set() {
  [ -n "$DRY" ] && return 0
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  local tmp="$STATE_FILE.tmp.$$"
  { [ -r "$STATE_FILE" ] && awk -F'\t' -v k="$1" -v n="$2" '!($1 == k && $2 == n)' "$STATE_FILE"
    printf '%s\t%s\t%s\n' "$1" "$2" "$3"
  } > "$tmp" && mv "$tmp" "$STATE_FILE"
}

# state_clear KIND NAME
state_clear() {
  [ -n "$DRY" ] && return 0
  [ -r "$STATE_FILE" ] || return 0
  local tmp="$STATE_FILE.tmp.$$"
  awk -F'\t' -v k="$1" -v n="$2" '!($1 == k && $2 == n)' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

# send EVENT SUBJECT DESCRIPTION IMPORTANCE
send() {
  if [ -n "$DRY" ]; then
    printf '%s\n%s\n%s\n%s\n---\n' "$1" "$2" "$3" "$4"
    return 0
  fi
  [ -x "$NOTIFY" ] || return 0
  "$NOTIFY" -e "$1" -s "$2" -d "$3" -i "$4"
}

# M1: the mover has a schedule but cron has no mover job. Needs two runs in a row.
check_m1() {
  [ -r "$VAR_INI" ] || return 0
  [ "$(ini_get "$VAR_INI" "" mdState)" = "STARTED" ] || return 0
  [ "$(ini_get "$VAR_INI" "" shareCacheEnabled)" = "yes" ] || return 0
  local sched st
  sched=$(ini_get "$VAR_INI" "" shareMoverSchedule)
  [ -n "$sched" ] || return 0
  st=$(state_get M1 mover)
  if [ -r "$CRON_ROOT" ] && grep -qF -e /usr/local/sbin/mover -e ca.mover.tuning/mover "$CRON_ROOT"; then
    if [ "$st" = "fired" ]; then
      send "Flotilla checkup" "Mover is scheduled" "Cron has a mover job again." normal
    fi
    [ -n "$st" ] && state_clear M1 mover
    return 0
  fi
  if [ -z "$st" ] && [ -z "$DRY" ]; then
    state_set M1 mover pending
  elif [ "$st" != "fired" ]; then
    send "Flotilla checkup" "Mover is not scheduled" \
      "The mover schedule is $sched, but cron has no mover job. The mover does not move files from the pool to the array. To correct this, open Settings > Scheduler > Mover Settings. Change the Time of the day, and then click Apply. You can then set the original time again and click Apply." \
      warning
    state_set M1 mover fired
  fi
}

main() {
  [ -r "$CFG" ] && . "$CFG"
  [ "${CHECKS:-yes}" = "no" ] && exit 0
  if [ -z "$DRY" ]; then
    mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
    if command -v flock >/dev/null 2>&1; then
      exec 9> "$STATE_DIR/checkup.lock"
      flock -n 9 || exit 0
    fi
  fi
  check_m1
  exit 0
}

[ -n "${CHECKUP_LIB:-}" ] && return 0 2>/dev/null
main
