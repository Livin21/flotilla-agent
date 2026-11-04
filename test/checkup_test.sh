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
