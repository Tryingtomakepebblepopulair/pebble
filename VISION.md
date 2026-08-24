# Pebble — Vision

*The product vision, agreed with Xavi. When a request and this document disagree, say so before building.*

## What Pebble is for

**A block-survival game that you and your friends can actually play together — whatever computer they own, with no account, no subscription, and nobody's servers in the middle.**

That sentence is not marketing; it is the reason every feature since 1.1.0 exists. Xavi had a finished single-player game on his Mac and friends he could not play it with: one in the same room, one in Portugal, one on Windows. LAN co-op, dedicated SMP servers, friend codes and the Windows port are all answers to that one problem, in the order the problem showed up.

## The three promises

**1. It is yours.** Open source, MIT, free. No account to create, no launcher, no telemetry, no cloud that can be switched off. Your worlds are files on your disk; your friends list is a JSON file next to them; your identity is a UUID your own game minted. Nothing about Pebble stops working because a company loses interest.

**2. You can play together.** Same WiFi: zero setup, the world just appears in the list. Across the internet: a real server (`pebble serve`) that stays up without a host player, joined by address. Across platforms: a Mac and a Windows PC in the same world, because the simulation is identical on both.

**3. It stays honest.** 550 frozen golden checks pin worldgen, physics and protocol bit-for-bit. The Mac app never breaks so that something else can move forward. And when something cannot be done — a Windows build I cannot test, a friend-request popup with no server to route it — the answer is "here is why, and here is what works instead", never a stub that pretends.

## Decisions already made

These are settled; revisit them deliberately, not by accident.

- **Host-authoritative multiplayer.** The host or server owns the world. Guests send intent and render the truth they are sent. No prediction/rollback: simpler, and honest about who decides.
- **Determinism is the transport format.** Guests regenerate untouched terrain from the seed and only download *modified* chunks. That is why joining a big world is fast — and why the frozen goldens are a load-bearing feature, not a testing nicety.
- **No central service, ever.** Discovery is Bonjour on the LAN and a typed address off it. Friendship is a code you swap over any chat app. This costs convenience (no online-presence for internet friends) and buys independence, forever.
- **One simulation, two renderers.** `PebbleCoreBase` is the shared, Foundation-only game. macOS draws it with Metal, Windows with Vulkan behind a C ABI. Neither renderer is allowed to leak into the shared core.
- **Zero external Swift dependencies.** Apple frameworks on macOS; vendored C for SQLite, PNG, ZIP and Vulkan headers. Nothing to `swift package update` into a broken weekend.
- **Faithful 32x is a guest.** The built-in art belongs to the Faithful team, ships under their license, is fully credited, and Pebble runs without it.

## Roadmap

**Done** — single-player survival across three dimensions; LAN co-op; standalone SMP servers; permanent identities and friend codes; custom skins; visible armor, held items and shields; the game-speed slider; published on GitHub with downloadable releases; the portable core, server and golden suite running on Windows; a Windows client that renders and joins real worlds.

**Now** — finishing the Windows client until it is not "the Windows version" but simply Pebble: audio (PORTING 10), animated entities, the first-person viewmodel, and a packaged download that is as easy as the Mac one (PORTING 14).

**Next** — the gaps the CHANGELOG already admits: portals for guests, live-syncing containers, commands for guests. Then the smaller kindnesses: name tags, other players' skins everywhere, shadows and bloom on Windows.

**Someday, maybe** — a Pebble website with a download page and an SMP setup helper; Linux, which is mostly free once Vulkan is real; mobile or console, which is not.

## Non-goals

- **Not a Minecraft clone claim.** Pebble is an original re-creation inspired by Java Edition 1.20: no Mojang code, no Mojang assets, no affiliation. That stays true in every commit.
- **No monetization.** No purchases, no ads, no premium servers. The Faithful license forbids it and so does the point of the project.
- **No anti-cheat arms race.** Host authority stops the obvious lies; a determined cheater on a friends-only server is a social problem, not an engineering one.
- **No launcher, no auto-updater, no accounts.** Downloading a zip is fine.

## How to talk about it

Xavi is a young Dutch hobbyist who is learning by building something real. Explain in Dutch, in plain words, with concrete next steps he can do himself. Say what actually works, what does not, and what it would honestly take — he has been told "impossible" and then handed a working Windows client, and both were true at the time they were said.
