// Deterministic gameplay suites: the entity zoo, systems (crafting/BEs/
// redstone/explosion/interact/portals), and the vanilla player-physics
// constants — moved verbatim out of pebsmoke for the portable runner
// (PORTING module 13).

import Foundation
import PebbleCoreBase

/// zoo/combat/physics/trades/pathfinding/spawning goldens
public func smokeEntitySuite() {
    section("entities: zoo/combat/physics/trades/pathfinding/spawning (vs goldens)")
    registerAllEntities()

    if let g = loadJSON("entity-goldens.json") {
        func hex(_ x: Double) -> String {
            String(x.bitPattern >> 32, radix: 16) + "-" + String(x.bitPattern & 0xffff_ffff, radix: 16)
        }
        func ifloor(_ x: Double) -> Int { Int(x.rounded(.down)) }
        func num(_ k: String) -> Int { (g[k] as! NSNumber).intValue }
        func hash32(_ k: String) -> UInt32 { UInt32(truncating: g[k] as! NSNumber) }

        check("entity type count", entityTypes().count == num("entityTypeCount"),
              "got \(entityTypes().count) want \(num("entityTypeCount"))")
        check("entity registration order", hashString(entityTypes().joined(separator: ",")) == hash32("entityTypesH"))
        check("spawnable mob list", hashString(spawnableMobs().joined(separator: ",")) == hash32("spawnableH"))

        func buildWorld() -> World {
            let world = World(dim: .overworld, seed: 12345)
            for cz in -2...2 {
                for cx in -2...2 {
                    let out = generateOverworldChunk(12345, cx, cz)
                    let light = computeLocalLight(blocks: out.blocks, height: WORLD_H, hasSky: true)
                    let c = Chunk(cx: cx, cz: cz, minY: GEN_MIN_Y, height: WORLD_H)
                    c.blocks = out.blocks
                    c.skyLight = light.sky
                    c.blockLight = light.blk
                    c.biomes = out.biomes
                    c.buildHeightmap()
                    c.scanSpecials()
                    c.status = .generated
                    world.setChunk(c)
                }
            }
            for cz in -2...2 {
                for cx in -2...2 {
                    world.light.stitchChunk(world.getChunk(cx, cz)!)
                }
            }
            return world
        }

        func serMob(_ e: Entity, _ i: Int) -> String {
            var s = "\(e.type)#\(i):\(hex(e.x)),\(hex(e.y)),\(hex(e.z)),\(hex(e.vx)),\(hex(e.vy)),\(hex(e.vz)),\(hex(e.yaw))"
            s += ",og\(e.onGround ? 1 : 0),w\(e.inWater ? 1 : 0),a\(e.age),f\(e.fireTicks)"
            if let liv = e as? LivingEntity { s += ",h\(hex(liv.health))" }
            return s
        }

        func stepWorld(_ world: World) {
            world.tick()
            tickPendingTimeouts(world)
            for e in world.entities { (e as? Entity)?.tick() }
            for e in world.entities where e.dead {
                world.removeEntity(e)
            }
        }

        func determinize(_ e: Entity, _ i: Int) {
            e.persistent = true
            if let m = e as? LivingEntity { m.rng = RandomX(hashString("\(e.type)#\(i)")) }
            if let sheep = e as? Sheep { sheep.color = i % 16; sheep.sheared = false }
            if let chicken = e as? Chicken { chicken.eggTime = 99999 }
            if e is Parrot { e.data.variant = i % 5 }
            if e is Frog { e.data.variant = i % 3 }
            if e is Axolotl { e.data.variant = i % 4 }
            if e is Panda { e.data.gene = "normal" }
            if let goat = e as? Goat { goat.screaming = false }
            if let z = e as? Zombie {
                z.baby = false; z.speed = 0.095
                if let d = z as? Drowned { d.hasTrident = false }
            }
            if let slime = e as? Slime { slime.setSize(2) }
            if let h = e as? HorseBase { h.jumpStrength = 0.7; h.speed = 0.2; h.maxHealth = 26; h.health = 26 }
            if let l = e as? Llama { l.maxHealth = 22; l.health = 22; l.data.variant = i % 4 }
            if let v = e as? Vex { v.lifeTicks = 99999 }
            if let d = e as? EnderDragon { d.pathAngle = 1.25 }
        }

        // --- A) zoo
        let ZOO = ["cow", "mooshroom", "pig", "sheep", "chicken", "rabbit", "wolf", "cat", "fox", "parrot",
                   "bee", "axolotl", "frog", "goat", "turtle", "dolphin", "squid", "bat", "polar_bear", "panda",
                   "strider", "camel", "sniffer", "allay", "cod", "villager", "iron_golem", "snow_golem", "horse", "llama",
                   "zombie", "skeleton", "creeper", "spider", "slime", "witch", "enderman", "silverfish", "phantom", "guardian",
                   "shulker", "pillager", "vindicator", "evoker", "vex", "blaze", "ghast", "magma_cube", "zombified_piglin", "piglin",
                   "hoglin", "wither_skeleton", "warden", "wither", "ender_dragon"]
        resetGameRng(hashString("zoo"))
        let zooWorld = buildWorld()
        zooWorld.dayTime = 13000
        var zooMobs: [Entity] = []
        for i in 0..<ZOO.count {
            let sx = -20 + (i % 8) * 6
            let sz = -20 + (i / 8) * 6
            let sy = zooWorld.surfaceY(sx, sz)
            let e = spawnMob(zooWorld, ZOO[i], Double(sx) + 0.5, Double(sy), Double(sz) + 0.5, SpawnOpts())!
            determinize(e, i)
            zooMobs.append(e)
        }
        func diffSer(_ label: String, _ got: String, _ want: String) -> Bool {
            if got == want { return true }
            let gParts = got.split(separator: "|", omittingEmptySubsequences: false)
            let wParts = want.split(separator: "|", omittingEmptySubsequences: false)
            for i in 0..<min(gParts.count, wParts.count) where gParts[i] != wParts[i] {
                print("    \(label) first diff @\(i):\n      got \(gParts[i])\n      want \(wParts[i])")
                return false
            }
            print("    \(label) length mismatch: got \(gParts.count) want \(wParts.count)")
            return false
        }

        // native baseline since entity-pushing landed (regenerate with
        // PEBBLE_REGOLD=1 after deliberate entity-behavior changes)
        let zooGold = g["zooStages"] as! [[String: Any]]
        let zooRegold = ProcessInfo.processInfo.environment["PEBBLE_REGOLD"] != nil
        var zooCaptured: [[String: Any]] = []
        var zooIdx = 0
        var zooOK = true
        for t in 1...200 {
            stepWorld(zooWorld)
            if t == 50 || t == 120 || t == 200 {
                let ser = zooMobs.enumerated().map { serMob($0.element, $0.offset) }.joined(separator: "|")
                if zooRegold {
                    zooCaptured.append(["ser": ser, "t": t])
                } else {
                    let want = zooGold[zooIdx]["ser"] as! String
                    if !diffSer("zoo t=\(t)", ser, want) { zooOK = false }
                }
                zooIdx += 1
            }
        }
        if zooRegold {
            for path in goldenPaths("entity-goldens.json") {
                guard let d = FileManager.default.contents(atPath: path),
                      var obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { continue }
                obj["zooStages"] = zooCaptured
                if let out = try? JSONSerialization.data(withJSONObject: obj) {
                    try? out.write(to: URL(fileURLWithPath: path))
                    print("    REGENERATED zooStages (\(zooCaptured.count) checkpoints) -> \(path)")
                }
                break
            }
            check("zoo: golden regenerated (native baseline)", true)
        } else {
            check("zoo: 55 mob types × 200 ticks bit-identical (3 checkpoints)", zooOK)
        }

        // --- B) combat
        resetGameRng(hashString("combat"))
        let combatWorld = buildWorld()
        combatWorld.dayTime = 13000
        let cPlayer = Player(world: combatWorld)
        let py = combatWorld.surfaceY(0, 0)
        cPlayer.setPos(0.5, Double(py), 0.5)
        cPlayer.rng = RandomX(hashString("player"))
        combatWorld.addEntity(cPlayer)
        var combatants: [Entity] = [cPlayer]
        let CMOBS = ["zombie", "spider", "slime", "vex", "iron_golem"]
        for i in 0..<CMOBS.count {
            let ang = Double(i) / Double(CMOBS.count) * .pi * 2
            let sx = ifloor(0.5 + cos(ang) * 10)
            let sz = ifloor(0.5 + sin(ang) * 10)
            let sy = combatWorld.surfaceY(sx, sz)
            let e = spawnMob(combatWorld, CMOBS[i], Double(sx) + 0.5, Double(sy), Double(sz) + 0.5, SpawnOpts())!
            determinize(e, 100 + i)
            combatants.append(e)
        }
        // contains the player → native baseline since the vanilla-physics change
        // (regenerate with PEBBLE_REGOLD=1 after deliberate physics changes)
        let combatGold = g["combatStages"] as! [[String: Any]]
        let combatRegold = ProcessInfo.processInfo.environment["PEBBLE_REGOLD"] != nil
        var combatCaptured: [[String: Any]] = []
        var combatIdx = 0
        var combatOK = true
        for t in 1...150 {
            stepWorld(combatWorld)
            cPlayer.travel()
            if t == 50 || t == 100 || t == 150 {
                var ser = combatants.enumerated().map { serMob($0.element, $0.offset) }.joined(separator: "|")
                ser += "|hunger\(cPlayer.hunger),sat\(hex(cPlayer.saturation)),exh\(hex(cPlayer.exhaustion)),dead\(cPlayer.dead ? 1 : 0)"
                if combatRegold {
                    combatCaptured.append(["t": t, "ser": ser])
                } else {
                    let want = combatGold[combatIdx]["ser"] as! String
                    if !diffSer("combat t=\(t)", ser, want) { combatOK = false }
                }
                combatIdx += 1
            }
        }
        if combatRegold {
            for path in goldenPaths("entity-goldens.json") {
                guard let d = FileManager.default.contents(atPath: path),
                      var obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { continue }
                obj["combatStages"] = combatCaptured
                if let out = try? JSONSerialization.data(withJSONObject: obj) {
                    try? out.write(to: URL(fileURLWithPath: path))
                    print("    REGENERATED combatStages (\(combatCaptured.count) checkpoints) -> \(path)")
                }
                break
            }
            check("combat: golden regenerated (vanilla baseline)", true)
        } else {
            check("combat: player + 5 mobs, damage/knockback in lockstep", combatOK)
        }

        // --- C) player physics
        resetGameRng(hashString("phys"))
        let physWorld = buildWorld()
        physWorld.dayTime = 13000
        let pPlayer = Player(world: physWorld)
        let ppy = physWorld.surfaceY(4, 4)
        pPlayer.setPos(4.5, Double(ppy), 4.5)
        pPlayer.rng = RandomX(hashString("physplayer"))
        physWorld.addEntity(pPlayer)
        // player physics is vanilla-exact since task #21 — this golden is a NATIVE
        // regression baseline now (regenerate with PEBBLE_REGOLD=1 after deliberate
        // physics changes) — these are native baselines, regenerated deliberately
        let physGold = g["physStages"] as! [[String: Any]]
        let regold = ProcessInfo.processInfo.environment["PEBBLE_REGOLD"] != nil
        var physCaptured: [[String: Any]] = []
        var physIdx = 0
        var physOK = true
        for t in 1...200 {
            pPlayer.moveForward = 0; pPlayer.moveStrafe = 0
            pPlayer.jumping = false; pPlayer.sprinting = false; pPlayer.sneaking = false
            if t <= 40 { pPlayer.moveForward = 1 }
            else if t <= 60 { pPlayer.moveForward = 1; pPlayer.jumping = true }
            else if t <= 100 { pPlayer.moveStrafe = 1 }
            else if t <= 140 { pPlayer.moveForward = 1; pPlayer.sprinting = true; pPlayer.jumping = t % 10 == 0 }
            else if t <= 160 { pPlayer.moveForward = 1; pPlayer.sneaking = true; pPlayer.yaw = 0.8 }
            physWorld.tick()
            pPlayer.tick()
            pPlayer.travel()
            if t % 20 == 0 {
                let s = "\(hex(pPlayer.x)),\(hex(pPlayer.y)),\(hex(pPlayer.z)),\(hex(pPlayer.vx)),\(hex(pPlayer.vy)),\(hex(pPlayer.vz)),og\(pPlayer.onGround ? 1 : 0),fall\(hex(pPlayer.fallDistance)),h\(hex(pPlayer.health))"
                if regold {
                    physCaptured.append(["t": t, "s": s])
                } else {
                    let want = physGold[physIdx]["s"] as! String
                    if s != want {
                        physOK = false
                        print("    phys t=\(t):\n      got \(s)\n      want \(want)")
                    }
                }
                physIdx += 1
            }
        }
        if regold {
            for path in goldenPaths("entity-goldens.json") {
                guard let d = FileManager.default.contents(atPath: path),
                      var obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { continue }
                obj["physStages"] = physCaptured
                if let out = try? JSONSerialization.data(withJSONObject: obj) {
                    try? out.write(to: URL(fileURLWithPath: path))
                    print("    REGENERATED physStages (\(physCaptured.count) checkpoints) -> \(path)")
                }
                break
            }
            check("player physics: golden regenerated (vanilla baseline)", true)
        } else {
            check("player physics: 200 scripted-input ticks vs native baseline", physOK)
        }

        // --- D) trades
        resetGameRng(hashString("trades"))
        let tradeWorld = buildWorld()
        var tradeOK = true
        let tradeGold = g["tradeProbes"] as! [String]
        var tg = 0
        for prof in PROFESSIONS {
            for lvl in 1...5 {
                let v = createEntity("villager", tradeWorld) as! Villager
                v.profession = prof
                v.tradeLevel = lvl
                v.rng = RandomX(hashString("\(prof)/\(lvl)"))
                v.refreshTrades()
                let ser = v.offers.map { o -> String in
                    var s = "\(o.buyA.id)x\(o.buyA.count)"
                    if let b = o.buyB { s += "+\(b.id)x\(b.count)" }
                    s += ">\(o.sell.id)x\(o.sell.count)"
                    if !o.sell.ench.isEmpty { s += "e[\(o.sell.ench.map { "\($0.id):\($0.lvl)" }.joined(separator: ","))]" }
                    return s
                }.joined(separator: ";")
                let got = "\(prof)@\(lvl)=\(ser)"
                if got != tradeGold[tg] {
                    tradeOK = false
                    print("    trade \(prof)@\(lvl):\n      got \(got)\n      want \(tradeGold[tg])")
                }
                tg += 1
            }
        }
        check("\(tradeGold.count) villager trade tables byte-identical", tradeOK)

        // --- E) pathfinding (terrain-dependent: regold rewrites with the rest)
        resetGameRng(hashString("paths"))
        let pathWorld = buildWorld()
        let pathGold = g["pathProbes"] as! [String]
        var pathOK = true
        var pathCaptured: [String] = []
        for i in 0..<8 {
            let fx = -24 + i * 6, fz = -18 + i * 4
            let tx = fx + 10 - (i % 3) * 7, tz = fz + 8 - (i % 4) * 5
            let p = findPath(pathWorld, Double(fx) + 0.5, Double(pathWorld.surfaceY(fx, fz)), Double(fz) + 0.5,
                             Double(tx) + 0.5, Double(pathWorld.surfaceY(tx, tz)), Double(tz) + 0.5)
            let got = p == nil ? "null" : p!.map { "\($0.x),\($0.y),\($0.z)" }.joined(separator: ";")
            pathCaptured.append(got)
            if !regold, got != pathGold[i] {
                pathOK = false
                print("    path[\(i)]:\n      got \(got.prefix(120))\n      want \(pathGold[i].prefix(120))")
            }
        }
        if regold {
            for path in goldenPaths("entity-goldens.json") {
                guard let d = FileManager.default.contents(atPath: path),
                      var obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { continue }
                obj["pathProbes"] = pathCaptured
                if let out = try? JSONSerialization.data(withJSONObject: obj) {
                    try? out.write(to: URL(fileURLWithPath: path))
                    print("    REGENERATED pathProbes (8)")
                }
                break
            }
            check("A* paths: golden regenerated (native baseline)", true)
        } else {
            check("8 A* paths node-identical", pathOK)
        }

        // --- F) natural spawning
        resetGameRng(hashString("spawn"))
        let spawnWorld = buildWorld()
        spawnWorld.dayTime = 13000
        let sPlayer = Player(world: spawnWorld)
        sPlayer.setPos(0.5, Double(spawnWorld.surfaceY(0, 0)), 0.5)
        spawnWorld.addEntity(sPlayer)
        var spawnRng = RandomX(hashString("natural"))
        for i in 0..<40 {
            spawnWorld.time = i * 400
            naturalSpawnTick(spawnWorld, [sPlayer], &spawnRng)
        }
        let spawnedSer = spawnWorld.entities
            .compactMap { $0 as? Entity }
            .filter { $0 !== sPlayer }
            .map { "\($0.type)@\(hex($0.x)),\(hex($0.y)),\(hex($0.z))" }
            .joined(separator: "|")
        // native baseline since the vanilla-1.20 spawn-light rework (regenerate
        // with PEBBLE_REGOLD=1 after deliberate spawning changes)
        if ProcessInfo.processInfo.environment["PEBBLE_REGOLD"] != nil {
            for path in goldenPaths("entity-goldens.json") {
                guard let d = FileManager.default.contents(atPath: path),
                      var obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { continue }
                obj["spawnCount"] = spawnWorld.entities.count - 1
                obj["spawnH"] = hashString(spawnedSer)
                if let out = try? JSONSerialization.data(withJSONObject: obj) {
                    try? out.write(to: URL(fileURLWithPath: path))
                    print("    REGENERATED spawnCount=\(spawnWorld.entities.count - 1) spawnH")
                }
                break
            }
            check("natural spawn: golden regenerated (native baseline)", true)
            check("natural spawn hash: golden regenerated", true)
        } else {
            check("natural spawn count", spawnWorld.entities.count - 1 == num("spawnCount"),
                  "got \(spawnWorld.entities.count - 1) want \(num("spawnCount"))")
            check("natural spawn types+positions hash", hashString(spawnedSer) == hash32("spawnH"),
                  "got \(hashString(spawnedSer)) want \(hash32("spawnH"))")
        }
    } else {
        check("entity-goldens.json loadable", false, "not found — run from the repo root (goldens/)")
    }
}

/// crafting/BEs/redstone/explosion/interact/portals goldens
public func smokeSystemsSuite() {
    section("systems: crafting/BEs/redstone/explosion/interact/portals (vs goldens)")
    // terrain-dependent systems goldens re-baseline under PEBBLE_REGOLD
    let sysRegold = ProcessInfo.processInfo.environment["PEBBLE_REGOLD"] != nil
    var sysCaptured: [String: Any] = [:]
    registerAllSystems()

    if let g = loadJSON("systems-goldens.json") {
        func hex(_ x: Double) -> String {
            String(x.bitPattern >> 32, radix: 16) + "-" + String(x.bitPattern & 0xffff_ffff, radix: 16)
        }
        func ifloor(_ x: Double) -> Int { Int(x.rounded(.down)) }
        /// deterministic Number→string: integral doubles print without ".0"
        func detNum(_ x: Double) -> String {
            if x == x.rounded() && abs(x) < 1e15 { return String(Int(x)) }
            return String(x)
        }
        func buildWorld() -> World {
            let world = World(dim: .overworld, seed: 12345)
            for cz in -1...1 {
                for cx in -1...1 {
                    let out = generateOverworldChunk(12345, cx, cz)
                    let light = computeLocalLight(blocks: out.blocks, height: WORLD_H, hasSky: true)
                    let c = Chunk(cx: cx, cz: cz, minY: GEN_MIN_Y, height: WORLD_H)
                    c.blocks = out.blocks
                    c.skyLight = light.sky
                    c.blockLight = light.blk
                    c.biomes = out.biomes
                    c.buildHeightmap()
                    c.scanSpecials()
                    c.status = .generated
                    world.setChunk(c)
                }
            }
            for cz in -1...1 { for cx in -1...1 { world.light.stitchChunk(world.getChunk(cx, cz)!) } }
            return world
        }
        func serStack(_ s: ItemStack?) -> String {
            guard let s else { return "-" }
            var str = "\(itemDef(s.id).name)x\(s.count)"
            if s.damage != 0 { str += "d\(s.damage)" }
            if !s.ench.isEmpty { str += "e[\(s.ench.map { "\($0.id):\($0.lvl)" }.joined(separator: ","))]" }
            if let p = s.data.potion { str += "p[\(p)]" }
            if let w = s.data.priorWork, w != 0 { str += "w\(w)" }
            if let t = s.data.trim { str += "t[\(t.pattern):\(t.material)]" }
            if let l = s.label { str += "l[\(l)]" }
            return str
        }
        func regionHash(_ world: World, _ x0: Int, _ y0: Int, _ z0: Int, _ x1: Int, _ y1: Int, _ z1: Int) -> UInt32 {
            var h: UInt32 = 2166136261
            for y in y0...y1 {
                for z in z0...z1 {
                    for x in x0...x1 {
                        let c = world.getBlock(x, y, z)
                        h = (h ^ UInt32(c & 0xff)) &* 16777619
                        h = (h ^ UInt32(c >> 8)) &* 16777619
                    }
                }
            }
            return h
        }
        func entsSer(_ world: World, _ skip: EntityRef? = nil) -> String {
            world.entities.filter { !($0 === skip) }
                .map { "\(($0 as? Entity)?.type ?? "?")@\(hex($0.x)),\(hex($0.y)),\(hex($0.z))" }
                .joined(separator: "|")
        }
        func stepWorld(_ world: World) {
            world.tick()
            tickPendingTimeouts(world)
            for e in world.entities { (e as? Entity)?.tick() }
            for e in world.entities where e.dead { world.removeEntity(e) }
        }
        func cmpList(_ label: String, _ got: [String], _ want: [String]) {
            var ok = got.count == want.count
            if ok {
                for (i, w) in want.enumerated() where got[i] != w {
                    ok = false
                    print("    \(label)[\(i)]:\n      got \(got[i])\n      want \(w)")
                    break
                }
            } else {
                print("    \(label) count: got \(got.count) want \(want.count)")
            }
            check(label, ok)
        }

        // --- A) crafting probes
        func st(_ name: String, _ count: Int = 1) -> ItemStack { ItemStack(iid(name), count) }
        var craftGot: [String] = []
        let craftCases: [(String, Int, Int, [ItemStack?])] = [
            ("planks", 2, 2, [st("oak_log"), nil, nil, nil]),
            ("sticks", 2, 2, [st("oak_planks"), nil, st("oak_planks"), nil]),
            ("table", 2, 2, [st("oak_planks"), st("oak_planks"), st("oak_planks"), st("oak_planks")]),
            ("pick", 3, 3, [st("oak_planks"), st("oak_planks"), st("oak_planks"), nil, st("stick"), nil, nil, st("stick"), nil]),
            ("axe-mirrored", 3, 3, [nil, st("oak_planks"), st("oak_planks"), nil, st("stick"), st("oak_planks"), nil, st("stick"), nil]),
            ("tag-planks-chest", 3, 3, [st("birch_planks"), st("birch_planks"), st("birch_planks"), st("birch_planks"), nil, st("birch_planks"), st("birch_planks"), st("birch_planks"), st("birch_planks")]),
            ("shapeless-flint", 2, 2, [st("iron_ingot"), st("flint"), nil, nil]),
            ("no-match-extra", 3, 3, [st("oak_log"), st("stick"), nil, nil, nil, nil, nil, nil, nil]),
            ("torch", 2, 2, [st("coal"), nil, st("stick"), nil]),
            ("bread", 3, 3, [st("wheat"), st("wheat"), st("wheat"), nil, nil, nil, nil, nil, nil]),
        ]
        for (label, w, h, grid) in craftCases {
            let m = matchCrafting(grid, w, h)
            craftGot.append("\(label)=\(m != nil ? serStack(m!.out) : "null")")
        }
        cmpList("crafting grid probes", craftGot, g["craftProbes"] as! [String])

        var smithGot: [String] = []
        smithGot.append("netherite=\(serStack(matchSmithing(st("netherite_upgrade"), st("diamond_sword"), st("netherite_ingot"))))")
        smithGot.append("trim=\(serStack(matchSmithing(st("coast_armor_trim"), st("iron_chestplate"), st("emerald"))))")
        smithGot.append("bad=\(serStack(matchSmithing(st("netherite_upgrade"), st("stone"), st("netherite_ingot"))))")
        cmpList("smithing probes", smithGot, g["smithProbes"] as! [String])

        // --- B) enchanting / anvil / grindstone
        var enchGot: [String] = []
        for (item, shelves, sd) in [("diamond_sword", 15, 777), ("book", 8, 1234), ("iron_pickaxe", 0, 42), ("diamond_chestplate", 15, 90210)] {
            let opts = enchantingOptions(st(item), shelves, sd)
            enchGot.append("\(item)@\(shelves)/\(sd)=" + opts.map { o in
                "L\(o.level):\(o.enchants.map { "\($0.id):\($0.lvl)" }.joined(separator: ","))"
            }.joined(separator: ";"))
        }
        cmpList("enchanting options", enchGot, g["enchProbes"] as! [String])

        var anvilGot: [String] = []
        let sword = ItemStack(iid("diamond_sword"), 1, damage: 100)
        let sword2 = ItemStack(iid("diamond_sword"), 1, damage: 500, ench: [EnchInstance("sharpness", 3)])
        let book = ItemStack(iid("enchanted_book"), 1, ench: [EnchInstance("sharpness", 3), EnchInstance("knockback", 2)])
        let r1 = anvilCombine(sword, sword2, nil)
        anvilGot.append("combine=\(r1 != nil ? serStack(r1!.out) + "$\(r1!.cost)" : "null")")
        let r2 = anvilCombine(sword, book, nil)
        anvilGot.append("book=\(r2 != nil ? serStack(r2!.out) + "$\(r2!.cost)" : "null")")
        let r3 = anvilCombine(sword, ItemStack(iid("diamond"), 3), nil)
        anvilGot.append("repair=\(r3 != nil ? serStack(r3!.out) + "$\(r3!.cost)" : "null")")
        let r4 = anvilCombine(ItemStack(iid("iron_sword"), 1), nil, "Slicey")
        anvilGot.append("rename=\(r4 != nil ? serStack(r4!.out) + "$\(r4!.cost)" : "null")")
        let g1 = grindstoneResult(sword2, nil)
        anvilGot.append("grind=\(g1 != nil ? serStack(g1!.out) + "$\(g1!.xp)" : "null")")
        cmpList("anvil/grindstone probes", anvilGot, g["anvilProbes"] as! [String])

        // --- C) BE timelines
        resetGameRng(hashString("be"))
        let beWorld = buildWorld()
        let bePy = beWorld.surfaceY(0, 0)
        let beBase = bePy + 20
        for dz in -3...3 { for dx in -3...3 { beWorld.setBlock(dx, beBase - 1, dz, Int(cell(B.stone))) } }
        beWorld.setBlock(0, beBase, 0, Int(cell(B.furnace, 0)))
        let fbe = makeFurnaceBE(0, beBase, 0, "furnace")
        var fitems = fbe.items!
        fitems[0] = ItemStack(iid("raw_iron"), 3)
        fitems[1] = ItemStack(iid("coal"), 2)
        fbe.items = fitems
        beWorld.setBlockEntity(fbe)
        beWorld.setBlock(0, beBase + 1, 0, Int(cell(B.hopper, 0)))
        let hbe = makeHopperBE(0, beBase + 1, 0)
        var hitems = hbe.items!
        hitems[0] = ItemStack(iid("raw_gold"), 2)
        hbe.items = hitems
        beWorld.setBlockEntity(hbe)
        beWorld.setBlock(2, beBase, 0, Int(cell(B.brewing_stand, 0)))
        let bbe = makeBrewingBE(2, beBase, 0)
        var bitems = bbe.items!
        var pd = StackData(); pd.potion = "awkward"
        bitems[0] = ItemStack(iid("potion"), 1, data: pd)
        bitems[3] = ItemStack(iid("blaze_powder"), 2)
        bitems[4] = ItemStack(iid("blaze_powder"), 2)
        bbe.items = bitems
        beWorld.setBlockEntity(bbe)
        var beGot: [String] = []
        for t in 1...450 {
            stepWorld(beWorld)
            if t == 100 || t == 250 || t == 450 {
                let f = "f:\((fbe.items ?? []).map(serStack).joined(separator: ",")):b\(fbe.burnTime ?? 0):c\(fbe.cookTime ?? 0):x\(detNum(fbe.xpBank ?? 0))"
                let h = "h:\((hbe.items ?? []).map(serStack).joined(separator: ",")):cd\(hbe.cooldown ?? 0)"
                let p = "p:\((bbe.items ?? []).map(serStack).joined(separator: ",")):bt\(bbe.brewTime ?? 0):fu\(bbe.fuel ?? 0)"
                beGot.append([f, h, p].joined(separator: "|"))
            }
        }
        cmpList("BE timelines (furnace/hopper/brewing)", beGot, g["beStages"] as! [String])

        // --- D) redstone contraption
        resetGameRng(hashString("redstone"))
        let rsWorld = buildWorld()
        let rsBase = rsWorld.surfaceY(8, 8) + 20
        for dz in 0...8 { for dx in 0...12 { rsWorld.setBlock(8 + dx, rsBase - 1, 8 + dz, Int(cell(B.stone))) } }
        rsWorld.setBlock(8, rsBase, 8, Int(cell(B.lever, 0)))
        for i in 1...5 { rsWorld.setBlock(8 + i, rsBase, 8, Int(cell(B.redstone_wire, 0))) }
        rsWorld.setBlock(14, rsBase, 8, Int(cell(B.repeater, 3)))
        rsWorld.setBlock(15, rsBase, 8, Int(cell(B.redstone_wire, 0)))
        rsWorld.setBlock(16, rsBase, 8, Int(cell(B.redstone_lamp)))
        rsWorld.setBlock(11, rsBase, 9, Int(cell(B.piston, 3)))
        rsWorld.setBlock(11, rsBase, 10, Int(cell(B.stone)))
        rsWorld.setBlock(12, rsBase, 10, Int(cell(B.observer, 4)))
        func flip(_ on: Bool) {
            let c = rsWorld.getBlock(8, rsBase, 8)
            rsWorld.setBlock(8, rsBase, 8, Int(cell(B.lever, on ? (c & 7) | 8 : c & 7)))
            rsWorld.updateNeighbors(8, rsBase, 8)
            rsWorld.updateNeighbors(8, rsBase - 1, 8)
        }
        var rsGot: [UInt32] = []
        flip(true)
        for _ in 1...30 { stepWorld(rsWorld) }
        rsGot.append(regionHash(rsWorld, 6, rsBase - 2, 6, 20, rsBase + 2, 14))
        flip(false)
        for _ in 1...30 { stepWorld(rsWorld) }
        rsGot.append(regionHash(rsWorld, 6, rsBase - 2, 6, 20, rsBase + 2, 14))
        flip(true)
        for _ in 1...4 { stepWorld(rsWorld) }
        rsGot.append(regionHash(rsWorld, 6, rsBase - 2, 6, 20, rsBase + 2, 14))
        let rsWant = (g["redstoneStages"] as! [NSNumber]).map { UInt32(truncating: $0) }
        check("redstone contraption (lever/wire/repeater/piston/lamp/observer)", rsGot == rsWant,
              "got \(rsGot) want \(rsWant)")

        // --- E) random ticks
        resetGameRng(hashString("crops"))
        let cropWorld = buildWorld()
        let cropBase = cropWorld.surfaceY(-8, -8) + 20
        for dz in 0..<6 {
            for dx in 0..<6 {
                cropWorld.setBlock(-8 + dx, cropBase - 1, -8 + dz, Int(cell(B.farmland, 7)))
                cropWorld.setBlock(-8 + dx, cropBase, -8 + dz, Int(cell(B.wheat, 0)))
            }
        }
        cropWorld.randomTickSpeed = 40
        for _ in 1...400 { cropWorld.tick() }
        let cropGot = regionHash(cropWorld, -8, cropBase - 1, -8, -3, cropBase, -3)
        if sysRegold {
            sysCaptured["cropHash"] = NSNumber(value: cropGot)
            check("crop growth: golden regenerated", true)
        } else {
            check("crop growth via seeded random ticks", cropGot == UInt32(truncating: g["cropHash"] as! NSNumber),
                  "got \(cropGot) want \(g["cropHash"]!)")
        }

        // --- F) explosion
        resetGameRng(hashString("boom"))
        let boomWorld = buildWorld()
        let bpx = 4, bpz = 4
        let bpy = boomWorld.surfaceY(bpx, bpz)
        let cow = spawnMob(boomWorld, "cow", Double(bpx) + 3.5, Double(bpy) + 1, Double(bpz) + 0.5, SpawnOpts())!
        (cow as? LivingEntity)?.rng = RandomX(hashString("boomcow"))
        cow.persistent = true
        explode(boomWorld, Double(bpx) + 0.5, Double(bpy) + 0.5, Double(bpz) + 0.5, 4, true, nil)
        let boomGot = regionHash(boomWorld, bpx - 8, bpy - 8, bpz - 8, bpx + 8, bpy + 8, bpz + 8)
        let boomEnts = hashString(entsSer(boomWorld))
        if sysRegold {
            sysCaptured["explosionHash"] = NSNumber(value: boomGot)
            sysCaptured["explosionEnts"] = NSNumber(value: boomEnts)
            check("explosion: goldens regenerated", true)
            check("explosion ents: goldens regenerated", true)
        } else {
            check("explosion crater bit-identical", boomGot == UInt32(truncating: g["explosionHash"] as! NSNumber),
                  "got \(boomGot) want \(g["explosionHash"]!)")
            check("explosion entity state (knockback + drops)", boomEnts == UInt32(truncating: g["explosionEnts"] as! NSNumber),
                  "got \(boomEnts) want \(g["explosionEnts"]!)")
        }

        // --- G) interact
        resetGameRng(hashString("interact"))
        let iWorld = buildWorld()
        let iPlayer = Player(world: iWorld)
        let ipy = iWorld.surfaceY(0, -10)
        iPlayer.setPos(0.5, Double(ipy), -9.5)
        iPlayer.rng = RandomX(hashString("iplayer"))
        iWorld.addEntity(iPlayer)
        let ictx = InteractCtx(world: iWorld, player: iPlayer)
        func giveP(_ name: String, _ count: Int = 1) { iPlayer.inventory[iPlayer.selectedSlot] = ItemStack(iid(name), count) }
        func mkHit(_ x: Int, _ y: Int, _ z: Int, _ face: Int) -> RaycastHit {
            RaycastHit(x: x, y: y, z: z, face: face, cell: iWorld.getBlock(x, y, z), t: 0,
                       px: Double(x) + 0.5, py: Double(y) + (face == 1 ? 1 : 0.5), pz: Double(z) + 0.5)
        }
        var iGot: [String] = []
        let ibx = 0, ibz = -14
        let iby = iWorld.surfaceY(ibx, ibz)
        iPlayer.yaw = 0
        giveP("oak_stairs", 4)
        iGot.append("stairs=\(placeBlock(ictx, mkHit(ibx, iby - 1, ibz, 1), Int(itemDef(iPlayer.mainHand!.id).block!), iPlayer.mainHand!))@\(String(iWorld.getBlock(ibx, iby, ibz), radix: 16))")
        giveP("oak_door", 2)
        iGot.append("door=\(placeBlock(ictx, mkHit(ibx + 2, iby - 1, ibz, 1), Int(itemDef(iPlayer.mainHand!.id).block!), iPlayer.mainHand!))@\(String(iWorld.getBlock(ibx + 2, iby, ibz), radix: 16)),\(String(iWorld.getBlock(ibx + 2, iby + 1, ibz), radix: 16))")
        iGot.append("doorUse=\(useBlock(ictx, mkHit(ibx + 2, iby, ibz, 3)))@\(String(iWorld.getBlock(ibx + 2, iby, ibz), radix: 16))")
        giveP("white_bed")
        iGot.append("bed=\(placeBlock(ictx, mkHit(ibx + 4, iby - 1, ibz, 1), Int(itemDef(iPlayer.mainHand!.id).block!), iPlayer.mainHand!))@\(String(iWorld.getBlock(ibx + 4, iby, ibz), radix: 16))")
        giveP("torch", 4)
        iGot.append("torch=\(placeBlock(ictx, mkHit(ibx, iby, ibz - 2, 3), Int(itemDef(iPlayer.mainHand!.id).block!), iPlayer.mainHand!))")
        giveP("iron_pickaxe")
        finishBreaking(ictx, ibx, iby, ibz)
        iWorld.setBlock(ibx + 6, iby - 1, ibz, Int(cell(B.farmland, 7)))
        iWorld.setBlock(ibx + 6, iby, ibz, Int(cell(B.wheat, 0)))
        iGot.append("bonemeal=\(applyBonemeal(iWorld, ibx + 6, iby, ibz))@\(String(iWorld.getBlock(ibx + 6, iby, ibz), radix: 16))")
        giveP("golden_apple")
        _ = useItem(ictx, nil)
        finishUsingItem(ictx)
        iGot.append("ate=h\(iPlayer.hunger),s\(hex(iPlayer.saturation)),fx\(iPlayer.effects.map { "\($0.id):\($0.duration):\($0.amplifier)" }.joined(separator: ";"))")
        let iEnts = hashString(entsSer(iWorld, iPlayer))
        let iRegion = regionHash(iWorld, ibx - 2, iby - 2, ibz - 4, ibx + 8, iby + 2, ibz + 2)
        if sysRegold {
            sysCaptured["interactProbes"] = iGot
            sysCaptured["interactEnts"] = NSNumber(value: iEnts)
            sysCaptured["interactRegion"] = NSNumber(value: iRegion)
            check("interact: goldens regenerated", true)
            check("interact ents: goldens regenerated", true)
            check("interact region: goldens regenerated", true)
        } else {
            cmpList("interact probes (place/use/break/bonemeal/eat)", iGot, g["interactProbes"] as! [String])
            check("interact entity drops", iEnts == UInt32(truncating: g["interactEnts"] as! NSNumber),
                  "got \(iEnts) want \(g["interactEnts"]!)")
            check("interact region blocks", iRegion == UInt32(truncating: g["interactRegion"] as! NSNumber),
                  "got \(iRegion) want \(g["interactRegion"]!)")
        }

        // --- H) portal
        let pWorld = buildWorld()
        let ppy2 = pWorld.surfaceY(-12, 12) + 25
        for dy in 0..<5 {
            for dx in 0..<4 {
                let frame = dy == 0 || dy == 4 || dx == 0 || dx == 3
                pWorld.setBlock(-12 + dx, ppy2 + dy, 12, frame ? Int(cell(B.obsidian)) : 0)
            }
        }
        let pok = tryIgnitePortal(pWorld, -11, ppy2 + 1, 12)
        let pGot = "\(pok)@\(regionHash(pWorld, -13, ppy2 - 1, 11, -8, ppy2 + 5, 13))"
        if sysRegold {
            sysCaptured["portal"] = pGot
            check("portal: golden regenerated", true)
        } else {
            check("nether portal frame ignition", pGot == (g["portal"] as! String),
                  "got \(pGot) want \(g["portal"]!)")
        }
        if sysRegold, !sysCaptured.isEmpty {
            for path in goldenPaths("systems-goldens.json") {
                guard let d = FileManager.default.contents(atPath: path),
                      var obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { continue }
                for (k, v) in sysCaptured { obj[k] = v }
                if let out = try? JSONSerialization.data(withJSONObject: obj) {
                    try? out.write(to: URL(fileURLWithPath: path))
                    print("    REGENERATED systems keys: \(sysCaptured.keys.sorted().joined(separator: ", "))")
                }
                break
            }
        }
    } else {
        check("systems-goldens.json loadable", false, "not found")
    }
}

/// vanilla player physics constants (independent derivations)
public func smokePhysicsSuite() {
    section("vanilla player physics constants (independent derivations)")
    do {
        // flat stone slab world — equilibrium measurements need perfectly flat ground
        func flatWorld(_ topBlock: UInt16 = 0) -> (World, Int) {
            let world = World(dim: .overworld, seed: 1)
            let groundY = 64
            for cz in -2...2 {
                for cx in -2...2 {
                    let c = Chunk(cx: cx, cz: cz, minY: GEN_MIN_Y, height: WORLD_H)
                    var blocks = [UInt16](repeating: 0, count: 16 * 16 * WORLD_H)
                    let stone = cell(B.stone)
                    for y in 0...(groundY - GEN_MIN_Y) {
                        for i in 0..<256 {
                            blocks[y * 256 + i] = y == groundY - GEN_MIN_Y && topBlock != 0 ? cell(topBlock) : stone
                        }
                    }
                    c.blocks = blocks
                    c.skyLight = [UInt8](repeating: 15, count: blocks.count)
                    c.blockLight = [UInt8](repeating: 0, count: blocks.count)
                    c.buildHeightmap()
                    c.scanSpecials()
                    c.status = .lit
                    world.setChunk(c)
                }
            }
            return (world, groundY + 1)
        }
        func mkPlayer(_ world: World, _ gy: Int) -> Player {
            let p = Player(world: world)
            p.setPos(0.5, Double(gy), 0.5)
            p.rng = RandomX(7)
            world.addEntity(p)
            // settle onto the ground
            for _ in 0..<5 { p.tick(); p.travel() }
            return p
        }
        func runTicks(_ p: Player, _ n: Int, forward: Double = 0, strafe: Double = 0,
                      jump: Bool = false, sprint: Bool = false, sneak: Bool = false) {
            for _ in 0..<n {
                p.moveForward = forward; p.moveStrafe = strafe
                p.jumping = jump; p.sprinting = sprint; p.sneaking = sneak
                p.tick()
                p.travel()
            }
        }

        // 1) WALK equilibrium: v* = a/(1-f), a = 0.98·speed·0.216…/slip³, f = slip·0.91
        do {
            let (w, gy) = flatWorld()
            let p = mkPlayer(w, gy)
            runTicks(p, 150, forward: 1)
            let z0 = p.z
            runTicks(p, 1, forward: 1)
            let perTick = p.z - z0
            let a = 0.98 * 0.1 * (0.21600002 / (0.6 * 0.6 * 0.6))
            let expect = a / (1 - 0.6 * 0.91)
            check("walk speed = \(String(format: "%.4f", perTick * 20)) b/s (vanilla 4.317)",
                  abs(perTick - expect) < 1e-9 && abs(perTick * 20 - 4.317) < 0.001,
                  "got \(perTick) want \(expect)")
        }
        // 2) SPRINT equilibrium (×1.3) → 5.612 b/s
        do {
            let (w, gy) = flatWorld()
            let p = mkPlayer(w, gy)
            runTicks(p, 150, forward: 1, sprint: true)
            let z0 = p.z
            runTicks(p, 1, forward: 1, sprint: true)
            let perTick = p.z - z0
            let a = 0.98 * 0.13 * (0.21600002 / 0.216)
            let expect = a / (1 - 0.546)
            check("sprint speed = \(String(format: "%.4f", perTick * 20)) b/s (vanilla 5.612)",
                  abs(perTick - expect) < 1e-9 && abs(perTick * 20 - 5.612) < 0.001)
        }
        // 3) SNEAK (input ×0.3) → 1.295 b/s
        do {
            let (w, gy) = flatWorld()
            let p = mkPlayer(w, gy)
            runTicks(p, 150, forward: 1, sneak: true)
            let z0 = p.z
            runTicks(p, 1, forward: 1, sneak: true)
            let perTick = p.z - z0
            let a = 0.3 * 0.98 * 0.1 * (0.21600002 / 0.216)
            let expect = a / (1 - 0.546)
            check("sneak speed = \(String(format: "%.4f", perTick * 20)) b/s (vanilla 1.295)",
                  abs(perTick - expect) < 1e-9 && abs(perTick * 20 - 1.295) < 0.001)
        }
        // 4) JUMP apex — independent recurrence: y += v; v = (v−0.08)·0.98 from 0.42
        do {
            let (w, gy) = flatWorld()
            let p = mkPlayer(w, gy)
            let y0 = p.y
            var apex = 0.0
            for t in 0..<30 {
                runTicks(p, 1, jump: t == 0)
                apex = max(apex, p.y - y0)
            }
            var ev = 0.42, ey = 0.0, eApex = 0.0
            for _ in 0..<30 {
                ey += ev
                eApex = max(eApex, ey)
                ev = (ev - 0.08) * 0.98
            }
            check("jump apex = \(String(format: "%.4f", apex)) (vanilla 1.2522)",
                  abs(apex - eApex) < 1e-9 && abs(apex - 1.2522) < 0.001,
                  "got \(apex) want \(eApex)")
        }
        // 5) SPRINT-JUMP: boosted arc lands ~12 ticks, covers vanilla-ish ~3.8-4.4 blocks
        do {
            let (w, gy) = flatWorld()
            let p = mkPlayer(w, gy)
            runTicks(p, 150, forward: 1, sprint: true)
            let z0 = p.z
            runTicks(p, 1, forward: 1, jump: true, sprint: true)
            var airTicks = 1
            while !p.onGround && airTicks < 30 {
                runTicks(p, 1, forward: 1, sprint: true)
                airTicks += 1
            }
            let dist = p.z - z0
            check("sprint-jump: \(String(format: "%.3f", dist)) blocks in \(airTicks) air ticks",
                  dist > 3.5 && dist < 4.6 && airTicks >= 11 && airTicks <= 14)
        }
        // 6) FALL DAMAGE: 20-block drop
        do {
            let (w, gy) = flatWorld()
            let p = mkPlayer(w, gy)
            p.setPos(0.5, Double(gy + 20), 0.5)
            p.vx = 0; p.vy = 0; p.vz = 0
            p.onGround = false   // stale from the settle phase pre-teleport
            var t = 0
            while !p.onGround && t < 100 {
                runTicks(p, 1)
                t += 1
            }
            check("20-block fall: damage \(String(format: "%.1f", 20 - p.health)) (vanilla 17)",
                  abs((20 - p.health) - 17) < 1.01)
        }
        // 7) WATER terminal sink velocity = −0.005/(1−0.8) = −0.025
        do {
            let (w, gy) = flatWorld()
            // water column (tall — the swim-up phase rises fast)
            for y in gy...(gy + 60) {
                w.setBlock(0, y, 0, Int(cell(B.water)), SET_SILENT)
            }
            let p = Player(world: w)
            p.setPos(0.5, Double(gy + 40), 0.5)
            p.rng = RandomX(7)
            w.addEntity(p)
            for _ in 0..<60 { p.tick(); p.travel() }
            check("water sink terminal vy = \(String(format: "%.4f", p.vy)) (vanilla −0.025)",
                  abs(p.vy - (-0.025)) < 0.002)
            // swim up: vy += 0.04 then ×0.8 −0.005 → +0.135 terminal
            p.setPos(0.5, Double(gy + 8), 0.5)
            p.vy = 0
            for _ in 0..<50 {
                p.jumping = true
                p.tick()
                p.travel()
            }
            check("swim-up terminal vy = \(String(format: "%.4f", p.vy)) (vanilla +0.135)",
                  abs(p.vy - 0.135) < 0.002)
        }
        // 8) ICE equilibrium: slip 0.98
        do {
            let (w, gy) = flatWorld(B.packed_ice)
            let p = mkPlayer(w, gy)
            runTicks(p, 150, forward: 1)
            let z0 = p.z
            runTicks(p, 1, forward: 1)
            let perTick = p.z - z0
            let slip = 0.98
            let a = 0.98 * 0.1 * (0.21600002 / (slip * slip * slip))
            let expect = a / (1 - slip * 0.91)
            check("ice glide = \(String(format: "%.3f", perTick * 20)) b/s",
                  abs(perTick - expect) < 1e-6)
        }
    }
}
