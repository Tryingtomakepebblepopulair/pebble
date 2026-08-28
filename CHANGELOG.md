# Changelog

All notable changes to Pebble. Versions follow `MAJOR.MINOR.PATCH`; the
in-app version string comes from `PEBBLE_VERSION` (PebbleCore/Game/Saves.swift).

## 1.3.0 — 2026-08-28 — LAN codes, and a Windows that remembers

### Playing together got one step

- **LAN codes.** Open a world to LAN and the pause menu hands you twelve
  characters: `Copy code: 18A2-NBZ6-VCQ2`. Read them out, or paste them into
  any chat app. Whoever you send them to opens *Multiplayer* → *Join By
  Code*, types them, and is in. **Mac to Windows, Windows to Mac, between
  people who have never met** — no friend codes to swap first, no accounts,
  no server in between, and no IP address to read out digit by digit. Macs
  still find each other automatically over Bonjour as well; the code is the
  route that exists on every platform, which is why it is now the first thing
  on the LAN tab.
- The code carries the host's address, so the same twelve characters also
  reach a port-forwarded `pebble serve` world.
- Mistype it and Pebble says so instead of connecting you to a stranger's
  computer and timing out: twelve check bits ride along, and every possible
  single-character typo is rejected. The alphabet has no I, L, O or U in it
  at all, and typing lowercase, dropping the dashes or adding spaces is fine.

### Finding each other actually works on Windows now

- **Windows can see games on the network.** It never could: discovery was
  Bonjour, Bonjour is Apple's, and so the LAN Games list on Windows was
  permanently, silently empty — a Windows player's only route in was typing
  an IP address. A host now also announces itself with a small UDP broadcast
  that both platforms speak, so open a world to LAN and it simply appears in
  the other person's list, Mac or Windows, and they click it.
- **You are no longer stuck showing as offline.** A friend counts as online
  when a discovered game carries their id — and with no discovery on Windows,
  nobody there was ever online, in either direction. Presence works both ways
  now.
- The LAN code still works and is still the answer when the network itself is
  in the way (guest wifi, a firewall that swallows broadcasts, or two
  different networks).
- **If Windows never asked whether Pebble may use the network, nobody can
  reach you.** The download's LEES-MIJ now says so, and says where to turn it
  on afterwards — Windows Security → Firewall → Allow an app.

### Windows: sprinting, and the view

- **Sprinting looks like sprinting again.** The field of view was pinned at
  70° on Windows, so the FOV kick that vanilla uses to tell you you're
  sprinting — and the one for elytra, and the zoom while drawing a bow — did
  nothing at all. It comes from the shared camera now, like on the Mac.
- **The FOV slider in Options works on Windows.** Same cause; it had been
  ignored entirely.
- **Surfaces should stop shimmering.** The far clip plane was fixed at 800
  blocks against a near plane of 0.05, which spends the depth buffer on
  distance nobody can see and leaves too little precision up close. It follows
  the render distance now, exactly as on the Mac.

### Windows: your worlds stay put

- **Pebble no longer loses its worlds when you start it a different way.**
  Worlds, settings, the texture pack and the log were all looked up relative
  to wherever Windows happened to think you were, rather than to Pebble.exe
  itself. Launch from a shortcut, from a terminal, or from the restart button
  on a crash dialog, and Pebble quietly built a second, empty `PebbleData`
  and fell back to the plain textures — a game that appeared to have
  forgotten everything and changed how it looked. Everything now hangs off
  the exe, wherever it is started from.
- If the folder holding Pebble.exe cannot be written to — Program Files, a
  network drive, the temporary folder Windows uses when you run straight from
  the zip — worlds go to `%LOCALAPPDATA%\Pebble` instead of failing silently.
- **Two Pebbles at once no longer scramble each other's saves.** A frozen
  window is usually still a running program, and the copy you start next to
  it writes the same worlds and settings; whichever closed last won. Starting
  a second copy now brings the first one to the front instead. (Two clients
  with different `PEBBLE_DATA_DIR`s still both run — that is how LAN gets
  tested on one machine.)

### Windows: when it does crash, it says so

- **A crash writes down what happened** — the fault, where it was, and what
  that means — and shows it, instead of the window simply vanishing.
- **The log of the crash survives the restart.** `pebble-log.txt` was wiped
  on every launch, and the first thing anyone does after a crash is start the
  game again, so the evidence went first. The previous run is now kept as
  `pebble-log-prev.txt`. Swift's own error messages, which went nowhere at
  all, are captured into the log too.
- **Two real leaks fixed in the renderer.** When a chunk's GPU buffers failed
  to allocate, the half-built ones were abandoned rather than released —
  which made the memory pressure that caused the failure steadily worse. The
  driver's allocation limit is now in the log next to your GPU's name, and a
  chunk that fails to upload says so rather than leaving a silent hole in the
  world.
- **A save file that will not open no longer kills the game on the spot.**
  Pebble explains which folder is the problem, and keeps running unsaved
  rather than disappearing before it draws a single frame.

### Everywhere

- **The font can draw its own punctuation now.** Every dash, ellipsis and
  status dot in the game had been coming out as a question mark — ninety-odd
  of them, including the ✕ that removes a friend and the ● that says whether
  one is online.

## 1.2.4 — 2026-08-26 — the camera, and water

- **Third-person view works on Windows.** F5 was not even wired up as a key,
  and the camera was taken straight off the player rather than from the
  shared camera, so it could not have pulled back anyway. Now F5 cycles
  through the three views exactly as on the Mac, your own body is drawn when
  the camera is behind you, and the hand disappears when it should.
- **View bobbing** works on Windows for the same reason — it lives in that
  shared camera and was being skipped.
- **Water matches.** The Windows renderer had been thickening water by 40% to
  make up for a missing highlight, which made it heavier than the Mac's. The
  real effect — the sun's glint and the glancing-angle sheen, under the ultra
  preset — is ported now, and the fudge is gone.

## 1.2.3 — 2026-08-26 — Intel Macs

- **The Mac download now runs on Intel Macs too.** It was built for Apple
  silicon only, and an arm64 app does not merely run slowly on an Intel Mac —
  it will not start at all, because Rosetta translates Intel code to Apple
  silicon and not the other way round. The release is a universal binary now,
  so both kinds of Mac run the same download. macOS 14 Sonoma or newer either
  way; on Intel that means a 2018 or later model.
- `pebble release` builds the universal binary too. A plain `pebble install`
  still builds only for your own machine, which is quicker.

## 1.2.2 — 2026-08-26 — Windows looks like the Mac

A hunt for anything that still rendered differently on the two platforms. A
resource pack installs seven things; the Windows client was taking one.

- **The world was the wrong colour.** Pack tiles come pre-coloured, so only a
  handful — grass, leaves, water — should still get the biome tint painted on
  top. macOS knew which; Windows did not, and tinted 728 of 789 tiles that
  the pack had already coloured.
- **The interface is the pack's again.** Menus, containers, the inventory and
  the bitmap font were all drawn from the built-in procedural art on Windows
  while macOS showed the pack's, right down to the letter spacing.
- **Item icons** — swords, tools, everything in your hotbar — now come from
  the pack on Windows too, instead of the hand-drawn fallbacks.
- **Block icons** in the inventory likewise.

Everything above already existed in shared code; it simply was never wired up
on the Windows side. The loaders now live in the core, so a pack behaves the
same on both platforms, and new checks cover the tint gate, the icon sheet,
the GUI composite and the font metrics.

## 1.2.1 — 2026-08-26 — mobs get their missing limbs back

- **Twenty-seven mob parts were invisible.** Hoglins and zoglins walked around
  on nothing — all four legs on both. Ghasts had none of their nine tentacles,
  vexes and allays were each missing an arm, and the camel's tail, the
  axolotl's tail, the tadpole's tail, the cod's tail and top fin, the allay's
  wings and the tropical fish's side fins were all gone too.
  The rigs and the animation were fine the whole time: each part was drawn
  correctly, at a spot on its texture sheet that nothing had painted, so it
  came out fully transparent. Two causes — a handful of paints simply used the
  wrong coordinates, and every flat part (a fin, a wing, a tail) has its
  visible faces offset down the sheet, which the paints did not account for.
- **Mobs on Windows now use the resource pack's artwork**, the way macOS
  always has. Until now the Windows client fell back to the built-in
  procedural skins, so the same creeper genuinely looked different on the two
  platforms.
- Both fixes live in the shared core, so the two platforms move together.
  A new check walks every rig on every mob and fails if any part would render
  fully transparent — the kind of bug that is invisible to every other test,
  because nothing errors: the geometry is right, the animation is right, and
  the frame draws fine.

## 1.2.0 — 2026-08-25 — Windows

- **Pebble runs on Windows.** Download `Pebble-Windows.zip` from the
  [releases page](../../releases/latest), unzip it anywhere, run `Pebble.exe`.
  Nothing to install: the Swift runtime travels with it. It is the same game,
  not a cut-down port — the same worldgen from the same seeds, the same mobs,
  the same LAN and SMP multiplayer, and worlds that are bit-identical to the
  Mac's. A Windows player and a Mac player can share a world.
  Both platforms warn once on first launch because neither build is signed;
  every download ships a text file with the one click that gets past it.
- **The Windows renderer is finished.** The Vulkan backend went from three
  passes to fifteen and now matches Metal one for one: the sky dome with
  stars, sun and moon and drifting clouds; particles; dropped items; the
  block-selection outline; soft shadows under mobs; sun shadows across the
  terrain; the first-person hand and whatever it is holding; mobs that
  actually walk, turn their heads and wear their armour; and the full post
  chain — bloom, tonemapping, and the ultra preset's ambient occlusion and
  god rays.
- **Sound on Windows.** Pebble synthesizes every effect from oscillators
  rather than shipping audio files, so Windows gets the identical engine —
  same footsteps, same creeper hiss, same cave reverb, same generative music
  and jukebox discs.
- **Guests no longer bleed to death in multiplayer.** A guest who took any
  damage at all — one heart from a fall, a single hit — would keep losing a
  heart per tick until they died, because the host was reading its own mirror
  of their health back to them as fresh damage. This affected real games, not
  just the test suite.
- **Clouds are clouds again** on both platforms. The cloud mask was sampled
  through a clamp-to-edge sampler, so everything past the first twelfth of the
  sky was a smear of one row of pixels stretched to the horizon.
- **Jukebox discs start on time.** A disc schedules around 600 notes up front
  and the voice limit was evicting the oldest — which are the ones due to play
  — leaving the first ~23 seconds silent.
- **Easier to share.** `pebble release` builds a signed, notarized zip when a
  Developer ID is configured, `pebble fix` unblocks a downloaded app macOS has
  quarantined, and pushing a version tag makes CI build and publish both
  platforms by itself.

## 1.1.0 — 2026-07-02 — multiplayer (LAN + servers + friends), custom skins, speed slider

- **LAN multiplayer.** Play together on the same WiFi: the host presses
  Esc → *Open to LAN* in any world, friends pick *Multiplayer* on the title
  screen — no setup, worlds are discovered automatically (Bonjour). The host
  runs the real world; guests stream it live. Building, mining, combat, item
  pickup/drops, chat, day/night and weather all sync. Guests regenerate
  untouched terrain from the world seed, so joining is fast even on big
  worlds — only edited chunks travel over the wire. Covered by a full
  host+guest protocol/e2e test suite; singleplayer simulation is
  bit-identical to 1.0.3 (goldens unchanged).
  Known limits (for now): guests can't use the Nether/End portals, containers
  opened by guests don't live-sync, and commands are host-only.
- **Standalone servers (SMP).** `pebble serve --create "My SMP"` runs a world
  headless at 20 TPS with no host player — it stays up as long as the machine
  does. LAN players find it under Multiplayer automatically; internet players
  add its address under Multiplayer → *Servers* (port-forward 25585 on the
  server's router). Console commands: `list`, `say`, `save`, `stop`; Ctrl-C
  saves and exits cleanly.
- **Player identity + friends.** Every player gets a permanent random id
  minted on first launch (names can change, the id can't) — servers key
  inventories/positions by it, so renaming yourself keeps your stuff.
  Multiplayer → *Friends* lists your friends with live presence (online +
  one-click Join when their game is visible on the network) and *Recent
  Players* — everyone you've shared a world with — promotable to friends
  with one click. No accounts, no cloud: friends live in a local JSON.
- **Friend codes.** Multiplayer → Friends → *Copy My Code* gives you a short
  "PEB1…" code carrying your permanent identity. Swap codes over any chat app
  and paste with *Add By Code* — that's the whole friend request + accept,
  no world needed, no central servers involved.
- **Custom skins.** Title screen → *Skins…*: load any standard 64×64
  Minecraft skin PNG, save the current skin as a template to draw on, or go
  back to Steve. The second skin layer (hats/jackets) is baked onto the model.
- **Visible gear.** Worn armor now shows on player bodies (all six materials,
  real pack textures, following every walk/swing animation), held items render
  in hands as 3D extruded sprites with the vanilla edge-forward tilt, shields
  strap to the arm and raise when blocking — in third person and on every
  player in multiplayer (armor + offhand sync over the wire). Plus a proper
  first-person view: your arm (in your own skin) or held item swings, eats,
  draws bows and blocks in the bottom-right, vanilla-style.
- **Speed multiplier.** Options → Accessibility: run the whole simulation at
  0.5×–3× (singleplayer only; LAN worlds share one clock).

## 1.0.3 — 2026-06-27 — gameplay bug fixes (#11)

- **Mobs can no longer be hit while dying, and no longer dupe their drops.**
  A mob's death was processed every tick it kept taking damage during the
  ~1s death animation, re-running its loot drop (and slime splits / raid
  `bad_omen`) each time. Damage is now rejected once an entity enters its
  death animation, so loot drops exactly once. Re-baselined the entity goldens.
- **Tree leaves now drop saplings, sticks and apples when they decay.** Leaf
  decay destroyed the block without rolling its drop table; it now uses the
  normal natural-break path, matching what hand-breaking already dropped.
- **Beds now show a sleep overlay.** Sleeping faded straight to a frozen frame
  with no feedback; the screen now fades to black with a "Sleeping…" prompt,
  and Sneak/Esc leaves the bed.
- **Entities now cast a contact shadow.** A soft dark disc is projected onto
  the ground beneath living entities — including your own player in third
  person — and fades out as they rise off the ground.
- **The offhand can now use items, and shields block.** The use action falls
  back to the offhand when the main hand does nothing (food, shields, torches,
  throwables, …), and raising a shield now negates frontal melee, projectile
  and explosion damage.

## 1.0.2 — 2026-06-13 — bug fixes

- **Fixed `./pebble install` failing to compile on Swift 6.2.x.** The
  smooth-lighting arithmetic in `Mesher.swift` (plus a few other expressions)
  overran the Swift type-checker's budget and tripped integer-vs-`Double`
  inference, breaking the build partway through `./pebble install`. The
  expressions are now broken into single-operation typed locals; Pebble builds
  cleanly on every Swift 6.0–6.3 toolchain. Worldgen/mesh output is unchanged.
  This completes the #1 fix that 1.0.1 only partially addressed.
- **Fixed over-dark lighting in pits, holes and undersides.** Smooth lighting
  averaged in the zero skylight of solid neighbours, so the walls and floor of
  a freshly-dug hole rendered far darker than they should in daylight. Opaque
  neighbours now contribute the face light (standard vanilla smooth lighting);
  ambient occlusion still shades the corners. Re-baselined the mesh goldens.
- **The installer now checks your Swift version up front.** `./pebble install`
  needs Swift 6.0+; if you're below that it explains the fix and can install a
  current toolchain for you (via swiftly) instead of failing partway through a
  build.

## 1.0.1 — 2026-06-13 — minor bug fixes

- **Fixed a build failure on newer toolchains.** A literal-arithmetic
  expression in `Mesher.swift` overran the Swift type-checker's budget on some
  toolchains (e.g. Swift 6.2.3 / Xcode 26.3, M-series), making `./pebble
  install` fail to compile. The expressions are now hoisted into typed locals;
  worldgen/mesh output is byte-identical.
- **Fixed entity facing.** Mobs and the third-person player were rendered
  rotated by `-yaw` instead of the Minecraft `180° - yaw` convention, so they
  faced (and appeared to walk) backward. Render-side only.

## 1.0.0 — 2026-06-11 — first public beta

**This is a beta.** The engine is pinned by 456 golden checks, but a game of
this scope certainly has bugs we haven't found yet. Reports and fix PRs are
incredibly welcome: https://github.com/thebriangao/pebble/issues (the README
lists what to include).

The initial release. What ships:

- **A complete, native block-survival game for macOS** — ~45,000 lines of
  Swift + Metal, zero external dependencies, no game engine, no .xcodeproj.
- **Content**: 879 blocks, 1,188 items, 63 biomes, 100 entity types (55+ mobs
  with goal-based AI and A* pathfinding), 19 structure types (30+ variants), 39 enchantments,
  full brewing/enchanting/smithing/stonecutting/archaeology systems,
  advancements, raids, and villager trading.
- **Three dimensions** with working portals and full progression: overworld →
  nether (fortresses, bastions) → end (dragon fight, end cities, gateways),
  plus the Wither and the Warden.
- **Worldgen**: multi-noise climate sampling, spline terrain, 3D density caves,
  ravines, aquifers, vanilla-1.20 ore tables, snow lines, cave biomes
  including the deep dark.
- **Redstone**: wire networks, repeaters, comparators with container reading,
  pistons with quasi-connectivity, observers, hoppers, rails, sculk sensors.
- **Vanilla-exact player physics**, verified by independent derivations in the
  test suite (walk 4.317 b/s, sprint 5.612 b/s, jump apex 1.2522 blocks).
- **Synthesized audio**: every sound and all music generated in real time
  from oscillator recipes — zero audio files.
- **Faithful 32x textures built in** (self-restoring, credited, license
  included) — atlas art, `.mcmeta` animations, GUIs, fonts, entity skins,
  and sun/moon, loaded through Pebble's own zip reader. **Ultra graphics**:
  a built-in enhanced pipeline (SSAO, volumetric light, soft shadows, ACES).
- **Persistence**: single SQLite database (WAL) holding worlds, chunks
  (compact binary records), players, and advancements.
- **Quality**: 456 golden regression checks, all green; the engine is fully
  deterministic — identical seeds produce identical worlds on any machine,
  across releases; the build is warning-free; 200+ fps at full fancy settings
  on an Apple-silicon MacBook Air, ~2–4 s world loads.

### Known limitations

- Singleplayer only, for now — there is no networking code in 1.0.0.
- Elytra flight omits vanilla's dive-redirect term (look-pitch speed transfer);
  flight feel is otherwise vanilla-derived.
- Armor trims show in tooltips but not yet on worn armor.
- No resource-pack or shader-pack loading — the Faithful art and the ultra
  pipeline are built in; user-supplied packs are not a feature.
