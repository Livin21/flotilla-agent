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
# set_free SECTION KIB: set fsFree of one disks.ini section
set_free() { sed -i.bak "/^\[\"$1\"\]/,/^fsSize=/ s/^fsFree=.*/fsFree=\"$2\"/" "$D/$DSK"; }
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

F1_APPDATA='Free space on cache is 99 GB. The Minimum free space for appdata is 100 GB. Unraid shows this value as 97.7 GB. Unraid does not create new files in appdata. To correct this, make free space on cache, or decrease Minimum free space in Shares > appdata.'
F1_MYSHARE='Free space on cache is 99 GB. The Minimum free space for my share is 100 GB. Unraid shows this value as 97.7 GB. Unraid does not create new files in my share. To correct this, make free space on cache, or decrease Minimum free space in Shares > my share.'
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
    'Free space on cache is 130 GB. The Minimum free space for appdata is 100 GB. Unraid shows this value as 97.7 GB. When free space on cache is 100 GB or less, Unraid does not create new files in appdata.' \
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
