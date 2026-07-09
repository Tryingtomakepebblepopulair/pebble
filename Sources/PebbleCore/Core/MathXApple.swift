// Math utilities (Apple): Mat4 (simd_float4x4, Metal clip space z∈[0,1]),
// projection/frustum forms adjusted from GL to Metal conventions, and the
// simd-backed Vec3 helpers used by the renderer. Apple-only by design —
// portable equivalents arrive with PORTING module 03's Mat4f.

import Foundation
import simd

@inline(__always) public func vLen(_ a: Vec3) -> Double { simd_length(a) }
@inline(__always) public func vLenSq(_ a: Vec3) -> Double { simd_length_squared(a) }
@inline(__always) public func vDist(_ a: Vec3, _ b: Vec3) -> Double { simd_distance(a, b) }
@inline(__always) public func vDistSq(_ a: Vec3, _ b: Vec3) -> Double { simd_distance_squared(a, b) }
@inline(__always) public func vDot(_ a: Vec3, _ b: Vec3) -> Double { simd_dot(a, b) }
@inline(__always) public func vCross(_ a: Vec3, _ b: Vec3) -> Vec3 { simd_cross(a, b) }
@inline(__always) public func vLerp(_ a: Vec3, _ b: Vec3, _ t: Double) -> Vec3 { a + (b - a) * t }

@inline(__always)
public func vNorm(_ a: Vec3) -> Vec3 {
    let l = simd_length(a)
    return l < 1e-9 ? Vec3() : a / l
}

// ---- Mat4 (Float, column-major, Metal clip space) ------------------------------
public typealias Mat4 = simd_float4x4

public func mat4Identity() -> Mat4 { matrix_identity_float4x4 }

/// perspective with Metal depth range z' ∈ [0, 1]
public func mat4Perspective(fovYRad: Float, aspect: Float, near: Float, far: Float) -> Mat4 {
    let f = 1 / tan(fovYRad / 2)
    var m = Mat4(0)
    m[0][0] = f / aspect
    m[1][1] = f
    m[2][2] = far / (near - far)
    m[2][3] = -1
    m[3][2] = (far * near) / (near - far)
    return m
}

/// ortho with Metal depth range z' ∈ [0, 1]
public func mat4Ortho(l: Float, r: Float, b: Float, t: Float, n: Float, f: Float) -> Mat4 {
    var m = Mat4(0)
    m[0][0] = 2 / (r - l)
    m[1][1] = 2 / (t - b)
    m[2][2] = -1 / (f - n)
    m[3][0] = -(r + l) / (r - l)
    m[3][1] = -(t + b) / (t - b)
    m[3][2] = -n / (f - n)
    m[3][3] = 1
    return m
}

public func mat4LookDir(eye: SIMD3<Float>, dir: SIMD3<Float>, up: SIMD3<Float>) -> Mat4 {
    let z = simd_normalize(-dir)
    let x = simd_normalize(simd_cross(up, z))
    let y = simd_cross(z, x)
    return Mat4(columns: (
        SIMD4<Float>(x.x, y.x, z.x, 0),
        SIMD4<Float>(x.y, y.y, z.y, 0),
        SIMD4<Float>(x.z, y.z, z.z, 0),
        SIMD4<Float>(-simd_dot(x, eye), -simd_dot(y, eye), -simd_dot(z, eye), 1)
    ))
}

public func mat4Translate(_ m: Mat4, _ x: Float, _ y: Float, _ z: Float) -> Mat4 {
    var out = m
    out[3] = m[0] * x + m[1] * y + m[2] * z + m[3]
    return out
}

public func mat4Scale(_ m: Mat4, _ x: Float, _ y: Float, _ z: Float) -> Mat4 {
    var out = m
    out[0] = m[0] * x
    out[1] = m[1] * y
    out[2] = m[2] * z
    return out
}

public func mat4RotateX(_ m: Mat4, _ rad: Float) -> Mat4 {
    let s = sin(rad), c = cos(rad)
    var out = m
    out[1] = m[1] * c + m[2] * s
    out[2] = m[2] * c - m[1] * s
    return out
}

public func mat4RotateY(_ m: Mat4, _ rad: Float) -> Mat4 {
    let s = sin(rad), c = cos(rad)
    var out = m
    out[0] = m[0] * c - m[2] * s
    out[2] = m[0] * s + m[2] * c
    return out
}

public func mat4RotateZ(_ m: Mat4, _ rad: Float) -> Mat4 {
    let s = sin(rad), c = cos(rad)
    var out = m
    out[0] = m[0] * c + m[1] * s
    out[1] = m[1] * c - m[0] * s
    return out
}

// ---- frustum (Float, Metal clip space) ------------------------------------------
public struct Frustum {
    /// 6 planes × (a,b,c,d): left, right, bottom, top, near, far
    public var planes = [Float](repeating: 0, count: 24)

    public init() {}

    public mutating func setFromMatrix(_ m: Mat4) {
        // rows of the column-major matrix
        let r0 = SIMD4<Float>(m[0][0], m[1][0], m[2][0], m[3][0])
        let r1 = SIMD4<Float>(m[0][1], m[1][1], m[2][1], m[3][1])
        let r2 = SIMD4<Float>(m[0][2], m[1][2], m[2][2], m[3][2])
        let r3 = SIMD4<Float>(m[0][3], m[1][3], m[2][3], m[3][3])
        // Metal clip: -w ≤ x,y ≤ w and 0 ≤ z ≤ w → near plane is r2 alone
        let ps: [SIMD4<Float>] = [r3 + r0, r3 - r0, r3 + r1, r3 - r1, r2, r3 - r2]
        for (i, pl) in ps.enumerated() {
            let len = simd_length(SIMD3<Float>(pl.x, pl.y, pl.z))
            let n = len > 0 ? pl / len : pl
            planes[i * 4] = n.x
            planes[i * 4 + 1] = n.y
            planes[i * 4 + 2] = n.z
            planes[i * 4 + 3] = n.w
        }
    }

    @inline(__always)
    public func intersectsBox(_ x0: Float, _ y0: Float, _ z0: Float, _ x1: Float, _ y1: Float, _ z1: Float) -> Bool {
        for i in 0..<6 {
            let o = i * 4
            let px = planes[o] > 0 ? x1 : x0
            let py = planes[o + 1] > 0 ? y1 : y0
            let pz = planes[o + 2] > 0 ? z1 : z0
            if planes[o] * px + planes[o + 1] * py + planes[o + 2] * pz + planes[o + 3] < 0 { return false }
        }
        return true
    }
}
