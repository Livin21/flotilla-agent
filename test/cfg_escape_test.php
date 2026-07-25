<?php
/*
 * Task 6's send-event.sh / heartbeat.sh both `source "$CFG"` as root. settings.php's 'save'
 * POST handler writes $_POST['RELAY'] and $_POST['LEVEL_MIN'] straight into that file via
 * flotilla_write_cfg(), so every value written there must be inert as bash text -- this test
 * proves flotilla_cfg_escape() achieves that without altering any legitimate value.
 */
require __DIR__ . '/../plugin/src/include/settings.php';

// Ordinary values must round-trip byte-for-byte (Task 6's config contract depends on this).
assert(flotilla_cfg_escape('https://push.flotilla.livinmathew.com') === 'https://push.flotilla.livinmathew.com');
assert(flotilla_cfg_escape('warning') === 'warning');
assert(flotilla_cfg_escape('yes') === 'yes');
assert(flotilla_cfg_escape('11111111-1111-4111-8111-111111111111') === '11111111-1111-4111-8111-111111111111');

// A value containing bash metacharacters must not let a real `source` of the resulting
// file execute anything, and must survive the round trip as inert literal text.
$marker = sys_get_temp_dir() . '/flotilla_cfg_escape_pwn_' . getmypid();
@unlink($marker);
$evil = 'http://x$(touch ' . $marker . ')`touch ' . $marker . '`"; touch ' . $marker . '; RELAY="y';
$escaped = flotilla_cfg_escape($evil);
$tmpCfg = sys_get_temp_dir() . '/flotilla_cfg_escape_test_' . getmypid() . '.cfg';
file_put_contents($tmpCfg, 'RELAY="' . $escaped . "\"\nOTHER=\"1\"\n");

exec('bash -c ' . escapeshellarg('source ' . escapeshellarg($tmpCfg) . '; printf "%s\n%s" "$RELAY" "$OTHER"'), $lines);

assert(!file_exists($marker));        // no command substitution / injected command ran
assert(($lines[0] ?? '') === $evil);  // value survives the round trip, inert
assert(($lines[1] ?? '') === '1');    // the following key (OTHER) wasn't hijacked either

@unlink($tmpCfg);
@unlink($marker);
echo "cfg_escape ok\n";
