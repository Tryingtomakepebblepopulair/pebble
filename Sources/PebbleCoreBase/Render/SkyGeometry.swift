// The sky's shared geometry and art: the star field and the cloud mask.
// Both were Metal-side helpers in WorldRenderer; they hold no Apple types
// and both backends need the exact same numbers, so they live here in the
// portable core (PORTING module 07 sky slice). Patterns pinned by the
// frozen baselines — changing either one changes every screenshot.

import Foundation

/// how many stars `pebStarField` returns
public let PEB_STAR_COUNT = 1300

/// the star field: unit-sphere directions + a magnitude, in the frozen
/// 16-byte-per-star stream (float3 dir, float mag) both renderers upload
/// verbatim as a vertex buffer.
public func pebStarField() -> [Float] {
    let n = PEB_STAR_COUNT
    var data = [Float](repeating: 0, count: n * 4)
    for i in 0..<n {
        let u = Double(hash2(777, i, 0)) / 4294967296.0
        let v = Double(hash2(777, i, 1)) / 4294967296.0
        let theta = u * .pi * 2
        let phi = Foundation.acos(2 * v - 1)
        data[i * 4] = Float(Foundation.sin(phi) * Foundation.cos(theta))
        data[i * 4 + 1] = Float(Foundation.cos(phi))
        data[i * 4 + 2] = Float(Foundation.sin(phi) * Foundation.sin(theta))
        data[i * 4 + 3] = Float(Double(hash2(777, i, 2)) / 4294967296.0)
    }
    return data
}

/// blobby cellular clouds, wrapping — straight RGBA8. The fragment shader
/// reads the red channel as a hard mask (>= 0.5 is cloud).
public func pebCloudTexture() -> PebImage {
    let size = 128
    var px = [UInt8](repeating: 0, count: size * size * 4)
    for y in 0..<size {
        for x in 0..<size {
            var v = 0.0
            for (s, w) in [(8, 0.55), (16, 0.3), (32, 0.15)] {
                let cellW = size / s
                let gx = x / cellW, gy = y / cellW
                let fx = Double(x % cellW) / Double(cellW), fy = Double(y % cellW) / Double(cellW)
                func h(_ a: Int, _ b: Int) -> Double {
                    Double(hash2(31337, ((a % s) + s) % s, ((b % s) + s) % s, UInt32(s))) / 4294967296.0
                }
                let v00 = h(gx, gy), v10 = h(gx + 1, gy), v01 = h(gx, gy + 1), v11 = h(gx + 1, gy + 1)
                let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
                v += ((v00 * (1 - sx) + v10 * sx) * (1 - sy) + (v01 * (1 - sx) + v11 * sx) * sy) * w
            }
            let on: UInt8 = v > 0.56 ? 255 : 0
            let i = (y * size + x) * 4
            px[i] = on; px[i + 1] = on; px[i + 2] = on; px[i + 3] = 255
        }
    }
    return PebImage(pixels: px, width: size, height: size)
}

/// the sun direction for a day fraction — the same angle the Mac's scene
/// pass builds, so both backends put the sun in the same place.
public func pebSunDirection(sunAngle: Double) -> (Float, Float, Float) {
    (Float(-Foundation.sin(sunAngle * .pi * 2 + .pi)),
     Float(Foundation.cos(sunAngle * .pi * 2)),
     0.18)
}
