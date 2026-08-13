# Unraid forum support thread

**Posted 2026-08-13** as topic **200208**, by `livin21`:
https://forums.unraid.net/topic/200208-plugin-flotilla-agent-encrypted-push-notifications-for-unraid/

Written in ASD-STE-100 (Simplified Technical English): short active sentences, simple present
tense, one idea per sentence, no idioms. Keep replies in the same register.

## Forum mechanics learned while posting

- **A new account cannot create topics in Plugin Support (forum 61).** There is no "Start new
  topic" button there. Plugin threads are created in **Plugin System (forum 60)** and a moderator
  moves them across — the same thing happened to the "Claude Code Remote Control" plugin thread.
- **New accounts are moderated.** The topic is held with "This content requires moderator approval
  before it's displayed publicly" until a moderator releases it.
- **There is a daily post limit for new accounts** — "You have reached the maximum number of posts
  you can make per day" appeared immediately after the first post. Budget replies accordingly for
  the first few days; answering questions in the thread is part of the launch plan's active posture
  and the limit will throttle it.

## Title

```
[Plugin] Flotilla Agent - encrypted push notifications for Unraid
```

## Body as posted

Flotilla Agent sends the notifications from your Unraid server to your iPhone. The plugin has an MIT license. All of the server code is public on GitHub.

FUNCTION

The plugin installs as an Unraid notify agent. It does not add its own monitor function. It sends the notifications that Unraid makes. These include parity checks, disk errors, SMART warnings and array events. Your User Scripts can also send notifications with the notify command.

The plugin sends a heartbeat signal at regular intervals. Then your phone can show the difference between a correct server and a server that is not on the network.

The settings page is at Settings > Flotilla Agent. You pair the phone with a QR code.

SECURITY

The plugin operates as the root user. Read this section before you install it.

The plugin encrypts the content of each event on your server with ChaCha20-Poly1305. The encryption occurs before the data goes out of your local network. The key is in two locations only: the configuration file on your server, and the keychain on the paired phone. The plugin does not send the key to the relay. The plugin does not write the key to a log file.

The relay sends the push message to Apple. The relay receives ciphertext and a pairing identifier. The relay cannot read the text of your notifications. Apple also cannot read the text.

The plugin does not send your Unraid API key, your host name, or other local secrets.

The relay code is also public. The file PROTOCOL.md gives the data format. You can examine the code and make sure that these statements are correct.

COST

The plugin is free and open source.

The push messages go to Flotilla. Flotilla is my iOS app for Unraid and Proxmox. The push function needs the Pro option in that app. The Pro option costs USD 4.99 one time.

I give you this information now, and not after you install the plugin.

REQUIREMENTS

Unraid 7.0 or later
An iPhone with the Flotilla app

INSTALLATION

The Community Applications review is not complete. Until it is complete, put this URL in Plugins > Install Plugin:

https://raw.githubusercontent.com/Livin21/flotilla-agent/main/plugin/flotilla-agent.plg

SOURCE CODE

Plugin, Proxmox beacon and encryption tool: https://github.com/Livin21/flotilla-agent
Relay: https://github.com/Livin21/flotilla-relay

LIMITS

The app operates on iOS only. There is no Android app.
I operate the relay. The relay keeps no data and reads no plaintext. But it is a dependency.
When you remove the plugin, it also removes the notify agent, the cron entry and the configuration directory.

Send your questions and your problem reports to this topic. The plugin is new. I want to know about the problems that you find.

---

## Notes for the CA submission (not part of the post)

**Expect the "why is this not a Docker container?" question.** CA policy excludes plugins that are
better suited as containers, and it is the most probable cause of a rejection. Three concrete
answers:

- The plugin registers a **notify agent** in `/boot/config/plugins/dynamix/notifications/agents`.
  emhttp reads that path on the host. A container cannot install itself there.
- The plugin adds a **Settings page** (a `.page` file under `/usr/local/emhttp/plugins/`).
  A container cannot add a page to the Unraid web interface.
- The plugin must continue to operate when the array stops. An alert that says "the server stops
  now" has no value if it stops with the array. Docker stops when the array stops.

**Order of operations**

1. Post the support thread. DONE — topic 200208, 2026-08-13.
2. Wait for moderator approval. CA checks the support link, so the topic must be publicly visible.
3. Push this repo, so the `<Icon>` and `README` URLs resolve.
4. Submit the repository through the CA form. Plugins are reviewed by hand; allow up to 48 hours.
