// LAN codes — a host's address packed into ten typeable characters.
//
// Friend codes (Social.swift) carry an identity; this carries an ADDRESS, and
// that is the whole difference. A LAN code is what you read out loud to
// someone sitting next to you: they type it on a Mac or a Windows PC, hit
// Join, and they are in. No friend list, no Bonjour, no accounts — which is
// why it is the one join path that works on every platform Pebble ships on.
// Bonjour discovery only exists in the Apple adapter, so before this the
// Windows client's only option was typing a raw "192.168.1.20:25585".
//
// The payload is 48 bits — four bytes of IPv4 plus a two-byte port — and
// twelve check bits, so twelve Crockford base32 characters hold it exactly,
// in three groups of four. Crockford's alphabet has no I, L, O or U, so the
// classic 0/O and 1/I/l mix-ups cannot happen; decoding folds them back
// anyway for the people who type what they think they see.
//
// Twelve check bits is generous for a six-byte payload, and deliberately so:
// a mistyped code that still decodes points a guest at a stranger's address
// and then sits there timing out with nothing to explain it. Rejecting it on
// the spot — "check that code again" — is the whole point.

import Foundation

public enum JoinCode {
    /// Crockford base32 — no I, L, O, U (unambiguous when read aloud)
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// bit layout, MSB first: [32 ip][16 port][12 check] = 60 bits = 12 chars.
    ///
    /// The check bits come from an avalanche mix, not a digit sum: a sum only
    /// notices the low bits it happens to carry, so half of all one-character
    /// typos decoded cleanly into a different address. This flips every check
    /// bit with even odds for any change to the input at all.
    private static func check(_ ip: UInt32, _ port: UInt16) -> UInt64 {
        var h = (UInt64(ip) << 16) | UInt64(port)
        h ^= h >> 33
        h &*= 0xff51_afd7_ed55_8ccd
        h ^= h >> 29
        h &*= 0xc4ce_b9fe_1a85_ec53
        h ^= h >> 32
        return h & 0xFFF
    }

    /// "192.168.1.20", 25585 → "R2M0-2533-Y6MV" (nil if the host isn't IPv4)
    public static func encode(host: String, port: UInt16) -> String? {
        guard let ip = ipv4(host) else { return nil }
        let packed = (UInt64(ip) << 28) | (UInt64(port) << 12) | check(ip, port)
        var out = ""
        for i in 0..<12 {
            let shift = UInt64(55 - i * 5)
            out.append(alphabet[Int((packed >> shift) & 31)])
            if i == 3 || i == 7 { out.append("-") }
        }
        return out
    }

    /// the code back into something `socketDial` accepts. Tolerant on
    /// purpose: dashes, spaces and case are noise, and a code pasted with the
    /// "PEB" the chat app's autocorrect stuck on the front still decodes.
    public static func decode(_ raw: String) -> (host: String, port: UInt16)? {
        var cleaned = ""
        for ch in raw.uppercased() where ch.isLetter || ch.isNumber {
            switch ch {
            case "I", "L": cleaned.append("1")
            case "O": cleaned.append("0")
            case "U": return nil          // never emitted; a real typo
            default: cleaned.append(ch)
            }
        }
        if cleaned.count == 15, cleaned.hasPrefix("PEB") { cleaned.removeFirst(3) }
        guard cleaned.count == 12 else { return nil }

        var packed: UInt64 = 0
        for ch in cleaned {
            guard let v = alphabet.firstIndex(of: ch) else { return nil }
            packed = (packed << 5) | UInt64(v)
        }
        let ip = UInt32(truncatingIfNeeded: packed >> 28)
        let port = UInt16(truncatingIfNeeded: packed >> 12)
        guard packed & 0xFFF == check(ip, port) else { return nil }
        guard ip != 0, port != 0 else { return nil }
        let host = "\((ip >> 24) & 255).\((ip >> 16) & 255).\((ip >> 8) & 255).\(ip & 255)"
        return (host, port)
    }

    /// dotted quad → the 32 bits, or nil for names and IPv6 (both of which
    /// still work through the Servers tab — they just don't fit in a code)
    private static func ipv4(_ host: String) -> UInt32? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var ip: UInt32 = 0
        for p in parts {
            guard p.count <= 3, let b = UInt16(p), b <= 255 else { return nil }
            ip = (ip << 8) | UInt32(b)
        }
        return ip
    }
}
