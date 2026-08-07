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
 * every overridable path pointed at a temp dir.
 *
 * DOUBLE-RENDER: Unraid evaluates a .page's content more than once per request. When the page
 * used a bare `require` for settings.php, the second evaluation re-ran its function declarations
 * and PHP died with "Cannot redeclare function flotilla_b64url()" -- a COMPILE-time fatal, so
 * Unraid's evalContent.php try/catch never caught it, nothing reached console.error, and the
 * settings page rendered EMPTY below its title on every real install. An earlier version of this
 * file worked around that by rendering each case in its own subprocess and noted the hazard in
 * passing; that made every CLI check pass against a page that was broken in a browser. The
 * double-render case below is now asserted explicitly.
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
file_put_contents($pagePhp, "<?php \$_GET = json_decode((string)getenv('FLOTILLA_TEST_GET'), true) ?: []; \$_POST = json_decode((string)getenv('FLOTILLA_TEST_POST'), true) ?: []; ?>" . $body);

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

// --- double render in ONE process, the way Unraid actually evaluates a .page ------------------
// Regression guard for the "Cannot redeclare function" fatal that rendered the settings page
// blank on every real install. This must run in a single process: a subprocess per render is
// exactly what hid the bug. Failure mode is a fatal, so a non-zero exit or any "redeclare" text
// in the output fails the test.
write_cfg($cfgPath);
$twice = "$tmp/twice.php";
file_put_contents($twice,
  "<?php \$_GET = []; ob_start(); include " . var_export($pagePhp, true) . ";" .
  " include " . var_export($pagePhp, true) . "; \$o = ob_get_clean();" .
  " if (stripos(\$o, 'redeclare') !== false) { fwrite(STDERR, \$o); exit(1); }" .
  " echo 'DOUBLE-RENDER-OK';");
$out = []; $rc = 0;
exec(escapeshellarg(PHP_BINARY) . ' ' . escapeshellarg($twice) . ' 2>&1', $out, $rc);
$html = implode("\n", $out);
assert($rc === 0, "the page must survive being evaluated twice in one process (Unraid does this), got exit $rc: $html");
assert(strpos($html, 'DOUBLE-RENDER-OK') !== false, "second evaluation of the page died: $html");
assert(stripos($html, 'redeclare') === false, "function redeclaration on second render: $html");

// And the mechanism itself: a bare `require` of settings.php reintroduces the fatal.
$pageSrc = file_get_contents(__DIR__ . '/../plugin/src/FlotillaAgent.page');
assert(preg_match('/^\s*require\s+[\'"][^\'"]*settings\.php/m', $pageSrc) !== 1,
       'FlotillaAgent.page must use require_once for settings.php, never a bare require');
echo "page_render: the page survives Unraid's double evaluation\n";


// --- a POST that is not one of ours must still RENDER, not exit mid-page --------------------
// Unraid renders this page for POST requests too (a browser reload after any POST re-submits
// it). The handler used to engage on ANY POST, fail the CSRF check, and exit() during the
// render -- producing a blank settings page with no error in any log and nothing in the browser
// console. Foreign POSTs must fall through to a normal render.
write_cfg($cfgPath);
function render_post(string $pagePhp, array $post): array {
  putenv('FLOTILLA_TEST_GET=' . json_encode([]));
  putenv('FLOTILLA_TEST_POST=' . json_encode($post));
  putenv('FLOTILLA_FORCE_WEB=1');
  $out = []; $rc = 0;
  exec('REQUEST_METHOD=POST ' . escapeshellarg(PHP_BINARY) . ' ' . escapeshellarg($pagePhp) . ' 2>&1', $out, $rc);
  putenv('FLOTILLA_FORCE_WEB'); putenv('FLOTILLA_TEST_POST');
  return [$rc, implode("\n", $out)];
}
// The killer case from the field: a browser re-submitting a STALE pair POST (no csrf_token,
// from the pre-CSRF 1.0 form) on every reload. `pair` IS one of our actions, so an
// action-allowlist guard does not save the render -- only direct-endpoint dispatch does.
// Rendering must survive every POST shape AND must never execute the action (cfg unchanged).
foreach ([[], ['somethingelse' => '1'], ['action' => 'not-ours'],
          ['action' => 'pair'],                                   // stale re-POST, no token
          ['action' => 'pair', 'csrf_token' => 'wrong-token'],    // stale re-POST, bad token
          ['action' => 'pair', 'csrf_token' => 'test-token-123'], // even a VALID token: render only
          ['action' => 'reset', 'csrf_token' => 'test-token-123']] as $post) {
  write_cfg($cfgPath);   // fresh unpaired cfg before each shape
  [$rc, $html] = render_post($pagePhp, $post);
  $d = json_encode($post);
  assert($rc === 0, "a POST must never kill the page render ($d), got exit $rc: $html");
  assert(strpos($html, 'Flotilla Push') !== false, "the page must still render for a POST ($d): $html");
  assert(strpos($html, 'value="pair"') !== false, "the pair form must still render for a POST ($d)");
  $after = file_get_contents($cfgPath);
  assert(strpos($after, 'PAIRING_ID=""') !== false, "rendering must NEVER execute the action ($d): $after");
}
echo "page_render: every POST shape renders the page and executes nothing\n";

// --- the direct endpoint: where actions actually execute -------------------------------------
// Forms post to /plugins/flotilla-agent/include/settings.php; simulated via FLOTILLA_FORCE_DIRECT.
$directPhp = "$tmp/direct.php";
file_put_contents($directPhp,
  "<?php \$_GET = []; \$_POST = json_decode((string)getenv('FLOTILLA_TEST_POST'), true) ?: [];" .
  " require " . var_export(__DIR__ . '/../plugin/src/include/settings.php', true) . ";");
function run_direct(array $post): array {
  putenv('FLOTILLA_TEST_POST=' . json_encode($post));
  putenv('FLOTILLA_FORCE_DIRECT=1');
  global $directPhp;
  $out = []; $rc = 0;
  exec('REQUEST_METHOD=POST ' . escapeshellarg(PHP_BINARY) . ' ' . escapeshellarg($directPhp) . ' 2>&1', $out, $rc);
  putenv('FLOTILLA_FORCE_DIRECT'); putenv('FLOTILLA_TEST_POST');
  return [$rc, implode("\n", $out)];
}
// valid CSRF + pair -> the action executes (cfg gains a pairing) and nothing is rendered
write_cfg($cfgPath);
[$rc, $out] = run_direct(['action' => 'pair', 'csrf_token' => 'test-token-123']);
assert($rc === 0, "direct pair must exit cleanly: $out");
$after = file_get_contents($cfgPath);
assert(strpos($after, 'PAIRING_ID=""') === false, "direct pair with a valid token must write a pairing: $after");
assert(strpos($out, 'Flotilla Push') === false, 'the direct endpoint must not render the page');
// bad CSRF -> no state change
write_cfg($cfgPath);
[$rc, $out] = run_direct(['action' => 'pair', 'csrf_token' => 'nope']);
assert($rc === 0, "direct pair with a bad token must exit cleanly: $out");
assert(strpos(file_get_contents($cfgPath), 'PAIRING_ID=""') !== false, 'a bad token must change nothing');
echo "page_render: the direct endpoint executes actions, CSRF still enforced\n";

array_map('unlink', glob("$tmp/*") ?: []);
@rmdir($tmp);
foreach (['FLOTILLA_CFG', 'FLOTILLA_VAR_INI', 'FLOTILLA_DYNAMIX_CFG', 'FLOTILLA_HEADERS',
          'FLOTILLA_CRON_FILE', 'FLOTILLA_CRONTAB', 'FLOTILLA_TEST_GET'] as $e) putenv($e);
echo "page_render ok\n";
