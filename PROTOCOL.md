# Flotilla Push protocol (§P)

This is the authoritative cross-repo contract for **Flotilla Push**: the
relay (`flotilla-relay`), every server-side sender in this repo
(`flotilla-agent` — the Unraid `.plg` notify agent and `flotilla-beacon` for
Proxmox VE), and the iOS app all conform to exactly this document. If any
implementation's behavior disagrees with what's written here, that's a bug —
fix the implementation, not this file.

Source of truth this was transcribed from: `§P Protocol` in the Flotilla Push
(Release 8) implementation plan
(`~/AppStudio/homelab-app/docs/superpowers/plans/2026-07-25-flotilla-push.md`),
copied verbatim, plus the small set of directly-related "Global Constraints"
from the same plan (APNs headers, caps, dead-man timing) needed to make this
file self-contained.

## Pairing values

- `pairingID` = lowercase UUIDv4
- `S` = 32 random bytes (auth secret)
- `K` = 32 random bytes (E2E key)

QR / manual code: `flotilla://pair?v=1&id=<pairingID>&k=<b64url K>&s=<b64url S>&n=<percent-encoded server name>`

## Endpoints

All endpoints are under `/v1/`, all bodies are JSON, and all responses carry
the header `X-Min-Agent: 1.0.0`.

Auth (every route except `health`): `Authorization: Bearer <b64url S>`. The
relay stores only `sHashHex = hex(SHA-256(raw S bytes))` — never the secret
itself. The first valid `enroll` for a `pairingID` creates the pairing record
(first-writer-wins); every other route against an unknown pairing returns
401.

| Endpoint | Body | Success | Errors |
|---|---|---|---|
| `POST /v1/enroll` | `{pairingID, deviceToken(hex), apnsEnv:"sandbox"\|"production", transactionJWS}` | 200 `{ok:true}` | 400 malformed · 401 S mismatch · 403 JWS invalid/not-entitled · 409 >10 tokens |
| `DELETE /v1/enroll` | `{pairingID, deviceToken}` | 200 `{ok:true}` | 401 |
| `POST /v1/push` | `{pairingID, sealed, level:"passive"\|"active"\|"time-sensitive"}` | 202 `{ok:true}` | 401 · 403 no entitled devices · 429 capped |
| `POST /v1/pve/<pairingID>` | `{severity,title,message}` (plaintext) | 202 | 401 · 403 · 429 |
| `POST /v1/heartbeat` | `{pairingID, state:"ok"\|"going-down"}` | 200 `{}` | 401 |
| `GET /v1/health` | — | 200 `{ok:true,minAgent:"1.0.0"}` | — |

**`flotilla-beacon` (this repo, `cmd/flotilla-beacon`) always uses
`POST /v1/push`** — it seals every PVE webhook event with the pairing's E2E
key `K` locally before it ever leaves the box, the same way the Unraid agent
(`plugin/src/scripts/send-event.sh`) does, rather than sending the PVE
webhook's `severity`/`title`/`message` to the relay as plaintext via
`/v1/pve`. `/v1/pve` is part of the relay's contract (documented above for
completeness, and any client is free to use it) but is deliberately not the
path this repo's own agents take — sealed `/v1/push` keeps the relay unable
to read event content, matching this product's core "E2E encrypted" claim.

## Sealed payload

Plaintext (exact, before sealing):

```json
{"v":1,"event":"<EVENT>","subject":"<SUBJECT>","description":"<DESCRIPTION>","importance":"normal"|"warning"|"alert","link":"<LINK>","ts":<unix seconds>}
```

Sealing: ChaCha20-Poly1305 (IETF, 12-byte nonce), `sealed = base64std(nonce ‖
ciphertext ‖ tag)`. Implemented once in `internal/sealbox` (`Seal`/`Open`) and
reused by every sender in this repo — never reimplemented.

Keys and secrets carried in URLs or bearer headers (`K`, `S`) are
**base64url, no padding**. The `sealed` field itself is **base64 standard**
(it travels inside a JSON string body, not a URL).

## Severity / importance / level mapping

| Importance | Level (APNs interruption-level) |
|---|---|
| `alert` | `time-sensitive` |
| `warning` | `active` |
| `normal` | `passive` |

PVE severity → importance (used by `flotilla-beacon` and the relay's
`/v1/pve` route alike): `error` → `alert`, `warning` → `warning`, anything
else (`info`, `notice`, ...) → `normal`.

## APNs payloads

Common headers: `apns-topic: dev.livin.Lab`, `apns-push-type: alert`,
`apns-priority: 10`, `mutable-content: 1`. Sandbox host
`api.sandbox.push.apple.com`, production `api.push.apple.com`, chosen per the
enrolled token's `apnsEnv`.

Payload shapes (userInfo keys beside `aps`):

- **Sealed event** (from `/v1/push`), shown here at `level:"active"` or
  `"time-sensitive"`:
  ```json
  {"aps":{"alert":{"title":"Flotilla","body":"New server event"},"mutable-content":1,"interruption-level":"<level>","sound":"default"},"pairingID":"…","sealed":"…"}
  ```
  `sound` is present **only** when `level` is `active` or `time-sensitive` —
  for `level:"passive"` the relay omits `sound` entirely (see `aps()` in
  `flotilla-relay/src/pairing-do.js`: `if (level !== "passive") aps.sound =
  "default"`). `interruption-level` is always set to `level`, `passive`
  included. The visible `alert.title`/`alert.body` here are an inert
  placeholder — the real subject/description only exist inside `sealed`,
  which the relay never decrypts.
- **PVE direct** (from `/v1/pve/<pairingID>`): same `aps` shape (including the
  passive-omits-`sound` rule above) but `alert:{title:<title>,body:<message>}`,
  plus `"pairingID","kind":"pve"`.
- **Relay-generated** (dead-man switch / cap notices, no client involved):
  `alert:{title:"Server unreachable",body:"The server or its connection is down."}`
  (or `"Server back online"` / `"Notification cap reached"`), plus
  `"pairingID","kind":"unreachable"|"recovered"|"cap"`; level
  `time-sensitive` for `unreachable`, `active` otherwise — both non-passive,
  so both always carry `sound:"default"` per the rule above.

## NSE (Notification Service Extension) behavior

If `sealed` is present: decrypt with keychain item `push.k.<pairingID>`
(access group `9527CN9B2J.dev.livin.Lab.shared`), then set `title = subject`,
`body = description` (falling back to `event` if empty), and
`threadIdentifier = pairingID`. On any failure (missing key, decrypt error,
malformed plaintext), leave the placeholder alert untouched — never show raw
ciphertext or an error to the user.

If `kind` is present (no `sealed`): prefix the title with the server name
looked up from the app-group shared defaults dictionary `lab.push.names`
(keyed by `pairingID`), e.g. `"Tower unreachable"`.

## Dead-man switch & rate caps (relay-side, for context)

- Heartbeat cadence: every 60s. The relay arms a per-pairing alarm 180s out
  on every `state:"ok"` heartbeat; if it fires with no heartbeat in between,
  the relay sends one `unreachable` push. `state:"going-down"` disarms the
  alarm so a planned shutdown/reboot never pages anyone — this is exactly
  what `flotilla-beacon`'s SIGTERM handler and the Unraid agent's
  `stopping_array` hook exist to send, and why that heartbeat's delivery is
  bounded rather than best-effort/fire-and-forget: a dropped `going-down`
  heartbeat produces a false "server unreachable" push.
- Caps per pairing: 60 event pushes/hour, 500/day, unreachable pushes capped
  at 3/day, at most one "cap reached" push/day. Heartbeats themselves are
  exempt from all caps. Max 10 device tokens/pairing.

## Implementations in this repo

- `internal/sealbox` — `Seal`/`Open` (ChaCha20-Poly1305), the single
  implementation every sender reuses.
- `cmd/flotilla-seal` — CLI wrapper (`keygen | seal | open`) used by the
  Unraid agent's shell scripts.
- `cmd/flotilla-beacon` — the PVE daemon this document accompanies: listens
  on `127.0.0.1:8799` (default) for PVE's native webhook target, seals with
  `K`, forwards via `POST /v1/push`, heartbeats every 60s, sends
  `state:"going-down"` on SIGTERM/SIGINT before shutting its listener down.
  Conf file `/etc/flotilla-beacon.conf` (mode 600): lines `relay=`,
  `pairing=`, `secret=`, `key=`, `listen=`.
- `beacon/beacon-install.sh` — installs `cmd/flotilla-beacon` as a systemd
  service on a Proxmox host. **Canonical invocation** (this is exactly what
  the iOS app must render for the user to paste):
  ```
  curl -fsSL <relay>/beacon-install.sh | FLOTILLA_SECRET=<s> FLOTILLA_KEY=<k> bash -s -- <relay> <pairingID>
  ```
  `<s>` (`S`) and `<k>` (`K`) are the pairing's base64url secret/key from
  above, passed via the `FLOTILLA_SECRET`/`FLOTILLA_KEY` env vars — never as
  positional args. Positional args land in `/proc/<pid>/cmdline`, which is
  world-readable, and in shell history; env vars land in
  `/proc/<pid>/environ`, which only root can read. Only `<relay>` and
  `<pairingID>` (both non-secret) are positional.
- `plugin/src/scripts/{send-event.sh,heartbeat.sh}` — the Unraid equivalent
  sender, invoked by Unraid's own `notify` agent and a cron job respectively.
