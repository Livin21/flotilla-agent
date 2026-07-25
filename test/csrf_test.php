<?php
/*
 * C1 fix: settings.php's POST handler must reject any request whose csrf_token doesn't
 * match Unraid's own per-session token (stored in /var/local/emhttp/var.ini, key
 * "csrf_token"). Without this, a forged single-field POST (action=save&RELAY=...) from
 * a malicious page can silently repoint RELAY while an admin is logged into the Unraid
 * GUI, and Task 6's scripts then leak Authorization: Bearer $SECRET + PAIRING_ID to the
 * attacker's RELAY on the next heartbeat.
 *
 * flotilla_var_ini_path() honors a FLOTILLA_VAR_INI env override (mirrors the FLOTILLA_CFG
 * override already used by Task 6's bash scripts / test/agent_test.sh) purely so this file
 * can point at disposable fixtures instead of the real (root-owned, Unraid-only)
 * /var/local/emhttp/var.ini -- production behavior (the hardcoded default path) is
 * unchanged when the env var isn't set.
 */
require __DIR__ . '/../plugin/src/include/settings.php';

$tmpIni = sys_get_temp_dir() . '/flotilla_var_ini_test_' . getmypid() . '.ini';

// --- correct token passes ---
file_put_contents($tmpIni, "csrf_token=\"abc123XYZ\"\nother=\"1\"\n");
putenv('FLOTILLA_VAR_INI=' . $tmpIni);
assert(flotilla_csrf_token() === 'abc123XYZ');
assert(flotilla_csrf_check('abc123XYZ') === true);

// --- wrong token rejected ---
assert(flotilla_csrf_check('WRONG-token') === false);

// --- missing / empty / non-string submitted token rejected ---
assert(flotilla_csrf_check('') === false);
assert(flotilla_csrf_check(null) === false);
assert(flotilla_csrf_check(['a']) === false);

// --- var.ini present but missing the csrf_token key: fail closed ---
file_put_contents($tmpIni, "other=\"1\"\n");
assert(flotilla_csrf_token() === false);
assert(flotilla_csrf_check('abc123XYZ') === false);
assert(flotilla_csrf_check('') === false);

// --- var.ini present but the key is empty: fail closed ---
file_put_contents($tmpIni, "csrf_token=\"\"\n");
assert(flotilla_csrf_token() === false);
assert(flotilla_csrf_check('') === false);

// --- unreadable / nonexistent token source: fail closed, not brick the page ---
@unlink($tmpIni);
putenv('FLOTILLA_VAR_INI=' . $tmpIni); // path no longer exists
assert(flotilla_csrf_token() === false);
assert(flotilla_csrf_check('abc123XYZ') === false);
assert(flotilla_csrf_check('') === false);
assert(flotilla_csrf_check(null) === false);

putenv('FLOTILLA_VAR_INI'); // unset override
echo "csrf ok\n";
