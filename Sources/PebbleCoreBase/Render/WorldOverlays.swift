// Mesh builders for the bits of world that are not chunks: falling blocks
// and TNT, and the crack overlay on the block you are breaking. Both emit
// the frozen 28-byte chunk stream and draw with the terrain pipelines, so
// they are pure data — extracted verbatim from the Metal renderer for the
// Vulkan backend (PORTING module 07 detail slice).

import Foundation

public func pebPackCube(_ out: inout [Float], _ outIdx: inout [UInt32],
                      _ x0: Float, _ y0: Float, _ z0: Float, _ x1: Float, _ y1: Float, _ z1: Float,
                      _ blockCell: Int, _ sky: Int, _ blk: Int, _ flash: Bool) {
    let id = blockCell >> 4
    let meta = blockCell & 15
    let def = blockDefs[id]
    func tileOf(_ face: Int) -> Int {
        def.texFn?(meta, face) ?? (def.tex.isEmpty ? 0 : Int(def.tex[face]))
    }
    func u32(_ layer: Int, _ normal: Int) -> UInt32 {
        // stepwise on a typed Int: the inline bitwise-OR chain overruns the
        // Swift type-checker on some toolchains (6.2.4). Same result.
        var v = layer & 4095
        v |= normal << 12
        v |= 3 << 15
        v |= (sky & 15) << 17
        v |= (blk & 15) << 21
        v |= (flash ? 1 : 0) << 25
        return UInt32(v)
    }
    let Bv: UInt32 = 0xffffff
    let faces: [(Int, [[Float]])] = [
        (0, [[x0, y0, z1], [x1, y0, z1], [x1, y0, z0], [x0, y0, z0]]),
        (1, [[x0, y1, z0], [x1, y1, z0], [x1, y1, z1], [x0, y1, z1]]),
        (2, [[x1, y0, z0], [x1, y1, z0], [x0, y1, z0], [x0, y0, z0]]),
        (3, [[x0, y0, z1], [x0, y1, z1], [x1, y1, z1], [x1, y0, z1]]),
        (4, [[x0, y0, z0], [x0, y1, z0], [x0, y1, z1], [x0, y0, z1]]),
        (5, [[x1, y0, z1], [x1, y1, z1], [x1, y1, z0], [x1, y0, z0]]),
    ]
    let uvs: [[Float]] = [[0, 1], [1, 1], [1, 0], [0, 0]]
    for (face, corners) in faces {
        let layer = tileOf(face)
        let base = UInt32(out.count / 7)
        for i in 0..<4 {
            let c = corners[i]
            out.append(contentsOf: [c[0], c[1], c[2], uvs[i][0], uvs[i][1],
                                    Float(bitPattern: u32(layer, face)), Float(bitPattern: Bv)])
        }
        outIdx.append(contentsOf: [base, base + 1, base + 2, base + 2, base + 3, base])
    }
}

/// falling blocks and primed TNT as textured cubes, camera-relative and
/// ready for the opaque chunk pipeline (alpha test 0.1)
public func pebCubeMeshes(_ w: World, camX: Double, camY: Double, camZ: Double,
                          partial: Double) -> (verts: [Float], idx: [UInt32]) {
    var verts: [Float] = []
    var idx: [UInt32] = []
    for e in w.entities {
        if e.dead { continue }
        guard let ent = e as? Entity else { continue }
        var blockCell = 0
        var flash = false
        if let fb = ent as? FallingBlockEntity {
            blockCell = fb.blockCell
        } else if let tnt = ent as? TNTEntity {
            blockCell = Int(cell(B.tnt))
            flash = (Double(tnt.fuse) / 5).truncatingRemainder(dividingBy: 2) < 1
        } else {
            continue
        }
        let dx = ent.x - camX, dz = ent.z - camZ
        if dx * dx + dz * dz > 96 * 96 { continue }
        let ix = Float(ent.prevX + (ent.x - ent.prevX) * partial - camX)
        let iy = Float(ent.prevY + (ent.y - ent.prevY) * partial - camY)
        let iz = Float(ent.prevZ + (ent.z - ent.prevZ) * partial - camZ)
        let bx = ifloor(ent.x), by = ifloor(ent.y + 0.5), bz = ifloor(ent.z)
        let half: Float = 0.49
        let fuse = (ent as? TNTEntity)?.fuse ?? 0
        pebPackCube(&verts, &idx, ix - half, iy, iz - half, ix + half, iy + half * 2, iz + half,
                    blockCell, w.getSkyLight(bx, by, bz),
                    max(w.getBlockLight(bx, by, bz), flash ? 15 : 0),
                    flash && fuse % 10 < 5)
    }
    return (verts, idx)
}

/// the crack overlay for one block, following its real outline shape
/// (slab/stairs/torch…). Positions are relative to the block corner, so the
/// caller draws it at origin (x, y, z). Alpha test 0.05, translucent pass.
public func pebCrackMesh(_ w: World, x: Int, y: Int, z: Int,
                         stage: Int) -> (verts: [Float], idx: [UInt32]) {
    let cell = w.getBlock(x, y, z)
    var scratch: [AABB] = []
    shapeBoxes(cell, { dx, dy, dz in w.getBlock(x + dx, y + dy, z + dz) }, &scratch, false)
    if scratch.isEmpty { scratch = [AABB(0, 0, 0, 1, 1, 1)] }
    var verts: [Float] = []
    var idx: [UInt32] = []
    let layer = tileId("destroy_\(stage)")
    let g: Float = 0.004
    let A = UInt32((layer & 4095) | (3 << 15) | (15 << 17) | (15 << 21))
    let uvs: [[Float]] = [[0, 1], [1, 1], [1, 0], [0, 0]]
    for b in scratch {
        let x0 = Float(b.x0) - g, y0 = Float(b.y0) - g, z0 = Float(b.z0) - g
        let x1 = Float(b.x1) + g, y1 = Float(b.y1) + g, z1 = Float(b.z1) + g
        let faces: [[[Float]]] = [
            [[x0, y0, z1], [x1, y0, z1], [x1, y0, z0], [x0, y0, z0]],
            [[x0, y1, z0], [x1, y1, z0], [x1, y1, z1], [x0, y1, z1]],
            [[x1, y0, z0], [x1, y1, z0], [x0, y1, z0], [x0, y0, z0]],
            [[x0, y0, z1], [x0, y1, z1], [x1, y1, z1], [x1, y0, z1]],
            [[x0, y0, z0], [x0, y1, z0], [x0, y1, z1], [x0, y0, z1]],
            [[x1, y0, z1], [x1, y1, z1], [x1, y1, z0], [x1, y0, z0]],
        ]
        for fi in 0..<6 {
            let base = UInt32(verts.count / 7)
            for i in 0..<4 {
                let c = faces[fi][i]
                verts.append(contentsOf: [c[0], c[1], c[2], uvs[i][0], uvs[i][1],
                                          Float(bitPattern: A | UInt32(fi << 12)), Float(bitPattern: 0xffffff)])
            }
            idx.append(contentsOf: [base, base + 1, base + 2, base + 2, base + 3, base])
        }
    }
    return (verts, idx)
}

/// the first solid block surface under a point, or nil if there is none
/// within 24 blocks — what a blob shadow lands on
public func pebGroundYUnder(_ w: World, _ x: Double, _ feetY: Double, _ z: Double) -> Double? {
    let bx = ifloor(x), bz = ifloor(z)
    var y = ifloor(feetY + 0.05)
    var steps = 0
    while steps < 24 {
        let id = w.getBlock(bx, y, bz) >> 4
        if id > 0 && id < blockDefs.count && blockDefs[id].solid { return Double(y + 1) }
        y -= 1
        steps += 1
    }
    return nil
}

/// a flat ground-projected disc, double-sided so the cull mode cannot drop
/// it. Returns raw float3 triangles, camera-relative.
public func pebBlobShadowDisc(_ sx: Double, _ sy: Double, _ sz: Double, _ r: Double) -> [Float] {
    let seg = 14
    var verts: [Float] = []
    let cy = Float(sy), cx = Float(sx), cz = Float(sz)
    for s in 0..<seg {
        let a0 = Double(s) / Double(seg) * .pi * 2
        let a1 = Double(s + 1) / Double(seg) * .pi * 2
        let x0 = Float(sx + Foundation.cos(a0) * r), z0 = Float(sz + Foundation.sin(a0) * r)
        let x1 = Float(sx + Foundation.cos(a1) * r), z1 = Float(sz + Foundation.sin(a1) * r)
        verts.append(contentsOf: [cx, cy, cz, x0, cy, z0, x1, cy, z1])
        verts.append(contentsOf: [cx, cy, cz, x1, cy, z1, x0, cy, z0])
    }
    return verts
}
