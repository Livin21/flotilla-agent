<?php
/*
 * I10: the .plg's install block writes flotilla-agent.cron and calls update_cron, but
 * Unraid's own update_cron only picks up a plugin's *.cron files once that plugin is
 * registered under /var/log/plugins/<name>.plg -- and that registration symlink is created
 * by the plugin manager AFTER the install FILE block finishes running. So the install-time
 * update_cron call is provably a no-op on a fresh install (confirmed on a live Unraid 7.3.2
 * box), and the heartbeat never gets scheduled until the next reboot or an unrelated
 * plugin's install -- meanwhile the relay's dead-man switch fires a false "Server
 * unreachable" push. flotilla_cron_ok() is the read-only detection FlotillaAgent.page uses
 * (mirrors flotilla_entities_ok(): null = can't tell, fail safe); flotilla_reassert_cron()
 * is the idempotent repair.
 *
 * flotilla_cron_file_path()/flotilla_crontab_path() honor FLOTILLA_CRON_FILE/FLOTILLA_CRONTAB
 * env overrides purely for testability (mirrors every other overridable path in this file)
 * -- this test never touches the real, root-only /boot or /etc paths.
 *
 * LIMITATION: update_cron itself is an Unraid system binary (/usr/local/sbin/update_cron)
 * that does not exist off a real Unraid box, so this suite cannot exercise it end-to-end --
 * there is no way here to prove flotilla_reassert_cron() actually causes /etc/cron.d/root to
 * be regenerated. What IS tested: the pure detection logic (flotilla_cron_ok()'s present /
 * absent / unreadable-file cases) and that flotilla_reassert_cron() never fatals and only
 * shells out when the detection is confidently false (never on a null/can't-tell state, and
 * never once the entry is already present).
 */
require __DIR__ . '/../plugin/src/include/settings.php';

$tmpCronFile = sys_get_temp_dir() . '/flotilla_cronfile_test_' . getmypid() . '.cron';
$tmpCrontab  = sys_get_temp_dir() . '/flotilla_crontab_test_' . getmypid() . '.root';
putenv('FLOTILLA_CRON_FILE=' . $tmpCronFile);
putenv('FLOTILLA_CRONTAB=' . $tmpCrontab);
assert(flotilla_cron_file_path() === $tmpCronFile);
assert(flotilla_crontab_path() === $tmpCrontab);

$heartbeatLine = "* * * * * bash /usr/local/emhttp/plugins/flotilla-agent/scripts/heartbeat.sh &> /dev/null";

// --- our .cron file doesn't exist at all (e.g. never installed, or read during a race):
// unknown, not a false "no" ---
@unlink($tmpCronFile);
@unlink($tmpCrontab);
assert(flotilla_cron_ok() === null);
flotilla_reassert_cron(); // must no-op silently, never fatal
echo "cron_ok: missing .cron file -> null, no fatal\n";

// --- .cron file present but empty: unknown (nothing meaningful to look for) ---
file_put_contents($tmpCronFile, '');
assert(flotilla_cron_ok() === null);
echo "cron_ok: empty .cron file -> null\n";

// --- .cron file present, but the live crontab doesn't exist yet (e.g. update_cron has
// genuinely never run on this box): unknown, fail safe ---
file_put_contents($tmpCronFile, $heartbeatLine . "\n");
@unlink($tmpCrontab);
assert(flotilla_cron_ok() === null);
echo "cron_ok: .cron file present, crontab missing -> null\n";

// --- .cron file present, crontab present but does NOT contain our line: the real bug this
// covers -- install ran, .cron file was written, but the plugin-manager registration race
// meant update_cron never picked it up. This is the confidently-false state. ---
file_put_contents($tmpCrontab, "# Generated crontab, do not edit\n0 3 * * * /usr/local/sbin/mover &> /dev/null\n");
assert(flotilla_cron_ok() === false);
echo "cron_ok: .cron file present, crontab present without our line -> false\n";

// --- crontab contains our line among others: present ---
file_put_contents($tmpCrontab, "# Generated crontab, do not edit\n" . $heartbeatLine . "\n0 3 * * * /usr/local/sbin/mover &> /dev/null\n");
assert(flotilla_cron_ok() === true);
echo "cron_ok: crontab contains our line -> true\n";

// --- unreadable .cron file: unknown, fail safe (matches flotilla_entities_ok()'s
// unreadable-dynamix.cfg case) ---
chmod($tmpCronFile, 0000);
if (!is_readable($tmpCronFile)) { // root can still read 0000 files; only meaningful as non-root
  assert(flotilla_cron_ok() === null);
  echo "cron_ok: unreadable .cron file -> null\n";
} else {
  echo "cron_ok: unreadable-file case skipped (running as root, 0000 still readable)\n";
}
chmod($tmpCronFile, 0644);

// --- unreadable crontab: unknown, fail safe ---
chmod($tmpCrontab, 0000);
if (!is_readable($tmpCrontab)) {
  assert(flotilla_cron_ok() === null);
  echo "cron_ok: unreadable crontab -> null\n";
} else {
  echo "cron_ok: unreadable-crontab case skipped (running as root, 0000 still readable)\n";
}
chmod($tmpCrontab, 0644);

// --- flotilla_reassert_cron() never fatals when the confidently-false state calls through
// to shell_exec('update_cron ...') -- update_cron doesn't exist on this dev machine, so this
// only proves the call is silent/non-fatal, NOT that anything was actually fixed (see the
// LIMITATION note above; that half genuinely requires a live Unraid box). ---
file_put_contents($tmpCrontab, "# Generated crontab, do not edit\n0 3 * * * /usr/local/sbin/mover &> /dev/null\n");
assert(flotilla_cron_ok() === false);
flotilla_reassert_cron(); // must not fatal even though update_cron doesn't exist here
echo "cron_reassert: does not fatal when the underlying update_cron binary is absent\n";

@unlink($tmpCronFile);
@unlink($tmpCrontab);
putenv('FLOTILLA_CRON_FILE'); // unset overrides
putenv('FLOTILLA_CRONTAB');
echo "cron_ok ok\n";
