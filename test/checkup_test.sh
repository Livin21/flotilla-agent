#!/bin/bash
# Tests plugin/src/scripts/checkup.sh against fixture trees. Needs only bash + awk.
cd "$(dirname "$0")/.." || exit 1
ROOT=$(pwd)
FAIL=0; t() { if "$@"; then echo "ok: $NAME"; else echo "FAIL: $NAME"; FAIL=1; fi; }
SCRIPT="$ROOT/plugin/src/scripts/checkup.sh"
FX="$ROOT/test/fixtures/checkup"

new_dir() {
  D=$(mktemp -d)
  cp -R "$FX/base/." "$D/"
  cat > "$D/notify" <<'NEOF'
#!/bin/bash
printf '%s\n' "$@" >> "$(dirname "$0")/notify.log"; echo --- >> "$(dirname "$0")/notify.log"
NEOF
  chmod +x "$D/notify"
}
run_checkup() {
  FLOTILLA_ROOT="$1" FLOTILLA_CFG="$1/cfg" FLOTILLA_NOTIFY="$1/notify" bash "$SCRIPT"
}
no_log() { [ ! -e "$D/notify.log" ]; }
log_count() { [ -e "$D/notify.log" ] && grep -c '^---$' "$D/notify.log" || echo 0; }
VAR=var/local/emhttp/var.ini
drop_mover() { sed -i.bak '/\/usr\/local\/sbin\/mover/d' "$D/etc/cron.d/root"; }

NAME="base sends nothing"; new_dir
t_base() { run_checkup "$D"; run_checkup "$D"; no_log; }; t t_base

NAME="checks off sends nothing"; new_dir
t_off() { echo 'CHECKS="no"' > "$D/cfg"; drop_mover; run_checkup "$D"; run_checkup "$D"; no_log; }; t t_off

M1_DESC='The mover schedule is 35 3 * * *, but cron has no mover job. The mover does not move files from the pool to the array. To correct this, open Settings > Scheduler > Mover Settings. Change the Time of the day, and then click Apply. You can then set the original time again and click Apply.'
NAME="M1 waits for a second run"; new_dir
t_m1() {
  drop_mover; run_checkup "$D"; no_log || return 1
  run_checkup "$D"
  local want got
  want=$(printf '%s\n' -e "Flotilla checkup" -s "Mover is not scheduled" -d "$M1_DESC" -i warning ---)
  got=$(cat "$D/notify.log")
  [ "$got" = "$want" ] || { echo "$got"; return 1; }
  run_checkup "$D"; [ "$(log_count)" = 1 ]
}; t t_m1

NAME="M1 clears"; new_dir
t_clear() {
  drop_mover; run_checkup "$D"; run_checkup "$D"
  cp "$FX/base/etc/cron.d/root" "$D/etc/cron.d/root"
  run_checkup "$D"
  [ "$(log_count)" = 2 ] || return 1
  local want got
  want=$(printf '%s\n' -e "Flotilla checkup" -s "Mover is scheduled" -d "Cron has a mover job again." -i normal ---)
  got=$(tail -n 9 "$D/notify.log")
  [ "$got" = "$want" ] || { echo "$got"; return 1; }
  run_checkup "$D"; [ "$(log_count)" = 2 ]
}; t t_clear

NAME="Mover Tuning cron counts"; new_dir
t_mt() {
  sed -i.bak 's#^35 3 .*#0 3 * * * /usr/local/emhttp/plugins/ca.mover.tuning/mover start |\& logger -t move#' "$D/etc/cron.d/root"
  grep -q 'ca.mover.tuning/mover' "$D/etc/cron.d/root" || return 1
  run_checkup "$D"; run_checkup "$D"; no_log
}; t t_mt

NAME="watchdog alone does not count"; new_dir
t_wd() {
  sed -i.bak 's#^35 3 .*#*/5 * * * * /usr/local/emhttp/plugins/ca.mover.tuning/age_mover watchdog >/dev/null 2>\&1#' "$D/etc/cron.d/root"
  grep -q age_mover "$D/etc/cron.d/root" || return 1
  run_checkup "$D"; no_log || return 1
  run_checkup "$D"; [ "$(log_count)" = 1 ] && grep -qx 'Mover is not scheduled' "$D/notify.log"
}; t t_wd

NAME="empty schedule sends nothing"; new_dir
t_empty() {
  sed -i.bak 's/^shareMoverSchedule=.*/shareMoverSchedule=""/' "$D/$VAR"; drop_mover
  run_checkup "$D"; run_checkup "$D"; no_log
}; t t_empty

NAME="missing shares.ini is silent"; new_dir
t_noshares() { rm "$D/var/local/emhttp/shares.ini"; drop_mover; run_checkup "$D"; [ $? = 0 ] && no_log; }; t t_noshares

NAME="dry run prints and writes nothing"; new_dir
t_dry() {
  drop_mover
  local out
  out=$(FLOTILLA_DRY_RUN=1 FLOTILLA_ROOT="$D" FLOTILLA_CFG="$D/cfg" FLOTILLA_NOTIFY="$D/notify" bash "$SCRIPT") || return 1
  echo "$out" | grep -q 'Mover is not scheduled' || return 1
  no_log && [ -z "$(find "$D" -name 'checkup.state*')" ]
}; t t_dry

# --- F1 / F2: share free space ---
DSK=var/local/emhttp/disks.ini
NL='
'
# set_disk SECTION KEY VALUE: set one key of a disks.ini section (fsSize ends each section)
set_disk() { sed -i.bak "/^\[\"$1\"\]/,/^fsSize=/ s/^$2=.*/$2=\"$3\"/" "$D/$DSK"; }
# set_free SECTION KIB: set fsFree of one disks.ini section
set_free() { set_disk "$1" fsFree "$2"; }
# set_share SHARE KEY VALUE: set one key of a shares.ini section (exclusive ends each section)
set_share() { sed -i.bak "/^\[\"$1\"\]/,/^exclusive=/ s/^$2=.*/$2=\"$3\"/" "$D/var/local/emhttp/shares.ini"; }
# state_of KIND NAME: the saved state, read through the script's own state_get
state_of() { ( CHECKUP_LIB=1 FLOTILLA_ROOT="$D" . "$SCRIPT"; state_get "$1" "$2" ); }
# has_notice SUBJECT DESCRIPTION IMPORTANCE: the log has this exact notify call
has_notice() {
  local want
  want=$(printf '%s\n' -e "Flotilla checkup" -s "$1" -d "$2" -i "$3" ---)
  [ -e "$D/notify.log" ] || { echo "no log; want: $1"; return 1; }
  case "---$NL$(cat "$D/notify.log")$NL" in *"---$NL$want$NL"*) return 0 ;; esac
  echo "missing: $1 / $2 / $3"; cat "$D/notify.log"; return 1
}
# no_subject PREFIX: no subject line starts with PREFIX
no_subject() { [ ! -e "$D/notify.log" ] || ! grep -q "^$1" "$D/notify.log"; }
f1_pool() { set_free cache 96435547; run_checkup "$D"; }
low_disks() { set_free disk1 190000000; set_free disk2 180000000; set_free disk3 "$1"; }

F1_APPDATA='Free space on cache is less than the Minimum free space for appdata (100 GB). Unraid shows this value as 97.7 GB. Unraid does not create new files in appdata. To correct this, make free space on cache, or decrease Minimum free space in Shares > appdata.'
F1_MYSHARE='Free space on cache is less than the Minimum free space for my share (100 GB). Unraid shows this value as 97.7 GB. Unraid does not create new files in my share. To correct this, make free space on cache, or decrease Minimum free space in Shares > my share.'
F1_CLEAR='Free space is more than the Minimum free space for appdata again.'

NAME="F1 pool only"; new_dir
t_f1_pool() {
  f1_pool
  has_notice "Share appdata refuses new files" "$F1_APPDATA" alert || return 1
  has_notice "Share my share refuses new files" "$F1_MYSHARE" alert || return 1
  [ "$(state_of F "my share")" = locked ] || { echo "state: $(state_of F "my share")"; return 1; }
  no_subject "Share vault"
}; t t_f1_pool

NAME="F1 array only"; new_dir
t_f1_array() {
  set_free disk1 190000000; set_free disk2 180000000; run_checkup "$D"
  has_notice "Share nextcloud refuses new files" \
    'Each disk that nextcloud can use has less free space than the Minimum free space for nextcloud (200 GB). Unraid shows this value as 195.3 GB. Unraid does not create new files in nextcloud. To correct this, make free space on one of these disks, or decrease Minimum free space in Shares > nextcloud.' \
    alert
}; t t_f1_array

NAME="F1 cache then array"; new_dir
t_f1_both() {
  set_free cache 180000000; low_disks 170000000; run_checkup "$D"
  has_notice "Share photos_immich refuses new files" \
    'Free space on cache and on each disk that photos_immich can use is less than the Minimum free space for photos_immich (200 GB). Unraid shows this value as 195.3 GB. Unraid does not create new files in photos_immich. To correct this, make free space on cache or on one of these disks, or decrease Minimum free space in Shares > photos_immich.' \
    alert || return 1
  no_subject "Share mirror"
}; t t_f1_both

NAME="F2 pool only"; new_dir
t_f2_pool() {
  set_free cache 126953125; run_checkup "$D"
  has_notice "Share appdata is near its Minimum free space" \
    'Cache has 29 GB of free space above the Minimum free space for appdata (100 GB). Unraid shows this value as 97.7 GB. When this space is full, Unraid does not create new files in appdata.' \
    warning
}; t t_f2_pool

NAME="F2 array only"; new_dir
t_f2_array() {
  low_disks 225041225; run_checkup "$D"
  has_notice "Share isos is near its Minimum free space" \
    'The disks that isos can use have 30 GB of free space above the Minimum free space for isos (200 GB). Unraid shows this value as 195.3 GB. When this space is full, Unraid does not create new files in isos.' \
    warning
}; t t_f2_array

NAME="F2 cache then array"; new_dir
t_f2_both() {
  set_free cache 225041225; low_disks 170000000; run_checkup "$D"
  has_notice "Share photos_immich is near its Minimum free space" \
    'Cache and the disks that photos_immich can use have 30 GB of free space above the Minimum free space for photos_immich (200 GB). Unraid shows this value as 195.3 GB. When this space is full, Unraid does not create new files in photos_immich.' \
    warning
}; t t_f2_both

NAME="F2 pool name capitalised"; new_dir
t_f2_cap() {
  set_free fast 225041225; low_disks 170000000; run_checkup "$D"
  has_notice "Share scratch is near its Minimum free space" \
    'Fast and the disks that scratch can use have 30 GB of free space above the Minimum free space for scratch (200 GB). Unraid shows this value as 195.3 GB. When this space is full, Unraid does not create new files in scratch.' \
    warning
}; t t_f2_cap

NAME="F1 clears with hysteresis"; new_dir
t_f1_clear() {
  f1_pool; local n; n=$(log_count)
  [ "$n" = 2 ] || { echo "count $n"; return 1; }
  set_free cache 98200000; run_checkup "$D"
  [ "$(log_count)" = "$n" ] || { echo "cleared too early"; return 1; }
  [ "$(state_of F appdata)" = locked ] || return 1
  set_free cache 448210904; run_checkup "$D"
  has_notice "Share appdata accepts new files" "$F1_CLEAR" normal || return 1
  ! grep -q 'is near its Minimum free space' "$D/notify.log"
}; t t_f1_clear

NAME="F does not repeat"; new_dir
t_f_repeat() {
  f1_pool; [ "$(log_count)" = 2 ] || return 1
  run_checkup "$D"; [ "$(log_count)" = 2 ]
}; t t_f_repeat

NAME="floor 0 is skipped"; new_dir
t_f_floor0() {
  set_free cache 39062500; run_checkup "$D"
  grep -qx 'Share appdata refuses new files' "$D/notify.log" || return 1
  no_subject "Share tmp"
}; t t_f_floor0

NAME="array stopped holds state"; new_dir
t_f_stopped() {
  f1_pool; local n; n=$(log_count)
  grep -qx 'Share appdata refuses new files' "$D/notify.log" || return 1
  sed -i.bak 's/^mdState=.*/mdState="STOPPED"/' "$D/$VAR"; set_free cache 448210904; run_checkup "$D"
  [ "$(log_count)" = "$n" ] || return 1
  [ "$(state_of F appdata)" = locked ] || return 1
  sed -i.bak 's/^mdState=.*/mdState="STARTED"/' "$D/$VAR"; run_checkup "$D"
  has_notice "Share appdata accepts new files" "$F1_CLEAR" normal
}; t t_f_stopped

NAME="missing shares.ini keeps state"; new_dir
t_f_noshares() {
  f1_pool; local n; n=$(log_count)
  [ "$(state_of F appdata)" = locked ] || return 1
  rm "$D/var/local/emhttp/shares.ini"
  run_checkup "$D" || return 1
  [ "$(log_count)" = "$n" ] || return 1
  [ "$(state_of F appdata)" = locked ] || return 1
  cp "$FX/base/var/local/emhttp/shares.ini" "$D/var/local/emhttp/shares.ini"
  run_checkup "$D"; [ "$(log_count)" = "$n" ]
}; t t_f_noshares

NAME="unmounted pool is skipped"; new_dir
t_f_unmounted() {
  set_free cache ""; set_free disk1 190000000; set_free disk2 180000000; run_checkup "$D"
  grep -qx 'Share nextcloud refuses new files' "$D/notify.log" || return 1
  no_subject "Share appdata"
}; t t_f_unmounted

NAME="F dry run reports as if no state"; new_dir
t_f_dry() {
  local out
  dry() { FLOTILLA_DRY_RUN=1 FLOTILLA_ROOT="$D" FLOTILLA_CFG="$D/cfg" FLOTILLA_NOTIFY="$D/notify" bash "$SCRIPT"; }
  set_free cache 96435547
  out=$(dry) || return 1
  echo "$out" | grep -qx 'Share appdata refuses new files' || return 1
  no_log && [ -z "$(find "$D" -name 'checkup.state*')" ] || return 1
  run_checkup "$D"; set_free cache 448210904
  out=$(dry) || return 1
  ! echo "$out" | grep -q 'accepts new files' || return 1
  [ "$(state_of F appdata)" = locked ]
}; t t_f_dry

# cache fsSize 244140625 KiB = 250e9 bytes, so margin = 25e9 (10%, under the 50e9 cap)
NAME="margin is 10% of a small pool"; new_dir
t_f_margin_pool() {
  set_disk cache fsSize 244140625
  set_free cache 126996875; run_checkup "$D"   # left 30e9: not close at 25e9 (would be close at 50e9)
  no_subject "Share appdata" || { echo "close at left 30 GB"; return 1; }
  set_free cache 121137600; run_checkup "$D"   # left 24.0001e9: close
  has_notice "Share appdata is near its Minimum free space" \
    'Cache has 24 GB of free space above the Minimum free space for appdata (100 GB). Unraid shows this value as 97.7 GB. When this space is full, Unraid does not create new files in appdata.' \
    warning
}; t t_f_margin_pool

# disk1 200 GB (margin 20e9), disk2 400 GB (40e9, largest, below the floor), disk3 300 GB (30e9, has the room)
NAME="array margin uses the largest eligible disk"; new_dir
t_f_margin_disk() {
  set_disk disk1 fsSize 195312500; set_free disk1 100000000
  set_disk disk2 fsSize 390625000; set_free disk2 150000000
  set_disk disk3 fsSize 292968750; set_free disk3 239201381; run_checkup "$D"   # left 45e9: not close at 40e9
  grep -qx 'Share nextcloud refuses new files' "$D/notify.log" || return 1
  no_subject "Share isos" || { echo "close at left 45 GB"; return 1; }
  set_free disk3 229435756; run_checkup "$D"   # left 35e9: close at 40e9 only
  has_notice "Share isos is near its Minimum free space" \
    'The disks that isos can use have 35 GB of free space above the Minimum free space for isos (200 GB). Unraid shows this value as 195.3 GB. When this space is full, Unraid does not create new files in isos.' \
    warning
}; t t_f_margin_disk

# cache margin 50e9: close below it, back to ok only past 55e9, silently both ways
NAME="close clears silently only past margin + 5 GB"; new_dir
t_f_close_ok() {
  set_free cache 126953125; run_checkup "$D"   # left 29.96e9: F2 for appdata and my share
  [ "$(log_count)" = 2 ] && [ "$(state_of F appdata)" = close ] || return 1
  set_free cache 147504688; run_checkup "$D"   # left 51e9 = margin + 1 GB
  [ "$(log_count)" = 2 ] || { echo "notice at margin + 1 GB"; return 1; }
  [ "$(state_of F appdata)" = close ] || { echo "left close at margin + 1 GB"; return 1; }
  set_free cache 152387500; run_checkup "$D"   # left 56e9 > margin + 5 GB
  [ "$(log_count)" = 2 ] || { echo "notice on close -> ok"; return 1; }
  [ -z "$(state_of F appdata)" ] || { echo "state $(state_of F appdata)"; return 1; }   # ok = no line
  set_free cache 126953125; run_checkup "$D"   # ok -> close sends F2 again
  [ "$(log_count)" = 4 ]
}; t t_f_close_ok

NAME="prefer locks only when the pool and every disk are at the floor"; new_dir
t_f_prefer() {
  set_share photos_immich useCache prefer
  set_free cache 180000000; set_free disk1 190000000; set_free disk2 180000000; run_checkup "$D"
  grep -qx 'Share nextcloud refuses new files' "$D/notify.log" || return 1
  no_subject "Share photos_immich" || { echo "locked with disk3 above the floor"; return 1; }
  set_free disk3 170000000; run_checkup "$D"
  has_notice "Share photos_immich refuses new files" \
    'Free space on cache and on each disk that photos_immich can use is less than the Minimum free space for photos_immich (200 GB). Unraid shows this value as 195.3 GB. Unraid does not create new files in photos_immich. To correct this, make free space on cache or on one of these disks, or decrease Minimum free space in Shares > photos_immich.' \
    alert
}; t t_f_prefer

NAME="exclude narrows the eligible disks"; new_dir
t_f_exclude() {
  set_free disk1 190000000; set_free disk2 180000000; run_checkup "$D"
  grep -qx 'Share nextcloud refuses new files' "$D/notify.log" || return 1
  no_subject "Share isos" || return 1
  set_share isos exclude disk3; run_checkup "$D"
  has_notice "Share isos refuses new files" \
    'Each disk that isos can use has less free space than the Minimum free space for isos (200 GB). Unraid shows this value as 195.3 GB. Unraid does not create new files in isos. To correct this, make free space on one of these disks, or decrease Minimum free space in Shares > isos.' \
    alert
}; t t_f_exclude

NAME="unknown useCache is skipped"; new_dir
t_f_unknown() {
  set_share appdata useCache maybe; f1_pool
  has_notice "Share my share refuses new files" "$F1_MYSHARE" alert || return 1
  no_subject "Share appdata"
}; t t_f_unknown

NAME="empty eligible set is skipped"; new_dir
t_f_noeligible() {
  set_share isos exclude "disk1,disk2,disk3"; set_share photos_immich exclude "disk1,disk2,disk3"
  set_free cache 180000000; set_free disk1 190000000; set_free disk2 180000000; run_checkup "$D"
  grep -qx 'Share nextcloud refuses new files' "$D/notify.log" || return 1
  no_subject "Share isos" && no_subject "Share photos_immich"
}; t t_f_noeligible

NAME="missing pool section is skipped"; new_dir
t_f_nopool() {
  set_share appdata cachePool gone; f1_pool
  has_notice "Share my share refuses new files" "$F1_MYSHARE" alert || return 1
  no_subject "Share appdata"
}; t t_f_nopool

# --- W1: load cycle count ---
W1_DESC='Load_Cycle_Count on disk2 (ST2000DM008-2UB102) is 1215433. The drive reports a normalized value of 1. The drive is near or past its rated number of load cycles. This value alone does not show a drive failure. Keep a current backup of the data on this disk.'
worn() { cp "$FX/smart-disk2-worn" "$D/var/local/emhttp/smart/${1:-disk2}"; }
w1_want() { printf '%s\n' -e "Flotilla SMART check" -s "disk2: load cycle count is near or past the rated limit" -d "$1" -i warning ---; }

NAME="W1 disk2 once"; new_dir
t_w1() {
  worn; run_checkup "$D"
  [ "$(cat "$D/notify.log")" = "$(w1_want "$W1_DESC")" ] || { cat "$D/notify.log"; return 1; }
  run_checkup "$D"; rm -f "$D/var/local/flotilla-agent/checkup.state"; run_checkup "$D"
  [ "$(log_count)" = 1 ]
}; t t_w1

NAME="W1 model with spaces"; new_dir
t_w1model() {
  worn; sed -i.bak 's/^id="ST2000DM008-2UB102_SERIAL2"/id="WDC_WD40EFRX-68N32N0_WD-WCC7K1234567"/' "$D/var/local/emhttp/disks.ini"
  run_checkup "$D"
  [ "$(log_count)" = 1 ] && grep -qxF 'Load_Cycle_Count on disk2 (WDC WD40EFRX-68N32N0) is 1215433. The drive reports a normalized value of 1. The drive is near or past its rated number of load cycles. This value alone does not show a drive failure. Keep a current backup of the data on this disk.' "$D/notify.log"
}; t t_w1model

NAME="W1 new disk id notifies again"; new_dir
t_w1new() {
  worn; run_checkup "$D"; [ "$(log_count)" = 1 ] || return 1
  sed -i.bak 's/SERIAL2/SERIALNEW/' "$D/var/local/emhttp/disks.ini"
  run_checkup "$D"; [ "$(log_count)" = 2 ]
}; t t_w1new

NAME="orphan smart file ignored"; new_dir
t_w1orphan() { worn disk9; run_checkup "$D"; [ $? = 0 ] && no_log; }; t t_w1orphan

NAME="healthy disks send nothing"; new_dir
t_w1healthy() { run_checkup "$D"; no_log && [ ! -e "$D/boot/config/plugins/flotilla-agent/wear.state" ]; }; t t_w1healthy

NAME="W1 dry run touches no state"; new_dir
t_w1dry() {
  worn
  local out
  out=$(FLOTILLA_DRY_RUN=1 FLOTILLA_ROOT="$D" FLOTILLA_CFG="$D/cfg" FLOTILLA_NOTIFY="$D/notify" bash "$SCRIPT") || return 1
  echo "$out" | grep -qF 'disk2: load cycle count is near or past the rated limit' || return 1
  no_log && [ ! -e "$D/boot" ]
}; t t_w1dry

NAME="formats"
t_fmt() (
  local r=0
  CHECKUP_LIB=1 FLOTILLA_ROOT=/nonexistent . "$SCRIPT"
  eq() { [ "$1" = "$2" ] || { echo "got '$1' want '$2'"; r=1; }; }
  eq "$(unraid_floor_text 97676156)" "97.7 GB"
  eq "$(unraid_floor_text 20000000)" "20 GB"
  eq "$(unraid_floor_text 20)" "20 KB"
  eq "$(unraid_floor_text 1000000)" "1 GB"
  eq "$(size_text 98750000128)" "99 GB"
  eq "$(size_text 700000000)" "under 1 GB"
  eq "$(size_text 1500000000000)" "1.5 TB"
  eq "$(left_text 30500000768)" "30 GB"
  eq "$(left_text 900000000)" "under 1 GB"
  eq "$(cap_first cache)" "Cache"
  return $r
); t t_fmt

exit $FAIL
