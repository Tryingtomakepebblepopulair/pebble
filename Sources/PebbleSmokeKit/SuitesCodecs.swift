// Portable codec suite (PORTING module 11): PNG round-trips, dimension and
// archive caps, corrupt-input rejection. Texture bytes must be identical on
// every platform, so these run in the cross-platform lane too.

import Foundation
import PebbleCoreBase

public func smokeCodecSuite() {
    section("portable codecs (PNG via lodepng, ZIP via miniz)")

    // deterministic 64×64 test card: gradients + full alpha range
    var px = [UInt8](repeating: 0, count: 64 * 64 * 4)
    for y in 0..<64 {
        for x in 0..<64 {
            let i = (y * 64 + x) * 4
            px[i] = UInt8(x * 4)
            px[i + 1] = UInt8(y * 4)
            px[i + 2] = UInt8((x ^ y) * 4 & 255)
            px[i + 3] = UInt8(255 - ((x + y) & 255))
        }
    }

    guard let png = pebEncodePNG(px, width: 64, height: 64) else {
        check("PNG encode", false)
        return
    }
    check("PNG encode produces a signed PNG", png.count > 8 && Array(png.prefix(4)) == [0x89, 0x50, 0x4E, 0x47])

    let back = pebDecodePNG(png)
    check("PNG round-trip bit-identical (RGBA8 straight)",
          back?.width == 64 && back?.height == 64 && back?.pixels == px)

    check("PNG dimension cap rejects before allocating", pebDecodePNG(png, maxDim: 32) == nil)
    check("corrupt PNG rejected", pebDecodePNG(png.prefix(40) + Data([7, 7, 7])) == nil)
    check("garbage rejected", pebDecodePNG(Data("not a png at all".utf8)) == nil)
    check("encode rejects wrong buffer size", pebEncodePNG([1, 2, 3], width: 64, height: 64) == nil)

    // zip round-trip
    let entries: [(name: String, data: Data)] = [
        ("pack.mcmeta", Data("{\"pack\":{}}".utf8)),
        ("assets/minecraft/textures/block/stone.png", png),
        ("assets/notes.txt", Data(repeating: 0xAB, count: 100_000)),
    ]
    guard let zip = pebZipCreate(entries) else {
        check("zip create", false)
        return
    }
    check("zip lists all entries, /-normalized",
          pebZipList(zip)?.sorted() == entries.map { $0.name }.sorted())
    check("zip extract bit-identical",
          pebZipExtract(zip, name: "assets/minecraft/textures/block/stone.png") == png
          && pebZipExtract(zip, name: "assets/notes.txt") == entries[2].data)
    check("zip missing entry is nil", pebZipExtract(zip, name: "nope.txt") == nil)
    check("corrupt zip rejected", pebZipList(Data(zip.dropFirst(4))) == nil)

    var caps = PebZipCaps()
    caps.maxFileSize = 1000
    check("zip per-file cap fails closed", pebZipList(zip, caps: caps) == nil
          && pebZipExtract(zip, name: "assets/notes.txt", caps: caps) == nil)

    // path traversal names must poison the whole archive
    if let evil = pebZipCreate([("../../etc/evil", Data([1])), ("ok.txt", Data([2]))]) {
        check("zip traversal rejected", pebZipList(evil) == nil)
    } else {
        // writer refused the name — equally safe
        check("zip traversal rejected", true)
    }
}
