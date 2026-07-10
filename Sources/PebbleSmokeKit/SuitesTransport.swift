// Portable transport suites (PORTING modules 05/12): the plain-socket
// TCP layer, and a full dedicated-server + guest e2e over it — the
// cross-platform multiplayer proof. The Apple Network.framework adapter
// keeps its own e2e inside pebsmoke.

import Foundation
import Dispatch
import PebbleCoreBase

public func smokeSocketTransportSuite() {
    section("socket transport (portable TCP, framed)")

    // frame parser edge cases first — shared by every transport
    do {
        var p = NetFrameParser()
        var got: [NetMsg] = []
        // a frame delivered one byte at a time must still decode exactly once
        let frame = encodeNetFrame(.chatS(text: "drip"))
        for b in frame {
            _ = p.feed(Data([b]), { m in got.append(m); return true })
        }
        var dripOK = false
        if got.count == 1, case let .chatS(text) = got[0] { dripOK = text == "drip" }
        check("byte-dripped frame decodes once", dripOK, "got \(got.count) msgs")

        // an oversized length header must reject the stream, not allocate
        var bad = Data()
        var le = UInt32(NET_MAX_FRAME + 1).littleEndian
        withUnsafeBytes(of: &le) { bad.append(contentsOf: $0) }
        var q = NetFrameParser()
        let err = q.feed(bad, { _ in true })
        check("oversized frame rejected", err != nil, "parser accepted it")
    }

    // real sockets on localhost — callbacks on a private queue so this
    // works without any run-loop pumping (also on Windows CI)
    let q = DispatchQueue(label: "smoke.socket")
    func waitFor(_ timeout: Double, _ cond: @escaping () -> Bool) -> Bool {
        let t0 = monotonicNow()
        while monotonicNow() - t0 < timeout {
            if q.sync(execute: cond) { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return q.sync(execute: cond)
    }

    let listener = SocketListener(delivery: q)
    var serverSide: NetConnection?
    var serverGot: [NetMsg] = []
    var serverClosed = ""
    listener.onConnection = { c in
        serverSide = c
        c.onMessage = { m in serverGot.append(m) }
        c.onClosed = { r in serverClosed = r }
    }
    do {
        try listener.start(serviceName: "smoke", fixedPort: nil, txt: [:])
    } catch {
        check("socket listener starts", false, "\(error)")
        return
    }
    check("socket listener picked a port", listener.port != 0)

    let guest = socketDial(host: "127.0.0.1", port: listener.port, delivery: q)
    var guestGot: [NetMsg] = []
    guest.onMessage = { m in guestGot.append(m) }
    guest.onClosed = { _ in }
    guest.start()

    check("connection accepted", waitFor(5) { serverSide != nil })

    // guest -> host
    guest.send(.hello(name: "Socke", pid: "S-1", version: PEBBLE_VERSION,
                      proto: NET_PROTOCOL_VERSION, skin: Data([9, 9])))
    var helloOK = false
    _ = waitFor(5) {
        if case let .hello(name, pid, _, _, skin)? = serverGot.first {
            helloOK = name == "Socke" && pid == "S-1" && skin == Data([9, 9])
        }
        return !serverGot.isEmpty
    }
    check("hello crosses guest -> host", helloOK)

    // host -> guest, bigger than one 64KB socket read
    let blob = Data((0..<200_000).map { UInt8($0 % 251) })
    serverSide?.send(.welcome(json: blob))
    var welcomeOK = false
    _ = waitFor(10) {
        if case let .welcome(json)? = guestGot.first { welcomeOK = json == blob }
        return !guestGot.isEmpty
    }
    check("200KB frame crosses host -> guest intact", welcomeOK)

    // ordering: a burst of small frames arrives complete and in sequence
    q.sync { serverGot.removeAll() }
    for i in 0..<500 { guest.send(.chatS(text: "m\(i)")) }
    _ = waitFor(10) { serverGot.count >= 500 }
    var orderOK = q.sync { serverGot.count == 500 }
    if orderOK {
        q.sync {
            for (i, m) in serverGot.enumerated() {
                guard case let .chatS(text) = m, text == "m\(i)" else { orderOK = false; break }
            }
        }
    }
    check("500 frames in order", orderOK, "got \(q.sync { serverGot.count })")

    // close propagates to the other side
    guest.close()
    check("close reaches the host side", waitFor(5) { !serverClosed.isEmpty },
          "no onClosed reason")
    listener.stop()
}

public func smokePortableServerSuite() {
    section("portable server (dedicated core + guest over plain sockets)")

    // GameCore's background work publishes through the main queue; verify
    // this platform pumps it via RunLoop before running the e2e
    var pumped = false
    DispatchQueue.main.async { pumped = true }
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    if !pumped {
        check("SKIPPED: main-queue pumping unavailable on this platform", true)
        return
    }

    // force the portable transport even when the Apple adapter is installed
    let savedFactory = makeNetListener
    makeNetListener = { SocketListener() }
    defer { makeNetListener = savedFactory }

    let recentsBefore = Set(SocialStore.shared.recents.map { $0.id })
    let server = GameCore()
    server.createWorld(name: "sockettest-smp", seedText: "4242", mode: 0, difficulty: 2)
    let worldId = server.worldRec?.id ?? ""
    server.exitToTitle()

    if let rec = server.db.getWorld(worldId) {
        do {
            try server.enterWorldDedicated(rec, port: nil)
        } catch {
            check("socket server started", false, "\(error)")
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

        check("socket listener ready", pumpUntil(900) { (server.netHost?.port ?? 0) != 0 })
        let g = GameCore()
        guest = g
        _ = g.joinLan(socketDial(host: "127.0.0.1", port: server.netHost?.port ?? 0),
                      name: "SockGuest", skin: Data())
        check("guest joined over plain sockets", pumpUntil(600) { g.hasWorld() },
              "status: \(g.netGuest?.status ?? "no session")")
        check("server lists the guest", server.netHost?.guestNames == ["SockGuest"])

        if g.hasWorld() {
            // block edits flow both ways over the portable wire
            let sx = Int((server.worlds[.overworld]?.spawnX ?? 0).rounded(.down))
            let sz = Int((server.worlds[.overworld]?.spawnZ ?? 0).rounded(.down))
            check("guest streamed spawn chunks", pumpUntil(800) { g.hasWorld() && g.world.isLoadedAt(sx, sz) })
            let sy = (server.worlds[.overworld]?.surfaceY(sx, sz) ?? 80) + 3
            server.worlds[.overworld]?.setBlock(sx, sy, sz, Int(B.stone) << 4)
            check("server block reaches guest", pumpUntil(200) {
                g.hasWorld() && g.world.getBlockId(sx, sy, sz) == Int(B.stone)
            })
            g.netGuest?.sendBreak(sx, sy, sz)
            check("guest break lands on server", pumpUntil(200) {
                server.worlds[.overworld]?.getBlockId(sx, sy, sz) == 0
            })
            g.exitToTitle()
        } else {
            check("block sync over sockets", false, "guest never joined")
        }
        check("server sees the leave", pumpUntil(200) { server.netHost?.guestCount == 0 })
        server.exitToTitle()
        check("socket server shut down cleanly", !server.hasWorld())
    } else {
        check("sockettest world record exists", false)
    }
    server.deleteWorld(worldId)
    check("sockettest world deleted", server.db.getWorld(worldId) == nil)
    // scrub recents the net tests recorded (they carry this machine's own pid)
    for r in SocialStore.shared.recents where !recentsBefore.contains(r.id) {
        SocialStore.shared.removeRecent(id: r.id)
    }
}
