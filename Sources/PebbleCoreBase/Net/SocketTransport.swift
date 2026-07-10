// Portable TCP transport (PORTING module 05) — plain sockets: WinSock on
// Windows, BSD sockets elsewhere. Same framing and callback contract as the
// Network.framework adapter in PebbleCore; no discovery (direct IP only —
// Bonjour stays in the Apple adapter). Callbacks hop to `delivery` (the main
// queue by default: the whole game sim is main-thread, so the net layer
// must be too).

import Foundation
import Dispatch
#if os(Windows)
import WinSDK
#elseif canImport(Glibc)
import Glibc
#endif

#if os(Windows)
typealias PebSocket = SOCKET
private let PEB_BAD_SOCKET: PebSocket = INVALID_SOCKET
/// WinSock needs a one-time init before any socket call
private let wsaReady: Bool = {
    var data = WSADATA()
    return WSAStartup(0x0202, &data) == 0
}()
#else
typealias PebSocket = Int32
private let PEB_BAD_SOCKET: PebSocket = -1
private let wsaReady = true
#endif

public struct SocketError: Error, CustomStringConvertible, LocalizedError {
    public let message: String
    public var description: String { message }
    public var errorDescription: String? { message }
}

// ---- tiny platform shims ----------------------------------------------------

private func pebCloseSocket(_ s: PebSocket) {
    #if os(Windows)
    closesocket(s)
    #else
    close(s)
    #endif
}

private func pebShutdown(_ s: PebSocket) {
    #if os(Windows)
    shutdown(s, SD_BOTH)
    #else
    shutdown(s, SHUT_RDWR)
    #endif
}

private func pebRecv(_ s: PebSocket, _ buf: UnsafeMutableRawPointer, _ n: Int) -> Int {
    #if os(Windows)
    return Int(recv(s, buf.assumingMemoryBound(to: CChar.self), Int32(min(n, Int(Int32.max))), 0))
    #else
    return recv(s, buf, n, 0)
    #endif
}

private func pebSend(_ s: PebSocket, _ buf: UnsafeRawPointer, _ n: Int) -> Int {
    #if os(Windows)
    return Int(send(s, buf.assumingMemoryBound(to: CChar.self), Int32(min(n, Int(Int32.max))), 0))
    #elseif canImport(Glibc)
    return send(s, buf, n, Int32(MSG_NOSIGNAL))
    #else
    return send(s, buf, n, 0)   // Darwin: SO_NOSIGPIPE is set on the socket
    #endif
}

/// low-latency + crash-safety socket options every Pebble connection wants
private func pebTuneSocket(_ s: PebSocket) {
    var one: Int32 = 1
    // TCP_NODELAY == 1 on Darwin, Linux, and WinSock alike; player state
    // frames are small and frequent — never Nagle-batch them
    _ = withUnsafePointer(to: &one) { p in
        #if os(Windows)
        p.withMemoryRebound(to: CChar.self, capacity: 4) {
            setsockopt(s, Int32(6 /* IPPROTO_TCP */), Int32(1 /* TCP_NODELAY */), $0, 4)
        }
        #else
        setsockopt(s, Int32(6 /* IPPROTO_TCP */), TCP_NODELAY, p, socklen_t(4))
        #endif
    }
    #if canImport(Darwin)
    var pipeOff: Int32 = 1
    _ = withUnsafePointer(to: &pipeOff) {
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(4))
    }
    #endif
}

// ---- connection -------------------------------------------------------------

/// one framed TCP connection over a plain socket
public final class SocketConnection: NetConnection {
    public var tag: AnyObject?
    public var onMessage: ((NetMsg) -> Void)?
    public var onClosed: ((String) -> Void)?
    public private(set) var closed = false

    private let lock = NSLock()
    private var fd: PebSocket
    private let delivery: DispatchQueue
    private let sendQueue = DispatchQueue(label: "pebble.net.send")
    private var parser = NetFrameParser()   // touched on `delivery` only
    /// dial target when created via socketDial (connect happens in start())
    private let dialTarget: (host: String, port: UInt16)?
    /// sessions send (hello!) right after start(), before the dial thread
    /// has connected — senders wait here like NWConnection's pre-ready buffer
    private let ready = NSCondition()
    private var isReady: Bool

    /// wrap an accepted socket
    init(fd: PebSocket, delivery: DispatchQueue) {
        self.fd = fd
        self.delivery = delivery
        dialTarget = nil
        isReady = true
    }

    /// prepare an outgoing connection — start() resolves + connects
    init(host: String, port: UInt16, delivery: DispatchQueue) {
        fd = PEB_BAD_SOCKET
        self.delivery = delivery
        dialTarget = (host, port)
        isReady = false
    }

    /// unblock queued senders — connected, failed, or closed alike
    private func markReady() {
        ready.lock()
        isReady = true
        ready.broadcast()
        ready.unlock()
    }

    private func waitReady() {
        ready.lock()
        while !isReady { ready.wait() }
        ready.unlock()
    }

    public func start() {
        Thread.detachNewThread { [self] in
            if let target = dialTarget {
                switch dialSocket(target.host, target.port) {
                case .success(let sock):
                    lock.lock()
                    if closed {   // close() raced the connect
                        lock.unlock()
                        pebCloseSocket(sock)
                        markReady()
                        return
                    }
                    fd = sock
                    lock.unlock()
                    markReady()
                case .failure(let err):
                    markReady()
                    finish("connection failed: \(err.message)")
                    return
                }
            }
            readLoop()
        }
    }

    private func readLoop() {
        let bufSize = 1 << 16
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 1)
        defer { buf.deallocate() }
        while true {
            lock.lock()
            let sock = fd
            let isClosed = closed
            lock.unlock()
            if isClosed || sock == PEB_BAD_SOCKET { return }
            let n = pebRecv(sock, buf, bufSize)
            if n <= 0 {
                finish(n == 0 ? "connection closed" : "connection lost")
                return
            }
            let data = Data(bytes: buf, count: n)
            delivery.async { [self] in
                if closed { return }
                if let err = parser.feed(data, { msg in
                    onMessage?(msg)
                    return !closed   // handler may close mid-drain
                }) {
                    finishOnDelivery(err)
                }
            }
        }
    }

    public func send(_ msg: NetMsg) {
        if closed { return }
        let frame = encodeNetFrame(msg)
        sendQueue.async { [self] in
            waitReady()
            lock.lock()
            let sock = fd
            let isClosed = closed
            lock.unlock()
            if isClosed || sock == PEB_BAD_SOCKET { return }
            frame.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                var sent = 0
                while sent < raw.count {
                    let n = pebSend(sock, raw.baseAddress! + sent, raw.count - sent)
                    if n <= 0 { return }   // reader will notice and finish
                    sent += n
                }
            }
        }
    }

    public func close() {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        let sock = fd
        lock.unlock()
        markReady()   // drop, don't strand, senders queued behind the dial
        if sock != PEB_BAD_SOCKET {
            pebShutdown(sock)
            pebCloseSocket(sock)
        }
    }

    /// failure path from the reader thread — hop to the delivery queue
    private func finish(_ reason: String) {
        delivery.async { self.finishOnDelivery(reason) }
    }

    private func finishOnDelivery(_ reason: String) {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        let sock = fd
        lock.unlock()
        markReady()
        if sock != PEB_BAD_SOCKET {
            pebShutdown(sock)
            pebCloseSocket(sock)
        }
        onClosed?(reason)
    }
}

/// resolve + connect (getaddrinfo handles names, IPv4, and IPv6)
private func dialSocket(_ host: String, _ port: UInt16) -> Result<PebSocket, SocketError> {
    guard wsaReady else { return .failure(SocketError(message: "WinSock init failed")) }
    var hints = addrinfo()
    hints.ai_socktype = {
        #if os(Windows)
        Int32(SOCK_STREAM)
        #else
        SOCK_STREAM
        #endif
    }()
    var res: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, String(port), &hints, &res) == 0, let first = res else {
        return .failure(SocketError(message: "cannot resolve \(host)"))
    }
    defer { freeaddrinfo(first) }
    var info: UnsafeMutablePointer<addrinfo>? = first
    while let ai = info {
        let s = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
        if s != PEB_BAD_SOCKET {
            #if os(Windows)
            let ok = connect(s, ai.pointee.ai_addr, Int32(ai.pointee.ai_addrlen)) == 0
            #else
            let ok = connect(s, ai.pointee.ai_addr, socklen_t(ai.pointee.ai_addrlen)) == 0
            #endif
            if ok {
                pebTuneSocket(s)
                return .success(s)
            }
            pebCloseSocket(s)
        }
        info = ai.pointee.ai_next
    }
    return .failure(SocketError(message: "cannot connect to \(host):\(port)"))
}

/// dial a direct host:port over the portable transport
public func socketDial(host: String, port: UInt16,
                       delivery: DispatchQueue = .main) -> NetConnection {
    SocketConnection(host: host, port: port, delivery: delivery)
}

// ---- listener -----------------------------------------------------------------

/// accepts TCP connections on all IPv4 interfaces; serviceName/txt are
/// ignored (no discovery on the portable path — guests dial the IP directly)
public final class SocketListener: NetListener {
    public var onConnection: ((NetConnection) -> Void)?
    public private(set) var port: UInt16 = 0

    private let delivery: DispatchQueue
    private var fd: PebSocket = PEB_BAD_SOCKET
    private var stopped = false
    private let lock = NSLock()

    public init(delivery: DispatchQueue = .main) {
        self.delivery = delivery
    }

    public func start(serviceName: String, fixedPort: UInt16? = nil,
                      txt: [String: String] = [:]) throws {
        guard wsaReady else { throw SocketError(message: "WinSock init failed") }
        #if os(Windows)
        let s = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let s = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard s != PEB_BAD_SOCKET else { throw SocketError(message: "socket() failed") }

        #if !os(Windows)
        // rebind fast after restarts (matches allowLocalEndpointReuse);
        // Windows' SO_REUSEADDR means something unsafe — skip it there
        var one: Int32 = 1
        _ = withUnsafePointer(to: &one) {
            setsockopt(s, SOL_SOCKET, SO_REUSEADDR, $0, socklen_t(4))
        }
        #endif

        var addr = sockaddr_in()
        #if os(Windows)
        addr.sin_family = ADDRESS_FAMILY(AF_INET)
        #else
        addr.sin_family = sa_family_t(AF_INET)
        #endif
        addr.sin_port = (fixedPort ?? 0).bigEndian
        // sin_addr already zeroed = INADDR_ANY
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                #if os(Windows)
                bind(s, $0, Int32(MemoryLayout<sockaddr_in>.size)) == 0
                #else
                bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                #endif
            }
        }
        guard bound, listen(s, 16) == 0 else {
            pebCloseSocket(s)
            throw SocketError(message: "cannot listen on port \(fixedPort ?? 0)")
        }

        // read back the real port (fixedPort may have been 0 = ephemeral)
        var bd = sockaddr_in()
        #if os(Windows)
        var blen = Int32(MemoryLayout<sockaddr_in>.size)
        #else
        var blen = socklen_t(MemoryLayout<sockaddr_in>.size)
        #endif
        _ = withUnsafeMutablePointer(to: &bd) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(s, $0, &blen)
            }
        }
        port = UInt16(bigEndian: bd.sin_port)
        fd = s

        Thread.detachNewThread { [self] in
            while true {
                let client = accept(s, nil, nil)
                lock.lock()
                let done = stopped
                lock.unlock()
                if done {
                    if client != PEB_BAD_SOCKET { pebCloseSocket(client) }
                    return
                }
                if client == PEB_BAD_SOCKET { return }   // listener closed
                pebTuneSocket(client)
                let c = SocketConnection(fd: client, delivery: delivery)
                delivery.async { [self] in
                    onConnection?(c)
                    c.start()
                }
            }
        }
    }

    public func stop() {
        lock.lock()
        if stopped {
            lock.unlock()
            return
        }
        stopped = true
        let s = fd
        fd = PEB_BAD_SOCKET
        lock.unlock()
        if s != PEB_BAD_SOCKET { pebCloseSocket(s) }
    }
}
