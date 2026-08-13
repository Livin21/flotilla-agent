# Unraid forum support thread — draft

Post to **Unraid forums → Plugin Support** (this becomes the `<Support>` URL in the CA
submission, so it must exist before submitting to Community Applications).

---

## Title

```
[Plugin] Flotilla Agent — end-to-end encrypted push notifications for Unraid
```

---

## Body

I got tired of finding out about a disk error the next time I happened to open the web UI, so I
wrote a plugin that forwards Unraid's notifications to my phone. It's MIT licensed and the whole
server side is on GitHub.

**What it does**

It registers as an Unraid *notify agent*, which means it doesn't invent its own monitoring — it
picks up whatever already raises a notification. Parity checks, disk errors, SMART warnings, array
start/stop, and anything your own User Scripts send with `notify` all come through. It also sends a
heartbeat, so your phone can tell the difference between "nothing is wrong" and "the server is
off the internet" — a silent server and a healthy server look identical otherwise.

Settings page lands under **Settings → Flotilla Agent**. Pairing is a QR code.

**What it can and can't see**

This is the part I'd want to know about before installing something that runs as root, so:

Event content is sealed with ChaCha20-Poly1305 **on your server, before anything leaves your LAN**.
The key lives in exactly two places — your server's config file and the paired phone's Keychain. It
is never sent to the relay, never in the QR beyond the initial pairing, never in a log. The relay
that forwards the push to Apple sees ciphertext and a pairing ID; it cannot read your notification
text, and neither can Apple. Your Unraid API key, hostname, and other server-local secrets are
never transmitted at all.

The relay is open source too: https://github.com/Livin21/flotilla-relay — and the wire format both
sides agree on is written down in PROTOCOL.md, so you can check the claim rather than take my word
for it.

**Being upfront about the money**

The plugin is free, MIT, and useful on its own terms. Push delivery goes to **Flotilla**, my iOS app
for Unraid and Proxmox, and the push feature sits behind its one-time $4.99 Pro unlock. I'd rather
say that in the fourth paragraph than have you find out after installing.

I'm not asking anyone to buy anything here — the reason this plugin is open source and standalone is
that I think the server side of a thing like this should be inspectable regardless of what the client
costs.

**Requirements**

- Unraid 7.0 or newer
- An iPhone running Flotilla, paired via QR

**Install**

Community Applications (pending review), or paste the plugin URL into **Plugins → Install Plugin**:

```
https://raw.githubusercontent.com/Livin21/flotilla-agent/main/plugin/flotilla-agent.plg
```

**Source**

- Plugin + Proxmox beacon + encryption CLI: https://github.com/Livin21/flotilla-agent
- Relay (Cloudflare Worker): https://github.com/Livin21/flotilla-relay
- Protocol: PROTOCOL.md in the agent repo

**Known limits**

- iOS only. There is no Android client and I'm not writing one.
- The relay is operated by me. It's stateless and holds no plaintext, but it is a dependency —
  if that's disqualifying for you, that's a fair call and I'd rather you knew now.
- Uninstall removes the notify agent, the cron entry and the config directory.

Happy to answer anything, and bug reports are very welcome — this is new and I'd rather hear about a
rough edge than have someone quietly uninstall it.

---

## Notes for the CA submission (not part of the post)

**Expect the "why isn't this a Docker container?" question.** CA policy explicitly excludes plugins
better suited as containers, and it is the most likely reason for a bounce. The answer is concrete:

- It registers a **notify agent** in `/boot/config/plugins/dynamix/notifications/agents`. A container
  cannot install itself into Unraid's notification system — that path is read by emhttp on the host.
- It adds a **Settings page** (`.page` file under `/usr/local/emhttp/plugins/`). Containers cannot
  add pages to the Unraid web UI.
- It must survive an **array stop**, since a "server going down" alert is worthless if it dies with
  the array. Docker itself stops when the array does.

Lead with those three if asked; none of them is a preference argument.

**Order of operations**

1. Post this thread → copy its URL.
2. Paste that URL into `<Support>` in `ca/flotilla-agent.xml`, commit, push.
3. Submit the repo through the CA form (plugins are manually reviewed; allow up to 48h).
