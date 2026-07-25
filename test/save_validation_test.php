<?php
/*
 * C2 fix: unchecked HTML checkboxes are absent from the POST entirely, so the 'save'
 * handler must key CAT_DISKS/CAT_ARRAY/CAT_OTHER off isset($_POST[$k]) -- not off the
 * stale $cfg value -- or a user can never disable a category (unchecking + saving would
 * be a silent no-op forever).
 *
 * I1 fix: RELAY is the only free-text field and must be validated as a strict absolute
 * http/https URL with a conservative character allowlist (no control chars, NUL, quotes,
 * backticks, $, backslash, whitespace); LEVEL_MIN must be whitelisted to exactly
 * normal|warning|alert. Invalid input keeps the previous value rather than being stored
 * verbatim -- this is what closes the NUL-byte config-corruption DoS and the backtick
 * escape/unescape growth defect, at the input boundary rather than by trying to escape
 * arbitrary bytes.
 *
 * flotilla_apply_save($cfg, $post) is the pure function extracted from the 'save' case so
 * this is all testable without any file I/O / FLOTILLA_CFG environment dependency.
 */
require __DIR__ . '/../plugin/src/include/settings.php';

function base_cfg() {
  return ['RELAY' => 'https://push.flotilla.livinmathew.com', 'PAIRING_ID' => '11111111-1111-4111-8111-111111111111',
          'SECRET' => 'sekrit', 'KEY' => 'keeey', 'LEVEL_MIN' => 'warning',
          'CAT_DISKS' => 'yes', 'CAT_ARRAY' => 'yes', 'CAT_OTHER' => 'yes'];
}

// --- C2: save WITHOUT CAT_DISKS in the POST must turn it off ---
$out = flotilla_apply_save(base_cfg(), ['action' => 'save', 'CAT_ARRAY' => 'yes', 'CAT_OTHER' => 'yes']);
assert($out['CAT_DISKS'] === 'no');
assert($out['CAT_ARRAY'] === 'yes');
assert($out['CAT_OTHER'] === 'yes');

// --- C2: save WITH CAT_DISKS present must turn it (back) on ---
$out2 = flotilla_apply_save(['RELAY' => 'https://x', 'PAIRING_ID' => '', 'SECRET' => '', 'KEY' => '',
                             'LEVEL_MIN' => 'warning', 'CAT_DISKS' => 'no', 'CAT_ARRAY' => 'no', 'CAT_OTHER' => 'no'],
                            ['action' => 'save', 'CAT_DISKS' => 'yes']);
assert($out2['CAT_DISKS'] === 'yes');
assert($out2['CAT_ARRAY'] === 'no');   // still absent -> stays off
assert($out2['CAT_OTHER'] === 'no');   // still absent -> stays off

// --- C2: unchecking every category in one save must turn all three off ---
$out3 = flotilla_apply_save(base_cfg(), ['action' => 'save']);
assert($out3['CAT_DISKS'] === 'no' && $out3['CAT_ARRAY'] === 'no' && $out3['CAT_OTHER'] === 'no');

// --- I1: LEVEL_MIN whitelist ---
assert(flotilla_valid_level_min('normal') === true);
assert(flotilla_valid_level_min('warning') === true);
assert(flotilla_valid_level_min('alert') === true);
assert(flotilla_valid_level_min('DROP TABLE') === false);
assert(flotilla_valid_level_min('') === false);
assert(flotilla_valid_level_min('Warning') === false); // case-sensitive, exact whitelist

$outLevel = flotilla_apply_save(base_cfg(), ['action' => 'save', 'LEVEL_MIN' => 'bogus; rm -rf /']);
assert($outLevel['LEVEL_MIN'] === 'warning'); // garbage falls back to the safe (previous) value

$outLevelOk = flotilla_apply_save(base_cfg(), ['action' => 'save', 'LEVEL_MIN' => 'alert']);
assert($outLevelOk['LEVEL_MIN'] === 'alert');

// --- I1: RELAY strict URL validation ---
assert(flotilla_valid_relay('https://push.flotilla.livinmathew.com') === true);
assert(flotilla_valid_relay('http://127.0.0.1:18799') === true);
assert(flotilla_valid_relay('not a url') === false);
assert(flotilla_valid_relay('ftp://example.com') === false);           // scheme not http/https
assert(flotilla_valid_relay('javascript:alert(1)') === false);
assert(flotilla_valid_relay('http://example.com/`id`') === false);     // backtick
assert(flotilla_valid_relay('http://example.com/$(id)') === false);    // $
assert(flotilla_valid_relay("http://example.com/\\x") === false);      // backslash
assert(flotilla_valid_relay('http://example.com/"q') === false);       // quote
assert(flotilla_valid_relay("http://example.com/'q") === false);       // quote
assert(flotilla_valid_relay("http://example.com/\x00x") === false);    // NUL
assert(flotilla_valid_relay("http://example.com/\nx") === false);      // control char (newline)
assert(flotilla_valid_relay('http://example.com/has space') === false); // whitespace

// --- I1: a backtick-bearing RELAY must be rejected, not stored (no escape-growth possible) ---
$prev = base_cfg();
$attempt1 = flotilla_apply_save($prev, ['action' => 'save', 'RELAY' => 'http://evil.example/`touch /tmp/pwned`']);
assert($attempt1['RELAY'] === $prev['RELAY']); // rejected: previous value kept
// re-saving the same malicious payload again must not mutate anything further (no growth)
$attempt2 = flotilla_apply_save($attempt1, ['action' => 'save', 'RELAY' => 'http://evil.example/`touch /tmp/pwned`']);
assert($attempt2['RELAY'] === $prev['RELAY']);

// --- I1: a valid RELAY is accepted and replaces the previous value ---
$attemptOk = flotilla_apply_save($prev, ['action' => 'save', 'RELAY' => 'https://self-hosted.example/relay']);
assert($attemptOk['RELAY'] === 'https://self-hosted.example/relay');

// --- I1 (belt and braces): flotilla_cfg_escape strips NUL/control bytes defensively,
// so even if a NUL somehow reached it, sourcing the resulting file in bash still yields
// the intact PAIRING_ID on the following line (the concrete DoS the reviewer described:
// an unstripped NUL in RELAY breaking bash's parse of the WHOLE file, wiping PAIRING_ID).
$evilNul = "http://evil.example/x\x00PAIRING_ID=\"pwned\"\nRELAY=\"y";
$escaped = flotilla_cfg_escape($evilNul);
assert(strpos($escaped, "\x00") === false); // NUL stripped
assert(strpos($escaped, "\n") === false);   // still stripped, as before

$tmpCfg = sys_get_temp_dir() . '/flotilla_nul_defense_test_' . getmypid() . '.cfg';
file_put_contents($tmpCfg, 'RELAY="' . $escaped . "\"\nPAIRING_ID=\"11111111-1111-4111-8111-111111111111\"\n");
exec('bash -c ' . escapeshellarg('source ' . escapeshellarg($tmpCfg) . '; printf "%s" "$PAIRING_ID"'), $lines);
assert(($lines[0] ?? '') === '11111111-1111-4111-8111-111111111111');
@unlink($tmpCfg);

echo "save_validation ok\n";
