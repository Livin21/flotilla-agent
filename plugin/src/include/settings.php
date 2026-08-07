<?php
/* Flotilla Agent settings backend. Pure functions + a tiny POST handler used by FlotillaAgent.page. */
// Honors a FLOTILLA_CFG env override purely for testability -- the same pattern as
// flotilla_var_ini_path()/flotilla_dynamix_cfg_path()/flotilla_headers_path()/
// flotilla_cron_file_path() below, and the same env var Task 6's bash scripts already read.
// Production always falls back to the real, hardcoded Unraid path when the env var is unset.
define('FLOTILLA_CFG', getenv('FLOTILLA_CFG') !== false
  ? getenv('FLOTILLA_CFG')
  : '/boot/config/plugins/flotilla-agent/flotilla-agent.cfg');
define('DYNAMIX_CFG', '/boot/config/plugins/dynamix/dynamix.cfg');
// Must track plugin/flotilla-agent.plg's <!ENTITY version> -- this is the "installed" side of
// Task 13 §8's min-agent comparison (see flotilla_min_agent_notice() below).
define('FLOTILLA_AGENT_VERSION', '2026.08.07');

function flotilla_b64url($bytes) { return rtrim(strtr(base64_encode($bytes), '+/', '-_'), '='); }

// I6: honors a FLOTILLA_DYNAMIX_CFG env override purely for testability (mirrors
// flotilla_var_ini_path()/flotilla_headers_path()'s pattern) -- production always falls back
// to the real, hardcoded Unraid path when the env var is unset.
function flotilla_dynamix_cfg_path() {
  $override = getenv('FLOTILLA_DYNAMIX_CFG');
  return $override !== false ? $override : DYNAMIX_CFG;
}

/*
 * CSRF protection (C1). Unraid stamps a per-session token into /var/local/emhttp/var.ini
 * (key "csrf_token") and its own pages echo it back as a hidden form field; we do the same
 * so a forged cross-site POST (no way to read the victim's session token) can't silently
 * repoint RELAY -- which would otherwise hand Task 6's next heartbeat's
 * "Authorization: Bearer $SECRET" + PAIRING_ID straight to an attacker's server.
 *
 * flotilla_var_ini_path() honors a FLOTILLA_VAR_INI env override purely for testability
 * (mirrors the FLOTILLA_CFG override Task 6's bash scripts already use); production always
 * falls back to the real, hardcoded Unraid path when the env var is unset.
 */
function flotilla_var_ini_path() {
  $override = getenv('FLOTILLA_VAR_INI');
  return $override !== false ? $override : '/var/local/emhttp/var.ini';
}

// Returns the current session's csrf_token as a string, or false if it can't be read
// (missing file, unparsable ini, or no/empty csrf_token key) -- callers must fail closed.
function flotilla_csrf_token() {
  $path = flotilla_var_ini_path();
  if (!is_readable($path)) return false;
  $ini = @parse_ini_file($path);
  if ($ini === false || !isset($ini['csrf_token']) || $ini['csrf_token'] === '') return false;
  return (string)$ini['csrf_token'];
}

// Constant-time comparison against the session's real token. Fails closed: if the token
// can't be established (unreadable var.ini, missing key) or the submitted value isn't a
// plain string, the request is rejected -- never silently accepted.
function flotilla_csrf_check($submitted) {
  $expected = flotilla_csrf_token();
  if ($expected === false) return false;
  if (!is_string($submitted)) return false;
  return hash_equals($expected, $submitted);
}

function flotilla_read_cfg() {
  $cfg = ['RELAY' => 'https://flotilla-push.livinmathew.com', 'PAIRING_ID' => '', 'SECRET' => '', 'KEY' => '',
          'LEVEL_MIN' => 'warning', 'CAT_DISKS' => 'yes', 'CAT_ARRAY' => 'yes', 'CAT_OTHER' => 'yes'];
  if (is_readable(FLOTILLA_CFG)) {
    $parsed = parse_ini_file(FLOTILLA_CFG);
    if ($parsed !== false) foreach ($parsed as $k => $v) $cfg[$k] = $v;
  }
  return $cfg;
}

/*
 * Escape a value for safe embedding inside a double-quoted string in a file that Task 6's
 * scripts `source` directly as bash (send-event.sh / heartbeat.sh both do `source "$CFG"`,
 * running as root off Unraid's notify agent and the heartbeat cron). Bash still performs
 * backslash processing, `$` (parameter/command substitution) and backtick (command
 * substitution) inside double quotes, so an unescaped POST-derived value (RELAY and
 * LEVEL_MIN both come straight from $_POST in the 'save' handler below) could otherwise
 * inject arbitrary shell commands that execute the next time the cfg is sourced. All
 * control characters (0x00-0x1F, 0x7F) -- not just CR/LF -- are stripped outright: a raw
 * NUL byte can truncate/corrupt bash's parse of the *whole* file (silently wiping
 * subsequent keys like PAIRING_ID/SECRET/KEY -- a persistent unpairing DoS), and a raw
 * newline starts a new, attacker-controlled statement rather than merely breaking out of
 * the quoted string. This is defense in depth: flotilla_valid_relay()/
 * flotilla_valid_level_min() are the primary defense and already reject these bytes at the
 * input boundary before a value ever reaches here. Ordinary values (URLs, uuids, base64url
 * secrets, "yes"/"no", "normal"/"warning"/"alert") never contain these characters, so this
 * is a no-op for every legitimate value Task 6's config contract uses.
 */
function flotilla_cfg_escape($v) {
  $v = preg_replace('/[\x00-\x1F\x7F]/', '', (string)$v);
  return str_replace(['\\', '"', '$', '`'], ['\\\\', '\\"', '\\$', '\\`'], $v);
}

/*
 * I9: write via a temp file that is chmod'd 0600 BEFORE it is renamed into place. The previous
 * file_put_contents()-then-chmod() order left the config -- containing SECRET and KEY -- sitting
 * at its final path with default-umask permissions for the window between the two calls, and a
 * crash or a failed chmod in between left it that way permanently. rename() within the same
 * directory is atomic, so a reader also never sees a half-written config.
 *
 * CAVEAT, deliberately recorded rather than papered over: FLOTILLA_CFG lives on /boot, which on
 * Unraid is a vfat flash volume. vfat carries no POSIX mode bits -- permissions come from the
 * mount's fmask/dmask -- so chmod() there is typically a no-op, and this cannot make the file
 * 0600 if the mount says otherwise. That is a property of Unraid's flash, not something this
 * function can fix; what it CAN do is stop being the reason the mode is wrong. The same pattern
 * (umask + temp + chmod + atomic mv) is what beacon-install.sh already uses for
 * /etc/flotilla-beacon.conf, where the mode bits are real.
 */
function flotilla_write_cfg($cfg) {
  $dir = dirname(FLOTILLA_CFG);
  if (!is_dir($dir)) mkdir($dir, 0700, true);
  $out = '';
  foreach ($cfg as $k => $v) $out .= $k . '="' . flotilla_cfg_escape($v) . '"' . "\n";
  $tmp = FLOTILLA_CFG . '.tmp.' . getmypid();
  if (@file_put_contents($tmp, $out) === false) return false;
  @chmod($tmp, 0600);
  if (!@rename($tmp, FLOTILLA_CFG)) { @unlink($tmp); return false; }
  @chmod(FLOTILLA_CFG, 0600);
  return true;
}

/*
 * Set the agents bit (4) on normal/warning/alert entity values, but ONLY inside the
 * [notify] section. Idempotent (OR-ing bit 4 twice is a no-op); every other section
 * -- including one that happens to reuse the same key names, e.g. [PTP]/[NTP] -- is
 * passed through untouched. Scoping is done by literal slicing between the "[notify]"
 * header and the next "\n[" section header (or end of string) rather than a whole-text
 * regex, so a naive match can't leak across section boundaries.
 */
function flotilla_fix_entities($text) {
  $marker = "[notify]";
  $start = strpos($text, $marker);
  if ($start === false) return $text; // no [notify] section present; nothing to fix

  $bodyStart = $start + strlen($marker);
  $nextHeader = strpos($text, "\n[", $bodyStart);
  $bodyEnd = ($nextHeader === false) ? strlen($text) : $nextHeader;

  $head = substr($text, 0, $bodyStart);
  $body = substr($text, $bodyStart, $bodyEnd - $bodyStart);
  $tail = substr($text, $bodyEnd);

  $body = preg_replace_callback(
    '/^(normal|warning|alert)="(\d+)"$/m',
    function ($m) { return $m[1] . '="' . ((int)$m[2] | 4) . '"'; },
    $body
  );

  return $head . $body . $tail;
}

/*
 * I6: flotilla_fix_entities() only ever ran once, from flotilla_pair() below -- but Unraid's
 * own Settings → Notifications page rewrites dynamix.cfg wholesale on save and clears bit 4
 * (the "run custom notification agents" bit) on normal/warning/alert, with zero indication to
 * the user that push silently died. These two functions are the fix: flotilla_entities_ok()
 * is the read-only check the settings page uses to show current state (null = unknown/can't
 * tell, fail open to "don't nag" rather than false-alarm); flotilla_reassert_entities() is the
 * idempotent, best-effort repair, now called from THREE places instead of only ever the first
 * pair -- flotilla_pair() (below), the 'save' action, and the plugin's install hook (.plg) --
 * plus a one-click "Repair" button on the settings page wired to a new 'repair_entities'
 * action, so a user who visited Unraid's own notification settings can fix it without having
 * to re-pair.
 */
function flotilla_entities_ok() {
  $path = flotilla_dynamix_cfg_path();
  if (!is_readable($path)) return null;
  $text = file_get_contents($path);
  if ($text === false) return null;
  $start = strpos($text, "[notify]");
  if ($start === false) return null;
  $bodyStart = $start + strlen("[notify]");
  $nextHeader = strpos($text, "\n[", $bodyStart);
  $body = substr($text, $bodyStart, ($nextHeader === false ? strlen($text) : $nextHeader) - $bodyStart);
  if (!preg_match_all('/^(normal|warning|alert)="(\d+)"$/m', $body, $rows, PREG_SET_ORDER)) return null;
  $seen = [];
  foreach ($rows as $row) $seen[$row[1]] = (((int)$row[2]) & 4) === 4;
  foreach (['normal', 'warning', 'alert'] as $k) {
    if (($seen[$k] ?? false) !== true) return false;
  }
  return true;
}

/*
 * I15: this is a read-modify-write of UNRAID'S OWN notification config, and it runs on every
 * pair, every save, every explicit repair and on plugin install. The previous
 * file_get_contents()/file_put_contents() pair had no locking and no atomicity, so a Flotilla
 * save landing at the same moment as a save on Unraid's own Settings -> Notifications page (or
 * as the install block's php -r racing an emhttp write) could clobber the other side's write or
 * leave dynamix.cfg truncated. Corrupting Unraid's notification configuration is a
 * disrupting-the-host outcome, which is why the narrow window is worth closing.
 *
 * Two changes: (1) return early when the text is already correct, which is the overwhelmingly
 * common case -- the repair is idempotent and called constantly, so not writing at all unless
 * something actually needs fixing removes almost every opportunity for the race; and (2) when a
 * write is genuinely needed, write a temp file in the same directory and rename() it into place,
 * so a reader never sees a partial file and a crash mid-write can't truncate Unraid's config.
 * The original file's permissions are carried over to the replacement.
 */
function flotilla_reassert_entities() {
  $path = flotilla_dynamix_cfg_path();
  if (!is_readable($path) || !is_writable($path)) return;
  $text = file_get_contents($path);
  if ($text === false) return;
  $fixed = flotilla_fix_entities($text);
  if ($fixed === $text) return; // already correct: don't touch Unraid's config at all
  $tmp = $path . '.flotilla-tmp.' . getmypid();
  if (@file_put_contents($tmp, $fixed) === false) return;
  $mode = @fileperms($path);
  if ($mode !== false) @chmod($tmp, $mode & 0777);
  if (!@rename($tmp, $path)) @unlink($tmp);
}

/*
 * Task 13: "Reset pairing" (the 'reset' action below) reuses this same function as the
 * initial 'pair' action, so this is the one place that can revoke the OLD pairing at the
 * relay before its values are overwritten -- while its secret is still known. A brand new
 * initial pairing has PAIRING_ID/SECRET both empty (flotilla_read_cfg()'s defaults), so
 * this naturally no-ops on first pair; only a reset (whose $cfg always already has both)
 * has anything to revoke. Best-effort: revoke.sh itself enforces a 5s timeout and always
 * exits 0, and this call site doesn't inspect its exit code either, so a relay that's down
 * (or briefly unreachable) can never block the local reset that follows.
 */
function flotilla_pair($cfg) {
  if (($cfg['PAIRING_ID'] ?? '') !== '' && ($cfg['SECRET'] ?? '') !== '') {
    shell_exec('bash /usr/local/emhttp/plugins/flotilla-agent/scripts/revoke.sh 2>/dev/null');
  }
  $cfg['PAIRING_ID'] = strtolower(trim((string)shell_exec('uuidgen')));
  $cfg['SECRET'] = flotilla_b64url(random_bytes(32));
  $cfg['KEY'] = flotilla_b64url(random_bytes(32));
  flotilla_write_cfg($cfg);
  flotilla_reassert_entities();
  // ensure the notify shim exists (also done by .plg install)
  //
  // I10: mkdir -p the directory first and chmod the result executable. Stock Unraid ships that
  // directory, but a wiped flash config or a user who has never touched notification settings
  // can leave it absent, in which case this write failed silently and push never fired while
  // this page still said "Paired." And the .plg's install block chmod +x's the shim it writes
  // while this fallback did not -- so a shim recreated here landed at whatever the umask gave,
  // which on a notify implementation that only runs executable agents is a silently dead
  // install. Both are best-effort (@): a failure here must never fatal the pairing itself.
  $shim = '/boot/config/plugins/dynamix/notifications/agents/FlotillaPush.sh';
  $shimDir = dirname($shim);
  if (!is_dir($shimDir)) @mkdir($shimDir, 0755, true);
  if (!file_exists($shim)) {
    if (@file_put_contents($shim, "#!/bin/bash\nexec bash /usr/local/emhttp/plugins/flotilla-agent/scripts/agent.sh\n") !== false)
      @chmod($shim, 0755);
  }
  return $cfg;
}

function flotilla_pair_url($cfg) {
  $host = trim((string)shell_exec('hostname'));
  return 'flotilla://pair?v=1&id=' . $cfg['PAIRING_ID'] . '&k=' . $cfg['KEY'] . '&s=' . $cfg['SECRET']
       . '&n=' . rawurlencode($host !== '' ? $host : 'Unraid');
}

// I1: whitelist LEVEL_MIN to exactly the three values the config contract (and Task 6's
// scripts' `case "${LEVEL_MIN:-warning}" in alert) ...; warning) ...; *) ...;` fallback)
// understand. Anything else is rejected (caller keeps the previous value).
function flotilla_valid_level_min($v) {
  return in_array($v, ['normal', 'warning', 'alert'], true);
}

// I1: RELAY is the only free-text field in the config, so it's validated strictly at the
// boundary rather than merely escaped: must be a well-formed absolute http/https URL, and
// -- belt and braces against filter_var's known laxness with odd characters -- every byte
// must come from a conservative allowlist that excludes control characters, NUL,
// whitespace, quotes, backticks, `$`, and backslash. This is what closes the NUL-byte
// config-corruption DoS and the backtick escape/unescape growth defect: neither byte can
// ever reach flotilla_write_cfg via RELAY in the first place.
function flotilla_valid_relay($v) {
  if (!is_string($v)) return false;
  if ($v === '' || strlen($v) > 2048) return false;
  for ($i = 0, $len = strlen($v); $i < $len; $i++) {
    $o = ord($v[$i]);
    if ($o <= 0x20 || $o === 0x7F) return false;      // control chars, NUL, whitespace
    if (strpos('\'"`$\\', $v[$i]) !== false) return false; // quotes, backtick, $, backslash
  }
  if (filter_var($v, FILTER_VALIDATE_URL) === false) return false;
  $scheme = strtolower((string)parse_url($v, PHP_URL_SCHEME));
  return $scheme === 'http' || $scheme === 'https';
}

/*
 * I14: flotilla_valid_relay() deliberately accepts http:// -- the test harness needs
 * http://127.0.0.1:18799, and LAN self-hosting is a documented goal -- but every request to the
 * relay carries "Authorization: Bearer <S>", so an http:// relay outside the local network puts
 * the bearer secret on the wire in the clear on every heartbeat (once a minute, forever). Event
 * *content* is unaffected: it's sealed with K before it leaves the box, so this is a secret
 * exposure, not a content exposure -- but S is enough to forge a going-down heartbeat that
 * silences the dead-man switch, or to delete the pairing.
 *
 * Returns true only when a warning is genuinely warranted, so the settings page doesn't cry wolf
 * at the two legitimate http:// cases: loopback and RFC1918/reserved addresses (a self-hosted
 * relay on the LAN), and ".local"/"localhost" names. A bare hostname can't be classified without
 * resolving it -- which this page must not do -- so it warns, since a plain hostname over http
 * is far more often a real remote host than a LAN one.
 */
function flotilla_relay_insecure($relay) {
  if (!is_string($relay) || $relay === '') return false;
  if (strtolower((string)parse_url($relay, PHP_URL_SCHEME)) === 'https') return false;
  $host = (string)parse_url($relay, PHP_URL_HOST);
  if ($host === '') return false; // unparsable; flotilla_valid_relay() is what gates this
  $host = strtolower(trim($host, '[]'));
  if ($host === 'localhost' || substr($host, -6) === '.local') return false;
  if (filter_var($host, FILTER_VALIDATE_IP) !== false) {
    // No-priv/no-res filters reject loopback, RFC1918, link-local and other reserved ranges --
    // i.e. "passes" here means a genuinely routable, public address.
    return filter_var($host, FILTER_VALIDATE_IP, FILTER_FLAG_NO_PRIV_RANGE | FILTER_FLAG_NO_RES_RANGE) !== false;
  }
  return true;
}

// Path to heartbeat.sh's last-captured relay response headers (Task 13 §8; see the -D flag
// in plugin/src/scripts/heartbeat.sh). Honors FLOTILLA_HEADERS purely for testability --
// mirrors flotilla_var_ini_path()'s FLOTILLA_VAR_INI override above -- production always
// falls back to the real, hardcoded path when the env var is unset.
function flotilla_headers_path() {
  $override = getenv('FLOTILLA_HEADERS');
  return $override !== false ? $override : '/var/local/flotilla-agent.headers';
}

/*
 * Task 13 §8 (spec §8 versioning): the relay advertises the minimum agent version it wants
 * via the X-Min-Agent response header on every request (flotilla-relay's index.js sets this
 * on every response, including /v1/heartbeat). heartbeat.sh captures that header, once per
 * beat, to flotilla_headers_path(); this reads it back and decides whether the settings page
 * should show an "update needed" notice.
 *
 * Returns the required version string if $installedVersion is older, or null if no notice
 * should show. Fails closed to null (no notice) for every kind of bad input -- a
 * missing/unreadable header file (heartbeat.sh has never run, or couldn't write it, e.g. a
 * fresh install or a read-only /var/local), a beat that predates this feature, or a
 * malformed/garbage X-Min-Agent value (a compromised or misconfigured relay) -- because a
 * wrongly-shown update nag is worse UX than an occasionally-missed one, and this must never
 * be capable of fataling out the settings page.
 *
 * Comparison uses version_compare(), NOT a lexicographic string comparison: this project's
 * own agent version is calendar-shaped ("2026.07.26"), and a naive string/`>` compare gets
 * segments like "9" vs "10" backwards (e.g. "2026.9.1" would lexicographically compare
 * *greater* than "2026.10.1", the opposite of the real chronological order). version_compare
 * splits on '.' and compares each numeric segment as a number, which is what a human means
 * by "newer version".
 */
function flotilla_min_agent_notice($installedVersion) {
  if (!is_string($installedVersion) || $installedVersion === '') return null;
  $path = flotilla_headers_path();
  if (!is_readable($path)) return null;
  $hdrs = @file_get_contents($path);
  if (!is_string($hdrs) || $hdrs === '') return null;
  // Bounded digit-group count/width: enough for any real dotted version, small enough that
  // a garbage/oversized header value can't cause pathological work.
  if (!preg_match('/^X-Min-Agent:\s*([0-9]{1,9}(?:\.[0-9]{1,9}){0,9})\s*$/mi', $hdrs, $m)) return null;
  $minAgent = $m[1];
  return version_compare($installedVersion, $minAgent, '<') ? $minAgent : null;
}

/*
 * I10: the .plg's install block writes flotilla-agent.cron and calls update_cron, but Unraid's
 * own update_cron (see /usr/local/sbin/update_cron) builds /etc/cron.d/root by iterating
 * /var/log/plugins/*.plg and cat-ing each registered plugin's *.cron files -- and that
 * registration symlink is created by the plugin manager AFTER the install FILE block finishes
 * running, not before. So the install-time update_cron call is provably a no-op on a fresh
 * install (confirmed on a live Unraid 7.3.2 box: no flotilla line in /etc/cron.d/root right
 * after `plugin install`, fixed instantly by running update_cron by hand). Left unfixed, the
 * heartbeat never gets scheduled until the next reboot or an unrelated plugin's install, and a
 * user who pairs right after installing gets a false "Server unreachable" push from the
 * relay's 180s dead-man switch.
 *
 * This settings page is the natural repair point -- it's where pairing happens, so a user who
 * just installed loads it almost immediately, long before the next reboot would otherwise fix
 * it on its own. flotilla_cron_ok() is the read-only check (mirrors flotilla_entities_ok():
 * null = can't tell, fail safe rather than a false alarm); flotilla_reassert_cron() is the
 * idempotent, best-effort repair -- called silently on every page load AND reachable via a
 * one-click "Repair" button (the 'repair_cron' action below) if the silent attempt didn't
 * stick. This is belt-and-braces alongside the .plg's own detached, delayed retry
 * (`( sleep 10; update_cron ) &> /dev/null &` at the end of its install block), which covers
 * the case where the user never opens this page at all.
 */
function flotilla_cron_file_path() {
  $override = getenv('FLOTILLA_CRON_FILE');
  return $override !== false ? $override : '/boot/config/plugins/flotilla-agent/flotilla-agent.cron';
}

// The live, generated system crontab that Unraid's update_cron writes -- NOT anything under
// /boot/config/plugins. Honors FLOTILLA_CRONTAB purely for testability, same pattern as every
// other overridable path in this file; production always falls back to the real path.
function flotilla_crontab_path() {
  $override = getenv('FLOTILLA_CRONTAB');
  return $override !== false ? $override : '/etc/cron.d/root';
}

// Returns true (our heartbeat line is present in the live crontab), false (our .cron file
// exists on the flash but the live crontab doesn't have it -- needs repair), or null (can't
// tell: our .cron file is missing/empty/unreadable, or the live crontab is unreadable -- fails
// safe to "don't nag" rather than risk a false alarm, mirroring flotilla_entities_ok()).
function flotilla_cron_ok() {
  $cronFile = flotilla_cron_file_path();
  if (!is_readable($cronFile)) return null;
  $want = trim((string)@file_get_contents($cronFile));
  if ($want === '') return null;
  $tabPath = flotilla_crontab_path();
  if (!is_readable($tabPath)) return null;
  $have = @file_get_contents($tabPath);
  if (!is_string($have)) return null;
  return strpos($have, $want) !== false;
}

// Idempotent, best-effort repair: re-run Unraid's own update_cron so the heartbeat entry
// (silently dropped by the registration-ordering trap documented above) gets picked up without
// waiting for a reboot or another plugin's install to trigger it incidentally. Only shells out
// when flotilla_cron_ok() is confidently false (both files readable and the entry is
// genuinely missing) -- a null (can't-tell) result never causes update_cron to be invoked, and
// update_cron is never called from here more than needed. update_cron itself is an Unraid
// system binary that doesn't exist off a real Unraid box, so this can't be exercised
// end-to-end by this repo's test suite (see test/cron_ok_test.php's note); shell_exec's stderr
// is discarded so a missing/failing binary can never fatal this out.
function flotilla_reassert_cron() {
  if (flotilla_cron_ok() !== false) return;
  shell_exec('update_cron 2>/dev/null');
}

/*
 * Pure computation of the new config for the 'save' action -- kept separate from the POST
 * handler so it's directly unit-testable with no file I/O.
 *
 * C2: CAT_DISKS/CAT_ARRAY/CAT_OTHER are keyed off isset($post[$k]) -- present means the
 * checkbox was checked, absent means it was unchecked (unchecked HTML checkboxes are never
 * submitted at all) -- never off the stale/previous $cfg value, or an unchecked-then-saved
 * category could never actually be turned off.
 *
 * I1: LEVEL_MIN/RELAY are only applied when present AND valid; invalid input silently
 * keeps the previous (already-known-good) value instead of being stored verbatim.
 */
function flotilla_apply_save(array $cfg, array $post) {
  if (isset($post['LEVEL_MIN']) && flotilla_valid_level_min($post['LEVEL_MIN'])) $cfg['LEVEL_MIN'] = $post['LEVEL_MIN'];
  if (isset($post['RELAY']) && flotilla_valid_relay($post['RELAY'])) $cfg['RELAY'] = $post['RELAY'];
  foreach (['CAT_DISKS', 'CAT_ARRAY', 'CAT_OTHER'] as $k) $cfg[$k] = isset($post[$k]) ? 'yes' : 'no';
  return $cfg;
}

if (php_sapi_name() !== 'cli' && ($_SERVER['REQUEST_METHOD'] ?? '') === 'POST') {
  // C1: reject any POST whose csrf_token doesn't match this session's real token. No state
  // change on mismatch -- just redirect, same as every other unhandled action.
  if (!flotilla_csrf_check($_POST['csrf_token'] ?? null)) { header('Location: /Settings/FlotillaAgent'); exit; }

  $cfg = flotilla_read_cfg();
  $errs = [];
  switch ($_POST['action'] ?? '') {
    case 'pair': case 'reset': $cfg = flotilla_pair($cfg); break;
    case 'save':
      if (isset($_POST['LEVEL_MIN']) && !flotilla_valid_level_min($_POST['LEVEL_MIN'])) $errs[] = 'level';
      if (isset($_POST['RELAY']) && !flotilla_valid_relay($_POST['RELAY'])) $errs[] = 'relay';
      $cfg = flotilla_apply_save($cfg, $_POST);
      flotilla_write_cfg($cfg);
      // I6: re-assert on every save, not just the first pair -- Unraid's own notification
      // settings page can clear bit 4 at any time, and 'save' is the action a paired user is
      // most likely to hit next.
      flotilla_reassert_entities();
      break;
    case 'repair_entities':
      // I6: one-click repair for the "Unraid will deliver ... to Flotilla: no" state shown
      // on the settings page below.
      flotilla_reassert_entities();
      break;
    case 'repair_cron':
      // I10: one-click repair for the "Heartbeat scheduled: no" state shown on the settings
      // page below, for whenever the silent on-page-load attempt in FlotillaAgent.page didn't
      // stick (e.g. update_cron itself failed transiently).
      flotilla_reassert_cron();
      break;
    case 'test':
      exec('/usr/local/emhttp/webGui/scripts/notify -e "Flotilla Agent" -s "Test notification" '
         . '-d "If this reached your phone, Flotilla Push works." -i "warning" 2>/dev/null');
      break;
  }
  header('Location: /Settings/FlotillaAgent' . ($errs ? ('?err=' . implode(',', $errs)) : ''));
  exit;
}
