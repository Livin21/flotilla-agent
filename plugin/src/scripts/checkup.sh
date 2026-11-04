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
  "$NOTIFY" -e "$1" -s "$2" -d "$3" -i "$4" 9>&- 3<&-
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

# f_eval: one line per checked share, from disks.ini and shares.ini (raw KiB in, bytes out):
# name kind pool locked close above1g pastmargin left floorKiB floorBytes
# kind is pool (only), array (no) or both (yes, prefer). Flags are 0 or 1. No field is empty.
f_eval() {
  awk -v which=1 '
    function unq(v) { sub(/\r$/, "", v); if (v ~ /^".*"$/) v = substr(v, 2, length(v) - 2); return v }
    /^\["/ {
      s = $0; sub(/^\["/, "", s); sub(/"\].*$/, "", s); cur = s
      if (which == 1) { nd++; dname[nd] = s; dsec[s] = 1 } else { ns++; sname[ns] = s }
      next
    }
    {
      i = index($0, "="); if (i == 0) next
      k = substr($0, 1, i - 1); v = unq(substr($0, i + 1))
      if (which == 1) d[cur, k] = v; else sh[cur, k] = v
    }
    END {
      for (j = 1; j <= ns; j++) {
        s = sname[j]; uc = sh[s, "useCache"]; fl = sh[s, "floor"]
        if (sh[s, "exclusive"] == "yes" || sh[s, "cachePool2"] != "") continue
        if (fl !~ /^[0-9]+$/ || fl + 0 <= 0) continue
        if (uc == "only") kind = "pool"; else if (uc == "no") kind = "array"
        else if (uc == "yes" || uc == "prefer") kind = "both"; else continue
        fl += 0; room = 0; locked = 1; margin = 0; pool = "-"; pfree = 0
        if (kind != "array") {
          pool = sh[s, "cachePool"]
          if (!(pool in dsec)) continue
          if (d[pool, "fsFree"] !~ /^[0-9]+$/ || d[pool, "fsSize"] !~ /^[0-9]+$/ || d[pool, "fsSize"] + 0 <= 0) continue
          pfree = d[pool, "fsFree"] + 0
          if (pfree > fl) { locked = 0; room += pfree - fl }
          margin = (d[pool, "fsSize"] + 0) * 1024 * 0.1
        }
        if (kind != "pool") {
          inc = sh[s, "include"]; exc = sh[s, "exclude"]; gsub(/ /, "", inc); gsub(/ /, "", exc)
          if (inc != "") n = split(inc, cand, ",")
          else { n = nd; for (c = 1; c <= nd; c++) cand[c] = dname[c] }
          seen = ","; ne = 0; alllow = 1; big = 0
          for (c = 1; c <= n; c++) {
            x = cand[c]
            if (x == "" || !(x in dsec) || d[x, "type"] != "Data") continue
            if (d[x, "fsSize"] !~ /^[0-9]+$/ || d[x, "fsFree"] !~ /^[0-9]+$/ || d[x, "fsSize"] + 0 <= 0) continue
            if (index("," exc ",", "," x ",") || index(seen, "," x ",")) continue
            seen = seen x ","; ne++
            f = d[x, "fsFree"] + 0
            if (f > fl) { alllow = 0; room += f - fl }
            if (d[x, "fsSize"] + 0 > big) big = d[x, "fsSize"] + 0
          }
          if (ne == 0) continue
          if (!alllow) locked = 0
          if (kind == "array") { locked = alllow; margin = big * 1024 * 0.1 }
        }
        if (margin > 50e9) margin = 50e9
        left = room * 1024
        printf "%s\t%s\t%s\t%d\t%d\t%d\t%d\t%.0f\t%.0f\t%.0f\n", s, kind, pool, locked,
          (!locked && left < margin), (left >= 1e9), (left > margin + 5e9), left, fl, fl * 1024
      }
    }' "$DISKS_INI" which=2 "$SHARES_INI"
}

# f_notice ID: send F1, F1clear or F2 for the share fields set by check_f
f_notice() {
  local fs uf sub desc imp
  fs=$(size_text "$fb"); uf=$(unraid_floor_text "$floor")
  case "$1" in
    F1)
      sub="Share $name refuses new files"; imp=alert
      case "$kind" in
        pool) desc="Free space on $pool is less than the Minimum free space for $name ($fs). Unraid shows this value as $uf. Unraid does not create new files in $name. To correct this, make free space on $pool, or decrease Minimum free space in Shares > $name." ;;
        array) desc="Each disk that $name can use has less free space than the Minimum free space for $name ($fs). Unraid shows this value as $uf. Unraid does not create new files in $name. To correct this, make free space on one of these disks, or decrease Minimum free space in Shares > $name." ;;
        *) desc="Free space on $pool and on each disk that $name can use is less than the Minimum free space for $name ($fs). Unraid shows this value as $uf. Unraid does not create new files in $name. To correct this, make free space on $pool or on one of these disks, or decrease Minimum free space in Shares > $name." ;;
      esac ;;
    F1clear)
      sub="Share $name accepts new files"; imp=normal
      desc="Free space is more than the Minimum free space for $name again." ;;
    F2)
      sub="Share $name is near its Minimum free space"; imp=warning
      case "$kind" in
        pool) desc="$(cap_first "$pool") has $(left_text "$left") of free space above the Minimum free space for $name ($fs). Unraid shows this value as $uf. When this space is full, Unraid does not create new files in $name." ;;
        array) desc="The disks that $name can use have $(left_text "$left") of free space above the Minimum free space for $name ($fs). Unraid shows this value as $uf. When this space is full, Unraid does not create new files in $name." ;;
        *) desc="$(cap_first "$pool") and the disks that $name can use have $(left_text "$left") of free space above the Minimum free space for $name ($fs). Unraid shows this value as $uf. When this space is full, Unraid does not create new files in $name." ;;
      esac ;;
  esac
  send "Flotilla checkup" "$sub" "$desc" "$imp"
}

# F1 / F2: a share refuses new files (locked) or is near it (close). State F per share: ok (no line), close, locked.
# A dry run sees no saved state, so it reports F1 and F2 for the current conditions and never a clear.
check_f() {
  [ -r "$VAR_INI" ] && [ -r "$SHARES_INI" ] && [ -r "$DISKS_INI" ] || return 0
  [ "$(ini_get "$VAR_INI" "" mdState)" = "STARTED" ] || return 0
  local out name kind pool locked close above1g pastmargin left floor fb prev new
  out=$(f_eval)
  [ -n "$out" ] || return 0
  while IFS="$TAB" read -r name kind pool locked close above1g pastmargin left floor fb <&3; do
    prev=$(state_get F "$name"); [ -n "$prev" ] || prev=ok
    if [ "$locked" = 1 ]; then
      new=locked
      [ "$prev" = locked ] || f_notice F1
    elif [ "$prev" = locked ]; then
      new=locked
      if [ "$above1g" = 1 ]; then
        f_notice F1clear
        if [ "$close" = 1 ]; then new=close; else new=ok; fi
      fi
    elif [ "$prev" = close ]; then
      if [ "$pastmargin" = 1 ]; then new=ok; else new=close; fi
    else
      new=ok
      [ "$close" = 1 ] && { f_notice F2; new=close; }
    fi
    [ "$new" = "$prev" ] && continue
    if [ "$new" = ok ]; then state_clear F "$name"; else state_set F "$name" "$new"; fi
  done 3<<EOF
$out
EOF
}

# W1: Load_Cycle_Count (attribute 193) normalized VALUE at or below 10. Once per disk id, kept in wear.state on the flash drive.
# Reads only the SMART files Unraid caches. Runs whether or not the array is started.
check_w1() {
  [ -d "$SMART_DIR" ] && [ -r "$DISKS_INI" ] || return 0
  local wear="$ROOT/boot/config/plugins/flotilla-agent/wear.state"
  local f name id line val raw model dtype tail
  for f in "$SMART_DIR"/*; do
    [ -f "$f" ] || continue
    name=${f##*/}
    [ "$name" = flash ] && continue
    ini_sections "$DISKS_INI" | grep -qxF -- "$name" || continue
    id=$(ini_get "$DISKS_INI" "$name" id)
    [ -n "$id" ] || continue
    line=$(awk '$1 == 193 { if ($4 ~ /^[0-9]+$/ && $10 ~ /^[0-9]+$/) print $4 + 0, $10; exit }' "$f" 2>/dev/null)
    [ -n "$line" ] || continue
    val=${line%% *}; raw=${line#* }
    awk -v v="$val" 'BEGIN { exit !(v <= 10) }' || continue
    if [ -z "$DRY" ]; then
      [ -r "$wear" ] && grep -qxF -- "$id" "$wear" && continue
      [ -n "$(state_get W1 "$id")" ] && continue
    fi
    model=$(printf '%s' "${id%_*}" | tr '_' ' ')
    dtype=$(ini_get "$DISKS_INI" "$name" type)
    tail="Keep a current backup of the data on this disk."
    [ "$dtype" = Parity ] && tail="If this parity disk fails, the array has less protection until you replace it."
    send "Flotilla SMART check" "$name: load cycle count is near or past the rated limit" \
      "Load_Cycle_Count on $name ($model) is $raw. The drive reports a normalized value of $val. The drive is near or past its rated number of load cycles. This value alone does not show a drive failure. $tail" \
      warning
    if [ -z "$DRY" ]; then
      state_set W1 "$id" sent
      mkdir -p "${wear%/*}" 2>/dev/null && { printf '%s\n' "$id" >> "$wear"; } 2>/dev/null
    fi
  done
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
  check_f
  check_w1
  exit 0
}

[ -n "${CHECKUP_LIB:-}" ] && return 0 2>/dev/null
main
