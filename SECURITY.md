# Security Policy

## What Pebble is (and isn't)

Pebble is a local game for macOS and Windows that can also talk to other
players on your network:

- **No accounts, no credentials, no personal data.** Pebble stores worlds,
  settings and keybinds under `~/Library/Application Support/Pebble/` on
  macOS and `PebbleData` next to the executable on Windows. It never asks for
  a password and has nothing to log in to.
- **No telemetry, no analytics, no update checks.** The game never contacts a
  server of ours, because there isn't one. The only thing that reaches the
  internet on its own is the `pebble update` shell command, which is `git
  pull` on your own checkout.
- **Networking is opt-in and peer-to-peer.** Singleplayer opens no sockets at
  all. Multiplayer connects you directly to another machine — a friend's game
  opened to LAN, or a `pebble serve` instance. There is no relay and no
  middleman.
- **No elevated privileges.** An ad-hoc-signed app on macOS, an unsigned exe
  on Windows, both running as a normal user.

So there are two realistic threat models: **files you load into the game**,
and, the moment you join or host a multiplayer world, **whatever the other
side sends you.**

## Attack surface

If you're auditing Pebble, these are the interesting places — all of them
parse untrusted input.

### Network (only live during multiplayer)

| Surface | Where | Notes |
|---|---|---|
| Frame reader | `Sources/PebbleCoreBase/Net/NetLink.swift` | length-prefixed framing over plain TCP; frames above `NET_MAX_FRAME` (8 MB) are rejected before allocation |
| Packet decoding | `Sources/PebbleCoreBase/Net/NetProtocol.swift` | every field is read through a bounds-checked cursor that throws on underflow; a peer cannot make the reader run past its buffer |
| Session handling | `Sources/PebbleCoreBase/Net/NetSession.swift` | the host is authoritative: guest-reported positions, block edits and attacks are all re-checked against the real world rather than trusted |
| Other players' skins | `NetSession.swift` → `pebDecodePNG` | a custom skin is a PNG from another machine. Capped at 256 KB before decoding, and the decoder itself rejects absurd dimensions (`PEB_IMAGE_MAX_DIM`) before allocating |
| Listening socket | `pebserver`, and any world opened to LAN | binds port 25585 by default. A dedicated server accepts connections from anyone who can reach it — put it behind a firewall or a friends-only network, not on the open internet |

Host authority is a design rule, not a claim about intent: a modified client
can lie about anything, and the host recomputes rather than believes. What it
deliberately does **not** do is stop a determined cheater on a server you
invited them to — that is a social problem (see the non-goals in VISION.md).

### Files

| Surface | Where | Notes |
|---|---|---|
| Resource pack zip | `Sources/PebbleCoreBase/Render/PebCodecs.swift`, `PackAtlas.swift` | project-owned zip reader + miniz inflate; PNG via lodepng. Extracts to memory, never to paths taken from the archive |
| Save database | `Sources/PebbleCore/Game/Saves.swift` | SQLite blobs in a `VCK1` container with a JSON tail; decode paths bounds-check lengths and clamp out-of-range block/item ids rather than trusting them |
| Settings/keybinds | `Sources/PebbleCoreBase/Game/Settings.swift` | plain JSON via `Codable` |

Hardening that already exists: chunk-blob decoding validates section lengths
and clamps corrupted block ids to air; player-data loading repairs array sizes
and drops out-of-range item ids; SQLite errors are surfaced and failed writes
retried rather than ignored; image decoding refuses oversized dimensions
before allocating.

## Reporting a vulnerability

If you find a way for a crafted save file, texture archive, skin, or network
packet to do anything beyond crashing the game — memory corruption, code
execution, file writes outside the data directory, or one player affecting
another's machine — please report it privately:

- **Email:** briangaoo2@gmail.com — subject line starting with `[pebble security]`
- Include: your platform and version, a minimal reproducing file or packet
  capture if possible, and what you observed.

Plain crashes / hangs from malformed files are ordinary bugs — file those as
[regular GitHub issues](../../issues) with the offending file attached
(CONTRIBUTING.md lists what else to include). This is a beta; reports of every
kind are incredibly welcome.

You can expect an acknowledgment within a few days. There's no bug bounty;
you'll get credit in the changelog and my genuine thanks.

## Supported versions

Only the latest release is supported. There's no backporting; the fix ships in
the next version.
