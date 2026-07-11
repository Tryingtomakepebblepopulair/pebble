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
    private var next: Int32 = 0

    private func id(for type: String) -> Int32? {
        if let g = geomIds[type] { return g >= 0 ? g : nil }
        if next >= 160 { return nil }
        let geo = buildEntityGeometry(type)
        guard geo.vertexCount > 0, !geo.skin.data.isEmpty else {
            geomIds[type] = -1
            return nil
        }
        let gid = next
        let rc = geo.verts.withUnsafeBufferPointer { vp in
            geo.skin.data.withUnsafeBufferPointer { sp in
                pb_vk_upload_entity_geom(gid, vp.baseAddress, Int32(geo.vertexCount),
                                         sp.baseAddress, Int32(geo.skin.w), Int32(geo.skin.h))
            }
        }
        guard rc == 0 else {
            plog("entity geom failed for \(type): \(String(cString: pb_vk_last_error()))")
            geomIds[type] = -1
            return nil
        }
        next += 1
        geomIds[type] = gid
        return gid
    }

    /// rebuild the frame's draw list around the camera
    func frame(game: GameCore, camX: Double, camY: Double, camZ: Double,
               dayLight: Float, partial: Double) {
        pb_vk_begin_entities()
        guard game.hasWorld() else { return }
        for eref in game.world.entities {
            guard let e = eref as? Entity, e is LivingEntity, e !== game.player, !e.dead else { continue }
            let dx = e.x - camX, dz = e.z - camZ
            if dx * dx + dz * dz > 64 * 64 { continue }
            guard let gid = id(for: e.type) else { continue }
            let xi = e.prevX + (e.x - e.prevX) * partial
            let yi = e.prevY + (e.y - e.prevY) * partial
            let zi = e.prevZ + (e.z - e.prevZ) * partial
            let model = mat4fTranslation(Float(xi - camX), Float(yi - camY), Float(zi - camZ))
                * mat4fRotateY(Float(.pi - e.yaw))
            model.m.withUnsafeBufferPointer {
                pb_vk_push_entity(gid, $0.baseAddress, max(0.25, dayLight), 1)
            }
        }
    }
}

#endif
