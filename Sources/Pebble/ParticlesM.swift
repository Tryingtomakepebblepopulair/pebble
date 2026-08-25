// Metal front end for the portable particle simulation. Everything that
// decides what a particle IS — the spawn recipes, the physics, the frozen
// 48-byte instance encoding — lives in PebbleCoreBase/Render/ParticleSim so
// the Vulkan backend draws the same particles. This file only owns the
// buffers and the draw call.

import Metal
import simd
import PebbleCore

struct ParticleUniforms {
    var viewProj: simd_float4x4
    var right: SIMD4<Float>
    var up: SIMD4<Float>     // xyz + dayLight
}

final class ParticleSystemM {
    let sim = PebParticles()
    private var instData = [Float](repeating: 0, count: PEB_MAX_PARTICLES * 12)
    // 3-buffer ring: with ~3 frames in flight the GPU may still read frame
    // N-2's instances while the CPU writes frame N (same scheme as UICanvas)
    private let instBufs: [MTLBuffer]
    private var instCursor = 0
    private let quadBuf: MTLBuffer

    init(device: MTLDevice) {
        let quad: [Float] = [-1, -1, 1, -1, 1, 1, -1, -1, 1, 1, -1, 1]
        quadBuf = quad.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)! }
        instBufs = (0..<3).map { _ in device.makeBuffer(length: PEB_MAX_PARTICLES * 48)! }
    }

    var count: Int { sim.count }
    func clear() { sim.clear() }
    func tick(_ world: World) { sim.tick(world) }
    func spawn(_ world: World, _ type: String, _ x: Double, _ y: Double, _ z: Double,
               _ count: Int, _ spread: Double = 0.3, cell: Int = 0, note: Int = 0, groundY: Double = 0) {
        sim.spawn(world, type, x, y, z, count, spread, cell: cell, note: note, groundY: groundY)
    }

    func render(_ enc: MTLRenderCommandEncoder, pipeline: MTLRenderPipelineState,
                atlasTex: MTLTexture, sampler: MTLSamplerState,
                viewProj: simd_float4x4, camPos: SIMD3<Double>,
                right: SIMD3<Float>, up: SIMD3<Float>, dayLight: Double) {
        let n = sim.encodeInstances(camX: camPos.x, camY: camPos.y, camZ: camPos.z, into: &instData)
        if n == 0 { return }
        let instBuf = instBufs[instCursor]
        instCursor = (instCursor + 1) % instBufs.count
        instData.withUnsafeBytes { raw in
            instBuf.contents().copyMemory(from: raw.baseAddress!, byteCount: n * 48)
        }
        var u = ParticleUniforms(
            viewProj: viewProj,
            right: SIMD4<Float>(right.x, right.y, right.z, 0),
            up: SIMD4<Float>(up.x, up.y, up.z, Float(dayLight)))
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(quadBuf, offset: 0, index: 0)
        enc.setVertexBuffer(instBuf, offset: 0, index: 1)
        enc.setVertexBytes(&u, length: MemoryLayout<ParticleUniforms>.stride, index: 2)
        enc.setFragmentTexture(atlasTex, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: n)
    }
}

@inline(__always) func ifloorD(_ x: Double) -> Int { Int(x.rounded(.down)) }
