// Portable network suites: NetMsg/wire-chunk protocol round-trips and the
// social JSON stores. Pure value types + files — the real-TCP LAN and
// dedicated-server e2e (Network.framework) stays in pebsmoke.

import Foundation
import PebbleCoreBase

/// NetMsg + wire chunk codec round-trips
public func smokeNetProtocolSuite() {
    section("net protocol (round-trip)")
    do {
        func roundTrip(_ msg: NetMsg) -> NetMsg? { try? NetMsg.decode(msg.encode()) }

        if case let .hello(name, pid, version, proto, skin)? =
            roundTrip(.hello(name: "Xavi", pid: "ABC-123", version: PEBBLE_VERSION,
                             proto: NET_PROTOCOL_VERSION, skin: Data([1, 2, 3]))) {
            check("hello round-trip", name == "Xavi" && pid == "ABC-123" && version == PEBBLE_VERSION
                && proto == NET_PROTOCOL_VERSION && skin == Data([1, 2, 3]))
        } else { check("hello round-trip", false) }

        if case let .playerJoin(eid, name, pid, skin)? =
            roundTrip(.playerJoin(eid: 9, name: "Guest", pid: "XY-9", skin: Data([7]))) {
            check("playerJoin round-trip", eid == 9 && name == "Guest" && pid == "XY-9" && skin == Data([7]))
        } else { check("playerJoin round-trip", false) }

        if case let .setBlock(dim, x, y, z, cell)? = roundTrip(.setBlock(dim: 1, x: -12345, y: -60, z: 99999, cell: 4321)) {
            check("setBlock round-trip", dim == 1 && x == -12345 && y == -60 && z == 99999 && cell == 4321)
        } else { check("setBlock round-trip", false) }

        var ps = NetPlayerState()
        ps.x = 123.456; ps.y = -60.25; ps.z = 7e6
        ps.vx = 0.5; ps.yaw = 3.14; ps.pitch = -1.2
        ps.flags = 0b10101; ps.dim = 2; ps.heldId = 77; ps.heldMeta = 3; ps.health = 13.5
        ps.armorIds = [301, -1, 305, 44]; ps.offhandId = 99
        if case let .playerState(got)? = roundTrip(.playerState(ps)) {
            check("playerState round-trip (incl. armor/offhand)", got == ps)
        } else { check("playerState round-trip (incl. armor/offhand)", false) }

        var e1 = NetEntityState(); e1.eid = 42; e1.x = 1.5; e1.y = 64; e1.z = -9.25
        e1.yaw = 1.1; e1.headYaw = 0.4; e1.flags = 0b1100101; e1.aux = 88
        var e2 = NetEntityState(); e2.eid = -7; e2.x = -1e5
        if case let .entityBatch(dim, states)? = roundTrip(.entityBatch(dim: 0, states: [e1, e2])) {
            check("entityBatch round-trip", dim == 0 && states == [e1, e2])
        } else { check("entityBatch round-trip", false) }

        if case let .entityRemove(eids)? = roundTrip(.entityRemove(eids: [1, -2, 30000])) {
            check("entityRemove round-trip", eids == [1, -2, 30000])
        } else { check("entityRemove round-trip", false) }

        if case let .useBlock(dim, x, y, z, face, px, py, pz, sneaking, held)? =
            roundTrip(.useBlock(dim: 0, x: 10, y: 70, z: -10, face: 4,
                                px: 10.5, py: 70.9, pz: -9.1, sneaking: true, held: Data("stack".utf8))) {
            check("useBlock round-trip", dim == 0 && x == 10 && y == 70 && z == -10
                && face == 4 && px == 10.5 && py == 70.9 && pz == -9.1 && sneaking && held == Data("stack".utf8))
        } else { check("useBlock round-trip", false) }

        if case let .blockBreak(dim, x, y, z, held)? =
            roundTrip(.blockBreak(dim: 2, x: 1, y: 2, z: 3, held: Data("pick".utf8))) {
            check("blockBreak round-trip", dim == 2 && x == 1 && y == 2 && z == 3 && held == Data("pick".utf8))
        } else { check("blockBreak round-trip", false) }

        if case let .chatS(text)? = roundTrip(.chatS(text: "héllo wörld §a✓")) {
            check("chat unicode round-trip", text == "héllo wörld §a✓")
        } else { check("chat unicode round-trip", false) }

        if case .goodbye? = roundTrip(.goodbye) {
            check("goodbye (empty payload) round-trip", true)
        } else { check("goodbye (empty payload) round-trip", false) }

        // welcome JSON round-trip
        var wel = NetWelcome()
        wel.worldName = "Test"; wel.seed = -777; wel.yourEid = 12
        wel.players = ["3": "Host"]; wel.modifiedKeys = ["0:1:2", "1:-3:4"]
        wel.dims = ["0": DimState(time: 555, dayTime: 6000, raining: true, thundering: false, weatherTimer: 99)]
        if let blob = try? JSONEncoder().encode(wel),
           case let .welcome(json)? = roundTrip(.welcome(json: blob)),
           let got = try? JSONDecoder().decode(NetWelcome.self, from: json) {
            check("welcome JSON round-trip", got.worldName == "Test" && got.seed == -777
                && got.yourEid == 12 && got.players["3"] == "Host"
                && got.modifiedKeys == wel.modifiedKeys && got.dims["0"]?.time == 555)
        } else { check("welcome JSON round-trip", false) }

        // wire chunk container round-trip against a real generated chunk
        let out = generateChunk(.overworld, 424242, 3, -2)
        let chunk = Chunk(cx: 3, cz: -2, minY: DIMS[0].minY, height: DIMS[0].height)
        chunk.blocks = out.blocks
        chunk.biomes = out.biomes
        let wire = encodeChunkForWire(chunk)
        if let rec = decodeWireChunk(wire, dim: 0, cx: 3, cz: -2) {
            check("wire chunk blocks round-trip", rec.blocks == out.blocks)
            check("wire chunk biomes round-trip", rec.biomes == out.biomes)
            check("wire chunk strips entities", rec.entities.isEmpty)
        } else {
            check("wire chunk decode", false)
        }

        // truncated frames must throw, not crash
        let full = NetMsg.playerState(ps).encode()
        var truncatedOK = true
        for cut in 0..<full.count where (try? NetMsg.decode(full.prefix(cut))) != nil {
            // cut == 0 yields empty data → decode throws; any successful partial decode is a bug
            truncatedOK = false
        }
        check("truncated frames rejected", truncatedOK)
    }
}

/// friends/servers/recents stores + friend codes
public func smokeSocialSuite() {
    section("social stores (friends / servers / recents)")
    do {
        let s = SocialStore.shared
        s.addFriend(id: "test:friend1", name: "Testy")
        check("friend added", s.isFriend("test:friend1"))
        s.addFriend(id: "test:friend1", name: "Renamed")
        check("friend rename by id", s.friends.first { $0.id == "test:friend1" }?.name == "Renamed"
            && s.friends.filter { $0.id == "test:friend1" }.count == 1)
        s.removeFriend(id: "test:friend1")
        check("friend removed", !s.isFriend("test:friend1"))

        s.addServer(ServerEntry(name: "TestSMP", host: "203.0.113.9", port: 25585))
        check("server saved", s.servers.contains { $0.host == "203.0.113.9" })
        s.removeServer(host: "203.0.113.9", port: 25585)
        check("server removed", !s.servers.contains { $0.host == "203.0.113.9" })

        s.recordRecent(id: "test:rp", name: "Recent Rob", how: "joined you")
        check("recent recorded", s.recents.first?.id == "test:rp")
        s.removeRecent(id: "test:rp")
        check("recent removed", !s.recents.contains { $0.id == "test:rp" })

        // friend codes: identity round-trips through the shareable string
        let pid = UUID().uuidString
        if let code = FriendCode.encode(pid: pid, name: "Xavi"),
           let back = FriendCode.decode(code) {
            check("friend code round-trip", back.pid == pid && back.name == "Xavi" && code.hasPrefix("PEB1"))
            check("friend code is paste-sized", code.count <= 64, "got \(code.count) chars")
        } else {
            check("friend code round-trip", false)
        }
        check("friend code rejects garbage", FriendCode.decode("PEB1!!!not-base64!!!") == nil
            && FriendCode.decode("hello") == nil && FriendCode.decode("") == nil)

        // LAN codes: the host's ADDRESS in ten characters, so a guest on any
        // platform can join without discovery, a friend list, or an IP to type
        var roundTripped = true
        for (host, port) in [("192.168.1.20", UInt16(25585)), ("10.0.0.2", 1),
                             ("172.16.254.1", 65535), ("255.255.255.255", 25585),
                             ("1.2.3.4", 25585)] {
            guard let code = JoinCode.encode(host: host, port: port),
                  let back = JoinCode.decode(code),
                  back.host == host, back.port == port else {
                roundTripped = false
                check("LAN code round-trip \(host):\(port)", false)
                continue
            }
        }
        check("LAN code round-trips every address", roundTripped)

        let sample = JoinCode.encode(host: "192.168.1.20", port: 25585) ?? ""
        check("LAN code is twelve characters in three groups", sample.count == 14
              && sample.split(separator: "-").allSatisfy { $0.count == 4 },
              "got \"\(sample)\"")
        check("LAN code avoids the letters people mistype",
              !sample.contains(where: { "ILOU".contains($0) }), "got \"\(sample)\"")

        // typed by hand, badly: case, spaces, the dash dropped, and the
        // characters Crockford base32 leaves out folded back to digits
        let messy = sample.replacingOccurrences(of: "-", with: " ").lowercased()
        check("LAN code survives sloppy typing",
              JoinCode.decode(messy)?.host == "192.168.1.20")
        if let folded = JoinCode.encode(host: "10.0.0.1", port: 25585) {
            let confused = folded.replacingOccurrences(of: "0", with: "O")
                                 .replacingOccurrences(of: "1", with: "l")
            check("LAN code folds O to zero and l to one",
                  JoinCode.decode(confused)?.host == "10.0.0.1")
        } else {
            check("LAN code folds O to zero and l to one", false)
        }

        // the two check bits: one wrong character must not silently connect
        // you to a stranger's machine
        var caught = 0
        var tried = 0
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        for i in sample.indices where sample[i] != "-" {
            for sub in alphabet where sub != sample[i] {
                var typo = sample
                typo.replaceSubrange(i...i, with: String(sub))
                tried += 1
                if JoinCode.decode(typo) == nil { caught += 1 }
            }
        }
        check("one-character typos are all rejected", caught == tried,
              "caught \(caught) of \(tried)")

        check("LAN code rejects what isn't an address",
              JoinCode.encode(host: "pebble.local", port: 25585) == nil
              && JoinCode.encode(host: "", port: 25585) == nil
              && JoinCode.encode(host: "192.168.1.999", port: 25585) == nil)
        check("LAN code rejects nonsense", JoinCode.decode("") == nil
            && JoinCode.decode("hello") == nil && JoinCode.decode(sample + "X") == nil)

        // whatever the machine running this has, it must be a dotted quad or
        // an honest nil — never a half-parsed address a guest would dial
        if let ip = localIPv4() {
            let quads = ip.split(separator: ".")
            check("local IPv4 is a dotted quad", quads.count == 4
                && quads.allSatisfy { UInt16($0).map { $0 <= 255 } == true }, "got \(ip)")
            check("local IPv4 makes a LAN code", JoinCode.encode(host: ip, port: 25585) != nil)
        } else {
            check("local IPv4 absent is survivable", true)   // no route: nothing to host on
            check("local IPv4 makes a LAN code", true)
        }

        // the screen itself: Join By Code has to be reachable with an empty
        // friends list and no discovery at all, because that is exactly the
        // state a fresh Windows install is in
        let game = GameCore()
        let ui = UIManager(cv: UICanvas())
        let mp = MultiplayerScreen()
        mp.initScreen(ui, game)
        check("multiplayer opens on the LAN tab with a code field",
              mp.fields.contains { $0 === mp.lanCodeField })
        check("Join By Code is offered without discovery",
              mp.buttons.contains { $0.label == "Join By Code" && $0.enabled })
    }
}
