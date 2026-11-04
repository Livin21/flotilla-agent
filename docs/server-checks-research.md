# Server checks research (Task 0 spikes)

Date: 2026-11-04. Public sources only; nothing run against Tower or any server.
Anything not confirmed from a fetched source is marked UNVERIFIED.

## Spike 1: Mover Tuning cron lines and syslog lines (M1)

**CA listing source (confirmed).** Community Applications feed (https://raw.githubusercontent.com/Squidly271/AppFeed/master/applicationFeed.json, updated 2026-11-04) lists three "Mover Tuning" entries. Two (R3yn4ld, hugenbdd) are `Deprecated: true`. The live one is masterwishx, PluginURL `https://raw.githubusercontent.com/masterwishx/ca.mover.tuning/master/plugins/ca.mover.tuning.plg`. The `.plg` is version 2026.10.30, and the latest GitHub release tag is `2026.10.30` (https://api.github.com/repos/masterwishx/ca.mover.tuning/releases/latest). Files read on `master`:
- https://raw.githubusercontent.com/masterwishx/ca.mover.tuning/master/source/ca.mover.tuning/usr/local/emhttp/plugins/ca.mover.tuning/updateCron.php
- https://raw.githubusercontent.com/masterwishx/ca.mover.tuning/master/source/ca.mover.tuning/usr/local/emhttp/plugins/ca.mover.tuning/age_mover

**Cron lines `updateCron.php` writes** (each is a file under `/boot/config/plugins/...`; the schedule field is the user's 5-field cron):

| File | Line | When |
|---|---|---|
| `/boot/config/plugins/ca.mover.tuning/mover.tuning.cron` | `<cron> /usr/local/emhttp/plugins/ca.mover.tuning/mover start \|& logger -t move` | Unraid >= 7.2.1, Mover Tuning schedule enabled |
| `/boot/config/plugins/dynamix/mover.cron` | `<cron> /usr/local/sbin/mover start \|& logger -t move` | Unraid < 7.2.1, schedule re-enabled by the plugin (`make_unraid_cron`) |
| `/boot/config/plugins/ca.mover.tuning/mover.cron` | `<cron> /usr/local/emhttp/plugins/ca.mover.tuning/mover.php force start \|& logger -t move` | "force move" enabled |
| `/boot/config/plugins/ca.mover.tuning/mover.watchdog.cron` | `*/5 * * * * /usr/local/emhttp/plugins/ca.mover.tuning/age_mover watchdog >/dev/null 2>&1` | cache watchdog on |

Each file is preceded by a `# Generated ...` comment line. The plugin then runs `update_cron`. That Unraid script merges `/boot/config/plugins/*/*.cron` into `/etc/cron.d/root`: UNVERIFIED here (Unraid is closed source; not read from a public file).

Every line the plugin writes for the Mover Tuning schedule contains either `ca.mover.tuning` (7.2.1+ and force move) or `/usr/local/sbin/mover` (stock path, pre-7.2.1). The watchdog line also contains `ca.mover.tuning` but is not a mover schedule, so M1 would count it as "scheduled" if the watchdog is on and the real schedule is missing. Flag this as a known false negative for M1.

**Syslog tag is `move`** (`logger -t move`), both in the cron lines and in `age_mover` (`mvlogger`, `mvDebuglogger`, watchdog).

**Syslog lines by logging setting** (`age_mover` `mvlogger`: `LOGLEVEL` 1 = `logging="yes"`, 0 = `"no"`, 2 = file-only):
- Logging on (`yes`): a cron run echoes each message; the cron line's `|& logger -t move` sends it to syslog. Lines include `Starting Mover tuning plugin ...` (age_mover line 3009), then `Mover Tuning Plugin version ...`, `Logging: yes`, the threshold/option lines, and `Mover tuning plugin done!` (line 3205). A manual (CLI or button) run calls `logger -t move` itself, without the time prefix.
- Logging off (`no`): `mvlogger` writes nothing to syslog or the log file, so `Starting Mover tuning plugin ...` is NOT written. Exceptions: lines starting `Error:` from `updateCron.php` are always logged. Whether the stock Unraid mover (called by `age_mover`) logs under `move` when Mover Tuning logging is off: UNVERIFIED (stock mover is not public).
- Consequence for Flotilla app 1.4 (app plan Task 5): matching `Starting Mover tuning plugin` only works when the user has Mover Tuning logging on. Tell Livin.

**M1 match: `/usr/local/sbin/mover` or `ca.mover.tuning`** (any line in `/etc/cron.d/root` containing either substring). No change to the Task 1 match or its `Mover Tuning cron counts` fixture; the fixture line can be `0 3 * * * /usr/local/emhttp/plugins/ca.mover.tuning/mover start |& logger -t move`.

## Spike 2: Attribute 193 Load_Cycle_Count across vendors (W1)

Shared pattern: normalized VALUE starts at 100 (Seagate, Toshiba) or 200 (WD) and falls as RAW rises. Raw is vendor-specific.

| Vendor | Model | VALUE | RAW | Source |
|---|---|---|---|---|
| Seagate | ST2000DM008 (Tower) | 001 | 1,215,433 | Livin's own reading (given) |
| Seagate | ST2000DM001-1CH164 | 001 | 573,675 | https://www.truenas.com/community/threads/load-cycle-count-auf-600k-wieso.50543/ |
| Seagate | ST4000DM000-1F2168 | 098 | 4,547 | https://www.truenas.com/community/threads/seagate-4tb-desktop-drive-longevity.14712/ |
| Seagate | ST2000DM001-9YN164 | 100 | 612 | https://gist.github.com/noroutine/d1eda80ebb7879aa974ef64ea8a7502a |
| WD | WD10EARS (Caviar Green) | 001 | 611,460 | https://pastebin.com/P47S9CfZ |
| WD | WD6400AADS (Caviar Green) | 053 | 442,121 | https://pastebin.com/P47S9CfZ |
| WD | WD2001FASS (Caviar Black) | 134 | 200,432 | https://gist.github.com/noroutine/d1eda80ebb7879aa974ef64ea8a7502a |
| WD | WD20EARX (Green) | 181 | 59,659 | https://pastebin.com/P47S9CfZ |
| WD | WD2003FZEX (Black) | 200 | 393 | https://gist.github.com/flobler/0e0599291af8b796c8d32eaa846dd39d |
| Toshiba | MQ01ABF032 | 097 | 36,758 | https://www.smartmontools.org/raw-attachment/ticket/1804/smartctl-Toshiba-MQ01ABF032.txt |
| Toshiba | MQ01ABD100 | 100 | 5,737 | https://www.smartmontools.org/raw-attachment/ticket/1501/TOSHIBA_MQ01ABD100_87PSPGCKT_2021-06-12%20statistics.txt |
| Toshiba | MG08ADA800E | 100 | 14 | https://www.smartmontools.org/raw-attachment/ticket/1794/smartctl-TOSHIBA_MG08ADA800E.txt |
| Toshiba | DT01ACA200 | 100 | 108 | https://gist.github.com/amelentev/795ed05fd20284dc66d5 |
| Toshiba | MQ01ACF050 | 085 | 158,150 | UNVERIFIED (search-result summary of https://forums.tomshardware.com/threads/toshiba-mq01acf050-has-high-udma-error-count-c7-and-high-write-error-rate-c8.3823356; page not read directly) |

**Rated load cycles** (all weak sources):
- Toshiba laptop drives: 600,000 (forum post quoting the rating for MQ01ABB200, https://www.truenas.com/community/threads/smart-193-load_cycle_count.23362). Not read from a Toshiba datasheet: UNVERIFIED.
- WD: 600,000 is widely quoted for WD Red (https://community.netgear.com/discussions/readynas-general/wd-red-drives-park-their-heads-like-wd-green-drives/869565, forum claim about WD's datasheet; page blocked for me by a bot wall). UNVERIFIED. The WD Green data above puts VALUE 001 at about 611k, consistent with a 600k scale.
- Seagate Barracuda desktop: 300,000 is the commonly quoted figure; I found no fetched source. UNVERIFIED.

**Reading the data.**
- WD: VALUE reaches 001 at ~611k raw (WD10EARS), i.e. at the rated count. Not early.
- Seagate: ST4000DM000 loses 2 points by 4.5k raw (about 1 point per 2.3k); extrapolating gives VALUE <= 10 around 200k to 230k raw, before a 300k rating but within the same order. ST2000DM001 at 573k and Tower at 1.2M are both pinned at 001, already past any plausible rating (UNVERIFIED rating).
- Toshiba: VALUE falls about 1 point per 10k to 12k raw (097 at 36.8k; 085 at 158k, unverified). VALUE <= 10 would come at roughly 900k+ raw, after the 600k rating. No Toshiba reading shows VALUE <= 10 before the rating.
- No vendor in the data shows VALUE <= 10 "well before" its rated count. Every drive at or under 10 is at or past roughly its rating (Seagate possibly at about 70 to 80 percent of an unverified 300k).
- Caveat: Tower's own reading (001 at 4x a 300k rating) confirms the check would fire on a worn drive. Raw-vs-VALUE behavior differs per firmware, and a single point per vendor is thin for Toshiba.

**W1 threshold VALUE <= 10: keep** (no vendor drops to <= 10 well before its rated count; Seagate is the closest, at roughly 70 to 90 percent of an UNVERIFIED 300k rating).
