# ix-peers

Claude Code's cross-session messaging, between linked teammates' sessions on different machines, through Ix.

On this machine, Claude sessions already reach each other: `ListAgents` lists them and `SendMessage` delivers to them. With this mod, the same two tools reach the live sessions of teammates you have linked in the same Ix org:

- **ListAgents** gains an "Ix peers" section. Each live session is listed by its address, `ix:<handle>/<repo> [ref]`, with its status (idle or busy) and its repo and branch.
- **SendMessage** to an `ix:` address, or to a peer's session name, goes over Ix. A bare handle such as `ben` tries a local agent first, as the built-in does, then Ix.
- **Incoming messages** arrive framed as `<cross-session-message from="ix:...">`. They reach the model at its next tool round while a turn runs, or start a turn when the session is idle. To reply, copy `from` as `to`.
- **`notify_when_idle`** works across machines. One `[Cross-session idle notice]` arrives when the peer next goes idle or exits.
- **Held messages** wait above the prompt with **Deliver** and **Decline** buttons. A declined or expired (10 min) message sends a delivery notice back to its sender. A message is held when:
  - **it comes from another person**, unless you list their handle in `IX_PEERS_AUTO_DELIVER` (comma-separated, e.g. `IX_PEERS_AUTO_DELIVER=ben,carol`). Your own sessions on other machines follow the built-in rules.
  - **its sender is in a different permission mode** from this session, or either mode is unknown. This is the built-in rule. Under managed settings the mod cannot read the mode, so every message is held.
- **Message text is escaped.** The body is HTML-escaped inside the frame, so a sender cannot close the frame early or forge a new one.

## Setup

1. Install `@ix/pro` 0.x or later and run `ix login`.
2. Link with a teammate. One side runs `ix peer link teammate@example.com`. The other side runs `ix peer accept <linkId>`, or links back with `ix peer link` to accept. `ix peer links` lists your links.
3. Install the mod: `/plugin install ix-peers --marketplace ix-infrastructure/ix-claude-plugin`.

Your own sessions on your other machines are always linked.

## How it works

The mod never handles credentials. Every call goes through the `ix` CLI:
- `ix peer presence` sends a heartbeat every 20s with busy/idle and the permission mode.
- `ix peer ls` lists peers for ListAgents.
- `ix peer send` delivers SendMessage.
- `ix peer watch --jsonl` is a live stream, restarted with backoff if it drops.

The server stamps the sender from your verified Ix identity. It delivers only between linked users in one org.

Set `IX_PEERS_BIN` to use an `ix` binary other than the one on `PATH`.

Headless runs (`claude -p`) do not register by default, so one-shot scripts don't clutter your peers' listings. Set `IX_PEERS_HEADLESS=1` to opt in.

## Develop

```sh
claude plugin validate mods/ix-peers
claude plugin test mods/ix-peers
claude --plugin-dir mods/ix-peers   # a session with the mod loaded
```
