// The sun's view-projection for the shadow pass, and the gate that decides
// whether shadows run at all. Extracted verbatim from WorldRenderer.render so
// both backends light the world from the same angle (PORTING module 07
// shadow slice).

import Foundation

/// shadows are overworld-only, need real daylight, and need the sun above the
/// horizon — the Mac's `shadowOK`
public func pebShadowsOn(_ w: World, settingOn: Bool, dayLight: Double,
                         sunDirY: Float) -> Bool {
    settingOn && w.dim == .overworld && dayLight > 0.1 && sunDirY > 0.05
}

/// the sun's view-projection, snapped to the shadow map's texel grid. The
/// snap pins the grid to the world rather than the camera: without it the
/// sub-texel drift while walking reads as shimmering shadow edges.
public func pebShadowMatrix(sunDir: (Float, Float, Float),
                            camX: Double, camY: Double, camZ: Double,
                            shadowSize: Int) -> Mat4f {
    let r: Float = 72
    let lightView = mat4fLookDir(eyeX: sunDir.0 * 120, eyeY: sunDir.1 * 120, eyeZ: sunDir.2 * 120,
                                 dirX: -sunDir.0, dirY: -sunDir.1, dirZ: -sunDir.2,
                                 upX: 0, upY: 1, upZ: 0)
    let lightProj = mat4fOrtho(l: -r, r: r, b: -r, t: r, n: 1, f: 320)
    var shadowMat = lightProj * lightView

    let ax = Float(-camX), ay = Float(-camY), az = Float(-camZ)
    let m = shadowMat.m
    let clipX = m[0] * ax + m[4] * ay + m[8] * az + m[12]
    let clipY = m[1] * ax + m[5] * ay + m[9] * az + m[13]
    let texel = 2 / Float(shadowSize)
    var snap = Mat4f()
    snap.m[12] = -clipX.truncatingRemainder(dividingBy: texel)
    snap.m[13] = -clipY.truncatingRemainder(dividingBy: texel)
    shadowMat = snap * shadowMat
    return shadowMat
}
