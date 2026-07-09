// Math utilities (portable): scalars, Vec3 (stdlib SIMD3<Double>, for sim),
// AABB with axis sweeps, ray/AABB. No Apple frameworks — this file builds on
// every Swift platform (PORTING module 03). The Metal-facing Mat4/Frustum and
// simd-backed vector helpers live in MathXApple.swift.

import Foundation

// ---- scalars -----------------------------------------------------------------
@inline(__always) public func clampD(_ x: Double, _ lo: Double, _ hi: Double) -> Double { x < lo ? lo : (x > hi ? hi : x) }
@inline(__always) public func clampF(_ x: Float, _ lo: Float, _ hi: Float) -> Float { x < lo ? lo : (x > hi ? hi : x) }
@inline(__always) public func lerpD(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
@inline(__always) public func lerpF(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
@inline(__always) public func smoothstepD(_ t: Double) -> Double { t * t * (3 - 2 * t) }
@inline(__always) public func smootherstepD(_ t: Double) -> Double { t * t * t * (t * (t * 6 - 15) + 10) }
@inline(__always) public func degToRad(_ d: Double) -> Double { d * .pi / 180 }
@inline(__always) public func radToDeg(_ r: Double) -> Double { r * 180 / .pi }

public func wrapDegrees(_ input: Double) -> Double {
    var d = input.truncatingRemainder(dividingBy: 360)
    if d >= 180 { d -= 360 }
    if d < -180 { d += 360 }
    return d
}

public func approachDegrees(_ cur: Double, _ target: Double, _ maxStep: Double) -> Double {
    let delta = wrapDegrees(target - cur)
    return cur + clampD(delta, -maxStep, maxStep)
}

@inline(__always)
public func mapRange(_ x: Double, _ a0: Double, _ a1: Double, _ b0: Double, _ b1: Double) -> Double {
    b0 + (b1 - b0) * clampD((x - a0) / (a1 - a0), 0, 1)
}

public func easeOutCubic(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
public func easeInOutQuad(_ t: Double) -> Double { t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2 }

// ---- Vec3 (Double — simulation space) -----------------------------------------
public typealias Vec3 = SIMD3<Double>

@inline(__always) public func vec3(_ x: Double = 0, _ y: Double = 0, _ z: Double = 0) -> Vec3 { Vec3(x, y, z) }
// ---- AABB (Double — collision space) -------------------------------------------
public struct AABB {
    public var x0: Double, y0: Double, z0: Double
    public var x1: Double, y1: Double, z1: Double

    @inline(__always)
    public init(_ x0: Double, _ y0: Double, _ z0: Double, _ x1: Double, _ y1: Double, _ z1: Double) {
        self.x0 = x0; self.y0 = y0; self.z0 = z0
        self.x1 = x1; self.y1 = y1; self.z1 = z1
    }

    @inline(__always)
    public func offset(_ x: Double, _ y: Double, _ z: Double) -> AABB {
        AABB(x0 + x, y0 + y, z0 + z, x1 + x, y1 + y, z1 + z)
    }

    @inline(__always)
    public func expand(_ x: Double, _ y: Double, _ z: Double) -> AABB {
        AABB(x0 - x, y0 - y, z0 - z, x1 + x, y1 + y, z1 + z)
    }

    @inline(__always)
    public func intersects(_ b: AABB) -> Bool {
        x0 < b.x1 && x1 > b.x0 && y0 < b.y1 && y1 > b.y0 && z0 < b.z1 && z1 > b.z0
    }

    @inline(__always)
    public func contains(_ x: Double, _ y: Double, _ z: Double) -> Bool {
        x >= x0 && x < x1 && y >= y0 && y < y1 && z >= z0 && z < z1
    }
}

/// how far box `a` may move along X by `d` before hitting `b`
@inline(__always)
public func sweepX(_ a: AABB, _ b: AABB, _ dIn: Double) -> Double {
    var d = dIn
    if a.y1 <= b.y0 || a.y0 >= b.y1 || a.z1 <= b.z0 || a.z0 >= b.z1 { return d }
    if d > 0 && a.x1 <= b.x0 { let m = b.x0 - a.x1; if m < d { d = m } }
    else if d < 0 && a.x0 >= b.x1 { let m = b.x1 - a.x0; if m > d { d = m } }
    return d
}

@inline(__always)
public func sweepY(_ a: AABB, _ b: AABB, _ dIn: Double) -> Double {
    var d = dIn
    if a.x1 <= b.x0 || a.x0 >= b.x1 || a.z1 <= b.z0 || a.z0 >= b.z1 { return d }
    if d > 0 && a.y1 <= b.y0 { let m = b.y0 - a.y1; if m < d { d = m } }
    else if d < 0 && a.y0 >= b.y1 { let m = b.y1 - a.y0; if m > d { d = m } }
    return d
}

@inline(__always)
public func sweepZ(_ a: AABB, _ b: AABB, _ dIn: Double) -> Double {
    var d = dIn
    if a.x1 <= b.x0 || a.x0 >= b.x1 || a.y1 <= b.y0 || a.y0 >= b.y1 { return d }
    if d > 0 && a.z1 <= b.z0 { let m = b.z0 - a.z1; if m < d { d = m } }
    else if d < 0 && a.z0 >= b.z1 { let m = b.z1 - a.z0; if m > d { d = m } }
    return d
}

/// ray vs AABB; returns t or -1
public func rayAABB(_ ox: Double, _ oy: Double, _ oz: Double, _ dx: Double, _ dy: Double, _ dz: Double, _ b: AABB) -> Double {
    var tmin = -Double.infinity, tmax = Double.infinity
    if abs(dx) < 1e-12 { if ox < b.x0 || ox > b.x1 { return -1 } }
    else {
        var t1 = (b.x0 - ox) / dx, t2 = (b.x1 - ox) / dx
        if t1 > t2 { swap(&t1, &t2) }
        tmin = max(tmin, t1); tmax = min(tmax, t2)
    }
    if abs(dy) < 1e-12 { if oy < b.y0 || oy > b.y1 { return -1 } }
    else {
        var t1 = (b.y0 - oy) / dy, t2 = (b.y1 - oy) / dy
        if t1 > t2 { swap(&t1, &t2) }
        tmin = max(tmin, t1); tmax = min(tmax, t2)
    }
    if abs(dz) < 1e-12 { if oz < b.z0 || oz > b.z1 { return -1 } }
    else {
        var t1 = (b.z0 - oz) / dz, t2 = (b.z1 - oz) / dz
        if t1 > t2 { swap(&t1, &t2) }
        tmin = max(tmin, t1); tmax = min(tmax, t2)
    }
    if tmax < tmin || tmax < 0 { return -1 }
    return tmin >= 0 ? tmin : tmax
}

