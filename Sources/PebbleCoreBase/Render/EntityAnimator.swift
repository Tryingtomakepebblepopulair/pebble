// The entity animator: the walk cycle, head turn, limb swing and every
// per-species quirk, as 24 part matrices. Pure math over a MobModel and an
// EntityPose — extracted verbatim from the Metal EntityRendererM so the
// Vulkan backend animates identically (PORTING module 07 animation slice).
//
// The matrix helpers are the portable Mat4f ones, which use detSin/detCos
// rather than libm: bit-stable on every platform, same result to the eye.

import Foundation

public struct EntityPose {
    public var x = 0.0, y = 0.0, z = 0.0
    public var yaw = 0.0
    public var headYaw = 0.0
    public var pitch = 0.0
    public var limbSwing = 0.0
    public var limbAmp = 0.0
    public var attackSwing = 0.0
    public var hurtFlash = 0.0
    public var scale = 1.0
    public var baby = false
    public var sky = 0, block = 0
    public var ageTicks = 0
    public var alpha = 1.0
    // mob-specific data (the golden baselines read these off ent.data)
    public var aiming = false
    public var crossed = false
    public var grazing = false
    public var airborne = false
    public var hanging = false
    public var open = 0.0
    public var sitting = false
    /// players: raised-shield pose ("main" | "off" hand), nil = not blocking
    public var blockingHand: String?

    public init() {}
}

/// the 24 part matrices for one posed entity
public func pebPoseParts(_ model: MobModel, _ p: EntityPose, _ time: Double) -> [Mat4f] {
    var out = [Mat4f](repeating: Mat4f(), count: 24)
    let swing = p.limbSwing
    let amp = p.limbAmp
    let walkA = Foundation.cos(swing * 0.6662) * 1.2 * amp
    let walkB = Foundation.cos(swing * 0.6662 + .pi) * 1.2 * amp
    let idle = Foundation.sin(time * 2 + p.x) * 0.02
    for i in 0..<24 {
        guard i < model.parts.count else {
            out[i] = Mat4f()
            continue
        }
        let part = model.parts[i]
        var m = Mat4f()
        let (px, py, pz) = part.pivot
        m = m * mat4fTranslation(Float(px / 16), Float(py / 16), Float(pz / 16))
        // baked part rotation (vanilla rotated boxes: quadruped bodies etc.)
        let (brx, bry, brz) = part.rot
        if brz != 0 { m = m * mat4fRotateZ(Float(brz)) }
        if bry != 0 { m = m * mat4fRotateY(Float(bry)) }
        if brx != 0 { m = m * mat4fRotateX(Float(brx)) }
        let n = part.name
        let anim = model.anim
        switch anim {
        case "biped", "zombie", "skeleton", "illager", "villager", "fly_biped":
            if n == "head" {
                m = m * mat4fRotateY(Float(p.headYaw))
                m = m * mat4fRotateX(Float(-p.pitch))
            } else if n == "armR" {
                var rx = walkA * 0.8
                if anim == "zombie" || (anim == "skeleton" && p.aiming) { rx = .pi / 2 + idle * 4 }
                if p.attackSwing > 0 { rx = .pi / 2 * Foundation.sin(p.attackSwing * .pi) + 0.4 }
                if anim == "illager" && p.crossed { rx = 0.7 }
                if p.blockingHand == "main" {
                    m = m * mat4fRotateY(-0.35)
                    rx = 0.55
                }
                m = m * mat4fRotateX(Float(rx))
            } else if n == "armL" {
                var rx = walkB * 0.8
                if anim == "zombie" { rx = .pi / 2 - idle * 4 }
                if anim == "illager" && p.crossed { rx = 0.7 }
                if p.blockingHand == "off" {
                    m = m * mat4fRotateY(0.35)
                    rx = 0.55
                }
                m = m * mat4fRotateX(Float(rx))
            } else if n == "legR" {
                m = m * mat4fRotateX(Float(walkA))
            } else if n == "legL" {
                m = m * mat4fRotateX(Float(walkB))
            } else if n == "wingR" {
                m = m * mat4fRotateY(Float(Foundation.sin(time * 18) * 0.8 + 0.3))
            } else if n == "wingL" {
                m = m * mat4fRotateY(Float(-Foundation.sin(time * 18) * 0.8 - 0.3))
            }
        case "quad", "quadTail", "horse":
            if n == "head" {
                m = m * mat4fRotateY(Float(p.headYaw * 0.6))
                m = m * mat4fRotateX(Float(-(p.pitch * 0.6) - (p.grazing ? 0.9 : 0)))
            } else if n == "legFR" || n == "legBL" {
                m = m * mat4fRotateX(Float(walkA))
            } else if n == "legFL" || n == "legBR" {
                m = m * mat4fRotateX(Float(walkB))
            } else if n == "tail" {
                m = m * mat4fRotateX(Float(-0.6 - Foundation.sin(time * 3) * 0.15 * (1 + amp * 2)))
            }
        case "creeper":
            if n == "head" {
                m = m * mat4fRotateY(Float(p.headYaw))
                m = m * mat4fRotateX(Float(-p.pitch))
            } else if n == "legFR" || n == "legBL" {
                m = m * mat4fRotateX(Float(walkA * 0.6))
            } else if n == "legFL" || n == "legBR" {
                m = m * mat4fRotateX(Float(walkB * 0.6))
            }
        case "spider":
            if n.hasPrefix("legR") || n.hasPrefix("legL") {
                let li = Double(Int(n.dropFirst(4)) ?? 0)
                let side: Double = n[n.index(n.startIndex, offsetBy: 3)] == "R" ? -1 : 1
                let lift = Foundation.cos(swing * 0.6662 * 2 + li * 1.7) * 0.3 * amp
                m = m * mat4fRotateZ(Float(-side * 0.55))
                m = m * mat4fRotateY(Float((li - 1.5) * 0.5236 * side))
                m = m * mat4fRotateZ(Float(-side * (0.05 + abs(lift))))
            } else if n == "head" {
                m = m * mat4fRotateY(Float(p.headYaw * 0.4))
            }
        case "chicken":
            if n == "head" {
                m = m * mat4fRotateY(Float(p.headYaw))
                m = m * mat4fRotateX(Float(-p.pitch))
            } else if n == "legR" {
                m = m * mat4fRotateX(Float(walkA))
            } else if n == "legL" {
                m = m * mat4fRotateX(Float(walkB))
            } else if n == "wingR" {
                m = m * mat4fRotateZ(Float(p.airborne ? Foundation.sin(time * 30) * 0.8 + 0.8 : 0))
            } else if n == "wingL" {
                m = m * mat4fRotateZ(Float(p.airborne ? -Foundation.sin(time * 30) * 0.8 - 0.8 : 0))
            }
        case "slime":
            let squish = 1 + Foundation.sin(time * 6 + p.x) * 0.06 * (1 + amp)
            m = m * mat4fScale(Float(squish), Float(1 / squish), Float(squish))
        case "blaze":
            if n.hasPrefix("rod") {
                let ri = Double(Int(n.dropFirst(3)) ?? 0)
                let ring = (ri / 4).rounded(.down)
                let ang = (ri.truncatingRemainder(dividingBy: 4)) / 4 * .pi * 2 + time * (ring == 1 ? -1.1 : 1.3) + ring * 0.7
                let r = 5.0 / 16 + ring * 2 / 16
                m = m * mat4fTranslation(Float(Foundation.cos(ang) * r),
                               Float(-ring * 5 / 16 + Foundation.sin(time * 3 + ri) * 0.04),
                               Float(Foundation.sin(ang) * r))
            } else if n == "head" {
                m = m * mat4fRotateY(Float(p.headYaw))
                m = m * mat4fRotateX(Float(-p.pitch))
            }
        case "ghast":
            if n.hasPrefix("tent") {
                let ti = Double(Int(n.dropFirst(4)) ?? 0)
                m = m * mat4fRotateX(Float(Foundation.sin(time * 2 + ti * 1.3) * 0.25))
            }
        case "squid":
            if n.hasPrefix("tent") {
                let ti = Double(Int(n.dropFirst(4)) ?? 0)
                let ang = ti / 8 * .pi * 2
                let sway = Foundation.sin(time * 4 + ti) * 0.3 + 0.4 * amp
                m = m * mat4fRotateX(Float(Foundation.cos(ang) * sway * 0.4))
                m = m * mat4fRotateZ(Float(-Foundation.sin(ang) * sway * 0.4))
            }
        case "fish", "dolphin":
            if n == "tail" {
                m = m * mat4fRotateY(Float(Foundation.sin(time * 8 + swing) * 0.5))
            } else if n == "body" && anim == "fish" {
                m = m * mat4fRotateY(Float(Foundation.sin(time * 8) * 0.1))
            } else if n == "head" && anim == "dolphin" {
                m = m * mat4fRotateX(Float(-p.pitch * 0.5))
            }
        case "guardian":
            if n.hasPrefix("spike") {
                let si = Int(n.dropFirst(5)) ?? 0
                let dirs: [(Double, Double, Double)] = [
                    (1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1),
                    (0.7, 0.7, 0), (-0.7, 0.7, 0), (0.7, -0.7, 0), (-0.7, -0.7, 0), (0, 0.7, 0.7), (0, 0.7, -0.7),
                ]
                let d = dirs[si % dirs.count]
                let ext = 0.45 + Foundation.sin(time * 2 + Double(si)) * 0.06
                m = m * mat4fTranslation(Float(d.0 * ext), Float(d.1 * ext), Float(d.2 * ext))
                // typed sub-expressions: the nested-ternary Float(...) forms
                // overrun the Swift type-checker on some toolchains (6.2.4).
                // Same arithmetic.
                var ax: Double = 0
                if d.2 != 0 {
                    let sx: Double = d.2 > 0 ? 1.0 : -1.0
                    ax = sx * Double.pi / 2 * abs(d.2)
                }
                m = m * mat4fRotateX(Float(ax))
                var az: Double = d.1 < 0 ? Double.pi : 0
                if d.0 != 0 {
                    let sz: Double = d.0 > 0 ? 1.0 : -1.0
                    az = -sz * Double.pi / 2 * abs(d.0)
                }
                m = m * mat4fRotateZ(Float(az))
            } else if n == "tail" {
                m = m * mat4fRotateY(Float(Foundation.sin(time * 4) * 0.3))
            }
        case "shulker":
            if n == "lid" {
                let open = p.open
                m = m * mat4fTranslation(0, Float(open * 0.45), 0)
                m = m * mat4fRotateY(Float(open * time * 1.5))
            }
        case "crystal":
            if n == "crystal" {
                m = m * mat4fTranslation(0, Float(Foundation.sin(time * 1.5) * 0.1), 0)
                m = m * mat4fRotateY(Float(time * 1.6))
                m = m * mat4fRotateZ(0.96)
            }
        case "bat":
            if n == "wingR" {
                m = m * mat4fRotateY(Float(Foundation.sin(time * 22) * 1 + 0.4))
            } else if n == "wingL" {
                m = m * mat4fRotateY(Float(-Foundation.sin(time * 22) * 1 - 0.4))
            } else if n == "head" && p.hanging {
                m = m * mat4fRotateX(.pi)
            }
        case "bee":
            if n == "wingR" {
                m = m * mat4fRotateY(Float(Foundation.sin(time * 40) * 0.9 + 0.3))
            } else if n == "wingL" {
                m = m * mat4fRotateY(Float(-Foundation.sin(time * 40) * 0.9 - 0.3))
            } else if n == "body" {
                m = m * mat4fRotateX(Float(Foundation.sin(time * 3) * 0.08))
            }
        case "parrot":
            if n == "wingR" || n == "wingL" {
                let flap = p.airborne ? Foundation.sin(time * 25) * 0.8 : 0
                m = m * mat4fRotateZ(Float((n == "wingR" ? 1.0 : -1.0) * flap))
            } else if n == "head" {
                m = m * mat4fRotateY(Float(p.headYaw))
                m = m * mat4fRotateX(Float(-p.pitch))
            }
        case "phantom":
            if n == "wingR" {
                m = m * mat4fRotateZ(Float(Foundation.sin(time * 4) * 0.3 + 0.1))
            } else if n == "wingL" {
                m = m * mat4fRotateZ(Float(-Foundation.sin(time * 4) * 0.3 - 0.1))
            }
        case "dragon":
            if n == "wingR" {
                m = m * mat4fRotateZ(Float(Foundation.sin(time * 1.6) * 0.55 + 0.12))
            } else if n == "wingL" {
                m = m * mat4fRotateZ(Float(-Foundation.sin(time * 1.6) * 0.55 - 0.12))
            } else if n == "head" {
                m = m * mat4fRotateY(Float(p.headYaw * 0.5))
                m = m * mat4fRotateX(Float(-p.pitch * 0.5))
            } else if n.hasPrefix("tail") {
                let ti = Double(Int(n.dropFirst(4)) ?? 0)
                m = m * mat4fRotateY(Float(Foundation.sin(time * 1.2 - ti * 0.6) * 0.18))
            } else if n.hasPrefix("leg") {
                m = m * mat4fRotateX(0.4)
            }
        case "wither":
            if n == "head" {
                m = m * mat4fRotateY(Float(p.headYaw))
                m = m * mat4fRotateX(Float(-p.pitch))
            } else if n == "headR" {
                m = m * mat4fRotateY(Float(p.headYaw + Foundation.sin(time * 1.4) * 0.3))
            } else if n == "headL" {
                m = m * mat4fRotateY(Float(p.headYaw - Foundation.sin(time * 1.7) * 0.3))
            }
        case "snowman":
            if n == "head" {
                m = m * mat4fRotateY(Float(p.headYaw))
            } else if n == "armR" {
                m = m * mat4fRotateZ(Float(Foundation.sin(time * 2) * 0.05))
            } else if n == "armL" {
                m = m * mat4fRotateZ(Float(-Foundation.sin(time * 2) * 0.05))
            }
        case "strider":
            if n == "legR" {
                m = m * mat4fRotateX(Float(walkA))
            } else if n == "legL" {
                m = m * mat4fRotateX(Float(walkB))
            }
        case "rabbit", "frog":
            let hop = min(1, max(0, Foundation.sin(swing * 1.2) * amp * 2))
            if n.hasPrefix("legB") {
                m = m * mat4fRotateX(Float(-hop * 0.8))
            } else if n.hasPrefix("legF") {
                m = m * mat4fRotateX(Float(hop * 0.5))
            }
        case "silverfish":
            if n == "body" {
                m = m * mat4fRotateY(Float(Foundation.sin(swing * 1.5) * 0.15 * amp))
            }
        default:
            break
        }
        out[i] = m
    }
    return out
}
