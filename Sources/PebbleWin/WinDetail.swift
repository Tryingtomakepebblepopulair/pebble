// The world's small details on Windows (PORTING module 07 detail slice):
// the block-selection outline, particles and item billboards. None of the
// logic lives here — the outline comes from the same shapeBoxes, the
// particles from the same PebParticles, the billboards from the same
// pebBillboards as the Mac. This file only turns them into Vulkan streams.

#if os(Windows)

import Foundation
import PebbleCoreBase
import CPebbleVulkan

final class DetailView {
    /// the shared simulation — WinHost's addParticles/spawnPrecipitation feed it
    let particles = PebParticles()
    private var partData = [Float](repeating: 0, count: PEB_MAX_PARTICLES * 12)

    /// "itemId|potion" → icon-atlas slot; each slot's 16×16 icon uploads once
    private var spriteSlots: [String: Int] = [:]
    private var sprData: [Float] = []

    /// the crack mesh is rebuilt only when the stage or the block changes —
    /// the same key the Mac caches on
    private var crackKey = -1
    private var crackMesh: (verts: [Float], idx: [UInt32])?

    private func spriteSlot(_ stack: ItemStack) -> Int {
        let key = "\(stack.id)|\(stack.data.potion ?? "")"
        if let slot = spriteSlots[key] { return slot }
        let slot = spriteSlots.count
        if slot >= 128 * 32 { return 0 }
        let px = itemIconPixels(stack.id, stack.data)
        let queued = px.withUnsafeBufferPointer {
            pb_vk_sprite_atlas_update(Int32((slot % 128) * 16), Int32((slot / 128) * 16),
                                      16, 16, $0.baseAddress) == 0
        }
        // only claim the slot once its icon is actually on its way to the GPU;
        // a dropped upload would otherwise leave that cell blank forever
        guard queued else { return 0 }
        spriteSlots[key] = slot
        return slot
    }

    /// the flat-coloured overlays: a blob shadow under every living entity and
    /// the outline around the block under the crosshair. One batch each, since
    /// every shadow fades by its own amount.
    func pushLines(_ game: GameCore, _ camX: Double, _ camY: Double, _ camZ: Double,
                   partial: Double) {
        pb_vk_begin_lines()
        pushBlobShadows(game, camX, camY, camZ, partial: partial)
        pushSelection(game, camX, camY, camZ)
    }

    /// a soft disc under living entities, fading out as they rise off the
    /// ground — the Mac's drawBlobShadow, same radius and same fade
    private func pushBlobShadows(_ game: GameCore, _ camX: Double, _ camY: Double, _ camZ: Double,
                                 partial: Double) {
        let w = game.world
        for e in w.entities {
            if e.dead { continue }
            // first person: the Mac skips the player's whole entity pass,
            // shadow included, and so does WinEntities
            guard let ent = e as? Entity, ent is LivingEntity,
                  ent !== game.player else { continue }
            let dx = ent.x - camX, dz = ent.z - camZ
            if dx * dx + dz * dz > 64 * 64 { continue }
            let ix = ent.prevX + (ent.x - ent.prevX) * partial
            let iy = ent.prevY + (ent.y - ent.prevY) * partial
            let iz = ent.prevZ + (ent.z - ent.prevZ) * partial
            guard let gy = pebGroundYUnder(w, ix, iy, iz), iy - gy <= 6 else { continue }
            let fade = Float(max(0, 1 - (iy - gy) / 6))
            if fade <= 0.01 { continue }
            let verts = pebBlobShadowDisc(ix - camX, gy + 0.015 - camY, iz - camZ,
                                          ent.width * 0.5 + 0.18)
            verts.withUnsafeBufferPointer {
                pb_vk_push_lines($0.baseAddress, Int32(verts.count / 3), 1, 0, 0, 0, 0.34 * fade)
            }
        }
    }

    /// the outline around the block under the crosshair — the Mac's drawSelection,
    /// including the same 0.002 inflation and the same targetedBlock bookkeeping
    private func pushSelection(_ game: GameCore, _ camX: Double, _ camY: Double, _ camZ: Double) {
        guard let p = game.player else { return }
        if (game.host?.hasScreen() ?? false) || p.deathTime > 0 {
            game.targetedBlock = nil
            return
        }
        guard let hit = game.crosshairBlock() else {
            game.targetedBlock = nil
            return
        }
        game.targetedBlock = (hit.x, hit.y, hit.z, hit.cell)
        let w = game.world
        var scratch: [AABB] = []
        shapeBoxes(hit.cell, { dx, dy, dz in w.getBlock(hit.x + dx, hit.y + dy, hit.z + dz) },
                   &scratch, false)
        var verts: [Float] = []
        for b in scratch {
            let X0 = Float(b.x0 + Double(hit.x) - camX - 0.002)
            let Y0 = Float(b.y0 + Double(hit.y) - camY - 0.002)
            let Z0 = Float(b.z0 + Double(hit.z) - camZ - 0.002)
            let X1 = Float(b.x1 + Double(hit.x) - camX + 0.002)
            let Y1 = Float(b.y1 + Double(hit.y) - camY + 0.002)
            let Z1 = Float(b.z1 + Double(hit.z) - camZ + 0.002)
            let edges: [[Float]] = [
                [X0, Y0, Z0, X1, Y0, Z0], [X1, Y0, Z0, X1, Y0, Z1], [X1, Y0, Z1, X0, Y0, Z1], [X0, Y0, Z1, X0, Y0, Z0],
                [X0, Y1, Z0, X1, Y1, Z0], [X1, Y1, Z0, X1, Y1, Z1], [X1, Y1, Z1, X0, Y1, Z1], [X0, Y1, Z1, X0, Y1, Z0],
                [X0, Y0, Z0, X0, Y1, Z0], [X1, Y0, Z0, X1, Y1, Z0], [X1, Y0, Z1, X1, Y1, Z1], [X0, Y0, Z1, X0, Y1, Z1],
            ]
            for e in edges { verts.append(contentsOf: e) }
        }
        guard !verts.isEmpty else { return }
        verts.withUnsafeBufferPointer {
            pb_vk_push_lines($0.baseAddress, Int32(verts.count / 3), 0, 0.05, 0.05, 0.05, 0.55)
        }
    }

    /// falling blocks and primed TNT, and the crack on the block being broken
    func pushOverlays(_ game: GameCore, camX: Double, camY: Double, camZ: Double,
                      partial: Double) {
        let w = game.world
        let cubes = pebCubeMeshes(w, camX: camX, camY: camY, camZ: camZ, partial: partial)
        if cubes.idx.isEmpty {
            pb_vk_clear_overlay_mesh(0)
        } else {
            _ = cubes.verts.withUnsafeBufferPointer { v in
                cubes.idx.withUnsafeBufferPointer { i in
                    // already camera-relative, so the origin is the camera
                    pb_vk_set_overlay_mesh(0, 0, 0.1, camX, camY, camZ,
                                           v.baseAddress, Int32(cubes.verts.count / 7),
                                           i.baseAddress, Int32(cubes.idx.count))
                }
            }
        }

        guard let p = game.player, p.breakingProgress >= 0, p.gameMode != GameMode.creative else {
            pb_vk_clear_overlay_mesh(1)
            crackKey = -1
            return
        }
        let stage = min(9, max(0, Int(p.breakingProgress * 10)))
        let cell = w.getBlock(p.breakingX, p.breakingY, p.breakingZ)
        let key = stage &+ (cell &* 16) &+ (p.breakingX &* 1_000_003)
            &+ (p.breakingY &* 7919) &+ (p.breakingZ &* 31)
        // the mesh only changes when the stage or the block does, but the
        // stream is per-frame, so it is re-sent either way — rebuilding is
        // what the key saves
        if key != crackKey {
            crackKey = key
            crackMesh = pebCrackMesh(w, x: p.breakingX, y: p.breakingY, z: p.breakingZ, stage: stage)
        }
        guard let mesh = crackMesh, !mesh.idx.isEmpty else { return }
        _ = mesh.verts.withUnsafeBufferPointer { v in
            mesh.idx.withUnsafeBufferPointer { i in
                pb_vk_set_overlay_mesh(1, 2, 0.05,
                                       Double(p.breakingX), Double(p.breakingY), Double(p.breakingZ),
                                       v.baseAddress, Int32(mesh.verts.count / 7),
                                       i.baseAddress, Int32(mesh.idx.count))
            }
        }
    }

    /// the live particles, in the frozen 48-byte instance stream. The camera
    /// basis is the Mac's: right from yaw only, up from yaw and pitch.
    func pushParticles(camX: Double, camY: Double, camZ: Double, yaw: Double, pitch: Double) {
        let n = particles.encodeInstances(camX: camX, camY: camY, camZ: camZ, into: &partData)
        if n == 0 {
            pb_vk_set_particles(nil, 0, nil, nil)
            return
        }
        let right: [Float] = [Float(detCos(yaw)), 0, Float(detSin(yaw))]
        let up: [Float] = [Float(detSin(yaw) * detSin(pitch)),
                           Float(detCos(pitch)),
                           Float(-detCos(yaw) * detSin(pitch))]
        partData.withUnsafeBufferPointer { d in
            right.withUnsafeBufferPointer { r in
                up.withUnsafeBufferPointer { u in
                    pb_vk_set_particles(d.baseAddress, Int32(n), r.baseAddress, u.baseAddress)
                }
            }
        }
    }

    /// dropped items, xp orbs and thrown projectiles as camera-facing quads
    func pushSprites(_ game: GameCore, camX: Double, camY: Double, camZ: Double,
                     yaw: Double, dayLight: Double, partial: Double) {
        let items = pebBillboards(game.world, dayLight: dayLight,
                                  camX: camX, camZ: camZ, partial: partial)
        sprData.removeAll(keepingCapacity: true)
        for it in items {
            let slot = spriteSlot(it.stack)
            let u0 = Float((slot % 128) * 16) / 2048
            let v0 = Float((slot / 128) * 16) / 512
            let light = it.emissive > 0 ? 1 : it.light * (0.35 + dayLight * 0.65) + 0.08
            sprData.append(contentsOf: [
                Float(it.x - camX), Float(it.y + it.bob - camY), Float(it.z - camZ),
                Float(it.size),
                u0, v0, u0 + 16 / 2048, v0 + 16 / 512,
                Float(light),
            ])
        }
        if sprData.isEmpty {
            pb_vk_set_sprites(nil, 0, nil)
            return
        }
        let right: [Float] = [Float(detCos(yaw)), 0, Float(detSin(yaw))]
        sprData.withUnsafeBufferPointer { d in
            right.withUnsafeBufferPointer { r in
                pb_vk_set_sprites(d.baseAddress, Int32(sprData.count / 9), r.baseAddress)
            }
        }
    }
}

#endif
