// The frozen renderer ABI (PORTING module 06): every backend — the shipping
// Metal renderer and the coming Vulkan one — consumes exactly these bytes.
// Human-readable spec: docs/render-abi.md. Change ONLY with a deliberate,
// reviewed regold of the mesh goldens and both backends' pipelines.

public enum RenderABI {
    // chunk sections (opaque / cutout / translucent + shadow pass)
    public static let chunkVertexStride = 28          // bytes
    public static let chunkVertexWords = 7            // UInt32 words per vertex
    public static let chunkPosOffset = 0              // float3
    public static let chunkUVOffset = 12              // float2
    public static let chunkAOffset = 20               // uint packed (see bits below)
    public static let chunkBOffset = 24               // uint packed
    public static let chunkIndexBytes = 4             // UInt32 indices
    // A word bit layout (LSB first)
    public static let aTileBits = 0..<12              // atlas layer index
    public static let aNormalBits = 12..<15           // face normal 0..5
    public static let aAOBits = 15..<17               // ambient occlusion 0..3
    public static let aSkyBits = 17..<21              // sky light 0..15
    public static let aBlockBits = 21..<25            // block light 0..15
    public static let aEmissiveBit = 25
    // B word: tint RGB in bits 0..23, animation frame count in 24..31
    public static let bTintBits = 0..<24
    public static let bAnimBits = 24..<32

    // entities / gear / held items (EntityModels output)
    public static let entityVertexStride = 36         // bytes = 9 float32
    public static let entityVertexFloats = 9          // pos3, normal3, uv2, partIdx
    public static let entityMaxParts = 24             // parts[] palette in EntityU

    // particles: quad corners + per-instance stream
    public static let particleCornerStride = 8        // float2
    public static let particleInstanceStride = 48     // float3 center, float4 uvRect, float size, float4 tint
    public static let particleCenterOffset = 0
    public static let particleUVRectOffset = 12
    public static let particleSizeOffset = 28
    public static let particleTintOffset = 32

    // UI batch (screens, HUD, text)
    public static let uiVertexStride = 32             // float2 pos, float2 uv, float4 color
    public static let uiPosOffset = 0
    public static let uiUVOffset = 8
    public static let uiColorOffset = 16

    // night sky
    public static let starsVertexStride = 16          // float3 pos, float twinkle
}
