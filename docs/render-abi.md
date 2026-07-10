# Pebble render ABI (frozen — PORTING module 06)

Every render backend (Metal today, Vulkan next) consumes exactly these
bytes. Constants live in `Sources/PebbleCoreBase/Render/RenderABI.swift`;
the smoke suite pins them against real mesher/model output on every CI run.
All data is little-endian; matrices are column-major `float4x4` (16-byte
aligned, `float4`-only uniform structs — std140-compatible as written).

## Vertex streams

| Stream | Stride | Layout |
|---|---|---|
| Chunk sections | 28 B | `float3 pos @0`, `float2 uv @12`, `uint A @20`, `uint B @24` — indexed by `u32` |
| Entities/gear | 36 B | `float3 pos @0`, `float3 normal @12`, `float2 uv @24`, `float partIdx @32` |
| Particles (corner) | 8 B | `float2 corner @0` (per-vertex, shared quad) |
| Particles (instance) | 48 B | `float3 center @0`, `float4 uvRect @12`, `float size @28`, `float4 tint @32` |
| UI | 32 B | `float2 pos @0`, `float2 uv @8`, `float4 color @16` |
| Stars | 16 B | `float3 pos @0`, `float twinkle @12` |

### Chunk `A` word (LSB→MSB)
`tile[0..11]` atlas layer · `normal[12..14]` face 0–5 · `ao[15..16]` ·
`sky[17..20]` · `block[21..24]` · `emissive[25]`

### Chunk `B` word
`tint RGB [0..23]` (R high byte) · `animFrames[24..31]`

## Uniform structs (mirrored in `Sources/Pebble/Shaders.swift` MSL)

- `ChunkShared`: viewProj, shadowMat (float4x4), light, fog, fogColor, misc
  (float4 each) + 16-byte per-draw `float4 origin` at buffer(2)
- `EntityU`: viewProj, model, `parts[24]` (float4x4), light, misc, overlay,
  fogColor — parts palette indexed by vertex `partIdx`
- `SkyU`, `CelestialU`, `StarsU`, `CloudU`, `ParticleU`, `LineU`, `SpriteU`,
  `CompositeU`, `UltraU`, `UIU` — see Shaders.swift; float4/float4x4 members
  only, no scalars, so C/GLSL mirrors need no padding tricks.

## Textures & passes (Metal reference behavior)

- Terrain atlas: `texture2d_array`, rgba8Unorm, straight alpha, no sRGB
  conversion (bytes from the portable codecs go in untouched)
- Scene color: bgra8Unorm (LDR) / rgba16Float (HDR path, ultra, bloom)
- Depth: depth32Float; shadow map: depth-only pass with chunk stream
- Chunk pass buffers: vertex buffer(0), `ChunkShared` buffer(1),
  per-draw origin buffer(2); atlas texture(0) sampler(0), shadow map
  texture(1) sampler(1)
- Blending: sourceAlpha/oneMinusSourceAlpha (additive variant: dst = one)

Backend-specific projection conventions (depth range, Y flip) are NOT part
of this ABI — each backend proves them with its own screenshot baselines
(modules 07/08).
