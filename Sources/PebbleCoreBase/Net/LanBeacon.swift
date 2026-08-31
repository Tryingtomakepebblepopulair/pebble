// Finding each other on a LAN, on both platforms.
//
// Discovery used to be Bonjour, which lives in Network.framework, which is
// Apple's. So `makeLanDiscovery` returned nil on Windows and the LAN Games
// list there was permanently, silently empty — and because a friend counts as
// "online" only when a discovered session carries their id, a Windows player
// was also permanently offline to everyone, and every Windows host invisible
// to the Macs. Two of the same bug wearing different clothes.
//
// This is the portable half: the host shouts a small UDP datagram onto the
// broadcast address a couple of times a second, and anyone listening on the
// beacon port hears it. No dependencies, no service registry, nothing to
// configure — the same reason Pebble has no central server in the first
// place. Bonjour stays on the Mac and the two are merged, so a Mac still
// finds a Mac the way it always did, and now finds a Windows PC as well.
//
// The datagram carries the same `txt` dictionary Bonjour advertises, so
// everything downstream — the game list, the [Server] tag, friend presence —
// reads it without knowing which of the two found it.

import Foundation
import Dispatch
#if os(Windows)
import WinSDK
#elseif canImport(Glibc)
import Glibc
#endif

/// The port beacons are sent to and heard on. One below the default game
/// port, and deliberately not the same: the game port is TCP and may be
/// remapped per world, while this one has to be a constant everybody knows.
public let LAN_BEACON_PORT: UInt16 = 25584

/// How often a host repeats itself, and how long a guest keeps a host in the
/// list after the last one. Three missed beacons before a game disappears —
/// enough that a dropped packet doesn't make the list flicker.
private let BEACON_INTERVAL = 1.5
private let BEACON_TTL = 5.0

// ---- wire format ---------------------------------------------------------------

/// "PEB1\n" then one key=value per line. Text, because the payload IS a
/// string dictionary and this way a beacon can be read with tcpdump when
/// something goes wrong on a machine nobody can attach a debugger to.
public func encodeLanBeacon(name: String, port: UInt16, txt: [String: String]) -> Data {
    func clean(_ s: String) -> String {
        String(s.replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "=", with: "-").prefix(64))
    }
    var out = "PEB1\nname=\(clean(name))\nport=\(port)\n"
    for k in txt.keys.sorted() where k != "name" && k != "port" {
        out += "\(clean(k))=\(clean(txt[k] ?? ""))\n"
    }
    return Data(out.prefix(512).utf8)
}

/// "Is anyone hosting?" — sent by whoever is LOOKING, and the reason it
/// exists is Windows Firewall.
///
/// A host has to be let through the firewall no matter what: people are
/// connecting IN to it. But a guest was also being asked to accept unsolicited
/// inbound broadcasts, and on a standard (non-administrator) Windows account
/// that prompt never appears at all — Windows simply drops the packets, and
/// the LAN list stays empty with nothing to click and nothing to explain it.
///
/// A reply to a datagram the guest sent first is a different matter: the
/// firewall already has a mapping for it and lets it back in, no prompt and no
/// permission needed. So the guest asks, and hosts answer.
public let LAN_QUERY_MAGIC = "PEBQ1"

public func encodeLanQuery() -> Data { Data((LAN_QUERY_MAGIC + "\n").utf8) }

public func isLanQuery(_ data: Data) -> Bool {
    data.count <= 64 && String(data: data, encoding: .utf8)?
        .hasPrefix(LAN_QUERY_MAGIC) == true
}

/// nil for anything that isn't one of ours — the beacon port is a shared
/// resource and other software is allowed to be on it
public func decodeLanBeacon(_ data: Data) -> (name: String, port: UInt16, txt: [String: String])? {
    guard data.count <= 1024, let text = String(data: data, encoding: .utf8) else { return nil }
    var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
    guard lines.first == "PEB1" else { return nil }
    lines.removeFirst()
    var txt: [String: String] = [:]
    for line in lines {
        guard let eq = line.firstIndex(of: "=") else { continue }
        txt[String(line[line.startIndex..<eq])] = String(line[line.index(after: eq)...])
    }
    guard let port = txt["port"].flatMap(UInt16.init), port != 0 else { return nil }
    let name = txt["name"] ?? "Pebble game"
    return (name, port, txt)
}

// ---- shared socket helpers -------------------------------------------------------

/// sockaddr_in for a dotted quad, without touching the in_addr union — its
/// Swift spelling differs between platforms, but the four address bytes sit
/// at offset 4 on every BSD-sockets ABI, Winsock included
private func beaconAddr(_ quad: (UInt8, UInt8, UInt8, UInt8), _ port: UInt16) -> sockaddr_in {
    var a = sockaddr_in()
    #if os(Windows)
    a.sin_family = ADDRESS_FAMILY(AF_INET)
    #else
    a.sin_family = sa_family_t(AF_INET)
    #endif
    a.sin_port = port.bigEndian
    withUnsafeMutableBytes(of: &a) { raw in
        raw[4] = quad.0; raw[5] = quad.1; raw[6] = quad.2; raw[7] = quad.3
    }
    return a
}

private func beaconSocket() -> PebSocket? {
    guard wsaReady else { return nil }
    #if os(Windows)
    let s = socket(AF_INET, Int32(SOCK_DGRAM), 0)
    #else
    let s = socket(AF_INET, SOCK_DGRAM, 0)
    #endif
    return s == PEB_BAD_SOCKET ? nil : s
}

/// share the beacon port with any other Pebble on this machine. Windows'
/// SO_REUSEADDR already means this for UDP; the BSDs need SO_REUSEPORT too,
/// and without it the second socket simply fails to bind.
private func allowPortSharing(_ s: PebSocket) {
    setFlag(s, SOL_SOCKET, SO_REUSEADDR)
    #if !os(Windows)
    setFlag(s, SOL_SOCKET, SO_REUSEPORT)
    #endif
}

private func setFlag(_ s: PebSocket, _ level: Int32, _ option: Int32) {
    var one: Int32 = 1
    _ = withUnsafePointer(to: &one) { p in
        #if os(Windows)
        p.withMemoryRebound(to: CChar.self, capacity: 4) {
            setsockopt(s, level, option, $0, 4)
        }
        #else
        setsockopt(s, level, option, p, socklen_t(4))
        #endif
    }
}

// ---- the host's side -------------------------------------------------------------

/// Repeats "there is a Pebble world here" onto the LAN until it is stopped.
/// The port is read fresh every time rather than captured, because the Apple
/// listener learns its own port asynchronously and the first beacons would
/// otherwise advertise zero.
public final class LanBeacon {
    private let name: String
    private let txt: [String: String]
    private let portSource: () -> UInt16
    private let lock = NSLock()
    private var stopped = false
    /// the socket that hears "is anyone hosting?" and answers it
    private var answerFd: PebSocket = PEB_BAD_SOCKET

    public init(name: String, txt: [String: String], port: @escaping () -> UInt16) {
        self.name = name
        self.txt = txt
        self.portSource = port
    }

    public func start() {
        startAnswering()
        Thread.detachNewThread { [self] in
            guard let s = beaconSocket() else { return }
            defer { pebCloseSocket(s) }
            setFlag(s, SOL_SOCKET, SO_BROADCAST)
            // the broadcast address, plus loopback so a second client on this
            // same machine sees us (broadcast does not reliably come back to
            // the sender, and host-and-guest-on-one-box is how LAN is tested)
            var targets = [beaconAddr((255, 255, 255, 255), LAN_BEACON_PORT),
                           beaconAddr((127, 0, 0, 1), LAN_BEACON_PORT)]
            while true {
                lock.lock()
                let done = stopped
                lock.unlock()
                if done { return }

                let port = portSource()
                if port != 0 {
                    let payload = [UInt8](encodeLanBeacon(name: name, port: port, txt: txt))
                    for i in targets.indices {
                        _ = payload.withUnsafeBufferPointer { buf in
                            withUnsafePointer(to: &targets[i]) { ap in
                                ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                                    #if os(Windows)
                                    sendto(s, UnsafeRawPointer(buf.baseAddress!)
                                        .assumingMemoryBound(to: CChar.self),
                                           Int32(payload.count), 0, sa,
                                           Int32(MemoryLayout<sockaddr_in>.size))
                                    #else
                                    sendto(s, buf.baseAddress, payload.count, 0, sa,
                                           socklen_t(MemoryLayout<sockaddr_in>.size))
                                    #endif
                                }
                            }
                        }
                    }
                }
                Thread.sleep(forTimeInterval: BEACON_INTERVAL)
            }
        }
    }

    public func stop() {
        lock.lock()
        stopped = true
        let a = answerFd
        answerFd = PEB_BAD_SOCKET
        lock.unlock()
        if a != PEB_BAD_SOCKET { pebCloseSocket(a) }
    }

    /// Listen on the beacon port and reply, unicast, to anyone who asks. This
    /// is the half that reaches a guest whose firewall drops unsolicited
    /// broadcasts — which on a standard Windows account is every guest,
    /// silently and with no prompt to say so.
    private func startAnswering() {
        guard let s = beaconSocket() else { return }
        allowPortSharing(s)
        var addr = beaconAddr((0, 0, 0, 0), LAN_BEACON_PORT)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                #if os(Windows)
                bind(s, $0, Int32(MemoryLayout<sockaddr_in>.size)) == 0
                #else
                bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                #endif
            }
        }
        guard bound else {
            pebCloseSocket(s)
            return
        }
        lock.lock()
        answerFd = s
        lock.unlock()

        Thread.detachNewThread { [self] in
            var buf = [UInt8](repeating: 0, count: 1024)
            while true {
                var from = sockaddr_in()
                #if os(Windows)
                var fromLen = Int32(MemoryLayout<sockaddr_in>.size)
                #else
                var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                #endif
                let n: Int = buf.withUnsafeMutableBytes { b in
                    withUnsafeMutablePointer(to: &from) { fp in
                        fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                            #if os(Windows)
                            Int(recvfrom(s, b.baseAddress!.assumingMemoryBound(to: CChar.self),
                                         Int32(b.count), 0, sa, &fromLen))
                            #else
                            recvfrom(s, b.baseAddress, b.count, 0, sa, &fromLen)
                            #endif
                        }
                    }
                }
                lock.lock()
                let done = stopped
                lock.unlock()
                if done || n <= 0 { return }
                guard isLanQuery(Data(buf[0..<n])) else { continue }
                let port = portSource()
                guard port != 0 else { continue }
                let payload = [UInt8](encodeLanBeacon(name: name, port: port, txt: txt))
                _ = payload.withUnsafeBufferPointer { pb in
                    withUnsafePointer(to: &from) { fp in
                        fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                            #if os(Windows)
                            sendto(s, UnsafeRawPointer(pb.baseAddress!)
                                .assumingMemoryBound(to: CChar.self),
                                   Int32(payload.count), 0, sa, fromLen)
                            #else
                            sendto(s, pb.baseAddress, payload.count, 0, sa, fromLen)
                            #endif
                        }
                    }
                }
            }
        }
    }
}

// ---- the guest's side ------------------------------------------------------------

/// Hears beacons and turns them into games you can click. Entries expire, so
/// a host that quits without saying goodbye leaves the list on its own.
public final class UDPLanDiscovery: LanDiscovery {
    public var onUpdate: (([DiscoveredGame]) -> Void)?

    private let delivery: DispatchQueue
    private var found: [String: (game: DiscoveredGame, seen: Double)] = [:]
    /// bound to the beacon port: hears hosts shouting unprompted. Best effort
    /// — a firewall that was never asked about Pebble drops these.
    private var listenFd: PebSocket = PEB_BAD_SOCKET
    /// an ordinary outbound socket: asks "is anyone hosting?" and hears the
    /// answers. This one survives a firewall, because the replies are
    /// solicited traffic on a socket that spoke first.
    private var askFd: PebSocket = PEB_BAD_SOCKET
    private var running = false
    private let lock = NSLock()

    public init(delivery: DispatchQueue = .main) {
        self.delivery = delivery
    }

    public func start() {
        lock.lock()
        if running {
            lock.unlock()
            return
        }
        running = true
        lock.unlock()
        startListening()
        startAsking()
    }

    public func stop() {
        lock.lock()
        running = false
        let a = listenFd, b = askFd
        listenFd = PEB_BAD_SOCKET
        askFd = PEB_BAD_SOCKET
        lock.unlock()
        if a != PEB_BAD_SOCKET { pebCloseSocket(a) }
        if b != PEB_BAD_SOCKET { pebCloseSocket(b) }
    }

    /// the beacon port, shared with any other Pebble on this machine
    private func startListening() {
        guard let s = beaconSocket() else { return }
        allowPortSharing(s)
        var addr = beaconAddr((0, 0, 0, 0), LAN_BEACON_PORT)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                #if os(Windows)
                bind(s, $0, Int32(MemoryLayout<sockaddr_in>.size)) == 0
                #else
                bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                #endif
            }
        }
        guard bound else {
            pebCloseSocket(s)
            return       // not fatal: asking still works, and that is the path
        }                // that gets through a firewall anyway
        lock.lock()
        listenFd = s
        lock.unlock()
        receiveLoop(s)
    }

    /// ask on an ephemeral port, and listen for the answers on it. Kept apart
    /// from the bound socket on purpose: a reply must come back to the socket
    /// that sent the question, or the firewall has no mapping for it.
    private func startAsking() {
        guard let s = beaconSocket() else { return }
        setFlag(s, SOL_SOCKET, SO_BROADCAST)
        lock.lock()
        askFd = s
        lock.unlock()
        receiveLoop(s)

        Thread.detachNewThread { [weak self] in
            let query = [UInt8](encodeLanQuery())
            var targets = [beaconAddr((255, 255, 255, 255), LAN_BEACON_PORT),
                           beaconAddr((127, 0, 0, 1), LAN_BEACON_PORT)]
            while true {
                guard let self else { return }
                self.lock.lock()
                let live = self.running
                self.lock.unlock()
                guard live else { return }
                for i in targets.indices {
                    _ = query.withUnsafeBufferPointer { qb in
                        withUnsafePointer(to: &targets[i]) { ap in
                            ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                                #if os(Windows)
                                sendto(s, UnsafeRawPointer(qb.baseAddress!)
                                    .assumingMemoryBound(to: CChar.self),
                                       Int32(query.count), 0, sa,
                                       Int32(MemoryLayout<sockaddr_in>.size))
                                #else
                                sendto(s, qb.baseAddress, query.count, 0, sa,
                                       socklen_t(MemoryLayout<sockaddr_in>.size))
                                #endif
                            }
                        }
                    }
                }
                Thread.sleep(forTimeInterval: BEACON_INTERVAL)
            }
        }
    }

    /// one thread per socket, folding whatever arrives into the same list
    private func receiveLoop(_ s: PebSocket) {
        Thread.detachNewThread { [weak self] in
            var buf = [UInt8](repeating: 0, count: 1024)
            while true {
                var from = sockaddr_in()
                #if os(Windows)
                var fromLen = Int32(MemoryLayout<sockaddr_in>.size)
                #else
                var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                #endif
                let n: Int = buf.withUnsafeMutableBytes { b in
                    withUnsafeMutablePointer(to: &from) { fp in
                        fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                            #if os(Windows)
                            Int(recvfrom(s, b.baseAddress!.assumingMemoryBound(to: CChar.self),
                                         Int32(b.count), 0, sa, &fromLen))
                            #else
                            recvfrom(s, b.baseAddress, b.count, 0, sa, &fromLen)
                            #endif
                        }
                    }
                }
                guard let self else { return }
                self.lock.lock()
                let live = self.running
                self.lock.unlock()
                guard live, n > 0 else { return }   // closed by stop()

                let quad = withUnsafeBytes(of: from) { raw in
                    (raw.load(fromByteOffset: 4, as: UInt8.self),
                     raw.load(fromByteOffset: 5, as: UInt8.self),
                     raw.load(fromByteOffset: 6, as: UInt8.self),
                     raw.load(fromByteOffset: 7, as: UInt8.self))
                }
                let host = "\(quad.0).\(quad.1).\(quad.2).\(quad.3)"
                let data = Data(buf[0..<n])
                self.delivery.async { self.heard(data, from: host) }
            }
        }
    }

    /// on the delivery queue: fold one beacon in and expire the stale ones
    private func heard(_ data: Data, from host: String) {
        if isLanQuery(data) { return }   // another guest asking, not a host answering
        guard let b = decodeLanBeacon(data) else { return }
        let now = monotonicNow()
        // keyed by address, so a host that changes its world name replaces its
        // own entry instead of appearing twice — and so the same host heard on
        // both sockets is one game, not two
        found["\(host):\(b.port)"] = (
            DiscoveredGame(name: b.name, txt: b.txt,
                           dial: { socketDial(host: host, port: b.port) }),
            now)
        found = found.filter { now - $0.value.seen < BEACON_TTL }
        onUpdate?(found.keys.sorted().compactMap { found[$0]?.game })
    }
}


// ---- both at once ----------------------------------------------------------------

/// Runs several discoveries and reports the union. macOS keeps Bonjour and
/// gains the beacon; the same Mac host arrives twice, so entries are folded
/// on the identity they advertise — the player id for an open world, the
/// service name for a dedicated server, which has none.
public final class CombinedLanDiscovery: LanDiscovery {
    public var onUpdate: (([DiscoveredGame]) -> Void)?

    private let sources: [LanDiscovery]
    private var latest: [Int: [DiscoveredGame]] = [:]

    public init(_ sources: [LanDiscovery]) {
        self.sources = sources
    }

    public func start() {
        for (i, src) in sources.enumerated() {
            src.onUpdate = { [weak self] games in
                guard let self else { return }
                self.latest[i] = games
                self.publish()
            }
            src.start()
        }
    }

    public func stop() {
        for s in sources { s.stop() }
        latest.removeAll()
    }

    private func publish() {
        var seen = Set<String>()
        var out: [DiscoveredGame] = []
        for i in latest.keys.sorted() {
            for g in latest[i] ?? [] {
                let pid = g.txt["pid"] ?? ""
                let key = pid.isEmpty ? "name:\(g.name)" : "pid:\(pid)"
                if seen.insert(key).inserted { out.append(g) }
            }
        }
        onUpdate?(out)
    }
}
