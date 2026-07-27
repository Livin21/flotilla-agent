# flotilla-agent

Server-side companions for **Flotilla Push** — the optional, paid push
notification feature of [Flotilla](https://livinmathew.com/flotilla), an iOS
Unraid/Proxmox homelab client app. This repo is everything that runs on *your*
server; the counterpart Cloudflare Worker that everything here talks to is
[flotilla-relay](https://github.com/Livin21/flotilla-relay). The wire format
both repos (and the iOS app) agree on is documented in [PROTOCOL.md](PROTOCOL.md).

Three components, one job each:

- **The Unraid plugin** (`plugin/`) — hooks into Unraid's own notification
  system (`notify` agent) and a heartbeat cron job, and adds a settings page
  under Unraid's Settings tab for pairing and configuration.
- **`flotilla-beacon`** (`cmd/flotilla-beacon`) — the equivalent for Proxmox
  VE: a small daemon that receives Proxmox's native webhook locally and
  forwards it, since Proxmox has no plugin system to hook into directly.
- **`flotilla-seal`** (`cmd/flotilla-seal`) — the shared encryption CLI
  (`internal/sealbox`, ChaCha20-Poly1305) both senders shell out to, so the
  sealing logic is implemented exactly once.

MIT-licensed, no runtime dependency on anything besides Go's standard library
and `golang.org/x/crypto` (used only by the Go binaries — the Unraid plugin is
plain PHP/bash and needs no runtime dependency at all beyond what Unraid
already ships: `bash`, `curl`, `jq`).

## What it does, and does not, see

- **Event content is sealed (ChaCha20-Poly1305) locally, before it ever
  reaches the relay.** Both senders in this repo — `send-event.sh` (the
  Unraid plugin) and `flotilla-beacon` (Proxmox) — encrypt with a key (`K`)
  that exists only in this server's config file and the paired iPhone's
  Keychain. Neither this repo's code, the relay, nor Apple's push
  infrastructure can read a sealed event's real subject/description; the
  relay only ever forwards ciphertext.
- **Your server's credentials never leave your LAN.** Nothing in this repo
  ever sends your Unraid API key, Proxmox API token, hostname, or any
  server-local secret to the relay. The only things that go out are: the
  pairing ID, the bearer auth secret (`S`, used only to authenticate — never
  logged or displayed), sealed event ciphertext, and (for `flotilla-beacon`)
  a periodic heartbeat.
- **The one exception: the beacon-less Proxmox webhook path.** If you point
  Proxmox's native webhook straight at the relay's `POST /v1/pve` instead of
  installing `flotilla-beacon`, there is no local encryption step — the
  relay (and therefore Apple, downstream) sees that event's title, message,
  and severity in plaintext. `flotilla-beacon` exists specifically to close
  this gap; see [PROTOCOL.md](PROTOCOL.md) for exactly which path each
  sender takes.
- **No telemetry.** Nothing in this repo phones home anywhere except the
  relay URL you've configured, and only for the pairing/heartbeat/event
  traffic described above.

## Install

### Unraid plugin

From Unraid's **Plugins → Install Plugin**, paste the `.plg` URL:

```
https://raw.githubusercontent.com/Livin21/flotilla-agent/main/plugin/flotilla-agent.plg
```

This installs the settings page under **Settings → Flotilla Agent**, where
you pair with the Flotilla iOS app (scan a QR code) and configure which
notification categories/severities get forwarded. "Reset pairing" there
revokes the old pairing at the relay (see below) and generates a new one.

### Proxmox VE (`flotilla-beacon`)

The iOS app renders the exact install command during pairing (also documented
in [PROTOCOL.md](PROTOCOL.md)) — the script itself is fetched straight from
this repo's GitHub raw URL, not from the relay:

```
curl -fsSL https://raw.githubusercontent.com/Livin21/flotilla-agent/main/beacon/beacon-install.sh | FLOTILLA_SECRET=<s> FLOTILLA_KEY=<k> bash -s -- <relay> <pairingID>
```

This installs `flotilla-beacon` as a systemd service listening on
`127.0.0.1:8799` by default, writes `/etc/flotilla-beacon.conf` (mode 600),
and points Proxmox's notification webhook target at it. Re-running the
install command is safe (it rewrites config/binary/unit and restarts the
service) — useful after a re-pair.

The binary is normally downloaded from this repo's GitHub releases (and the
systemd unit from `raw.githubusercontent.com`), which requires a published
release and this repo to be public — already a launch requirement (the
Unraid CA and Proxmox community-scripts both mandate open source). For
testing against an unpublished build — e.g. before this repo has
ever cut a release — set `FLOTILLA_BEACON_BIN=/path/to/a/locally-built
flotilla-beacon` (a binary you built yourself, e.g. via `GOOS=linux go build
-o flotilla-beacon ./cmd/flotilla-beacon`): the script installs that file
directly instead of downloading one, and copies the `flotilla-beacon.service`
unit sitting next to `beacon-install.sh` on disk instead of fetching it from
GitHub. Everything else about the install (config file, systemd enable/restart)
is unchanged.

### `flotilla-seal` (standalone)

```bash
go build -o flotilla-seal ./cmd/flotilla-seal
./flotilla-seal keygen                       # 32 random bytes, base64url
echo '{"hello":"world"}' | ./flotilla-seal seal --key <b64url-key>
```

## Reset / revoke

Resetting the pairing (Unraid's "Reset pairing" button, or re-running
`beacon-install.sh` for Proxmox after re-pairing) sends `DELETE
/v1/pairing` to the relay with the *old* pairing's secret before generating
new pairing values, so the relay-side state (device tokens, heartbeat/alarm
state) for the old pairing is actually wiped rather than silently
orphaned. This is best-effort: a relay that's unreachable at that moment
never blocks the local reset (`plugin/src/scripts/revoke.sh` always exits 0,
bounded to a 5s timeout).

## Self-hosting

Every sender's relay URL is a config value, not a hardcoded constant: the
Unraid plugin's settings page (`RELAY`), `flotilla-beacon`'s conf file
(`relay=`), and the iOS app's own settings all point at a URL you control. To
point this repo's agents at your own relay you only need to change that URL —
nothing else in this repo is tied to a specific deployment. (Whether a
self-hosted relay can itself deliver push for the official App Store build of
Flotilla is a constraint of `flotilla-relay`, not of anything here — see that
repo's README.)

## Development

```bash
go build ./...
go test ./...                 # cmd/flotilla-seal, cmd/flotilla-beacon, internal/sealbox
php test/*.php                # settings.php unit tests (CSRF, cfg escaping, entity fixup, ...)
bash test/agent_test.sh       # send-event.sh/heartbeat.sh/revoke.sh against a local capture relay
bash plugin/build.sh <version> # rebuilds plugin/flotilla-agent-<version>.txz from plugin/src
```

`test/agent_test.sh` needs `jq`, `python3`, and `go` on `PATH`; it spins up
`test/capture_server.py` as a fake relay and drives the real shell scripts
against it end-to-end (including timeout/black-hole behavior against an
unreachable relay).

## License

MIT — see [LICENSE](LICENSE).
