<?php
/* Flotilla Agent settings backend. Pure functions + a tiny POST handler used by FlotillaAgent.page. */
define('FLOTILLA_CFG', '/boot/config/plugins/flotilla-agent/flotilla-agent.cfg');
define('DYNAMIX_CFG', '/boot/config/plugins/dynamix/dynamix.cfg');

function flotilla_b64url($bytes) { return rtrim(strtr(base64_encode($bytes), '+/', '-_'), '='); }

function flotilla_read_cfg() {
  $cfg = ['RELAY' => 'https://push.flotilla.livinmathew.com', 'PAIRING_ID' => '', 'SECRET' => '', 'KEY' => '',
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
 * inject arbitrary shell commands that execute the next time the cfg is sourced. Newlines
 * are stripped outright since a raw newline starts a new, attacker-controlled statement
 * rather than merely breaking out of the quoted string. Ordinary values (URLs, uuids,
 * base64url secrets, "yes"/"no", "normal"/"warning"/"alert") never contain these
 * characters, so this is a no-op for every legitimate value Task 6's config contract uses.
 */
function flotilla_cfg_escape($v) {
  $v = str_replace(["\r", "\n"], '', (string)$v);
  return str_replace(['\\', '"', '$', '`'], ['\\\\', '\\"', '\\$', '\\`'], $v);
}

function flotilla_write_cfg($cfg) {
  $dir = dirname(FLOTILLA_CFG);
  if (!is_dir($dir)) mkdir($dir, 0700, true);
  $out = '';
  foreach ($cfg as $k => $v) $out .= $k . '="' . flotilla_cfg_escape($v) . '"' . "\n";
  file_put_contents(FLOTILLA_CFG, $out);
  chmod(FLOTILLA_CFG, 0600);
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

function flotilla_pair($cfg) {
  $cfg['PAIRING_ID'] = strtolower(trim((string)shell_exec('uuidgen')));
  $cfg['SECRET'] = flotilla_b64url(random_bytes(32));
  $cfg['KEY'] = flotilla_b64url(random_bytes(32));
  flotilla_write_cfg($cfg);
  if (is_readable(DYNAMIX_CFG) && is_writable(DYNAMIX_CFG)) {
    $dtext = file_get_contents(DYNAMIX_CFG);
    if ($dtext !== false) file_put_contents(DYNAMIX_CFG, flotilla_fix_entities($dtext));
  }
  // ensure the notify shim exists (also done by .plg install)
  $shim = '/boot/config/plugins/dynamix/notifications/agents/FlotillaPush.sh';
  if (!file_exists($shim))
    file_put_contents($shim, "#!/bin/bash\nexec bash /usr/local/emhttp/plugins/flotilla-agent/scripts/agent.sh\n");
  return $cfg;
}

function flotilla_pair_url($cfg) {
  $host = trim((string)shell_exec('hostname'));
  return 'flotilla://pair?v=1&id=' . $cfg['PAIRING_ID'] . '&k=' . $cfg['KEY'] . '&s=' . $cfg['SECRET']
       . '&n=' . rawurlencode($host !== '' ? $host : 'Unraid');
}

if (php_sapi_name() !== 'cli' && ($_SERVER['REQUEST_METHOD'] ?? '') === 'POST') {
  $cfg = flotilla_read_cfg();
  switch ($_POST['action'] ?? '') {
    case 'pair': case 'reset': $cfg = flotilla_pair($cfg); break;
    case 'save':
      foreach (['LEVEL_MIN', 'CAT_DISKS', 'CAT_ARRAY', 'CAT_OTHER', 'RELAY'] as $k)
        if (isset($_POST[$k])) $cfg[$k] = $_POST[$k];
      foreach (['CAT_DISKS', 'CAT_ARRAY', 'CAT_OTHER'] as $k) $cfg[$k] = ($cfg[$k] === 'yes') ? 'yes' : 'no';
      flotilla_write_cfg($cfg); break;
    case 'test':
      exec('/usr/local/emhttp/webGui/scripts/notify -e "Flotilla Agent" -s "Test notification" '
         . '-d "If this reached your phone, Flotilla Push works." -i "warning" 2>/dev/null');
      break;
  }
  header('Location: /Settings/FlotillaAgent'); exit;
}
