# Final fix wave report

1. Input validation (checkup.sh f_eval, check_w1): pool needs digit fsSize > 0 and digit fsFree; array disks need digit fsFree and fsSize > 0; floor must be all digits; W1 VALUE and RAW must be digits. Tests: `zero-size pool is skipped`, `non-digit floor is skipped`, `non-numeric SMART value is skipped`.
2. W1 also recorded via state_set W1 <id> in checkup.state; skipped when either store has the id; wear.state write errors silenced. Tests: `W1 once when flash is read-only`, `W1 boundary` (10 sends, 11 does not).
3. Parity wording: last sentence switches on disks.ini type=Parity. Test: `W1 on a parity disk` (full description and subject).
4. send(): notify runs with `9>&- 3<&-`.
5. plg removal echo now says "Relay URL, filter settings and the server checks setting were kept". test/plg_test.php does not assert it.
6. docs/server-checks-research.md: ruling line added after the M1 false-negative sentence.
7. page_render_test save_checks: seeds RELAY=https://relay.example.test and CAT_OTHER="no", asserts both kept plus CHECKS="no".
8. checkup_test.sh: TMPDIRS array + EXIT trap removes temp dirs (restores perms first).
9. plugins/flotilla-agent.xml: first Overview paragraph rewrapped at 98 cols, words unchanged.

Verification:
- `bash test/checkup_test.sh`: exit 0, 44 ok, 0 FAIL
- `for f in test/*.php ...`: no FAIL lines
- `bash test/agent_test.sh` (pyenv python3 first on PATH): exit 0
- simplexml_load_file: `ok`
