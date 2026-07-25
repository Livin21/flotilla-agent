<?php
/*
 * Task 13 §8: flotilla_min_agent_notice() reads heartbeat.sh's captured X-Min-Agent
 * response header (see plugin/src/scripts/heartbeat.sh's -D flag) and decides whether
 * FlotillaAgent.page should show an "update needed" notice. This must fail closed (null,
 * i.e. no notice) on every kind of bad input, and must compare versions numerically, not
 * lexicographically -- a naive string compare gets "9" vs "10" backwards.
 *
 * flotilla_headers_path() honors a FLOTILLA_HEADERS env override (mirrors the
 * FLOTILLA_VAR_INI / FLOTILLA_CFG override pattern already used elsewhere in this repo)
 * so this test never touches the real, root-only /var/local path.
 */
require __DIR__ . '/../plugin/src/include/settings.php';

$tmpHdr = sys_get_temp_dir() . '/flotilla_min_agent_test_' . getmypid() . '.headers';
putenv('FLOTILLA_HEADERS=' . $tmpHdr);

// --- path override actually takes effect ---
assert(flotilla_headers_path() === $tmpHdr);

// --- missing header file entirely (fresh install / heartbeat never ran): fail closed ---
@unlink($tmpHdr);
assert(flotilla_min_agent_notice('2026.07.26') === null);

// --- empty header file: fail closed ---
file_put_contents($tmpHdr, '');
assert(flotilla_min_agent_notice('2026.07.26') === null);

// --- header file present but no X-Min-Agent line at all: fail closed ---
file_put_contents($tmpHdr, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n");
assert(flotilla_min_agent_notice('2026.07.26') === null);

// --- malformed X-Min-Agent value (non-numeric): fail closed, never fatals ---
file_put_contents($tmpHdr, "HTTP/1.1 200 OK\r\nX-Min-Agent: not-a-version\r\n\r\n");
assert(flotilla_min_agent_notice('2026.07.26') === null);

// --- realistic captured headers (CRLF line endings, case-insensitive header name),
// installed version already satisfies the minimum: no notice ---
file_put_contents($tmpHdr, "HTTP/1.1 200 OK\r\nx-min-agent: 1.0.0\r\ncontent-type: application/json\r\n\r\n");
assert(flotilla_min_agent_notice('2026.07.26') === null);

// --- installed version is behind: notice fires with the required version ---
file_put_contents($tmpHdr, "HTTP/1.1 200 OK\r\nX-Min-Agent: 2026.08.01\r\n\r\n");
assert(flotilla_min_agent_notice('2026.07.26') === '2026.08.01');

// --- exact match: "≥" means equal is fine, no notice ---
file_put_contents($tmpHdr, "HTTP/1.1 200 OK\r\nX-Min-Agent: 2026.07.26\r\n\r\n");
assert(flotilla_min_agent_notice('2026.07.26') === null);

// --- the actual bug this replaces: a lexicographic/string compare gets month/day
// rollovers backwards ("9" > "10" as strings). version_compare must get this right. ---
file_put_contents($tmpHdr, "HTTP/1.1 200 OK\r\nX-Min-Agent: 2026.10.1\r\n\r\n");
assert(flotilla_min_agent_notice('2026.9.1') === '2026.10.1'); // installed is actually older
file_put_contents($tmpHdr, "HTTP/1.1 200 OK\r\nX-Min-Agent: 2026.9.1\r\n\r\n");
assert(flotilla_min_agent_notice('2026.10.1') === null); // installed is actually newer

// --- installed version itself missing/malformed: fail closed rather than warn ---
file_put_contents($tmpHdr, "HTTP/1.1 200 OK\r\nX-Min-Agent: 2026.08.01\r\n\r\n");
assert(flotilla_min_agent_notice('') === null);
assert(flotilla_min_agent_notice(null) === null);

// --- oversized/garbage value doesn't match the bounded regex: fail closed ---
file_put_contents($tmpHdr, "HTTP/1.1 200 OK\r\nX-Min-Agent: " . str_repeat('9', 50) . "\r\n\r\n");
assert(flotilla_min_agent_notice('2026.07.26') === null);

@unlink($tmpHdr);
putenv('FLOTILLA_HEADERS'); // unset override
echo "min_agent ok\n";
