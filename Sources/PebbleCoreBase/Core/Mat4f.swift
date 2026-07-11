// Portable column-major 4×4 float matrix (PORTING module 03) — the exact
// math of MathXApple's simd Mat4 helpers, usable on every platform. The
// Metal path keeps its simd version; the Vulkan/Windows client uses this.
// Projection uses depth range z' ∈ [0, 1] (Metal/Vulkan convention); the
// Vulkan shader flips Y (gl_Position.y = -y), not the matrix.

public struct Mat4f {
    /// 16 values, column-major: m[c*4+r]
    public var m: [Float]

    public init() { m = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1] }
    public init(_ values: [Float]) {
        precondition(values.count == 16)
        m = values
    }

    public static func * (a: Mat4f, b: Mat4f) -> Mat4f {
        var out = [Float](repeating: 0, count: 16)
        for c in 0..<4 {
            for r in 0..<4 {
                var s: Float = 0
                for k in 0..<4 { s += a.m[k * 4 + r] * b.m[c * 4 + k] }
                out[c * 4 + r] = s
            }
        }
        return Mat4f(out)
    }
}

public func mat4fPerspective(fovYRad: Float, aspect: Float, near: Float, far: Float) -> Mat4f {
    let f = 1 / tanf32(fovYRad / 2)
    var m = [Float](repeating: 0, count: 16)
    m[0] = f / aspect
    m[5] = f
    m[10] = far / (near - far)
    m[11] = -1
    m[14] = (far * near) / (near - far)
    return Mat4f(m)
}

public func mat4fLookDir(eyeX: Float, eyeY: Float, eyeZ: Float,
                         dirX: Float, dirY: Float, dirZ: Float,
                         upX: Float, upY: Float, upZ: Float) -> Mat4f {
    func norm(_ x: Float, _ y: Float, _ z: Float) -> (Float, Float, Float) {
        let l = (x * x + y * y + z * z).squareRoot()
        return l > 0 ? (x / l, y / l, z / l) : (0, 0, 0)
    }
    func cross(_ a: (Float, Float, Float), _ b: (Float, Float, Float)) -> (Float, Float, Float) {
        (a.1 * b.2 - a.2 * b.1, a.2 * b.0 - a.0 * b.2, a.0 * b.1 - a.1 * b.0)
    }
    func dot(_ a: (Float, Float, Float), _ b: (Float, Float, Float)) -> Float {
        a.0 * b.0 + a.1 * b.1 + a.2 * b.2
    }
    let z = norm(-dirX, -dirY, -dirZ)
    let x = norm(cross((upX, upY, upZ), z).0, cross((upX, upY, upZ), z).1, cross((upX, upY, upZ), z).2)
    let y = cross(z, x)
    let eye = (eyeX, eyeY, eyeZ)
    return Mat4f([
        x.0, y.0, z.0, 0,
        x.1, y.1, z.1, 0,
        x.2, y.2, z.2, 0,
        -dot(x, eye), -dot(y, eye), -dot(z, eye), 1,
    ])
}

public func mat4fTranslation(_ x: Float, _ y: Float, _ z: Float) -> Mat4f {
    Mat4f([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, x, y, z, 1])
}

public func mat4fRotateY(_ angle: Float) -> Mat4f {
    let c = Float(detCos(Double(angle))), s = Float(detSin(Double(angle)))
    return Mat4f([c, 0, -s, 0, 0, 1, 0, 0, s, 0, c, 0, 0, 0, 0, 1])
}

@inline(__always) private func tanf32(_ x: Float) -> Float {
    Float(_tan(Double(x)))
}
@inline(__always) private func _tan(_ x: Double) -> Double {
    // detSin/detCos are bit-stable everywhere — perfect for a camera matrix
    detSin(x) / detCos(x)
}
