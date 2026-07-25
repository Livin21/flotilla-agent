<?php
/*
 * I6: flotilla_fix_entities() only ever ran once, from flotilla_pair() -- invisible and never
 * re-asserted, so Unraid's own Settings → Notifications page silently killing push (it
 * rewrites dynamix.cfg and clears bit 4) had no indication and no repair path short of
 * re-pairing. flotilla_entities_ok() is the read-only check the settings page shows;
 * flotilla_reassert_entities() is the idempotent repair now called from flotilla_pair(), the
 * 'save' action, the new 'repair_entities' action, and the plugin's install hook.
 *
 * flotilla_dynamix_cfg_path() honors a FLOTILLA_DYNAMIX_CFG env override purely for
 * testability (mirrors flotilla_var_ini_path()/flotilla_headers_path()'s pattern) -- this test
 * never touches the real, root-only /boot path.
 */
require __DIR__ . '/../plugin/src/include/settings.php';

$tmpDynamix = sys_get_temp_dir() . '/flotilla_dynamix_test_' . getmypid() . '.cfg';
putenv('FLOTILLA_DYNAMIX_CFG=' . $tmpDynamix);
assert(flotilla_dynamix_cfg_path() === $tmpDynamix);

// --- missing dynamix.cfg entirely: unknown, not a false "no" ---
@unlink($tmpDynamix);
assert(flotilla_entities_ok() === null);
flotilla_reassert_entities(); // must no-op silently, never fatal, never create the file
assert(!file_exists($tmpDynamix));

// --- present but no [notify] section: unknown ---
file_put_contents($tmpDynamix, "[display]\nunit=\"C\"\n");
assert(flotilla_entities_ok() === null);

// --- [notify] present, bit 4 NOT set on any of the three: "no" ---
file_put_contents($tmpDynamix, "[notify]\nnormal=\"1\"\nwarning=\"1\"\nalert=\"1\"\nposition=\"top-right\"\n");
assert(flotilla_entities_ok() === false);

// --- repair turns it "yes", is idempotent, and leaves neighboring keys/sections untouched ---
flotilla_reassert_entities();
assert(flotilla_entities_ok() === true);
$fixedOnce = file_get_contents($tmpDynamix);
flotilla_reassert_entities();
assert(file_get_contents($tmpDynamix) === $fixedOnce); // idempotent
assert(strpos($fixedOnce, "position=\"top-right\"") !== false);

// --- partially cleared (Unraid's own settings page rewrote just warning/alert back to
// unflagged, e.g. a real-world partial edit) still reads as "no" until repaired ---
file_put_contents($tmpDynamix, "[notify]\nnormal=\"5\"\nwarning=\"1\"\nalert=\"1\"\n");
assert(flotilla_entities_ok() === false);
flotilla_reassert_entities();
assert(flotilla_entities_ok() === true);

// --- unwritable dynamix.cfg: reassert must not fatal, and ok-check still reflects reality ---
file_put_contents($tmpDynamix, "[notify]\nnormal=\"1\"\nwarning=\"1\"\nalert=\"1\"\n");
chmod($tmpDynamix, 0400);
flotilla_reassert_entities(); // best-effort: silently does nothing when not writable
assert(flotilla_entities_ok() === false);
chmod($tmpDynamix, 0600);

@unlink($tmpDynamix);
putenv('FLOTILLA_DYNAMIX_CFG'); // unset override
echo "entities_state ok\n";
