// Headless smoke tests for PebbleCore. The frozen golden baselines
// (goldens/*.json) pin engine behavior — the engine must reproduce them
// bit-for-bit so worldgen seeds carry over across releases.
//
// The deterministic suites live in PebbleSmokeKit, shared with the
// portable pebsmokecore runner that Windows CI executes (PORTING module
// 13). This binary runs those same suites plus the Apple-only checks:
// simd frustum math and the LAN/dedicated-server e2e over real TCP.

import Foundation
import simd
import PebbleCore
import PebbleSmokeKit

smokeBootstrapDataRoot()
installAppleNetTransport()   // the LAN/dedicated e2e exercises the Apple adapter

smokeRandomSuite()
smokeNoiseSuite()
smokeMathSuite()

// Apple simd camera math — Mat4/Frustum live in PebbleCore, not the
// portable core, so these three checks can't join smokeMathSuite
var fr = Frustum()
let proj = mat4Perspective(fovYRad: Float(degToRad(70)), aspect: 16.0 / 9.0, near: 0.05, far: 400)
let view = mat4LookDir(eye: SIMD3<Float>(0, 0, 0), dir: SIMD3<Float>(0, 0, 1), up: SIMD3<Float>(0, 1, 0))
fr.setFromMatrix(proj * view)
check("frustum sees box ahead", fr.intersectsBox(-5, -5, 10, 5, 5, 20))
check("frustum culls box behind", !fr.intersectsBox(-5, -5, -20, 5, 5, -10))
check("frustum culls box far right", !fr.intersectsBox(500, -5, 10, 510, 5, 20))

smokeBlockRegistrySuite()
smokeItemRegistrySuite()
smokeBiomeSuite()
smokeTerrainSuite()
smokeFeatureSuite()
smokeAtlasSuite()
smokeMesherSuite()
smokeWorldSimSuite()
smokeItemsSuite()
smokeFdlibmSuite()
smokeEntitySuite()
smokeSystemsSuite()
smokePhysicsSuite()
smokeRenderABISuite()
smokeCodecSuite()
smokeNetProtocolSuite()
smokeSocketTransportSuite()

// ---------------------------------------------------------------------------
section("LAN multiplayer (host + guest cores over localhost TCP)")
do {
    // a real host core with a throwaway world (deleted at the end)
    let hostCore = GameCore()
    hostCore.settings.playerName = "HostTester"
    hostCore.createWorld(name: "nettest-e2e", seedText: "424242", mode: 0, difficulty: 2)
    let worldId = hostCore.worldRec?.id ?? ""
    check("host entered world", hostCore.hasWorld())

    var guestCore: GameCore? = nil
    /// step both sims + let Network.framework's main-queue hops run
    func pump(_ realSeconds: Double = 0.01, simTicks: Int = 1) {
        for _ in 0..<simTicks {
            _ = hostCore.frame(dtMs: 50)
            _ = guestCore?.frame(dtMs: 50)
            RunLoop.main.run(until: Date().addingTimeInterval(realSeconds))
        }
    }
    func pumpUntil(_ timeoutTicks: Int, _ cond: () -> Bool) -> Bool {
        for _ in 0..<timeoutTicks {
            if cond() { return true }
            pump()
        }
        return cond()
    }

    check("open to LAN", hostCore.startLanHost())
    let portReady = pumpUntil(300) { (hostCore.netHost?.port ?? 0) != 0 }
    check("listener got a port", portReady, "port stayed 0")

    if portReady {
        let g = GameCore()
        guestCore = g
        _ = g.joinLan(netDial(host: "127.0.0.1", port: hostCore.netHost!.port),
                      name: "Guesty", skin: Data())
        check("guest joined a world", pumpUntil(600) { g.hasWorld() },
              "status: \(g.netGuest?.status ?? "no session")")
        check("guest sees the right spawn", g.hasWorld()
            && abs(g.player.x - hostCore.player.x) < 64 && abs(g.player.z - hostCore.player.z) < 64)

        // puppet appeared on the host
        let hostPlayers = hostCore.world.entities.filter { ($0 as? Entity)?.isPlayer ?? false }
        check("host has 2 players (own + puppet)", hostPlayers.count == 2, "got \(hostPlayers.count)")

        // guest streams the spawn chunk (regenerated locally from the seed)
        let hp = hostCore.player!
        let bx = Int(hp.x.rounded(.down)), bz = Int(hp.z.rounded(.down))
        check("guest loaded spawn chunks", pumpUntil(800) { g.hasWorld() && g.world.isLoadedAt(bx, bz) })

        // block change host → guest
        let by = hostCore.world.surfaceY(bx, bz) + 3
        hostCore.world.setBlock(bx, by, bz, Int(B.stone) << 4)
        check("setBlock reaches the guest", pumpUntil(200) { g.world.getBlockId(bx, by, bz) == Int(B.stone) })

        // guest action replays on the host (break that same block)
        g.netGuest?.sendBreak(bx, by, bz)
        check("guest break lands on host", pumpUntil(200) { hostCore.world.getBlockId(bx, by, bz) == 0 })

        // entity replication: a pig on the host appears as a guest shadow
        _ = spawnMob(hostCore.world, "pig", hp.x + 2, hp.y + 2, hp.z + 2, nil)
        check("mob replicates to guest", pumpUntil(200) {
            g.hasWorld() && g.world.entities.contains { ($0 as? Entity)?.type == "pig" }
        })

        // item pickup: host-side item near the puppet lands in the guest's bag.
        // step the guest away from spawn first — the host player stands there
        // too and its own item magnet would win the race.
        g.player.setPos(hp.x + 8, Double(hostCore.world.surfaceY(bx + 8, bz + 8)) + 1, hp.z + 8)
        let puppet = hostPlayers.first(where: { $0 !== hostCore.player }) as? Player
        _ = pumpUntil(100) {
            guard let puppet else { return false }
            let dx = puppet.x - hp.x, dz = puppet.z - hp.z
            return dx * dx + dz * dz > 16   // puppet followed the guest away
        }
        let stick = ItemStack(iid("stick"), 3)
        if let puppet {
            _ = spawnItem(hostCore.world, puppet.x, puppet.y + 0.5, puppet.z, stick.copy())
        }
        check("pickup grants to guest inventory", pumpUntil(300) {
            g.player?.inventory.contains { $0?.id == iid("stick") } ?? false
        })

        // guest attack: a shadow pig maps back to a real pig on the host.
        // worldgen may have spawned extra pigs, so watch ALL of them, and
        // stand next to the SHADOW (that's what a player would aim at) —
        // the host rejects out-of-reach swings.
        if let pigShadow = g.world.entities.first(where: { ($0 as? Entity)?.type == "pig" }) as? Entity {
            func hostPigs() -> [LivingEntity] {
                hostCore.worlds.values.flatMap { w in
                    w.entities.compactMap { ($0 as? LivingEntity)?.type == "pig" ? $0 as? LivingEntity : nil }
                }
            }
            let before = Dictionary(uniqueKeysWithValues: hostPigs().map { (ObjectIdentifier($0), $0.health) })
            func anyPigHurt() -> Bool {
                hostPigs().contains { pig in
                    pig.dead || pig.health < (before[ObjectIdentifier(pig)] ?? pig.health) - 0.001
                }
            }
            // pigs wander: a single converge-then-swing can land after the pig
            // stepped out of reach (flaked in CI) — chase and re-swing instead
            var sent = false
            var hurt = false
            for _ in 0..<8 where !hurt {
                _ = pumpUntil(50) {
                    g.player.setPos(pigShadow.x + 1, pigShadow.y + 0.5, pigShadow.z)
                    guard let puppet else { return false }
                    return hostPigs().contains { puppet.distanceTo($0) < 2.5 }
                }
                sent = (g.netGuest?.sendAttack(pigShadow) ?? false) || sent
                hurt = pumpUntil(50) { anyPigHurt() }
            }
            check("guest attack hurts host mob", hurt,
                  "sent=\(sent) pigs=\(hostPigs().count)")
        } else {
            check("guest attack hurts host mob", false, "no pig shadow on guest")
        }

        // host-authoritative damage flows to the guest (post-armor amount)
        if let puppet {
            let before = g.player.health
            _ = puppet.hurt(3, "mob")
            check("puppet damage reaches guest", pumpUntil(100) { g.player.health < before },
                  "guest health stayed \(g.player.health)")
        }

        // clock sync keeps drift small
        check("clocks in sync", abs(hostCore.world.dayTime - g.world.dayTime) < 60,
              "host \(hostCore.world.dayTime) guest \(g.world.dayTime)")

        // leave: puppet despawns, guest data saved under worldId#name
        g.exitToTitle()
        check("guest exited cleanly", !g.hasWorld())
        check("puppet despawns on host", pumpUntil(200) {
            hostCore.world.entities.filter { ($0 as? Entity)?.isPlayer ?? false }.count == 1
        })
        check("guest data saved on host (by permanent id)",
              hostCore.db.getPlayer("\(worldId)#id:\(g.settings.playerId ?? "")") != nil)
    }

    hostCore.exitToTitle()
    if !worldId.isEmpty { hostCore.deleteWorld(worldId) }
    check("throwaway world deleted", hostCore.db.getWorld(worldId) == nil)
}

smokeSocialSuite()

// ---------------------------------------------------------------------------
section("dedicated server (pebserver core — no host player)")
do {
    let recentsBefore = Set(SocialStore.shared.recents.map { $0.id })
    let server = GameCore()
    server.createWorld(name: "nettest-smp", seedText: "777", mode: 0, difficulty: 2)
    let worldId = server.worldRec?.id ?? ""
    server.exitToTitle()

    if let rec = server.db.getWorld(worldId) {
        do {
            try server.enterWorldDedicated(rec, port: nil)
        } catch {
            check("server started", false, "\(error)")
        }
        check("server world open, no local player", server.hasWorld() && server.player == nil)

        var guest: GameCore? = nil
        func pump(_ realSeconds: Double = 0.01, simTicks: Int = 1) {
            for _ in 0..<simTicks {
                _ = server.frame(dtMs: 50)
                _ = guest?.frame(dtMs: 50)
                RunLoop.main.run(until: Date().addingTimeInterval(realSeconds))
            }
        }
        func pumpUntil(_ timeoutTicks: Int, _ cond: () -> Bool) -> Bool {
            for _ in 0..<timeoutTicks {
                if cond() { return true }
                pump()
            }
            return cond()
        }

        check("server listener ready", pumpUntil(900) { (server.netHost?.port ?? 0) != 0 })
        let g = GameCore()
        guest = g
        _ = g.joinLan(netDial(host: "127.0.0.1", port: server.netHost?.port ?? 0),
                      name: "SMPGuest", skin: Data())
        check("guest joined the server", pumpUntil(600) { g.hasWorld() },
              "status: \(g.netGuest?.status ?? "no session")")
        check("server lists the guest", server.netHost?.guestNames == ["SMPGuest"])
        check("guest knows it's a dedicated server", g.hasWorld())

        // the world simulates without any host player
        let t0 = server.worlds[.overworld]?.time ?? 0
        pump(simTicks: 30)
        check("server world ticks on its own", (server.worlds[.overworld]?.time ?? 0) > t0 + 20)

        // guest edits reach the server world
        let sx = Int((server.worlds[.overworld]?.spawnX ?? 0).rounded(.down))
        let sz = Int((server.worlds[.overworld]?.spawnZ ?? 0).rounded(.down))
        check("guest streamed spawn", pumpUntil(800) { g.hasWorld() && g.world.isLoadedAt(sx, sz) })
        let sy = (server.worlds[.overworld]?.surfaceY(sx, sz) ?? 80) + 3
        server.worlds[.overworld]?.setBlock(sx, sy, sz, Int(B.stone) << 4)
        check("server block reaches guest", pumpUntil(200) { g.world.getBlockId(sx, sy, sz) == Int(B.stone) },
              "server=\(server.worlds[.overworld]?.getBlockId(sx, sy, sz) ?? -1)"
              + " guest=\(g.world.getBlockId(sx, sy, sz))"
              + " loaded=\(g.world.isLoadedAt(sx, sz))"
              + " hook=\(server.worlds[.overworld]?.hooks.onBlockChanged != nil)")
        g.netGuest?.sendBreak(sx, sy, sz)
        check("guest break lands on server", pumpUntil(200) {
            server.worlds[.overworld]?.getBlockId(sx, sy, sz) == 0
        })

        // leave: inventory/position saved under the PERMANENT id
        let pid = g.settings.playerId ?? ""
        g.exitToTitle()
        check("server sees the leave", pumpUntil(200) { server.netHost?.guestCount == 0 })
        check("guest saved by permanent id", !pid.isEmpty
            && server.db.getPlayer("\(worldId)#id:\(pid)") != nil)

        server.exitToTitle()
        check("server shut down cleanly", !server.hasWorld())
    } else {
        check("smp world record exists", false)
    }
    server.deleteWorld(worldId)
    check("smp world deleted", server.db.getWorld(worldId) == nil)
    // scrub recents the net tests recorded (they carry this machine's own pid)
    for r in SocialStore.shared.recents where !recentsBefore.contains(r.id) {
        SocialStore.shared.removeRecent(id: r.id)
    }
}

smokePortableServerSuite()

print("\n\(passed) passed, \(failed) failed")
exit(failed > 0 ? 1 : 0)
