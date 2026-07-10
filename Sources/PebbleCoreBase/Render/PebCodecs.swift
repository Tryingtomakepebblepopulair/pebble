// Portable PNG + ZIP codecs (PORTING module 11) — thin Swift wrappers over
// vendored lodepng/miniz with hard caps so a hostile resource pack can't
// balloon memory. Straight (non-premultiplied) RGBA8, no color-space
// conversion: texture bytes must be identical on every platform.

import Foundation
import CCodecs

/// decoded image — straight RGBA8, row-major, no padding
public struct PebImage {
    public let pixels: [UInt8]
    public let width: Int
    public let height: Int
    public init(pixels: [UInt8], width: Int, height: Int) {
        self.pixels = pixels
        self.width = width
        self.height = height
    }
}

/// widest texture Pebble will ever accept (a 16K×16K RGBA = 1GB — beyond
/// any legitimate pack asset)
public let PEB_IMAGE_MAX_DIM = 16384

/// decode a PNG to straight RGBA8. `maxDim` caps width/height BEFORE the
/// pixel buffer is allocated; nil on corrupt data or over-cap dimensions.
public func pebDecodePNG(_ data: Data, maxDim: Int = PEB_IMAGE_MAX_DIM) -> PebImage? {
    if data.isEmpty { return nil }
    var w: UInt32 = 0
    var h: UInt32 = 0

    // peek the header first — reject absurd dimensions before allocating
    var state = LodePNGState()
    lodepng_state_init(&state)
    defer { lodepng_state_cleanup(&state) }
    let headerOK = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
        lodepng_inspect(&w, &h, &state, raw.bindMemory(to: UInt8.self).baseAddress, data.count) == 0
    }
    guard headerOK, w > 0, h > 0, Int(w) <= maxDim, Int(h) <= maxDim else { return nil }

    var out: UnsafeMutablePointer<UInt8>?
    let err = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> UInt32 in
        lodepng_decode32(&out, &w, &h, raw.bindMemory(to: UInt8.self).baseAddress, data.count)
    }
    guard err == 0, let buf = out else {
        if let buf = out { free(buf) }
        return nil
    }
    defer { free(buf) }
    let count = Int(w) * Int(h) * 4
    return PebImage(pixels: Array(UnsafeBufferPointer(start: buf, count: count)),
                    width: Int(w), height: Int(h))
}

/// encode straight RGBA8 to a PNG; nil when the buffer doesn't match w×h×4
public func pebEncodePNG(_ pixels: [UInt8], width: Int, height: Int) -> Data? {
    guard width > 0, height > 0, width <= PEB_IMAGE_MAX_DIM, height <= PEB_IMAGE_MAX_DIM,
          pixels.count == width * height * 4 else { return nil }
    var out: UnsafeMutablePointer<UInt8>?
    var outSize = 0
    let err = pixels.withUnsafeBufferPointer {
        lodepng_encode32(&out, &outSize, $0.baseAddress, UInt32(width), UInt32(height))
    }
    guard err == 0, let buf = out else {
        if let buf = out { free(buf) }
        return nil
    }
    defer { free(buf) }
    return Data(bytes: buf, count: outSize)
}

// ---- ZIP reading (resource packs) -------------------------------------------

/// caps for hostile archives: entry count, per-file size, and total
/// uncompressed size are all checked BEFORE extraction
public struct PebZipCaps {
    public var maxEntries = 10_000
    public var maxFileSize = 64 << 20        // 64MB per entry
    public var maxTotalSize = 256 << 20      // 256MB whole archive
    public init() {}
}

/// entry names normalized to forward slashes; traversal ("..", absolute
/// paths) and over-cap archives yield nil — fail closed, never partially
public func pebZipList(_ data: Data, caps: PebZipCaps = PebZipCaps()) -> [String]? {
    var zip = mz_zip_archive()
    let ok = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
        mz_zip_reader_init_mem(&zip, raw.baseAddress, data.count, 0) != 0
    }
    guard ok else { return nil }
    defer { mz_zip_reader_end(&zip) }

    let n = Int(mz_zip_reader_get_num_files(&zip))
    guard n <= caps.maxEntries else { return nil }
    var names: [String] = []
    var total = 0
    for i in 0..<n {
        var stat = mz_zip_archive_file_stat()
        guard mz_zip_reader_file_stat(&zip, mz_uint(i), &stat) != 0 else { return nil }
        let name = withUnsafeBytes(of: &stat.m_filename) { raw -> String in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }.replacingOccurrences(of: "\\", with: "/")
        guard !name.hasPrefix("/"), !name.split(separator: "/").contains("..") else { return nil }
        let size = Int(stat.m_uncomp_size)
        guard size <= caps.maxFileSize else { return nil }
        total += size
        guard total <= caps.maxTotalSize else { return nil }
        if stat.m_is_directory == 0 { names.append(name) }
    }
    return names
}

/// extract one entry by (normalized) name; nil when missing, corrupt, or
/// bigger than the caps allow
public func pebZipExtract(_ data: Data, name: String, caps: PebZipCaps = PebZipCaps()) -> Data? {
    var zip = mz_zip_archive()
    let ok = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
        mz_zip_reader_init_mem(&zip, raw.baseAddress, data.count, 0) != 0
    }
    guard ok else { return nil }
    defer { mz_zip_reader_end(&zip) }

    let idx = mz_zip_reader_locate_file(&zip, name, nil, 0)
    guard idx >= 0 else { return nil }
    var stat = mz_zip_archive_file_stat()
    guard mz_zip_reader_file_stat(&zip, mz_uint(idx), &stat) != 0,
          Int(stat.m_uncomp_size) <= caps.maxFileSize else { return nil }

    var size = 0
    guard let buf = mz_zip_reader_extract_to_heap(&zip, mz_uint(idx), &size, 0) else { return nil }
    defer { mz_free(buf) }
    guard size == Int(stat.m_uncomp_size) else { return nil }
    return Data(bytes: buf, count: size)
}

/// build a zip in memory (skin/pack exports + the codec smoke suite)
public func pebZipCreate(_ entries: [(name: String, data: Data)]) -> Data? {
    var zip = mz_zip_archive()
    guard mz_zip_writer_init_heap(&zip, 0, 0) != 0 else { return nil }
    var finished = false
    defer { if !finished { mz_zip_writer_end(&zip) } }
    for (name, data) in entries {
        let ok = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            mz_zip_writer_add_mem(&zip, name, raw.baseAddress, data.count,
                                  mz_uint(6 /* MZ_DEFAULT_LEVEL */)) != 0
        }
        guard ok else { return nil }
    }
    var out: UnsafeMutableRawPointer?
    var outSize = 0
    guard mz_zip_writer_finalize_heap_archive(&zip, &out, &outSize) != 0, let buf = out else { return nil }
    mz_zip_writer_end(&zip)
    finished = true
    defer { mz_free(buf) }
    return Data(bytes: buf, count: outSize)
}
