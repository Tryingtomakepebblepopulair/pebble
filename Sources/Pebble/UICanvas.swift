// The Metal backend for the portable UICanvas (PORTING module 08 split):
// the canvas itself — batching, transforms, font, icon slots — lives in
// PebbleCoreBase/Render/UIBatch.swift and is shared with the Windows
// client; this file only uploads its dirty atlas pixels and draws the
// segments. Behavior must match the pre-split UICanvas exactly.

import Metal
import simd
import PebbleCore

struct UIUniforms {
    var screen: SIMD4<Float>
}

final class UICanvasMetal {
    private let device: MTLDevice
    private var atlas: MTLTexture            // GPU mirror of canvas.atlasPixels
    let sampler: MTLSamplerState
    /// the pack GUI composite (2048×2560) — set alongside canvas.hasGuiSheet
    var guiTexture: MTLTexture?

    init(device: MTLDevice) {
        self.device = device
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                          width: UICanvas.ATLAS_SIZE,
                                                          height: UICanvas.ATLAS_SIZE, mipmapped: false)
        td.usage = .shaderRead
        atlas = device.makeTexture(descriptor: td)!
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .nearest
        sd.magFilter = .nearest
        sampler = device.makeSamplerState(descriptor: sd)!
    }

    private var ringBuffers: [MTLBuffer] = []
    private var ringIndex = 0

    func flush(_ cv: UICanvas, _ enc: MTLRenderCommandEncoder, pipeline: MTLRenderPipelineState) {
        // sync freshly painted icon/tile cells into the GPU atlas
        let size = UICanvas.ATLAS_SIZE
        for r in cv.takeAtlasDirty() {
            cv.atlasPixels.withUnsafeBytes { raw in
                atlas.replace(region: MTLRegionMake2D(r.x, r.y, r.w, r.h), mipmapLevel: 0,
                              withBytes: raw.baseAddress! + (r.y * size + r.x) * 4,
                              bytesPerRow: size * 4)
            }
        }

        let verts = cv.verts
        guard !verts.isEmpty else { return }
        var u = UIUniforms(screen: SIMD4<Float>(Float(cv.width), Float(cv.height), 0, 0))
        enc.setRenderPipelineState(pipeline)
        verts.withUnsafeBytes { raw in
            if raw.count <= 4096 {
                enc.setVertexBytes(raw.baseAddress!, length: raw.count, index: 0)
            } else {
                // triple-buffered persistent ring: a fresh makeBuffer per frame
                // showed up in the profile
                if ringBuffers.count < 3 {
                    ringBuffers.append(device.makeBuffer(length: max(2 << 20, raw.count), options: .storageModeShared)!)
                }
                ringIndex = (ringIndex + 1) % ringBuffers.count
                if ringBuffers[ringIndex].length < raw.count {
                    ringBuffers[ringIndex] = device.makeBuffer(length: raw.count * 2, options: .storageModeShared)!
                }
                ringBuffers[ringIndex].contents().copyMemory(from: raw.baseAddress!, byteCount: raw.count)
                enc.setVertexBuffer(ringBuffers[ringIndex], offset: 0, index: 0)
            }
        }
        enc.setVertexBytes(&u, length: MemoryLayout<UIUniforms>.stride, index: 1)
        enc.setFragmentSamplerState(sampler, index: 0)
        let segs = cv.segments.isEmpty ? [(gui: false, start: 0)] : cv.segments
        for (i, seg) in segs.enumerated() {
            let end = i + 1 < segs.count ? segs[i + 1].start : verts.count
            let count = (end - seg.start) / 8
            if count == 0 { continue }
            enc.setFragmentTexture(seg.gui ? (guiTexture ?? atlas) : atlas, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: seg.start / 8, vertexCount: count)
        }
    }
}
