// The sky/day-light computation, shared by every renderer (PORTING module
// 06): at the same world.dayTime a Mac and a Windows machine MUST show the
// same sky and the same terrain brightness — multiplayer already keeps
// dayTime in lockstep, this keeps the eyes in lockstep too. Extracted
// verbatim from the Metal WorldRenderer.skyColors.

import Foundation

public struct PebSky {
    public var zenith: (Float, Float, Float) = (0, 0, 0)
    public var horizon: (Float, Float, Float) = (0, 0, 0)
    public var fog: (Float, Float, Float) = (0, 0, 0)
    public var dayLight = 1.0
    public var sunGlow = 0.0
    public init() {}
}

public func pebSkyColors(_ world: World, nightVision: Double = 0) -> PebSky {
    var out = PebSky()
    let info = world.info
    if world.dim == .nether {
        let f = info.fogColor
        out.zenith = (Float(f.0 * 0.55), Float(f.1 * 0.5), Float(f.2 * 0.5))
        out.horizon = (Float(f.0), Float(f.1), Float(f.2))
        out.fog = out.horizon
        return out
    }
    if world.dim == .end {
        out.zenith = (0.03, 0.025, 0.05)
        out.horizon = (0.1, 0.08, 0.13)
        out.fog = (0.07, 0.06, 0.1)
        return out
    }
    let angle = world.sunAngle()
    let sunH = Foundation.cos(angle * .pi * 2)
    let day = min(1.0, max(0.0, sunH * 2 + 0.5))
    let dusk = min(1.0, max(0.0, 1 - abs(sunH) * 3.2))
    let rain = Float(world.rainLevel)
    func lerp3(_ a: (Float, Float, Float), _ b: (Float, Float, Float), _ t: Float) -> (Float, Float, Float) {
        (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
    }
    var zenith = lerp3((0.012, 0.015, 0.04), (0.45, 0.65, 1.0), Float(day))
    var horizon = lerp3((0.04, 0.05, 0.1), (0.74, 0.84, 1.0), Float(day))
    let grayZ = (zenith.0 + zenith.1 + zenith.2) / 3
    let grayH = (horizon.0 + horizon.1 + horizon.2) / 3
    zenith = lerp3(zenith, (grayZ * 0.7, grayZ * 0.7, grayZ * 0.75), rain)
    horizon = lerp3(horizon, (grayH * 0.75, grayH * 0.75, grayH * 0.8), rain)
    out.zenith = zenith
    out.horizon = horizon
    out.fog = horizon
    out.dayLight = min(1, max(0.06, day + nightVision))
    out.sunGlow = dusk * (1 - Double(rain))
    return out
}
