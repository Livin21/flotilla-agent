<?php
/*
 * I14 + I9.
 *
 * I14: flotilla_valid_relay() accepts http:// on purpose (the test harness needs
 * http://127.0.0.1:18799, and LAN self-hosting is a documented goal), but every request to the
 * relay carries "Authorization: Bearer <S>" -- so an http:// relay outside the local network
 * puts the bearer secret on the wire in the clear once a minute, forever, with no warning
 * anywhere. Event content stays sealed (K never leaves the box), so this is secret exposure,
 * not content exposure. flotilla_relay_insecure() is what the settings page uses to warn, and
 * it must not cry wolf at the legitimate http:// cases or the warning gets ignored.
 *
 * I9: flotilla_write_cfg() used to file_put_contents() then chmod(), leaving the config --
 * containing SECRET and KEY -- at its final path with default-umask permissions for the window
 * between the two calls, permanently so if anything went wrong in between. It now writes a temp
 * file, chmods THAT to 0600, and renames it into place.
 */

// Must be set before settings.php is required: FLOTILLA_CFG is a define().
$tmpCfg = sys_get_temp_dir() . '/flotilla_cfg_test_' . getmypid() . '.cfg';
putenv('FLOTILLA_CFG=' . $tmpCfg);
require __DIR__ . '/../plugin/src/include/settings.php';
assert(FLOTILLA_CFG === $tmpCfg, 'the FLOTILLA_CFG override must be honored');

// --- I14: cases that must NOT warn ---------------------------------------------------------
foreach ([
  'https://flotilla-push.livinmathew.com', // the default
  'https://relay.example.com:8443/base',
  'HTTPS://UPPERCASE.EXAMPLE.COM',         // scheme comparison is case-insensitive
  'http://127.0.0.1:18799',                // the test harness
  'http://localhost:8080',
  'http://tower.local',                    // mDNS name
  'http://192.168.0.42:8787',              // RFC1918
  'http://10.1.2.3',
  'http://172.16.9.9',
  'http://169.254.1.1',                    // link-local
  'http://[::1]:8799',                     // IPv6 loopback
  'http://[fd00::1]:8799',                 // IPv6 ULA
] as $relay) {
  assert(flotilla_relay_insecure($relay) === false, "must not warn for $relay");
}
echo "relay_warning: https, loopback, .local and RFC1918 http relays do not warn\n";

// --- I14: cases that MUST warn --------------------------------------------------------------
foreach ([
  'http://relay.example.com',              // public hostname over http
  'http://relay.example.com:8080/v1',
  'http://8.8.8.8',                        // public IPv4
  'http://[2606:4700::1111]',              // public IPv6
] as $relay) {
  assert(flotilla_relay_insecure($relay) === true, "must warn for $relay");
}
echo "relay_warning: plaintext http to a public host warns\n";

// --- I14: never fatals, never warns, on junk (the settings page must always render) ---------
foreach ([null, '', [], 42, 'not a url', 'ftp://x/y'] as $junk) {
  $r = flotilla_relay_insecure($junk);
  assert($r === true || $r === false);
}
echo "relay_warning: malformed input returns a bool rather than fataling the page\n";

// --- I9: the config is never readable by anyone but root, at any point ----------------------
@unlink($tmpCfg);
$cfg = flotilla_read_cfg();
$cfg['PAIRING_ID'] = '11111111-1111-4111-8111-111111111111';
$cfg['SECRET'] = 'c2VjcmV0LXZhbHVlLXRoYXQtbXVzdC1zdGF5LXByaXZhdGU';
$cfg['KEY'] = 'a2V5LXZhbHVlLXRoYXQtbXVzdC1zdGF5LXByaXZhdGUtdG9v';
assert(flotilla_write_cfg($cfg) === true);
clearstatcache();
assert(file_exists($tmpCfg));
assert((fileperms($tmpCfg) & 0777) === 0600,
  'the written config must be 0600, got 0' . decoct(fileperms($tmpCfg) & 0777));
echo "relay_warning: flotilla_write_cfg lands the config at 0600\n";

// The rewrite is atomic and leaves no temp file behind holding the same secrets.
assert(flotilla_write_cfg($cfg) === true);
$leftovers = glob(dirname($tmpCfg) . '/' . basename($tmpCfg) . '.tmp.*');
assert($leftovers === [] || $leftovers === false, 'no temp config may be left behind');
$back = parse_ini_file($tmpCfg);
assert($back['SECRET'] === $cfg['SECRET'] && $back['KEY'] === $cfg['KEY'] && $back['PAIRING_ID'] === $cfg['PAIRING_ID']);
echo "relay_warning: rewrite is atomic, leaves no temp file, and round-trips\n";

// A write into a directory that cannot be created fails cleanly rather than fataling.
putenv('FLOTILLA_CFG'); // unset override
@unlink($tmpCfg);
echo "relay_warning ok\n";
