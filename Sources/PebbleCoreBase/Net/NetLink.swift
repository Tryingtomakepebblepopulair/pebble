// Transport-neutral connection interfaces (PORTING module 05). Sessions and
// GameCore talk to these protocols only; the concrete transport is an
// adapter: Network.framework + Bonjour on macOS (PebbleCore), plain TCP
// sockets everywhere (SocketTransport.swift). Frames are
// [u32 little-endian length][message bytes] on every transport.

import Foundation
import Dispatch

/// one framed TCP connection (host-side accepted socket, or the guest's link)
public protocol NetConnection: AnyObject {
    /// application tag (the host hangs its per-guest state here)
    var tag: AnyObject? { get set }
    var onMessage: ((NetMsg) -> Void)? { get set }
    var onClosed: ((String) -> Void)? { get set }
    var closed: Bool { get }
    func start()
    func send(_ msg: NetMsg)
    func close()
}

/// host side: accepts connections; adapters may also advertise (Bonjour)
public protocol NetListener: AnyObject {
    var onConnection: ((NetConnection) -> Void)? { get set }
    /// TCP port once ready (0 before) — tests and direct-IP guests dial it
    var port: UInt16 { get }
    func start(serviceName: String, fixedPort: UInt16?, txt: [String: String]) throws
    func stop()
}

/// factory for session listeners — platform shells may replace it: the macOS
/// app installs the Network.framework + Bonjour adapter at startup, the
/// portable default is plain TCP sockets with no discovery (direct IP)
public var makeNetListener: () -> NetListener = { SocketListener() }

/// shared frame codec so every transport splits bytes identically
public struct NetFrameParser {
    private var buffer = Data()
    public init() {}

    /// append received bytes and deliver every complete frame. `deliver`
    /// returns false to stop draining (handler closed the connection).
    /// Returns an error string when the stream must be dropped.
    public mutating func feed(_ data: Data, _ deliver: (NetMsg) -> Bool) -> String? {
        buffer.append(data)
        while buffer.count >= 4 {
            let len = Int(UInt32(littleEndian: buffer.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
            if len > NET_MAX_FRAME {
                return "oversized frame (\(len) bytes)"
            }
            guard buffer.count >= 4 + len else { return nil }
            let frame = buffer.subdata(in: (buffer.startIndex + 4)..<(buffer.startIndex + 4 + len))
            buffer.removeFirst(4 + len)
            if let msg = try? NetMsg.decode(frame) {
                if !deliver(msg) { return nil }   // handler may close mid-drain
            }
            // unknown/corrupt frames are skipped — forward compatibility
        }
        return nil
    }
}

/// [u32 LE length][body] — the bytes `NetFrameParser` expects
public func encodeNetFrame(_ msg: NetMsg) -> Data {
    let body = msg.encode()
    var frame = Data(capacity: body.count + 4)
    var le = UInt32(body.count).littleEndian
    withUnsafeBytes(of: &le) { frame.append(contentsOf: $0) }
    frame.append(body)
    return frame
}
