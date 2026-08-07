<?php
/*
 * I7 + I14, and a first smoke test for the settings page itself — nothing rendered
 * FlotillaAgent.page before, so a fatal there was only ever discoverable on a live box.
 *
 * I7: `explode(',', $_GET['err'])` guarded only by isset(). explode()'s second argument must be
 * a string; PHP 8 (which Unraid 7 ships) throws an uncaught TypeError, not a warning, when it
 * isn't — so /Settings/FlotillaAgent?err[]=x 500'd the settings page instead of rendering it.
 *
 * I14: an http:// relay pointed at a public host sends "Authorization: Bearer <S>" in the clear
 * on every heartbeat. The page must say so, and must NOT say so for the legitimate http:// cases
 * (loopback, LAN, .local) or the warning is noise.
 *
 * The page is rendered in a subprocess with its emhttp require rewritten to this repo's copy and
 * every overridable path pointed at a temp dir. A subprocess per render is required: the page
 * `require`s settings.php (not require_once), so two renders in one process would fatal on a
 * function redeclaration rather than on anything this test cares about.
 */

$tmp = sys_get_temp_dir() . '/flotilla_page_test_' . getmypid();
@mkdir($tmp, 0700, true);
$cfgPath = "$tmp/flotilla-agent.cfg";
putenv('FLOTILLA_CFG=' . $cfgPath);
putenv('FLOTILLA_VAR_INI=' . "$tmp/var.ini");
putenv('FLOTILLA_DYNAMIX_CFG=' . "$tmp/dynamix.cfg");
putenv('FLOTILLA_HEADERS=' . "$tmp/headers.txt");
putenv('FLOTILLA_CRON_FILE=' . "$tmp/flotilla.cron");
putenv('FLOTILLA_CRONTAB=' . "$tmp/crontab");
file_put_contents("$tmp/var.ini", "csrf_token=\"test-token-123\"\n");

$src = file_get_contents(__DIR__ . '/../plugin/src/FlotillaAgent.page');
$sep = strpos($src, "---\n");
assert($sep !== false, 'the .page file must have its Menu/Title/Icon header block');
$body = substr($src, $sep + 4);
$body = str_replace('/usr/local/emhttp/plugins/flotilla-agent/include/settings.php',
                    __DIR__ . '/../plugin/src/include/settings.php', $body);
// PHP CLI never populates $_GET, so the harness injects it.
$pagePhp = "$tmp/page.php";
file_put_contents($pagePhp, "<?php \$_GET = json_decode((string)getenv('FLOTILLA_TEST_GET'), true) ?: []; ?>" . $body);

function render(string $pagePhp, array $get): array {
  putenv('FLOTILLA_TEST_GET=' . json_encode($get));
  $out = []; $rc = 0;
  exec(escapeshellarg(PHP_BINARY) . ' ' . escapeshellarg($pagePhp) . ' 2>&1', $out, $rc);
  return [$rc, implode("\n", $out)];
}

function write_cfg(string $path, array $over = []): void {
  $cfg = ['RELAY' => 'https://flotilla-push.livinmathew.com', 'PAIRING_ID' => '', 'SECRET' => '',
          'KEY' => '', 'LEVEL_MIN' => 'warning', 'CAT_DISKS' => 'yes', 'CAT_ARRAY' => 'yes',
          'CAT_OTHER' => 'yes'];
  foreach ($over as $k => $v) $cfg[$k] = $v;
  $out = '';
  foreach ($cfg as $k => $v) $out .= $k . '="' . $v . '"' . "\n";
  file_put_contents($path, $out);
}

$paired = ['PAIRING_ID' => '11111111-1111-4111-8111-111111111111',
           'SECRET' => 'c2VjcmV0LXZhbHVlLWZvci10aGUtcmVuZGVyLXRlc3Rz',
           'KEY' => 'a2V5LXZhbHVlLWZvci10aGUtcmVuZGVyLXRlc3RzLW9r'];

// --- unpaired: renders the pair button, no QR ------------------------------------------------
write_cfg($cfgPath);
[$rc, $html] = render($pagePhp, []);
assert($rc === 0, "unpaired page must render: $html");
assert(strpos($html, 'value="pair"') !== false, 'unpaired page offers the pair action');
assert(strpos($html, 'test-token-123') !== false, 'the CSRF token is stamped into the form');
echo "page_render: unpaired page renders\n";

// --- paired: renders the QR and the manual code ----------------------------------------------
write_cfg($cfgPath, $paired);
[$rc, $html] = render($pagePhp, []);
assert($rc === 0, "paired page must render: $html");
assert(strpos($html, '<b>Paired.</b>') !== false);
// The pair URL appears twice: json_encode'd inside <script> for the QR, and htmlspecialchars'd
// (so `&` becomes `&amp;`) inside the manual-code textarea.
assert(substr_count($html, 'flotilla:\/\/pair?v=1&id=11111111-1111-4111-8111-111111111111') === 1);
assert(substr_count($html, 'flotilla://pair?v=1&amp;id=11111111-1111-4111-8111-111111111111') === 1);
echo "page_render: paired page renders the pairing QR/code\n";

// --- I7: an array $_GET['err'] must render, not fatal ----------------------------------------
[$rc, $html] = render($pagePhp, ['err' => ['x']]);
assert($rc === 0, "?err[]=x must not fatal the settings page, got exit $rc: $html");
assert(strpos($html, 'TypeError') === false, 'no TypeError may leak into the page');
assert(strpos($html, '<b>Paired.</b>') !== false, 'the page still renders normally');
echo "page_render: ?err[]=x renders instead of throwing a TypeError\n";

// ...and the ordinary string form still shows the error messages it is meant to.
[$rc, $html] = render($pagePhp, ['err' => 'relay,level']);
assert($rc === 0);
assert(strpos($html, 'Relay URL was invalid') !== false);
assert(strpos($html, 'Minimum importance value was invalid') !== false);
echo "page_render: ?err=relay,level still shows both messages\n";

// --- I14: the plaintext-relay warning ---------------------------------------------------------
$WARN = 'Not encrypted in transit';
write_cfg($cfgPath, $paired + ['RELAY' => 'http://relay.example.com']);
[$rc, $html] = render($pagePhp, []);
assert($rc === 0);
assert(strpos($html, $WARN) !== false, 'a public http:// relay must warn');
echo "page_render: a public http:// relay shows the plaintext warning\n";

foreach (['https://flotilla-push.livinmathew.com', 'http://192.168.0.42:8787', 'http://127.0.0.1:18799'] as $relay) {
  write_cfg($cfgPath, $paired + ['RELAY' => $relay]);
  [$rc, $html] = render($pagePhp, []);
  assert($rc === 0);
  assert(strpos($html, $WARN) === false, "must not warn for $relay");
}
echo "page_render: https and LAN relays show no warning\n";

array_map('unlink', glob("$tmp/*") ?: []);
@rmdir($tmp);
foreach (['FLOTILLA_CFG', 'FLOTILLA_VAR_INI', 'FLOTILLA_DYNAMIX_CFG', 'FLOTILLA_HEADERS',
          'FLOTILLA_CRON_FILE', 'FLOTILLA_CRONTAB', 'FLOTILLA_TEST_GET'] as $e) putenv($e);
echo "page_render ok\n";
