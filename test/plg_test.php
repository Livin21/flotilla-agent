<?php
/*
 * C1: the .plg must be able to install itself.
 *
 * The shipped .plg used to extract a package it never downloaded -- there was no
 * <FILE Name="..."><URL>...</URL></FILE> element at all, and /plugin/*.txz is .gitignore'd, so
 * the package was unreachable from anywhere. Because the INLINE block has no `set -e`, a fresh
 * install failed at `tar` and then kept going: it still wrote a notify shim into
 * /boot/config/plugins/dynamix/notifications/agents/FlotillaPush.sh pointing at an agent.sh
 * that did not exist, and still echoed "installed", so the plugin manager reported success
 * while every subsequent Unraid notification spawned a shim that exited 127. Worse than
 * installing nothing, and nothing in the repo could catch it.
 *
 * This test is that missing guard. It parses the .plg exactly the way Unraid's plugin manager
 * does (libxml, entities resolved) and asserts the structural invariants that make the install
 * both possible and fail-safe. It cannot prove the release asset actually exists on GitHub --
 * only a real install can -- but it does prove the .plg asks for one, at the exact name
 * plugin/build.sh produces, with an MD5 the plugin manager can check.
 */

$plgPath = __DIR__ . '/../plugin/flotilla-agent.plg';
$xml = simplexml_load_file($plgPath);
assert($xml !== false, 'the .plg must parse as XML');
echo "plg: parses\n";

// --- version consistency across the three places that carry it -----------------------------
// &version; drives the download URL, the on-flash package name and the plugin manager's
// update check; FLOTILLA_AGENT_VERSION is the "installed" side of the relay's X-Min-Agent
// comparison. If they drift, the agent nags (or fails to nag) against the wrong number.
$raw = file_get_contents($plgPath);
assert(preg_match('/<!ENTITY\s+version\s+"([^"]+)"/', $raw, $m) === 1);
$version = $m[1];
require_once __DIR__ . '/../plugin/src/include/settings.php';
assert(FLOTILLA_AGENT_VERSION === $version,
  'FLOTILLA_AGENT_VERSION (' . FLOTILLA_AGENT_VERSION . ') must match the .plg version (' . $version . ')');
echo "plg: version $version matches settings.php\n";

// --- the download element must exist, and point at the asset build.sh produces -------------
$expectedPkg = '/boot/config/plugins/flotilla-agent/flotilla-agent-' . $version . '.txz';
$expectedURL = 'https://github.com/Livin21/flotilla-agent/releases/download/' . $version
             . '/flotilla-agent-' . $version . '.txz';
$download = null;
$install  = null;
$remove   = null;
foreach ($xml->FILE as $f) {
  $name   = (string)($f['Name'] ?? '');
  $method = (string)($f['Method'] ?? '');
  if ($name !== '' && isset($f->URL)) $download = $f;
  if ($method === 'install') $install = trim((string)$f->INLINE);
  if ($method === 'remove')  $remove  = trim((string)$f->INLINE);
}
assert($download !== null, 'the .plg must declare a <FILE Name="..."><URL>...</URL></FILE> download element');
assert((string)$download['Name'] === $expectedPkg, 'download lands at ' . $expectedPkg);
assert(trim((string)$download->URL) === $expectedURL, 'download URL is the release asset: ' . $expectedURL);
$md5 = trim((string)$download->MD5);
assert(preg_match('/^[0-9a-f]{32}$/i', $md5) === 1, '<MD5> must be 32 hex digits (plugin/build.sh writes it)');
echo "plg: declares its package download ($expectedURL) with an MD5\n";

// --- the install block must extract exactly the file that was downloaded -------------------
assert(is_string($install) && $install !== '', 'install INLINE block must exist');
assert(strpos($install, 'tar -xJf ' . $expectedPkg) !== false,
  'install must extract the same path the download element writes');
echo "plg: install extracts the downloaded package\n";

// --- fail-safe ordering: a failed extraction must abort BEFORE Unraid's own state is touched
// This is the actual regression guard. Every write into a path Unraid itself reads --
// the notify agent shim, the heartbeat .cron file, the array event hooks -- must come after
// the `tar` guard and its `exit`.
$tarPos = strpos($install, 'tar -xJf');
assert($tarPos !== false);
$guard = substr($install, $tarPos);
assert(preg_match('/^if\s*!\s*tar -xJf/m', $install) === 1,
  'the tar must be guarded (a bare `tar` line cannot abort the install -- there is no set -e)');
$exitPos = strpos($install, 'exit 1');
assert($exitPos !== false && $exitPos > $tarPos, 'the tar guard must exit non-zero on failure');
foreach ([
  '/boot/config/plugins/dynamix/notifications/agents' => 'the notify agent shim',
  'flotilla-agent.cron'                               => 'the heartbeat cron file',
  '/usr/local/emhttp/webGui/event/'                   => 'the array event hooks',
] as $needle => $what) {
  $pos = strpos($install, $needle);
  assert($pos !== false, "install still writes $what");
  assert($pos > $exitPos, "$what must only be written AFTER the tar guard can abort");
}
echo "plg: a failed extraction aborts before anything is written to Unraid's own paths\n";

// The extraction guard alone can't catch a well-formed archive missing the files the rest of
// the block depends on, so the install also asserts they landed.
assert(strpos($install, '/scripts/agent.sh') !== false && strpos($install, 'flotilla-seal') !== false,
  'install must verify agent.sh and flotilla-seal actually extracted');
echo "plg: install verifies the extracted payload before wiring anything up\n";

// --- packages must not accumulate on the flash ---------------------------------------------
assert(preg_match('#for f in /boot/config/plugins/flotilla-agent/flotilla-agent-\*\.txz#', $install) === 1,
  'install must sweep stale .txz packages off the flash');
assert(strpos($install, 'mkdir -p /boot/config/plugins/dynamix/notifications/agents') !== false,
  'install must mkdir -p the notifications agents dir before writing the shim into it');
echo "plg: stale packages are swept and the agents dir is created before use\n";

// --- and now actually RUN the install block, both ways ------------------------------------
// The ordering assertions above are static; this executes the real INLINE with every absolute
// path redirected into a sandbox, so the fail-safe property is proven rather than inferred.
// update_cron and the php reassert don't exist in the sandbox -- that's deliberate and matches
// the block's own design (both are best-effort and must never abort a working install).
function flotilla_run_install(string $install, string $sandbox, bool $withPackage): array {
  $version = FLOTILLA_AGENT_VERSION;
  foreach (["$sandbox/boot/config/plugins/flotilla-agent",
            "$sandbox/boot/config/plugins/dynamix/notifications/agents",
            "$sandbox/usr/local/emhttp/plugins"] as $d) mkdir($d, 0755, true);

  if ($withPackage) {
    // A minimal but structurally valid package: the two paths the install block verifies.
    $stage = "$sandbox/stage/flotilla-agent";
    mkdir("$stage/scripts", 0755, true);
    file_put_contents("$stage/scripts/agent.sh", "#!/bin/bash\n");
    file_put_contents("$stage/flotilla-seal", "#!/bin/bash\n");
    file_put_contents("$stage/scripts/event-array-started.sh", "#!/bin/bash\n");
    file_put_contents("$stage/scripts/event-stopping-array.sh", "#!/bin/bash\n");
    chmod("$stage/flotilla-seal", 0755);
    shell_exec('cd ' . escapeshellarg("$sandbox/stage") . ' && tar -cJf '
      . escapeshellarg("$sandbox/boot/config/plugins/flotilla-agent/flotilla-agent-$version.txz")
      . ' flotilla-agent 2>/dev/null');
  }
  // A package left over from an older version, to prove the sweep runs.
  file_put_contents("$sandbox/boot/config/plugins/flotilla-agent/flotilla-agent-1999.01.01.txz", 'stale');

  $script = str_replace(['/boot/', '/usr/local/emhttp'], [$sandbox . '/boot/', $sandbox . '/usr/local/emhttp'], $install);
  $path = "$sandbox/install.sh";
  file_put_contents($path, $script);
  $out = []; $rc = 0;
  exec('/bin/bash ' . escapeshellarg($path) . ' 2>&1', $out, $rc);
  return [$rc, implode("\n", $out)];
}

$sandbox = sys_get_temp_dir() . '/flotilla_plg_install_' . getmypid();
$shim    = "$sandbox/boot/config/plugins/dynamix/notifications/agents/FlotillaPush.sh";

// (a) No package on the flash -- e.g. the download element is missing/renamed, or the asset
// 404s. The install MUST fail loudly and MUST NOT leave a shim behind in Unraid's notification
// path pointing at an agent.sh that was never extracted. This is the exact Critical.
shell_exec('rm -rf ' . escapeshellarg($sandbox));
[$rc, $out] = flotilla_run_install($install, $sandbox, false);
assert($rc !== 0, 'a missing package must fail the install (got exit 0)');
assert(!file_exists($shim), 'a failed install must NOT write a notify shim: ' . $out);
assert(!file_exists("$sandbox/boot/config/plugins/flotilla-agent/flotilla-agent.cron"),
  'a failed install must NOT write a heartbeat cron entry');
assert(strpos($out, 'installed') === false, 'a failed install must NOT report success: ' . $out);
shell_exec('rm -rf ' . escapeshellarg($sandbox));
echo "plg: install with no package -> non-zero exit, no shim, no cron, no false success\n";

// (b) Package present: the whole block runs to completion and wires everything up.
[$rc, $out] = flotilla_run_install($install, $sandbox, true);
assert($rc === 0, "install with a valid package must succeed: $out");
assert(file_exists($shim), 'install must write the notify shim');
assert(is_executable($shim), 'the notify shim must be executable');
assert(strpos(file_get_contents($shim), 'scripts/agent.sh') !== false, 'the shim must exec agent.sh');
assert(file_exists("$sandbox/boot/config/plugins/flotilla-agent/flotilla-agent.cron"),
  'install must write the heartbeat cron file');
assert(file_exists("$sandbox/usr/local/emhttp/webGui/event/array_started/flotilla-agent")
    && file_exists("$sandbox/usr/local/emhttp/webGui/event/stopping_array/flotilla-agent"),
  'install must install both array event hooks');
assert(!file_exists("$sandbox/boot/config/plugins/flotilla-agent/flotilla-agent-1999.01.01.txz"),
  'install must sweep packages from older versions off the flash');
assert(file_exists("$sandbox/boot/config/plugins/flotilla-agent/flotilla-agent-" . FLOTILLA_AGENT_VERSION . '.txz'),
  'install must KEEP the current package (the plugin manager reuses it, MD5-checked)');
assert(strpos($out, 'installed') !== false, 'a successful install reports success');
shell_exec('rm -rf ' . escapeshellarg($sandbox));
echo "plg: install with a valid package -> shim, cron, hooks, stale packages swept\n";

// --- remove block ---------------------------------------------------------------------------
assert(is_string($remove) && $remove !== '', 'remove INLINE block must exist');
assert(strpos($remove, 'revoke.sh') !== false, 'remove must revoke the pairing at the relay');
// I5: revoking server-side while leaving PAIRING_ID/SECRET/KEY on the flash meant a
// remove-then-reinstall showed "Paired." and a green "Heartbeat scheduled: yes" while every
// push 401'd -- and 4xx is deliberately never queued, so notifications were silently dropped
// forever with nothing prompting a re-scan. The revoke and the local clear must go together.
assert(strpos($remove, 'sed -i') !== false, 'remove must rewrite the flash config with sed');
assert(preg_match_all("/-e '([^']*)'/", $remove, $sm) >= 1, "remove's sed must use -e 'expr' form");
$sedArgs = '';
foreach ($sm[1] as $expr) $sedArgs .= ' -e ' . escapeshellarg($expr);
$revokePos = strpos($remove, 'revoke.sh');
$sedPos    = strpos($remove, 'sed -i');
assert($sedPos > $revokePos, 'the pairing must be revoked BEFORE its secret is cleared locally');

// Run that exact sed expression against a realistic cfg and check the result, rather than
// pattern-matching the source: what matters is that the three pairing fields really do come
// back empty and that RELAY / the filter preferences really do survive.
$tmpCfg = sys_get_temp_dir() . '/flotilla_plg_remove_test_' . getmypid() . '.cfg';
file_put_contents($tmpCfg, implode("\n", [
  'RELAY="https://relay.example.invalid"',
  'PAIRING_ID="11111111-1111-4111-8111-111111111111"',
  'SECRET="c2VjcmV0LXZhbHVlLXRoYXQtbXVzdC1nby1hd2F5"',
  'KEY="a2V5LXZhbHVlLXRoYXQtbXVzdC1nby1hd2F5LXRvbw"',
  'LEVEL_MIN="alert"',
  'CAT_DISKS="no"',
]) . "\n");
// GNU sed (Unraid) takes -i with no argument; BSD sed (this dev Mac) requires a backup suffix.
$sedBin = trim((string)shell_exec('command -v gsed 2>/dev/null'));
$inPlace = $sedBin !== '' ? '-i' : '-i.bak';
if ($sedBin === '') $sedBin = 'sed';
shell_exec($sedBin . ' ' . $inPlace . ' ' . $sedArgs . ' ' . escapeshellarg($tmpCfg) . ' 2>/dev/null');
$after = parse_ini_file($tmpCfg);
@unlink($tmpCfg); @unlink($tmpCfg . '.bak');
assert(is_array($after), 'the rewritten cfg must still parse');
foreach (['PAIRING_ID', 'SECRET', 'KEY'] as $k) {
  assert(($after[$k] ?? null) === '', "remove must clear $k from the flash config");
}
assert(($after['RELAY'] ?? null) === 'https://relay.example.invalid', 'remove must keep RELAY');
assert(($after['LEVEL_MIN'] ?? null) === 'alert', 'remove must keep the filter preferences');
assert(($after['CAT_DISKS'] ?? null) === 'no', 'remove must keep the filter preferences');
assert(strpos($remove, 'flotilla-agent-*.txz') !== false, 'remove must delete packages from the flash');
assert(strpos($remove, '/var/local/flotilla-agent.queue') !== false,
  'remove must delete the retry queue (a reinstall before reboot would otherwise drain events '
  . 'sealed under the revoked pairing)');
echo "plg: remove revokes, then clears the dead pairing, and leaves nothing behind\n";

echo "plg ok\n";
