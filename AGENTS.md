# Pebble — Agent Reference

An open-source Minecraft-style survival game for macOS **and Windows**: ~50,000 lines of Swift with zero external Swift dependencies, a hand-written Metal renderer on macOS, a hand-written Vulkan renderer on Windows, worldgen/mobs/redstone/enchanting/three dimensions, LAN + SMP multiplayer, and every sound synthesized at runtime. Original engine by [Brian Gao](https://github.com/thebriangao/pebble) (MIT); this repo is the multiplayer + cross-platform edition.

Owner: **Xavi** — a young Dutch hobbyist. Explain things to him **simply and in Dutch**; all code, comments, commits, docs, and in-game text stay **English**. He tests on real hardware (his Mac, a Windows PC, and a friend's Windows laptop) and reports back with screenshots.

> **Read [VISION.md](VISION.md) first.** It says what Pebble is for and which trade-offs are already decided. When a request and the vision disagree, raise it instead of silently picking one.
>
> **Read [PORTING/](PORTING/) before touching platform code.** Xavi's cousin wrote that 14-module plan; the port follows it, and it is the reason the port has stayed green instead of collapsing into a rewrite.

## State

**2026-07-12 — the Windows client is a real, playable Pebble.** It boots the actual Pebble UI (title screen, options, multiplayer/direct-connect lobby), renders terrain with Faithful textures, draws mobs and other players, streams chunks, takes input, and joins Mac-hosted worlds over direct IP. Both CI lanes are green. Known gaps on Windows: no audio (PORTING 10), entities are in bind pose (no animator yet — that still lives Apple-side in `EntityRendererM`), no shadows/bloom/ultra, no first-person viewmodel.

macOS is unchanged: same app, same saves, same green checks — 585 of them now.

## Where things live

| Target | What it is | Platform |
|---|---|---|
| `PebbleCoreBase` | The portable core: simulation, worldgen, registries, entities, items, systems, mesher, render ABI, UI stack, protocol + social types, settings, codecs glue. **Foundation only.** | all |
| `PebbleCore` | Apple-side runtime: `GameCore` orchestration, SQLite `SaveDB`, Network.framework/Bonjour adapter, `MathXApple` (simd/Mat4/Frustum). Re-exports Base via `Reexport.swift`. | macOS |
| `Pebble` | The macOS app: AppKit shell, Metal renderer, AVFoundation audio, gear/entity renderers. | macOS |
| `PebbleWin` | The Windows client: Win32 window + message pump, input, lobby, host bridge, and the entity/UI/detail/viewmodel/audio views. | Windows |
| `CPebbleVulkan` | Vulkan renderer behind a `pb_vk_*` C ABI; loads `vulkan-1.dll` at runtime (no SDK needed). Embedded SPIR-V in `shaders_spv.h` — edit `shaders/*.vert|frag`, recompile with `glslangValidator -V --target-env vulkan1.0`, then `python3 shaders/embed.py`. The `.spv` files are checked in, so a build never needs the compiler. | Windows (stubs elsewhere) |
| `CPebbleAudio` | Audio sink behind a `pb_audio_*` C ABI: winmm's waveOut (plain C, no COM, no SDK). Pebble synthesizes every sound, so a platform only hands over finished stereo samples. | Windows (stubs elsewhere) |
| `CSQLite` / `CCodecs` | Project-owned SQLite, lodepng + miniz — same engine/codecs on every platform. | all |
| `PebbleSmokeKit` | The shared golden suites both smoke runners execute. | all |
| `pebsmoke` / `pebsmokecore` | macOS full suite (585) / portable suite (550) — the one Windows CI runs. | macOS / all |
| `pebserver` | Headless SMP server: 20 TPS, no host player, direct IP everywhere, Bonjour on macOS. | all |

## Rules that must not break

1. **The goldens are frozen.** `goldens/*.json` pins worldgen, registries, physics and protocol bit-for-bit. Never set `PEBBLE_REGOLD`; CI refuses it and gates on `git diff --exit-code goldens/`. If a change moves a golden, the change is wrong until proven otherwise — and then it is a separate, reviewed commit.
2. **macOS stays green.** Both platforms ship now, but the Mac is where the game is developed and played daily. Never destabilize it to make Windows work.
3. **No fake portability.** Empty targets, runtime-fatal stubs, or skipped suites that pretend to pass are worse than an honest red lane. If a Windows lane cannot be made green in-session, remove the lane and document why.
4. **Nothing Apple enters `PebbleCoreBase`.** No AppKit, Metal, AVFoundation, Network, ImageIO, CoreGraphics, Compression, simd, `CFAbsoluteTimeGetCurrent`, or hard-coded Application Support paths. Use the seams: `PebCodecs` for PNG/ZIP, `monotonicNow()` for time, `Mat4f` for matrices, `vcSupportDir()`/`vcOverrideDataDir()` for storage, the socket transport for networking.
5. **Storage is injectable.** Anything that writes must resolve through `vcSupportDir()`, which honors `PEBBLE_DATA_DIR`. Tests and CI pin a temp root **before** constructing `GameCore`, `SaveDB`, settings or social stores.
6. **Save and wire formats are stable.** Changing `NetProtocol` means bumping `NET_PROTOCOL_VERSION` (mismatched clients get a clear disconnect reason, never a corrupt session).
7. **Commit and push after every green step.** Small commits, real messages. Xavi's sessions end abruptly when tokens run out — unpushed work is lost work.
8. **`git pull --rebase` before pushing.** Xavi edits the README through the GitHub web UI.

## Build and test

```
swift build                       # debug, all targets
swift build -c release            # what CI builds
swift run pebsmoke                # macOS: 585 checks (self-assigns a temp data root)
swift run pebsmokecore            # portable: 525 checks, runs anywhere
./pebble install                  # release build → ~/Applications/Pebble.app (~7 min)
./pebble serve --create "My SMP"  # headless server
```

Windows binaries are never built locally — see CI below.

## CI (`.github/workflows/ci.yml`)

- **macOS lane:** release build of everything, `pebsmoke` under a temp data root, goldens-unmodified gate.
- **Windows lane:** `pebsmokecore` (the same frozen goldens — this is the proof that a Windows Pebble generates *bit-identical worlds*), `pebserver` build + `--help` smoke, `PebbleWin` release build, and it uploads the **`pebble-windows-demo`** artifact (Pebble.exe + Swift runtime DLLs + assets + a Dutch `LEES-MIJ.txt`).

All Windows code is therefore written **blind** and verified on CI. Push, then `gh run watch <id>`; expect one to three compile-fix rounds on new Win32/Swift interop, and read errors with `gh run view <id> --log-failed`. Use Swift **6.2.1+** in `compnerd/gha-setup-swift` (6.0.3 dies with `ucrt` cyclic-module errors on current runners).

Xavi's hardware-test loop: repo → **Actions** → newest run → **Artifacts** → `pebble-windows-demo` → unzip → `Pebble.exe`. Ask him for `pebble-log.txt` plus a screenshot taken with **Win+Shift+S** (phone photos add rolling-shutter tilt and exposure artifacts that have already cost a debugging round).

## Verifying visually on macOS

The app has built-in test hooks — use them instead of asking Xavi to check:

```
PEBBLE_AUTOLOAD=1 PEBBLE_NEWWORLD=4242 \
PEBBLE_CMD="/gamemode creative;/equip diamond;/give diamond_sword;/perspective 1" \
PEBBLE_SHOT="/tmp/shot.png@300" swift run Pebble
```

Then read the PNG. Other hooks: `PEBBLE_BOT=1` (physics bot), `PEBBLE_PHOTOBOOTH=1`, `PEBBLE_NETDEBUG=1` (wire traces), `PEBBLE_PACKDEBUG=1`, `PEBBLE_PROF=1`.

## Multiplayer in one paragraph

Host-authoritative. The host runs the untouched simulation; every guest exists on the host as a puppet `Player` entity driven by ~20 Hz state messages, so mob AI, spawning, item magnets and combat need no special cases. Guest actions replay on the host through the normal Interact/Combat paths; resulting edits fan out as `setBlock` deltas via `WorldHooks.onBlockChanged`. Guests regenerate pristine terrain from the seed and fetch only *modified* chunks (the same VCK1 container the save DB uses), which is why joining is fast and why worldgen determinism is a hard requirement. Identity is a permanent UUID (`Settings.playerId`); servers key player data as `worldId#id:<pid>` so renames keep your stuff. Friend codes (`PEB1…`) are that identity in a shareable string — swapping codes over any chat app *is* the friend request, because Pebble has no central server.

## Gotchas already paid for

- **Re-arm TCP receives on the connection queue, not after the main-thread hop.** The original code lost throughput to one read per frame and dropped deltas during floods.
- **Gate guest message handling** on `joined && inWorld && game.netGuest === self` — messages queued around a disconnect crashed on `game.world`.
- **Host-bridge closures must compare `player === self.player`,** never `is Player`: LAN puppets otherwise open screens on the host.
- **`GameCore.player` is nil on dedicated servers.** Anything reachable from `serverTick` must handle that (this bit `processLightQueue`).
- **Pack item icons are not 16×16** (Faithful is 32×) — never hard-code sprite sizes.
- **After the π-yaw model flip, model +X is the player's left.** Sign errors here look like "the sword is inside the body".
- **Worldgen spawns extra mobs**, and pigs wander: e2e checks must watch *all* candidates and chase-then-swing, or they flake.
- **Test runs that crash leave `nettest-*` worlds in the real `pebble.db`** — that is why the hermetic data root exists; clean strays with `sqlite3` if you find them.
- **`setenv` is POSIX-only**; use `_putenv_s` on Windows (`import CRT`). `Dispatch` may need an explicit import on Windows.

## Session handoff

Sessions end when Xavi's tokens run out, often mid-task. Before that happens:

1. Push everything green.
2. Update the project memory (`~/.claude/projects/-Users-xavi/memory/pebble-lan-multiplayer.md`) with what landed, what is in flight (including CI runs still pending), and the exact next step.
3. Tell Xavi in Dutch what he can do next.

A new session should start by reading that memory, then `gh run list` to see how the last push ended.
