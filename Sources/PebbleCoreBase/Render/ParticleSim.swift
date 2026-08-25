// The CPU particle simulation: spawn recipes, physics and the frozen
// 48-byte instance encoding (tile*256 + size*100). Extracted verbatim from
// the Metal ParticlesM so the Vulkan backend simulates and draws exactly the
// same particles (PORTING module 07 detail slice). Foundation only.

import Foundation

private struct Particle {
    var x = 0.0, y = 0.0, z = 0.0
    var vx = 0.0, vy = 0.0, vz = 0.0
    var life = 0.0, maxLife = 30.0
    var size = 0.1
    var gravity = 0.04
    var drag = 0.98
    var tile = 0
    var u0 = 0.0, v0 = 0.0, u1 = 0.25, v1 = 0.25
    var r = 1.0, g = 1.0, b = 1.0
    var light = 1.0
    var collide = false
    var shrink = true
}

public let PEB_MAX_PARTICLES = 4096

public final class PebParticles {
    private var particles: [Particle] = []
    private var rngState: UInt32 = 12345

    public init() {}

    private func rand() -> Double {
        rngState = rngState &* 1664525 &+ 1013904223
        return Double(rngState) / 4294967296.0
    }

    private func push(_ p: Particle) {
        if particles.count >= PEB_MAX_PARTICLES { particles.removeFirst() }
        particles.append(p)
    }

    public var count: Int { particles.count }

    public func clear() { particles.removeAll() }

    /// spawn by type name; `cell` carries the block cell for 'block' particles, `note` for notes
    public func spawn(_ world: World, _ type: String, _ x: Double, _ y: Double, _ z: Double,
               _ count: Int, _ spread: Double = 0.3, cell: Int = 0, note: Int = 0, groundY: Double = 0) {
        let lightOf = world.lightAt(ifloor(x), ifloor(y), ifloor(z)) / 15
        for _ in 0..<count {
            let ox = (rand() - 0.5) * 2 * spread
            let oy = (rand() - 0.5) * 2 * spread
            let oz = (rand() - 0.5) * 2 * spread
            var p = Particle()
            p.x = x + ox; p.y = y + oy; p.z = z + oz
            p.vx = (rand() - 0.5) * 0.08; p.vy = rand() * 0.1; p.vz = (rand() - 0.5) * 0.08
            p.maxLife = 20 + rand() * 20
            p.size = 0.08 + rand() * 0.06
            p.tile = tileId("stone")
            p.light = lightOf
            switch type {
            case "block":
                let id = cell >> 4
                if id == 0 { return }
                let def = blockDefs[id]
                p.tile = def.texFn?(cell & 15, 2) ?? (def.tex.isEmpty ? 0 : Int(def.tex[2]))
                let u = rand() * 0.75, v = rand() * 0.75
                p.u0 = u; p.v0 = v; p.u1 = u + 0.25; p.v1 = v + 0.25
                if TINT_OF[id] == 1 || TINT_OF[id] == 2 {
                    let bm = BIOMES[world.biomeAt(ifloor(x), ifloor(y), ifloor(z))]
                    let c = TINT_OF[id] == 1 ? (bm?.grassColor ?? 0x91bd59) : (bm?.foliageColor ?? 0x77ab2f)
                    p.r = Double((c >> 16) & 255) / 255; p.g = Double((c >> 8) & 255) / 255; p.b = Double(c & 255) / 255
                }
                p.vx = (rand() - 0.5) * 0.2
                p.vy = rand() * 0.18 + 0.05
                p.vz = (rand() - 0.5) * 0.2
                p.collide = true
                p.maxLife = 14 + rand() * 16
            case "smoke", "campfire_smoke":
                p.tile = tileId("smoke_particle")
                p.gravity = -0.004
                p.vy = 0.04 + rand() * 0.04
                p.vx *= 0.4; p.vz *= 0.4
                p.maxLife = type == "campfire_smoke" ? 80 + rand() * 60 : 30 + rand() * 20
                let g2 = 0.25 + rand() * 0.2
                p.r = g2; p.g = g2; p.b = g2
                p.size = 0.12 + rand() * 0.1
            case "flame":
                p.tile = tileId("flame_particle")
                p.gravity = -0.001
                p.vx *= 0.2; p.vy = 0.01; p.vz *= 0.2
                p.maxLife = 16 + rand() * 10
                p.light = 1
                p.size = 0.07
            case "soul_flame":
                p.tile = tileId("flame_particle")
                p.r = 0.2; p.g = 0.85; p.b = 0.9
                p.gravity = -0.002
                p.maxLife = 20
                p.light = 1
                p.size = 0.07
            case "portal":
                p.tile = tileId("portal_particle")
                p.gravity = -0.01
                p.vx = (rand() - 0.5) * 0.25
                p.vy = (rand() - 0.5) * 0.25
                p.vz = (rand() - 0.5) * 0.25
                p.r = 0.5 + rand() * 0.3; p.g = 0.2; p.b = 0.8
                p.light = 1
                p.maxLife = 30 + rand() * 30
            case "crit":
                p.tile = tileId("crit_particle")
                p.vx = (rand() - 0.5) * 0.4
                p.vy = rand() * 0.3
                p.vz = (rand() - 0.5) * 0.4
                p.r = 1; p.g = 0.85; p.b = 0.4
                p.maxLife = 10 + rand() * 8
            case "heart":
                p.tile = tileId("heart_particle")
                p.gravity = -0.002
                p.vy = 0.05
                p.maxLife = 24
                p.size = 0.12
                p.light = 1
            case "angry":
                p.tile = tileId("angry_particle")
                p.gravity = -0.002
                p.maxLife = 20
                p.size = 0.12
                p.light = 1
            case "splash", "bubble":
                p.tile = tileId(type == "bubble" ? "bubble_particle" : "splash_particle")
                p.gravity = type == "bubble" ? -0.02 : 0.06
                p.vy = type == "bubble" ? 0.05 : 0.18 + rand() * 0.1
                p.r = 0.7; p.g = 0.8; p.b = 1
                p.maxLife = type == "bubble" ? 18 : 14
            case "drip_water", "drip_lava":
                p.tile = tileId(type == "drip_water" ? "splash_particle" : "flame_particle")
                p.gravity = 0.05
                p.vx = 0; p.vz = 0; p.vy = 0
                p.maxLife = 40
                p.collide = true
                if type == "drip_lava" { p.r = 1; p.g = 0.5; p.b = 0.1; p.light = 1 }
                else { p.r = 0.3; p.g = 0.45; p.b = 1 }
            case "rain":
                p.tile = tileId("splash_particle")
                p.gravity = 0
                p.vx = 0; p.vz = 0
                p.vy = -0.9 - rand() * 0.2
                p.r = 0.6; p.g = 0.7; p.b = 1
                p.maxLife = 30
                p.size = 0.1
                p.collide = true
                p.shrink = false
            case "snow":
                p.tile = tileId("snow_particle")
                p.gravity = 0
                p.vy = -0.06 - rand() * 0.04
                p.vx = (rand() - 0.5) * 0.03
                p.vz = (rand() - 0.5) * 0.03
                p.maxLife = 120
                p.size = 0.07
                p.collide = true
                p.shrink = false
            case "cherry_petal":
                p.tile = tileId("petal_particle")
                p.gravity = 0.003
                p.drag = 0.96
                p.vx = (rand() - 0.5) * 0.06
                p.vy = -0.02
                p.vz = (rand() - 0.5) * 0.06
                p.maxLife = 140
                p.size = 0.09
                p.collide = true
                p.shrink = false
            case "note":
                p.tile = tileId("note_particle")
                p.gravity = -0.004
                let hue = Double(note) / 24
                p.r = min(1, max(0, Foundation.sin(hue * 6.28) * 0.5 + 0.6))
                p.g = min(1, max(0, Foundation.sin(hue * 6.28 + 2.1) * 0.5 + 0.6))
                p.b = min(1, max(0, Foundation.sin(hue * 6.28 + 4.2) * 0.5 + 0.6))
                p.maxLife = 18
                p.light = 1
                p.size = 0.12
            case "redstone":
                p.tile = tileId("redstone_particle")
                p.gravity = 0
                p.vx = 0; p.vy = 0.005; p.vz = 0
                p.r = 1; p.g = 0.15; p.b = 0.1
                p.maxLife = 18
                p.light = 1
                p.size = 0.09
            case "explosion":
                p.tile = tileId("smoke_particle")
                p.size = 0.5 + rand() * 0.6
                p.gravity = -0.002
                p.vx = (rand() - 0.5) * 0.3
                p.vy = (rand() - 0.5) * 0.3
                p.vz = (rand() - 0.5) * 0.3
                let w = 0.85 + rand() * 0.15
                p.r = w; p.g = w * 0.95; p.b = w * 0.85
                p.maxLife = 12 + rand() * 10
                p.light = 1
            case "sculk_soul", "soul":
                p.tile = tileId("soul_particle")
                p.gravity = -0.006
                p.r = 0.25; p.g = 0.8; p.b = 0.85
                p.maxLife = 40
                p.light = 1
            case "enchant":
                p.tile = tileId("enchant_particle")
                p.gravity = 0.02
                p.vx = (rand() - 0.5) * 0.3
                p.vy = 0.2 + rand() * 0.2
                p.vz = (rand() - 0.5) * 0.3
                p.r = 0.8; p.g = 0.6; p.b = 1
                p.maxLife = 26
                p.light = 1
            case "slime":
                p.tile = tileId("slime_particle")
                p.r = 0.45; p.g = 0.8; p.b = 0.35
                p.maxLife = 12
            case "totem":
                p.tile = tileId("crit_particle")
                p.r = 0.5 + rand() * 0.5; p.g = 0.9; p.b = 0.3
                p.vx = (rand() - 0.5) * 0.5
                p.vy = rand() * 0.5
                p.vz = (rand() - 0.5) * 0.5
                p.maxLife = 40 + rand() * 30
                p.light = 1
            case "squid_ink":
                p.tile = tileId("smoke_particle")
                p.r = 0.08; p.g = 0.08; p.b = 0.12
                p.gravity = 0.01
                p.maxLife = 30
                p.size = 0.15
            case "glow":
                p.tile = tileId("crit_particle")
                p.r = 0.4; p.g = 0.95; p.b = 0.85
                p.gravity = -0.001
                p.light = 1
                p.maxLife = 30
            case "dragon_breath":
                p.tile = tileId("portal_particle")
                p.r = 0.75; p.g = 0.2; p.b = 0.85
                p.gravity = 0.002
                p.light = 1
                p.maxLife = 30 + rand() * 20
                p.size = 0.14
            case "wax":
                p.tile = tileId("crit_particle")
                p.r = 1; p.g = 0.7; p.b = 0.2
                p.maxLife = 12
            case "sweep":
                p.tile = tileId("sweep_particle")
                p.size = 0.6
                p.gravity = 0
                p.vx = 0; p.vy = 0; p.vz = 0
                p.maxLife = 5
                p.light = 1
            default:
                break
            }
            push(p)
        }
    }

    public func tick(_ world: World) {
        var i = particles.count - 1
        while i >= 0 {
            particles[i].life += 1
            if particles[i].life >= particles[i].maxLife {
                particles.remove(at: i)
                i -= 1
                continue
            }
            var p = particles[i]
            p.vy -= p.gravity
            p.vx *= p.drag; p.vy *= p.drag; p.vz *= p.drag
            let nx = p.x + p.vx, ny = p.y + p.vy, nz = p.z + p.vz
            if p.collide {
                let cell = world.getBlock(ifloor(nx), ifloor(ny), ifloor(nz))
                let id = cell >> 4
                if id != 0 && blockDefs[id].solid {
                    p.vx = 0; p.vz = 0
                    if p.vy < 0 {
                        p.vy = 0
                        p.life = max(p.life, p.maxLife - 4)
                    }
                    particles[i] = p
                    i -= 1
                    continue
                }
            }
            p.x = nx; p.y = ny; p.z = nz
            particles[i] = p
            i -= 1
        }
    }

    /// pack the live particles into the frozen 48-byte instance stream
    /// (12 floats each) and return how many were written. `out` must hold at
    /// least PEB_MAX_PARTICLES * 12 floats.
    public func encodeInstances(camX: Double, camY: Double, camZ: Double,
                                into out: inout [Float]) -> Int {
        let n = min(particles.count, PEB_MAX_PARTICLES)
        if n == 0 { return 0 }
        for i in 0..<n {
            let p = particles[i]
            let o = i * 12
            out[o] = Float(p.x - camX)
            out[o + 1] = Float(p.y - camY)
            out[o + 2] = Float(p.z - camZ)
            out[o + 3] = Float(p.u0)
            out[o + 4] = Float(p.v0)
            out[o + 5] = Float(p.u1)
            out[o + 6] = Float(p.v1)
            let lifeF = p.shrink ? max(0.2, 1 - p.life / p.maxLife) : 1
            out[o + 7] = Float(Double(p.tile) * 256 + min(255, p.size * lifeF * 100))
            out[o + 8] = Float(p.r)
            out[o + 9] = Float(p.g)
            out[o + 10] = Float(p.b)
            out[o + 11] = Float(p.light)
        }
        return n
    }
}
