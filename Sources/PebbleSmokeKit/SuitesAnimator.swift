// The entity animator, checked without a GPU: pose a rig and look at the
// matrices. A T-posing mob is the classic symptom of this slice being wrong
// on one platform, and it is invisible to every other suite.

import Foundation
import PebbleCoreBase

/// column 3 of a Mat4f is its translation; the 3×3 part is its rotation
private func translation(_ m: Mat4f) -> (Float, Float, Float) {
    (m.m[12], m.m[13], m.m[14])
}

private func isIdentity(_ m: Mat4f) -> Bool {
    for i in 0..<16 {
        let want: Float = (i % 5 == 0) ? 1 : 0
        if abs(m.m[i] - want) > 1e-6 { return false }
    }
    return true
}

public func smokeAnimatorSuite() {
    section("entity animator (part matrices, no GPU)")
    ensureModels()

    let biped = getModel("zombie")
    check("biped rig has parts", !biped.parts.isEmpty, "\(biped.parts.count)")

    // a mob standing perfectly still
    var still = EntityPose()
    still.limbSwing = 0
    still.limbAmp = 0
    let a = pebPoseParts(biped, still, 0)
    check("pose returns 24 matrices", a.count == 24, "\(a.count)")

    // ...and the same mob mid-stride
    var walking = EntityPose()
    walking.limbSwing = 3.7
    walking.limbAmp = 1.0
    let b = pebPoseParts(biped, walking, 0)

    var moved = 0
    for i in 0..<24 where !isIdentity(a[i]) || !isIdentity(b[i]) { moved += 1 }
    check("posing moves parts off identity", moved > 0, "\(moved) of 24")

    var differs = false
    for i in 0..<24 {
        for k in 0..<16 where abs(a[i].m[k] - b[i].m[k]) > 1e-5 { differs = true }
    }
    check("walking differs from standing", differs)

    // the legs of a walking biped swing in opposite directions
    if let rIdx = biped.parts.firstIndex(where: { $0.name == "legR" }),
       let lIdx = biped.parts.firstIndex(where: { $0.name == "legL" }),
       rIdx < 24, lIdx < 24 {
        // m[6] is the rotation's yz term — the sign of the leg's pitch
        check("legs swing in opposite phase", b[rIdx].m[6] * b[lIdx].m[6] < 0,
              "R \(b[rIdx].m[6]) L \(b[lIdx].m[6])")
    } else {
        check("biped has legR and legL", false)
    }

    // head yaw actually rotates the head part
    var looking = EntityPose()
    looking.headYaw = 0.8
    let c = pebPoseParts(biped, looking, 0)
    if let hIdx = biped.parts.firstIndex(where: { $0.name == "head" }), hIdx < 24 {
        check("head yaw rotates the head", !isIdentity(c[hIdx]) &&
              abs(c[hIdx].m[0] - 1) > 1e-4)
    } else {
        check("biped has a head", false)
    }

    // every part carries its pivot as a translation
    var pivots = 0
    for (i, part) in biped.parts.enumerated() where i < 24 {
        let t = translation(a[i])
        let want = (Float(part.pivot.0 / 16), Float(part.pivot.1 / 16), Float(part.pivot.2 / 16))
        if abs(t.0 - want.0) < 1e-5 && abs(t.1 - want.1) < 1e-5 && abs(t.2 - want.2) < 1e-5 {
            pivots += 1
        }
    }
    check("parts sit at their pivots", pivots == min(24, biped.parts.count),
          "\(pivots) of \(min(24, biped.parts.count))")

    // no rig may produce a NaN — one bad matrix is a screenful of garbage
    var clean = true
    for name in entityTypes() {
        guard hasModel(name) else { continue }
        let mats = pebPoseParts(getModel(name), walking, 1.25)
        for m in mats {
            for v in m.m where !v.isFinite { clean = false }
        }
    }
    check("no rig produces NaN or infinity", clean)
}

/// the sun's shadow matrix and the gate in front of it — also GPU-free
public func smokeShadowSuite() {
    section("sun shadows (matrix + gate, no GPU)")

    let over = World(dim: .overworld, seed: 1)
    let nether = World(dim: .nether, seed: 1)
    // y = cos(angle * 2pi), so the sun is overhead at angle 0 and on the
    // horizon at 0.25 — not the other way round
    let sunHigh = pebSunDirection(sunAngle: 0)
    check("sun is overhead at angle 0", sunHigh.1 > 0.9, "y = \(sunHigh.1)")
    check("sun is at the horizon at angle 0.25",
          abs(pebSunDirection(sunAngle: 0.25).1) < 0.01)
    check("shadows on in daylight overworld",
          pebShadowsOn(over, settingOn: true, dayLight: 1.0, sunDirY: sunHigh.1))
    check("shadows off when the setting is off",
          !pebShadowsOn(over, settingOn: false, dayLight: 1.0, sunDirY: sunHigh.1))
    check("shadows off in the nether",
          !pebShadowsOn(nether, settingOn: true, dayLight: 1.0, sunDirY: sunHigh.1))
    check("shadows off at night",
          !pebShadowsOn(over, settingOn: true, dayLight: 0.05, sunDirY: sunHigh.1))
    check("shadows off with the sun below the horizon",
          !pebShadowsOn(over, settingOn: true, dayLight: 1.0, sunDirY: -0.5))

    let m = pebShadowMatrix(sunDir: sunHigh, camX: 100.5, camY: 70.25, camZ: -40.75,
                            shadowSize: 2048)
    var finite = true
    for v in m.m where !v.isFinite { finite = false }
    check("shadow matrix is finite", finite)

    // a point at the camera must land inside the map, or nothing is ever lit
    func project(_ mm: Mat4f, _ x: Float, _ y: Float, _ z: Float) -> (Float, Float, Float) {
        let a = mm.m
        let cx = a[0] * x + a[4] * y + a[8] * z + a[12]
        let cy = a[1] * x + a[5] * y + a[9] * z + a[13]
        let cz = a[2] * x + a[6] * y + a[10] * z + a[14]
        let cw = a[3] * x + a[7] * y + a[11] * z + a[15]
        return (cx / cw, cy / cw, cz / cw)
    }
    let origin = project(m, 0, 0, 0)   // camera-relative, so the camera is 0,0,0
    check("the camera projects inside the shadow map",
          abs(origin.0) < 1 && abs(origin.1) < 1 && origin.2 > 0 && origin.2 < 1,
          "(\(origin.0), \(origin.1), \(origin.2))")

    // the texel snap must nudge, not shove: moving the camera a hair may not
    // move the shadow grid by more than one texel
    let a = pebShadowMatrix(sunDir: sunHigh, camX: 100.5, camY: 70.25, camZ: -40.75,
                            shadowSize: 2048)
    let b = pebShadowMatrix(sunDir: sunHigh, camX: 100.5001, camY: 70.25, camZ: -40.75,
                            shadowSize: 2048)
    let texel = 2 / Float(2048)
    check("texel snap stays within one texel",
          abs(a.m[12] - b.m[12]) <= texel * 1.001 && abs(a.m[13] - b.m[13]) <= texel * 1.001,
          "dx \(a.m[12] - b.m[12]) dy \(a.m[13] - b.m[13])")
}

/// the matrix inverse the sky ray and the ultra pass both depend on
public func smokeMatrixSuite() {
    section("matrix inverse (sky ray + ultra unprojection)")
    let proj = mat4fPerspective(fovYRad: 70 * .pi / 180, aspect: 16.0 / 9, near: 0.05, far: 800)
    let view = mat4fLookDir(eyeX: 0, eyeY: 0, eyeZ: 0,
                            dirX: 0.3, dirY: -0.2, dirZ: 0.9, upX: 0, upY: 1, upZ: 0)
    let vp = proj * view
    guard let inv = mat4fInverse(vp) else {
        check("viewProj is invertible", false)
        return
    }
    check("viewProj is invertible", true)
    let id = vp * inv
    var worst: Float = 0
    for i in 0..<16 {
        let want: Float = (i % 5 == 0) ? 1 : 0
        worst = max(worst, abs(id.m[i] - want))
    }
    check("viewProj * inverse is the identity", worst < 1e-3, "worst term off by \(worst)")

    // a point in front of the camera must survive the round trip
    let px: Float = 3, py: Float = -1, pz: Float = 12
    let m = vp.m
    let cw = m[3] * px + m[7] * py + m[11] * pz + m[15]
    let cx = (m[0] * px + m[4] * py + m[8] * pz + m[12]) / cw
    let cy = (m[1] * px + m[5] * py + m[9] * pz + m[13]) / cw
    let cz = (m[2] * px + m[6] * py + m[10] * pz + m[14]) / cw
    let n = inv.m
    let bw = n[3] * cx + n[7] * cy + n[11] * cz + n[15]
    let bx = (n[0] * cx + n[4] * cy + n[8] * cz + n[12]) / bw
    let by = (n[1] * cx + n[5] * cy + n[9] * cz + n[13]) / bw
    let bz = (n[2] * cx + n[6] * cy + n[10] * cz + n[14]) / bw
    check("unprojection round-trips a world point",
          abs(bx - px) < 0.01 && abs(by - py) < 0.01 && abs(bz - pz) < 0.01,
          "(\(bx), \(by), \(bz)) vs (\(px), \(py), \(pz))")

    check("a singular matrix returns nil", mat4fInverse(Mat4f([Float](repeating: 0, count: 16))) == nil)
}
