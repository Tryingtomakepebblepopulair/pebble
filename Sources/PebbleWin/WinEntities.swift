// Entities on Windows (PORTING module 07, entity slice): bind-pose
// geometry + procedural skins from the shared EntityModels, drawn through
// the Vulkan entity pipeline. One geometry+skin per mob type, per-frame
// model matrices for every living thing near the camera — mobs and OTHER
// PLAYERS become visible in multiplayer. Walk animation joins when the
// shared animator moves into the portable core.

#if os(Windows)

import Foundation
import PebbleCoreBase
import CPebbleVulkan

final class EntityView {
    /// type name → geometry slot (-1 = failed, don't retry)
    private var geomIds: [String: Int32] = [:]
    /// the rig each slot was built from — the animator needs it every frame
    private var models: [Int32: MobModel] = [:]
    private var next: Int32 = 0
    /// scratch for the 384-float part stream, reused across draws
    private var parts = [Float](repeating: 0, count: 24 * 16)
    /// the resource pack, for armour sheets — nil means procedural colours
    var packZip: Data?

    /// register (once) the geometry for one piece of gear
    private func gearId(_ piece: PebGearGeom) -> Int32? {
        let key: String
        switch piece {
        case .armor(let idx, let material): key = "armor:\(idx):\(material)"
        case .held(let s): key = "held:\(s.id):\(s.data.potion ?? "")"
        }
        if let g = geomIds[key] { return g >= 0 ? g : nil }
        if next >= 224 { return nil }

        var verts: [Float] = []
        var count = 0
        var pixels: [UInt8] = []
        var texW = 0, texH = 0
        switch piece {
        case .armor(let idx, let material):
            let built = buildEntityGeometry(from: pebArmorModel(idx, material), skinName: key)
            verts = built.verts
            count = built.vertexCount
            pixels = built.skin.data
            texW = built.skin.w
            texH = built.skin.h
            models[next] = built.model
            // vanilla armour sheets are 64x32; leather is greyscale + tinted
            if let zip = packZip {
                let layer = idx == 2 ? "2" : "1"
                if let img = packTexture(zip: zip, rel: "models/armor/\(material)_layer_\(layer).png"),
                   img.width * 32 == img.height * 64 {
                    var px = img.pixels
                    if material == "leather" { bakeTint(&px, 0x8a5a33) }
                    pixels = px
                    texW = img.width
                    texH = img.height
                }
            }
        case .held(let s):
            guard let built = pebItemGeometry(s) else {
                geomIds[key] = -1
                return nil
            }
            verts = built.geom.verts
            count = built.geom.vertexCount
            pixels = built.tex
            texW = built.geom.skin.w
            texH = built.geom.skin.h
            models[next] = built.geom.model
        }
        guard count > 0, !pixels.isEmpty else {
            geomIds[key] = -1
            return nil
        }
        let gid = next
        let rc = verts.withUnsafeBufferPointer { vp in
            pixels.withUnsafeBufferPointer { sp in
                pb_vk_upload_entity_geom(gid, vp.baseAddress, Int32(count),
                                         sp.baseAddress, Int32(texW), Int32(texH))
            }
        }
        if rc != 0 {
            geomIds[key] = -1
            return nil
        }
        next += 1
        geomIds[key] = gid
        return gid
    }

    private func push(_ gid: Int32, _ model: Mat4f, _ mats: [Mat4f], _ brightness: Float) {
        for i in 0..<24 {
            for k in 0..<16 { parts[i * 16 + k] = i < mats.count ? mats[i].m[k] : (k % 5 == 0 ? 1 : 0) }
        }
        model.m.withUnsafeBufferPointer { mp in
            parts.withUnsafeBufferPointer { pp in
                pb_vk_push_entity(gid, mp.baseAddress, brightness, 1, pp.baseAddress)
            }
        }
    }

    private func id(for key: String, type: String, skinPNG: Data?) -> Int32? {
        if let g = geomIds[key] { return g >= 0 ? g : nil }
        // the top 32 slots belong to the viewmodel (WinViewmodel), so mobs
        // and other players stop short of them
        if next >= 224 { return nil }
        let geo = buildEntityGeometry(type)
        guard geo.vertexCount > 0, !geo.skin.data.isEmpty else {
            geomIds[key] = -1
            return nil
        }
        // the resource pack's art for this mob, exactly as the Mac picks it —
        // without this the same creeper looked procedural here and Faithful
        // there. The procedural skin stays the fallback.
        var pixels = geo.skin.data
        var texW = geo.skin.w, texH = geo.skin.h
        if let zip = packZip, !geo.model.packTex.isEmpty,
           let img = pebPackEntityImage(zip: zip, rels: geo.model.packTex,
                                        stack: geo.model.packTexStack,
                                        tints: geo.model.packTexTints),
           img.width * geo.model.texH == img.height * geo.model.texW {
            pixels = img.pixels
            texW = img.width
            texH = img.height
        }
        if let blob = skinPNG, let img = pebDecodePNG(blob),
           img.width * geo.model.texH == img.height * geo.model.texW {
            pixels = img.pixels
            texW = img.width
            texH = img.height
        }
        let gid = next
        models[gid] = geo.model
        let rc = geo.verts.withUnsafeBufferPointer { vp in
            pixels.withUnsafeBufferPointer { sp in
                pb_vk_upload_entity_geom(gid, vp.baseAddress, Int32(geo.vertexCount),
                                         sp.baseAddress, Int32(texW), Int32(texH))
            }
        }
        guard rc == 0 else {
            plog("entity geom failed for \(key): \(String(cString: pb_vk_last_error()))")
            geomIds[key] = -1
            return nil
        }
        next += 1
        geomIds[key] = gid
        return gid
    }

    /// rebuild the frame's draw list around the camera
    func frame(game: GameCore, camX: Double, camY: Double, camZ: Double,
               dayLight: Float, partial: Double, timeSec: Double) {
        pb_vk_begin_entities()
        guard game.hasWorld() else { return }
        for eref in game.world.entities {
            // the local player is only hidden in first person — in third
            // person you are looking at your own back
            guard let e = eref as? Entity, e is LivingEntity, !e.dead else { continue }
            if e === game.player && game.perspective == 0 { continue }
            let dx = e.x - camX, dz = e.z - camZ
            if dx * dx + dz * dz > 64 * 64 { continue }
            let key = e.skinPNG != nil ? "player#\(e.id)" : e.type
            guard let gid = id(for: key, type: e.type, skinPNG: e.skinPNG) else { continue }
            let xi = e.prevX + (e.x - e.prevX) * partial
            let yi = e.prevY + (e.y - e.prevY) * partial
            let zi = e.prevZ + (e.z - e.prevZ) * partial
            let model = mat4fTranslation(Float(xi - camX), Float(yi - camY), Float(zi - camZ))
                * mat4fRotateY(Float(.pi - e.yaw))
            // the walk cycle, head turn and limb swing come from the shared
            // animator — the same matrices the Mac feeds its entity shader
            let bright = max(0.25, dayLight)
            let pose = pebEntityPose(game.world, e, partial: partial)
            var bodyParts = [Mat4f](repeating: Mat4f(), count: 24)
            if let rig = models[gid] { bodyParts = pebPoseParts(rig, pose, timeSec) }
            push(gid, model, bodyParts, bright)

            // players wear their armour and hold their items, posed off the
            // body rig that was just computed
            if let pl = e as? Player {
                for piece in pebPlayerGear(pl, pose: pose, bodyParts: bodyParts, time: timeSec) {
                    guard let gearGid = gearId(piece.geom) else { continue }
                    push(gearGid, model, piece.parts, bright)
                }
            }
        }
    }
}

#endif
