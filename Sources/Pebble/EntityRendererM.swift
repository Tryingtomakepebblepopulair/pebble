// Entity drawing — Builds one vertex buffer
// + skin texture per model, computes per-part pose matrices from the animator
// profiles, draws with the entity pipeline.

import Foundation
import Metal
import simd
import PebbleCore

struct EntityUniforms {
    var viewProj: simd_float4x4
    var model: simd_float4x4
    // 24 slots — the ender dragon's rig needs more than the old 16
    var parts: (simd_float4x4, simd_float4x4, simd_float4x4, simd_float4x4, simd_float4x4,
                simd_float4x4, simd_float4x4, simd_float4x4, simd_float4x4, simd_float4x4,
                simd_float4x4, simd_float4x4, simd_float4x4, simd_float4x4, simd_float4x4, simd_float4x4,
                simd_float4x4, simd_float4x4, simd_float4x4, simd_float4x4, simd_float4x4,
                simd_float4x4, simd_float4x4, simd_float4x4)
    var light: SIMD4<Float>     // sky, block, dayLight, gamma
    var misc: SIMD4<Float>      // ambient, alpha, fogStart, fogEnd
    var overlay: SIMD4<Float>
    var fogColor: SIMD4<Float>
}

final class ModelGPU {
    let vb: MTLBuffer
    let count: Int
    let texture: MTLTexture
    let model: MobModel

    init(vb: MTLBuffer, count: Int, texture: MTLTexture, model: MobModel) {
        self.vb = vb
        self.count = count
        self.texture = texture
        self.model = model
    }
}

final class EntityRendererM {
    let device: MTLDevice
    private var geoms: [String: ModelGPU] = [:]
    var partMats = [simd_float4x4](repeating: matrix_identity_float4x4, count: 24)
    /// armor overlays keyed "armor:<piece>:<material>" (GearRenderM)
    var gearGeoms: [String: ModelGPU] = [:]
    /// extruded held-item meshes keyed by item id / "shield" (GearRenderM)
    var itemGeoms: [String: ModelGPU] = [:]

    init(device: MTLDevice) {
        self.device = device
    }

    /// resource-pack swap: rebuild skins (geometry is rebuilt with them)
    func resetSkins() {
        geoms.removeAll()
        gearGeoms.removeAll()
        itemGeoms.removeAll()
    }

    func geom(_ name: String, cacheKey: String? = nil, skinPNG: Data? = nil) -> ModelGPU {
        let key = cacheKey ?? name
        if let g = geoms[key] { return g }
        let resolved = hasModel(name) ? name : "pig"
        let built = buildEntityGeometry(resolved)
        let vb = built.verts.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: max(1, $0.count))! }
        // pack entity texture when the model's UV layout matches vanilla and the
        // image proportions agree; otherwise the procedural skin
        var skinW = built.skin.w, skinH = built.skin.h
        var pixels = built.skin.data
        if let blob = skinPNG, let img = decodePNG(blob),
           img.width * built.model.texH == img.height * built.model.texW {
            // another player's custom skin (traveled in hello/playerJoin)
            skinW = img.width
            skinH = img.height
            pixels = img.pixels
        } else if resolved == "player", let img = customPlayerSkin() {
            skinW = img.width
            skinH = img.height
            pixels = img.pixels
        } else if let img = packEntityImage(built.model.packTex, stack: built.model.packTexStack,
                                     tints: built.model.packTexTints),
           img.width * built.model.texH == img.height * built.model.texW {
            skinW = img.width
            skinH = img.height
            pixels = img.pixels
        } else if ProcessInfo.processInfo.environment["PEBBLE_PACKDEBUG"] != nil {
            let why = built.model.packTex.isEmpty ? "no packTex mapping" : "pack image missing or proportions mismatch"
            print("[packs] PROCEDURAL skin for model \(resolved): \(why)")
            fflush(stdout)
        }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                          width: skinW, height: skinH, mipmapped: false)
        td.usage = .shaderRead
        let tex = device.makeTexture(descriptor: td)!
        pixels.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake2D(0, 0, skinW, skinH), mipmapLevel: 0,
                        withBytes: raw.baseAddress!, bytesPerRow: skinW * 4)
        }
        let g = ModelGPU(vb: vb, count: built.vertexCount, texture: tex, model: built.model)
        if ProcessInfo.processInfo.environment["PEBBLE_GEOM_DEBUG"] != nil {
            print("[geom] \(name): \(built.model.parts.count) parts, \(built.vertexCount) verts")
            fflush(stdout)
        }
        geoms[key] = g
        return g
    }

    /// compute per-part matrices by animator profile
    func pose(_ g: ModelGPU, _ p: EntityPose, _ time: Double) {
        // the animator itself is shared with the Vulkan client
        let mats = pebPoseParts(g.model, p, time)
        for i in 0..<24 { partMats[i] = simd_float4x4(mats[i]) }
    }

    func draw(_ enc: MTLRenderCommandEncoder, pipeline: MTLRenderPipelineState, sampler: MTLSamplerState,
              viewProj: simd_float4x4, camPos: SIMD3<Double>, name: String, p: EntityPose,
              time: Double, dayLight: Double, fog: (color: SIMD3<Float>, start: Float, end: Float),
              gamma: Double, ambient: Double, cacheKey: String? = nil, skinPNG: Data? = nil) {
        let g = geom(name, cacheKey: cacheKey, skinPNG: skinPNG)
        pose(g, p, time)
        var m = matrix_identity_float4x4
        m = mTranslate(m, Float(p.x - camPos.x), Float(p.y - camPos.y), Float(p.z - camPos.z))
        // models are built MC-style facing -Z; vanilla renders them rotated by
        // (180° - yaw) so the -Z front ends up pointing along the entity's yaw.
        // Without the 180° the whole bestiary (and 3rd-person player) moonwalks.
        m = mRotateY(m, Float(.pi - p.yaw))
        let sc = Float(p.scale * g.model.scale * (p.baby ? 0.5 : 1))
        m = mScale(m, sc, sc, sc)

        var u = EntityUniforms(
            viewProj: viewProj,
            model: m,
            parts: (partMats[0], partMats[1], partMats[2], partMats[3], partMats[4], partMats[5], partMats[6],
                    partMats[7], partMats[8], partMats[9], partMats[10], partMats[11], partMats[12], partMats[13],
                    partMats[14], partMats[15], partMats[16], partMats[17], partMats[18], partMats[19],
                    partMats[20], partMats[21], partMats[22], partMats[23]),
            light: SIMD4<Float>(Float(p.sky), Float(p.block), Float(dayLight), Float(gamma)),
            misc: SIMD4<Float>(Float(ambient), Float(p.alpha), fog.start, fog.end),
            overlay: SIMD4<Float>(1, 0.2, 0.2, Float(p.hurtFlash * 0.5)),
            fogColor: SIMD4<Float>(fog.color.x, fog.color.y, fog.color.z, 1))
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(g.vb, offset: 0, index: 0)
        enc.setVertexBytes(&u, length: MemoryLayout<EntityUniforms>.stride, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<EntityUniforms>.stride, index: 1)
        enc.setFragmentTexture(g.texture, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: g.count)
    }
}
