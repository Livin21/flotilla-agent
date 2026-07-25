<?php
require __DIR__ . '/../plugin/src/include/settings.php';
$in = "[notify]\nentity=\"1\"\nnormal=\"1\"\nwarning=\"1\"\nalert=\"5\"\nposition=\"top-right\"\n[display]\ndate=\"%c\"\n";
$out = flotilla_fix_entities($in);
assert(strpos($out, "normal=\"5\"") !== false);
assert(strpos($out, "warning=\"5\"") !== false);
assert(strpos($out, "alert=\"5\"") !== false);          // unchanged (already has bit 4)
assert(strpos($out, "position=\"top-right\"") !== false); // untouched neighbors
assert(strpos($out, "[display]") !== false);
$out2 = flotilla_fix_entities($out);
assert($out === $out2);                                   // idempotent
echo "entity_fixup ok\n";

// Section-aware check: a later section reusing the same key names (normal/warning/alert)
// must NOT be touched -- only the [notify] section's own keys are in scope. This guards
// against a naive whole-file regex silently corrupting an unrelated section that happens
// to share a key name with [notify].
$in2 = "[display]\nunit=\"C\"\n[notify]\nnormal=\"1\"\nwarning=\"1\"\nalert=\"1\"\nposition=\"top-right\"\n"
     . "[PTP]\nnormal=\"0\"\nwarning=\"0\"\n[NTP]\nalert=\"0\"\n";
$out3 = flotilla_fix_entities($in2);
assert(strpos($out3, "[notify]\nnormal=\"5\"\nwarning=\"5\"\nalert=\"5\"\nposition=\"top-right\"\n") !== false);
assert(strpos($out3, "[PTP]\nnormal=\"0\"\nwarning=\"0\"\n") !== false);   // untouched: different section
assert(strpos($out3, "[NTP]\nalert=\"0\"\n") !== false);                  // untouched: different section
$out4 = flotilla_fix_entities($out3);
assert($out3 === $out4);                                                   // idempotent, section-scoped
echo "entity_fixup section-aware ok\n";
