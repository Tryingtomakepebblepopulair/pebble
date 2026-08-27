// Gear rendering — worn armor overlays, held items and shields on player
// models (third person + other players in multiplayer). Armor pieces are
// separate biped-part models posed by the same name-based animator as the
// body, so they follow every walk/swing/sneak motion for free. Held items
// are extruded 16×16 icon sprites (one tiny cube per opaque pixel face)
// attached to the posed arm matrices. Nothing here touches the frozen model
// registry: gear geometry is built through buildEntityGeometry(from:).

import Foundation
import Metal
import simd
import PebbleCore

extension EntityRendererM {
    // =========================================================================
    // shared: EntityGeometry + explicit pixels → ModelGPU
    // =========================================================================
    private func makeGPU(_ built: EntityGeometry, _ pixels: [UInt8], _ w: Int, _ h: Int) -> ModelGPU? {
        guard !built.verts.isEmpty else { return nil }
        let vb = built.verts.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: max(1, $0.count)) }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                          width: w, height: h, mipmapped: false)
        td.usage = .shaderRead
        guard let vb, let tex = device.makeTexture(descriptor: td) else { return nil }
        pixels.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                        withBytes: raw.baseAddress!, bytesPerRow: w * 4)
        }
        return ModelGPU(vb: vb, count: built.vertexCount, texture: tex, model: built.model)
    }

    // =========================================================================
    // armor overlays
    // =========================================================================
    /// vanilla armor texture material for a worn stack ("golden_helmet" → "gold")
    private func armorGeom(_ piece: Int, _ mat: String) -> ModelGPU? {
        let key = "armor:\(piece):\(mat)"
        if let g = gearGeoms[key] { return g }
        let model = pebArmorModel(piece, mat)
        let built = buildEntityGeometry(from: model, skinName: key)
        // vanilla armor sheets are 64×32; leather is grayscale + tinted, with
        // an untinted overlay on top
        let layer = piece == 2 ? "2" : "1"
        var rels = ["models/armor/\(mat)_layer_\(layer).png"]
        var tints: [Int] = []
        if mat == "leather" {
            rels.append("models/armor/leather_layer_\(layer)_overlay.png")
            tints = [0x8a5a33, 0xFFFFFF]
        }
        var pixels = built.skin.data
        var w = built.skin.w, h = built.skin.h
        if let img = packEntityImage(rels, tints: tints), img.width * 32 == img.height * 64 {
            pixels = img.pixels
            w = img.width
            h = img.height
        }
        guard let g = makeGPU(built, pixels, w, h) else { return nil }
        gearGeoms[key] = g
        return g
    }

    // =========================================================================
    // held items — extruded icon sprites
    // =========================================================================
    /// one thin textured slab per opaque icon pixel face; no shader tricks,
    /// works with any pipeline. 16 px = 1 model unit, grip scaled at draw time.
    private func itemGeom(_ stack: ItemStack) -> ModelGPU? {
        let key = "item:\(stack.id):\(stack.data.potion ?? "")"
        if itemDef(stack.id).name == "shield" { return shieldGeom() }
        if let g = itemGeoms[key] { return g }
        guard let built = pebItemGeometry(stack),
              let g = makeGPU(built.geom, built.tex, built.geom.skin.w, built.geom.skin.h)
        else { return nil }
        itemGeoms[key] = g
        return g
    }

    /// simple board shield (planks + iron boss), procedural texture
    private func shieldGeom() -> ModelGPU? {
        if let g = itemGeoms["shield"] { return g }
        let built = buildEntityGeometry(from: pebShieldModel(), skinName: "shield")
        guard let g = makeGPU(built, built.skin.data, built.skin.w, built.skin.h) else { return nil }
        itemGeoms["shield"] = g
        return g
    }

    // =========================================================================
    // draw pass — call straight after draw() for a player entity, while
    // partMats still holds that player's pose
    // =========================================================================
    func drawPlayerGear(_ enc: MTLRenderCommandEncoder, pipeline: MTLRenderPipelineState, sampler: MTLSamplerState,
                        viewProj: simd_float4x4, camPos: SIMD3<Double>, player: Player, p: EntityPose,
                        time: Double, dayLight: Double, fog: (color: SIMD3<Float>, start: Float, end: Float),
                        gamma: Double, ambient: Double) {
        // the arms the held items ride come from partMats, which still holds
        // this player's body pose — pebPlayerGear takes the whole rig below
        var base = matrix_identity_float4x4
        base = mTranslate(base, Float(p.x - camPos.x), Float(p.y - camPos.y), Float(p.z - camPos.z))
        base = mRotateY(base, Float(.pi - p.yaw))
        let sc = Float(p.scale)
        base = mScale(base, sc, sc, sc)

        func submit(_ g: ModelGPU, _ modelM: simd_float4x4, _ mats: [simd_float4x4]) {
            var u = EntityUniforms(
                viewProj: viewProj,
                model: modelM,
                parts: (mats[0], mats[1], mats[2], mats[3], mats[4], mats[5], mats[6],
                        mats[7], mats[8], mats[9], mats[10], mats[11], mats[12], mats[13],
                        mats[14], mats[15], mats[16], mats[17], mats[18], mats[19],
                        mats[20], mats[21], mats[22], mats[23]),
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

        // every piece and every matrix comes from the shared gear list, so
        // the Vulkan client hangs the same sword off the same wrist
        let bodyParts = partMats.map { Mat4f($0) }
        for piece in pebPlayerGear(player, pose: p, bodyParts: bodyParts, time: time) {
            let g: ModelGPU?
            switch piece.geom {
            case .held(let s): g = itemGeom(s)
            case .armor(let idx, let material): g = armorGeom(idx, material)
            }
            guard let g else { continue }
            submit(g, base, piece.parts.map { simd_float4x4($0) })
        }
    }

    // =========================================================================
    // first-person viewmodel — bare arm or held item in the bottom-right,
    // with swing / eat / draw / block animations (vanilla feel)
    // =========================================================================
    /// bare right arm textured with the current player skin
    private func fpArmGeom() -> ModelGPU? {
        if let g = itemGeoms["fp_arm"] { return g }
        let model = pebFirstPersonArmModel()
        let built = buildEntityGeometry(from: model, skinName: "fp_arm")
        guard let vb = built.verts.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: max(1, $0.count)) })
        else { return nil }
        // share the live player texture (custom skins included)
        let g = ModelGPU(vb: vb, count: built.vertexCount, texture: geom("player").texture, model: model)
        itemGeoms["fp_arm"] = g
        return g
    }

    func drawFirstPerson(_ enc: MTLRenderCommandEncoder, pipeline: MTLRenderPipelineState, sampler: MTLSamplerState,
                         proj: simd_float4x4, player: Player, timeSec: Double, dayLight: Double,
                         skyL: Int, blockL: Int, gamma: Double, ambient: Double) {
        func submit(_ g: ModelGPU, _ m: simd_float4x4) {
            var u = EntityUniforms(
                viewProj: proj,
                model: m,
                parts: (matrix_identity_float4x4, matrix_identity_float4x4, matrix_identity_float4x4,
                        matrix_identity_float4x4, matrix_identity_float4x4, matrix_identity_float4x4,
                        matrix_identity_float4x4, matrix_identity_float4x4, matrix_identity_float4x4,
                        matrix_identity_float4x4, matrix_identity_float4x4, matrix_identity_float4x4,
                        matrix_identity_float4x4, matrix_identity_float4x4, matrix_identity_float4x4,
                        matrix_identity_float4x4, matrix_identity_float4x4, matrix_identity_float4x4,
                        matrix_identity_float4x4, matrix_identity_float4x4, matrix_identity_float4x4,
                        matrix_identity_float4x4, matrix_identity_float4x4, matrix_identity_float4x4),
                light: SIMD4<Float>(Float(skyL), Float(blockL), Float(dayLight), Float(gamma)),
                misc: SIMD4<Float>(Float(ambient), 1, 9999, 10000),   // no fog on the hand
                overlay: SIMD4<Float>(1, 0.2, 0.2, Float(player.hurtTime > 0 ? Double(player.hurtTime) / 10 * 0.5 : 0)),
                fogColor: SIMD4<Float>(0, 0, 0, 1))
            enc.setRenderPipelineState(pipeline)
            enc.setVertexBuffer(g.vb, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<EntityUniforms>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<EntityUniforms>.stride, index: 1)
            enc.setFragmentTexture(g.texture, index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: g.count)
        }

        // every piece and every matrix comes from the shared viewmodel, so
        // the Vulkan client holds the same item at the same angle
        for part in pebViewmodel(player) {
            let g: ModelGPU?
            switch part.piece {
            case .fist: g = fpArmGeom()
            case .item(let s), .offhand(let s): g = itemGeom(s)
            }
            guard let g else { continue }
            submit(g, simd_float4x4(part.model))
        }
    }
}
