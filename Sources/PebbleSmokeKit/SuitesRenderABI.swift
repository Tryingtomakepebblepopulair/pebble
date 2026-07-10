// Render ABI suite (PORTING module 06): pins the frozen byte contract
// against REAL mesher and entity-model output — a backend can trust these
// numbers on every platform CI runs.

import Foundation
import PebbleCoreBase

public func smokeRenderABISuite() {
    section("render ABI (frozen byte contract)")

    // a real generated section mesh must be exact multiples of the contract
    let out = generateOverworldChunk(12345, 0, 0)
    let light = computeLocalLight(blocks: out.blocks, height: WORLD_H, hasSky: true)
    let P = 18
    var blocks = [UInt16](repeating: 0, count: P * P * P)
    var sky = [UInt8](repeating: 0, count: P * P * P)
    var blk = [UInt8](repeating: 0, count: P * P * P)
    let biomes = [UInt8](repeating: 0, count: P * P)
    // surface section: topmost non-air block in the corner column
    var topY = 64
    var yy = WORLD_H - 1
    while yy > 0 {
        if out.blocks[yy * 256] != 0 { topY = yy; break }
        yy -= 1
    }
    let baseY = (topY >> 4) << 4
    for dy in -1...16 {
        for dz in -1...16 {
            for dx in -1...16 {
                let idx = ((dy + 1) * P + (dz + 1)) * P + (dx + 1)
                let wy = baseY + dy
                let lx = min(15, max(0, dx)), lz = min(15, max(0, dz))
                if wy < 0 || wy >= WORLD_H { continue }
                let ci = (wy * 16 + lz) * 16 + lx
                blocks[idx] = out.blocks[ci]
                sky[idx] = light.sky[ci]
                blk[idx] = light.blk[ci]
            }
        }
    }
    let mesh = buildSectionMesh(MeshInput(blocks: blocks, skyLight: sky, blockLight: blk, biomes: biomes))
    let total = mesh.opaque.count + mesh.cutout.count + mesh.translucent.count
    check("mesher emits vertices", total > 0, "empty section")
    for (name, layer) in [("opaque", mesh.opaque), ("cutout", mesh.cutout), ("translucent", mesh.translucent)] {
        check("chunk \(name) stream is \(RenderABI.chunkVertexWords) words × count (\(RenderABI.chunkVertexStride)B stride)",
              layer.data.count == layer.count * RenderABI.chunkVertexWords,
              "data \(layer.data.count) verts \(layer.count)")
    }

    // A-word fields of a real vertex stay inside their frozen bit windows
    if let layer = [mesh.opaque, mesh.cutout, mesh.translucent].first(where: { $0.count > 0 }) {
        let A = layer.data[5]
        let tile = A & 4095
        let normal = (A >> 12) & 7
        check("A word decodes (tile \(tile) < tileCount, normal \(normal) < 6)",
              Int(tile) < tileCount() && normal < 6)
    }

    // entity geometry: 9 floats per vertex, part indices inside the palette
    registerAllEntities()
    let pig = buildEntityGeometry("pig")
    check("entity stream is \(RenderABI.entityVertexFloats) floats × N (\(RenderABI.entityVertexStride)B stride)",
          !pig.verts.isEmpty && pig.verts.count % RenderABI.entityVertexFloats == 0)
    var partsOK = true
    var vi = RenderABI.entityVertexFloats - 1
    while vi < pig.verts.count {
        if Int(pig.verts[vi]) >= RenderABI.entityMaxParts { partsOK = false; break }
        vi += RenderABI.entityVertexFloats
    }
    check("entity part indices < \(RenderABI.entityMaxParts)", partsOK)

    // the numeric contract itself — a change here must be a deliberate,
    // documented ABI bump (docs/render-abi.md)
    check("frozen strides", RenderABI.chunkVertexStride == 28
          && RenderABI.entityVertexStride == 36
          && RenderABI.particleInstanceStride == 48
          && RenderABI.uiVertexStride == 32
          && RenderABI.starsVertexStride == 16
          && RenderABI.particleCornerStride == 8)
}
