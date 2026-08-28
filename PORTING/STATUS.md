# Windows port — where it stands

Living checklist for the Metal → Vulkan work. Update it as slices land; it is
the handoff note when a session ends mid-flight.

**How to verify without a Windows machine** (all of this runs on the Mac):

```bash
# the real #ifdef _WIN32 body of the Vulkan and audio backends
x86_64-w64-mingw32-gcc -c -o /tmp/v.o -I Sources/CPebbleVulkan/include Sources/CPebbleVulkan/pebvk.c
x86_64-w64-mingw32-gcc -c -o /tmp/a.o -I Sources/CPebbleAudio/include Sources/CPebbleAudio/pebaudio.c
# shaders + their push-constant block sizes (mirror these with _Static_assert)
glslangValidator -V --target-env vulkan1.0 -q -o /dev/null Sources/CPebbleVulkan/shaders/sky.vert
# the goldens
swift run -c release pebsmoke        # macOS, 613
swift run -c release pebsmokecore    # portable — what Windows CI runs, 578
```

`Sources/PebbleWin/*.swift` sits behind `#if os(Windows)` and never type-checks
on macOS. To check it, copy the file into a scratch .swift, strip the `#if`,
stub the C ABI, and:

```bash
D=.build/arm64-apple-macosx/debug
swiftc -typecheck -I $D/Modules \
  -Xcc -fmodule-map-file=$D/CCodecs.build/module.modulemap \
  -Xcc -fmodule-map-file=$D/CSQLite.build/module.modulemap scratch.swift
```

## Render passes

Metal has 15 real passes; Vulkan mirrors them one for one where ticked.

- [x] chunk (opaque / cutout / translucent)
- [x] entity — posed by the shared animator, with armour and held items
- [x] ui
- [x] sky dome
- [x] stars
- [x] celestial (sun + moon, procedural and pack art)
- [x] cloud
- [x] line (selection outline, blob shadows) — batched, one colour each
- [x] particle
- [x] sprite (item / projectile billboards)
- [x] viewmodel (first-person hand + held item)
- [x] shadow (depth-only pass over every section, 3x3 PCF in chunk.frag)
- [x] bloom_extract / blur / composite (offscreen scene target + half-res chain)
- [x] ultra / ultra_blur (SSAO + volumetrics)

`logo` and `title` have no Vulkan counterpart on purpose: the Windows title
screen draws its art through UI image quads instead.

## Other systems

- [x] audio (module 10) — synthesized engine shared, winmm waveOut sink
- [x] resource packs, in full: terrain, mob art, item icons, block icons,
      the GUI composite with its bitmap font, and the tint gate. The Windows
      client used to install only the terrain tiles.
- [x] terrain atlas, resource packs, sun/moon art
- [x] falling blocks / TNT, block-break crack overlay
- [x] entity animation (walk cycle, head turn, limb swing)
- [x] gear on entities (armour, held items on mobs and players)

## Startup, storage and crashes (1.3.0)

The renderer was never the whole port. Three things outside it were making
Windows feel like a different, less trustworthy game, and all three are fixed
in `WinStart.swift`:

- **Paths came off the working directory.** `PebbleData`, `assets\` and
  `pebble-log.txt` were all `currentDirectoryPath + "\..."`. That equals the
  exe's folder only when Explorer launches it; a shortcut, a terminal, a
  crash dialog's restart button, or running from inside the zip all give
  something else — and Pebble then made a second, empty data root and fell
  back to procedural textures. `exeDir()` (GetModuleFileNameW) is the anchor
  now, with `%LOCALAPPDATA%\Pebble` as the fallback when the exe's folder
  cannot be written to.
- **Nothing stopped two clients sharing one data root.** A hung window is
  still a live process, and the copy started beside it wrote the same worlds
  and settings. A named mutex over the data root — not over Pebble, so two
  clients with different `PEBBLE_DATA_DIR`s still both run — refuses the
  second and fronts the first.
- **A crash left no trace.** The log was opened with `"w"`, so the restart
  destroyed it; Swift's traps went to stderr, which went nowhere; and an
  unhandled exception closed the window in silence. The previous run is kept
  as `pebble-log-prev.txt`, stderr is `_dup2`'d onto the log, and
  `SetUnhandledExceptionFilter` writes the code, the address and what that
  code means before saying so in a dialog.

Two renderer defects came out of reading for crash causes. `make_buffer` left
half-built handles behind on its failure path, and `pb_vk_upload_section`
returned with its slot still marked free — so a failed chunk upload leaked,
under exactly the memory pressure that had made it fail. Both clean up now,
`maxMemoryAllocationCount` is logged next to the GPU name (a section costs
two allocations and that limit is 4096 on common hardware), and `WinHost`
reports the first failed upload instead of discarding the return value.

**None of this has run on Windows.** It compiles, and the C compiles under
mingw, but CI cannot press Alt+F4, fill a disk, or start Pebble twice. The
crash handler, the mutex and the AppData fallback are all still unproven.

## In progress / next

Nothing in the renderer. Every Metal pass has a Vulkan counterpart, and every
`GameHost` hook is implemented. `logo` and `title` have no Vulkan sibling on
purpose: the Windows title screen draws its art through UI image quads
instead.

What is left is the kind of thing only real hardware tells you — none of this
has run on a Windows machine, or an Intel Mac, yet. When it does, start with:

- the shadow map's orientation (the Y convention is subtle, see below),
- the ultra pass, which is the newest and least exercised,
- audio latency: waveOut with 512-frame buffers is about 43 ms, and if that
  feels late, WASAPI is the upgrade path,
- a Mac and a Windows player side by side on one seed, comparing screens —
  LAN codes make that setup a thirty-second job now, in either direction.

Every difference found so far was found by reading, not by running; that
method has stopped yielding, and the next one will not.

### How the differences were found

Worth recording, because the same sweep is repeatable:

1. Grep the Windows sources for symbols the Mac uses and Windows does not.
   That is how the resource-pack gaps surfaced — a pack installs seven
   things and Windows was taking one.
2. Grep the Vulkan shaders and the Windows client for comments that admit a
   divergence: "no fresnel", "for now", "later slice", "unlike the Mac".
   Code tends to confess. That found the water fudge and two stale claims.
3. Diff the two clients' per-frame call sequences against each other. That
   found the camera: Windows derived the eye from the player directly and so
   skipped view bobbing, third person and the front view, all of which live
   in the shared `camState`.
4. Check that a shared constant is actually *read* on both sides, not merely
   defined. `PACK_TINT_GATE` existed in the portable mesher and was left nil
   on Windows, which miscoloured 728 of 789 tiles.

## Conventions that bite

- Vulkan clip Y points down: every vertex shader ends with
  `gl_Position.y = -gl_Position.y`. The sky's inverse-viewProj undoes it on
  the way in instead.
- MSL allows `smoothstep(hi, lo, x)`; GLSL leaves `edge0 >= edge1` undefined.
  Write `1.0 - smoothstep(lo, hi, x)` — identical algebra, defined result.
- The terrain atlas is a 2D tile grid here, not a texture array (`fogColor.w`
  carries the column count). Anything sampling it needs the same cell maths.
- Per-frame streams are written before `pb_vk_frame` waits on the fence, so
  every setter calls `wait_frame_slot()` first.
- Entity geometry slots: 0..223 mobs and remote players, 224..255 viewmodel.
- Never compensate for a missing effect with a fudge factor. The Vulkan water
  was thickened 40% to stand in for an absent highlight, which made it differ
  from the Mac in the common case where the Mac has no highlight either. Port
  the effect or leave the gap visible; a fudge hides the difference from the
  next person to look.
- Take the camera from `camState`, never from the player. It carries view
  bobbing, the third-person pull-back with its block clipping, and the
  front-view flip. Deriving an eye position by hand silently drops all three.
- The Mac build must be universal. An arm64-only app does not run slowly on an
  Intel Mac, it does not launch at all — Rosetta translates x86 to arm, not
  the reverse. `pebble release` and the release workflow lipo both slices.
- Entity part matrices (24 per draw) ride a dynamic uniform buffer; entities
  have their own descriptor-set layout because the shared one cannot grow a
  binding without breaking chunk/UI/sprite/cloud/celestial.
- The post chain is best-effort: if the offscreen targets fail to build,
  `g_postOK` stays 0 and the frame draws straight into the swapchain, exactly
  as it did before that slice. A missing bloom beats a black window.
- Terrain has its own descriptor-set layout too (atlas, shadow map, and the
  sun's matrix in a dynamic uniform). The particle pass samples the same
  atlas through the plain layout, so the atlas has two sets.
- Anything over 128 bytes cannot be a push constant. Three blocks hit this:
  the entity rig (24 matrices), the sun's matrix, and the ultra block. All
  three ride dynamic uniform buffers with one slot per frame in flight.
- The shadow map DOES need the Y flip on lookup. `shadow.vert` applies the
  clip-Y flip on the way in, but the varying handed to `chunk.frag` is the
  unflipped `shadowMat * world`, so the map coordinate is
  `v = 0.5 - sp.y*0.5`. MSL reaches the same expression via
  `suv.y = 1.0 - suv.y`. Get it backwards and every shadow is mirrored
  vertically — which looks plausible until you walk past a wall.

## Fixed along the way

`pebsmoke` used to fail `puppet damage reaches guest` about one run in ten.
It was not a timing race: the host mirrors a guest's reported health onto its
puppet, then read that mirror back as fresh damage and sent it to the guest,
which lowered its health, reported it, and went round again — a point per
tick until the guest died from a single scratch. `applyGuestState` now moves
the watermark down with the report, and `guest damage does not echo` in the
LAN block pins it (that check fails 12 runs out of 12 with the fix removed).
