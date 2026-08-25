// The first-person hand on Windows (PORTING module 07 viewmodel slice).
// The item mesh, the empty fist and every placement matrix come from the
// shared pebViewmodel, so the Mac and Windows hold the same pickaxe at the
// same angle. This file only registers the geometry and pushes the draws.
//
// The viewmodel rides the entity geometry registry and the entity shader —
// the Vulkan pipeline for it differs only in having no depth test, so the
// arm never clips into a wall.

#if os(Windows)

import Foundation
import PebbleCoreBase
import CPebbleVulkan

final class ViewmodelView {
    /// geometry key → entity-geometry slot (-1 = failed, don't retry)
    private var slots: [String: Int32] = [:]
    /// viewmodel geometry is registered high in the shared entity table so it
    /// cannot collide with the mob slots EntityView hands out from 0 upward
    private var next: Int32 = 224
    private let maxSlot: Int32 = 255

    private func key(for piece: PebViewmodelPiece) -> String {
        switch piece {
        case .fist: return "fp_arm"
        case .item(let s), .offhand(let s):
            return "item:\(s.id):\(s.data.potion ?? "")"
        }
    }

    private func slot(for piece: PebViewmodelPiece) -> Int32? {
        let k = key(for: piece)
        if let s = slots[k] { return s >= 0 ? s : nil }
        if next > maxSlot { return nil }

        var verts: [Float]
        var count: Int
        var tex: [UInt8]
        var texW: Int
        var texH: Int
        switch piece {
        case .fist:
            // the arm wears the player's own skin, like the Mac's fpArmGeom
            let arm = buildEntityGeometry(from: pebFirstPersonArmModel(), skinName: "fp_arm")
            let player = buildEntityGeometry("player")
            verts = arm.verts
            count = arm.vertexCount
            tex = player.skin.data
            texW = player.skin.w
            texH = player.skin.h
        case .item(let stack), .offhand(let stack):
            guard let built = pebItemGeometry(stack) else {
                slots[k] = -1
                return nil
            }
            verts = built.geom.verts
            count = built.geom.vertexCount
            tex = built.tex
            texW = built.geom.skin.w
            texH = built.geom.skin.h
        }
        guard count > 0, !tex.isEmpty else {
            slots[k] = -1
            return nil
        }
        let id = next
        let rc = verts.withUnsafeBufferPointer { v in
            tex.withUnsafeBufferPointer { t in
                pb_vk_upload_entity_geom(id, v.baseAddress, Int32(count),
                                         t.baseAddress, Int32(texW), Int32(texH))
            }
        }
        if rc != 0 {
            slots[k] = -1
            return nil
        }
        next += 1
        slots[k] = id
        return id
    }

    /// hand the frame's viewmodel to the renderer. `proj` is the projection
    /// alone — the placement matrices are already in view space.
    func frame(game: GameCore, proj: Mat4f, dayLight: Float) {
        pb_vk_begin_viewmodel()
        guard let p = game.player, p.deathTime == 0, !p.dead else { return }
        proj.m.withUnsafeBufferPointer { pb_vk_set_viewmodel_proj($0.baseAddress) }
        // the hand takes the light at head height, like the Mac
        let w = game.world
        let bx = ifloor(p.x), by = ifloor(p.y + 1), bz = ifloor(p.z)
        let sky = Double(w.getSkyLight(bx, by, bz)) / 15 * Double(dayLight)
        let blk = Double(w.getBlockLight(bx, by, bz)) / 15
        let brightness = Float(max(0.25, max(sky, blk)))
        for part in pebViewmodel(p) {
            guard let id = slot(for: part.piece) else { continue }
            part.model.m.withUnsafeBufferPointer {
                pb_vk_push_viewmodel(id, $0.baseAddress, brightness, 1)
            }
        }
    }
}

#endif
