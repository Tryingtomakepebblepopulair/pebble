// UICanvas — the immediate-mode 2D quad batcher (PORTING module 08 split).
// This is the WHOLE canvas the screens/menus/HUD draw through: fillRect,
// gradients, transforms, globalAlpha, item icons, atlas-tile blits, and the
// 5×7 pixel font — producing the frozen 32-byte UI vertex stream
// (pos2f uv2f color4f) plus a CPU-side dynamic atlas with dirty-rect
// tracking. Backends (Metal on macOS, Vulkan on Windows) only upload the
// dirty pixels and draw the segments; behavior here must stay bit-identical
// to the pre-split UICanvas so every screen renders exactly the same.

import Foundation

public final class UICanvas {
    public static let ATLAS_SIZE = 1024

    /// the frame's vertex stream: pos2 uv2 color4 (32 bytes per vertex)
    public private(set) var verts: [Float] = []
    /// CPU dynamic atlas: white texel + icon/tile slots (16×16 grid cells)
    public private(set) var atlasPixels: [UInt8]
    private var atlasDirty: [(x: Int, y: Int, w: Int, h: Int)] = []
    private var slots: [String: (Int, Int)] = [:]   // key → cell origin
    private var nextSlot = 1                        // 0 reserved for white

    // canvas state
    public var fillStyle: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1)
    public var strokeStyle: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1)
    public var globalAlpha: Float = 1
    private var transform = UIAffine()
    private var stack: [UIAffine] = []

    public var width = 0.0
    public var height = 0.0

    public init() {
        atlasPixels = [UInt8](repeating: 0, count: UICanvas.ATLAS_SIZE * UICanvas.ATLAS_SIZE * 4)
        for y in 0..<16 {
            for x in 0..<16 {
                let i = (y * UICanvas.ATLAS_SIZE + x) * 4
                atlasPixels[i] = 255; atlasPixels[i + 1] = 255
                atlasPixels[i + 2] = 255; atlasPixels[i + 3] = 255
            }
        }
        atlasDirty.append((0, 0, 16, 16))
    }

    /// backends drain this each frame and upload the listed atlas regions
    public func takeAtlasDirty() -> [(x: Int, y: Int, w: Int, h: Int)] {
        let d = atlasDirty
        atlasDirty.removeAll()
        return d
    }

    // ---- color parsing ("#rrggbb", rgb(), rgba(), hsl(), hsla()) ----------------
    public static func parse(_ s: String) -> SIMD4<Float> {
        if s.hasPrefix("#") {
            let hex = String(s.dropFirst())
            if hex.count == 6, let v = Int(hex, radix: 16) {
                return SIMD4<Float>(Float((v >> 16) & 255) / 255, Float((v >> 8) & 255) / 255, Float(v & 255) / 255, 1)
            }
            if hex.count == 4, let v = Int(hex, radix: 16) {  // #rgba (e.g. '#0000' = transparent)
                return SIMD4<Float>(Float((v >> 12) & 15) / 15, Float((v >> 8) & 15) / 15, Float((v >> 4) & 15) / 15, Float(v & 15) / 15)
            }
            if hex.count == 3, let v = Int(hex, radix: 16) {
                return SIMD4<Float>(Float((v >> 8) & 15) / 15, Float((v >> 4) & 15) / 15, Float(v & 15) / 15, 1)
            }
            return SIMD4<Float>(1, 1, 1, 1)
        }
        func nums(_ s: String) -> [Double] {
            var out: [Double] = []
            var cur = ""
            for ch in s {
                if ch.isNumber || ch == "." || ch == "-" { cur.append(ch) }
                else if !cur.isEmpty { out.append(Double(cur) ?? 0); cur = "" }
            }
            if !cur.isEmpty { out.append(Double(cur) ?? 0) }
            return out
        }
        let n = nums(s)
        if s.hasPrefix("hsl") {
            let h = n.count > 0 ? n[0] : 0, sat = (n.count > 1 ? n[1] : 0) / 100, l = (n.count > 2 ? n[2] : 0) / 100
            let a = s.hasPrefix("hsla") && n.count > 3 ? n[3] : 1
            let c = (1 - abs(2 * l - 1)) * sat
            let hp = ((h.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360) / 60
            let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
            let (r1, g1, b1): (Double, Double, Double)
            switch Int(hp) {
            case 0: (r1, g1, b1) = (c, x, 0)
            case 1: (r1, g1, b1) = (x, c, 0)
            case 2: (r1, g1, b1) = (0, c, x)
            case 3: (r1, g1, b1) = (0, x, c)
            case 4: (r1, g1, b1) = (x, 0, c)
            default: (r1, g1, b1) = (c, 0, x)
            }
            let m = l - c / 2
            return SIMD4<Float>(Float(r1 + m), Float(g1 + m), Float(b1 + m), Float(a))
        }
        if s.hasPrefix("rgb") {
            let a = s.hasPrefix("rgba") && n.count > 3 ? n[3] : 1
            return SIMD4<Float>(Float((n.count > 0 ? n[0] : 0) / 255), Float((n.count > 1 ? n[1] : 0) / 255),
                                Float((n.count > 2 ? n[2] : 0) / 255), Float(a))
        }
        return SIMD4<Float>(1, 1, 1, 1)
    }

    public func setFill(_ s: String) { fillStyle = UICanvas.parse(s) }
    public func setStroke(_ s: String) { strokeStyle = UICanvas.parse(s) }

    // ---- transform stack --------------------------------------------------------
    public func save() { stack.append(transform) }
    public func restore() { if let t = stack.popLast() { transform = t } }
    public func resetTransform() {
        transform = UIAffine()
        stack.removeAll()
        globalAlpha = 1
    }
    public func translate(_ x: Double, _ y: Double) {
        transform = transform * UIAffine(tx: Float(x), ty: Float(y))
    }
    public func rotate(_ a: Double) {
        let c = Float(Foundation.cos(a)), s = Float(Foundation.sin(a))
        transform = transform * UIAffine(a: c, b: s, c: -s, d: c)
    }
    public func scale(_ x: Double, _ y: Double) {
        transform = transform * UIAffine(a: Float(x), d: Float(y))
    }

    @inline(__always) private func xf(_ x: Float, _ y: Float) -> SIMD2<Float> {
        transform.apply(x, y)
    }

    // ---- quad emission ------------------------------------------------------------
    // the vertex stream is segmented by texture: the slot atlas (default) and
    // the pack GUI sheet composite — backends switch textures per segment so
    // draw order (panel under items under text) is preserved
    /// true once the resource pack installed its GUI composite in the backend
    public var hasGuiSheet = false
    public private(set) var segments: [(gui: Bool, start: Int)] = []
    private var curGui = false

    @inline(__always) private func mark(_ gui: Bool) {
        if segments.isEmpty || curGui != gui {
            segments.append((gui, verts.count))
            curGui = gui
        }
    }

    /// blit from the pack GUI composite (atlas pixel coords, 2048×2560)
    public func guiQuad(_ ax: Double, _ ay: Double, _ aw: Double, _ ah: Double,
                        _ dx: Double, _ dy: Double, _ dw: Double, _ dh: Double,
                        _ tint: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1)) {
        guard hasGuiSheet else { return }
        mark(true)
        emitQuad(Float(dx), Float(dy), Float(dw), Float(dh),
                 Float(ax / 2048), Float(ay / 2560), Float((ax + aw) / 2048), Float((ay + ah) / 2560),
                 tint, tint)
    }

    private func quad(_ x: Float, _ y: Float, _ w: Float, _ h: Float,
                      _ u0: Float, _ v0: Float, _ u1: Float, _ v1: Float,
                      _ cTop: SIMD4<Float>, _ cBot: SIMD4<Float>) {
        mark(false)
        emitQuad(x, y, w, h, u0, v0, u1, v1, cTop, cBot)
    }

    private func emitQuad(_ x: Float, _ y: Float, _ w: Float, _ h: Float,
                          _ u0: Float, _ v0: Float, _ u1: Float, _ v1: Float,
                          _ cTop: SIMD4<Float>, _ cBot: SIMD4<Float>) {
        let p0 = xf(x, y), p1 = xf(x + w, y), p2 = xf(x + w, y + h), p3 = xf(x, y + h)
        var ct = cTop, cb = cBot
        ct.w *= globalAlpha
        cb.w *= globalAlpha
        // no intermediate arrays — this runs per glyph pixel in HUD text
        verts.reserveCapacity(verts.count + 48)
        func push(_ p: SIMD2<Float>, _ u: Float, _ v: Float, _ c: SIMD4<Float>) {
            verts.append(p.x); verts.append(p.y); verts.append(u); verts.append(v)
            verts.append(c.x); verts.append(c.y); verts.append(c.z); verts.append(c.w)
        }
        push(p0, u0, v0, ct); push(p1, u1, v0, ct); push(p2, u1, v1, cb)
        push(p0, u0, v0, ct); push(p2, u1, v1, cb); push(p3, u0, v1, cb)
    }

    private let whiteUV: (Float, Float, Float, Float) = (4.0 / 1024, 4.0 / 1024, 8.0 / 1024, 8.0 / 1024)

    public func fillRect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) {
        quad(Float(x), Float(y), Float(w), Float(h), whiteUV.0, whiteUV.1, whiteUV.2, whiteUV.3, fillStyle, fillStyle)
    }
    public func fillRect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, top: String, bottom: String) {
        quad(Float(x), Float(y), Float(w), Float(h), whiteUV.0, whiteUV.1, whiteUV.2, whiteUV.3,
             UICanvas.parse(top), UICanvas.parse(bottom))
    }
    public func strokeRect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ lw: Double = 1) {
        let c = fillStyle
        fillStyle = strokeStyle
        fillRect(x, y, w, lw)
        fillRect(x, y + h - lw, w, lw)
        fillRect(x, y, lw, h)
        fillRect(x + w - lw, y, lw, h)
        fillStyle = c
    }
    public func line(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ width: Double = 1) {
        // thin quad between points
        let dx = x1 - x0, dy = y1 - y0
        let len = (dx * dx + dy * dy).squareRoot()
        if len < 0.001 { return }
        let nx = -dy / len * width / 2, ny = dx / len * width / 2
        mark(false)
        let c = strokeStyle * SIMD4<Float>(1, 1, 1, globalAlpha)
        func push(_ px: Double, _ py: Double) {
            let p = xf(Float(px), Float(py))
            verts.append(contentsOf: [p.x, p.y, whiteUV.0, whiteUV.1, c.x, c.y, c.z, c.w])
        }
        push(x0 + nx, y0 + ny); push(x1 + nx, y1 + ny); push(x1 - nx, y1 - ny)
        push(x0 + nx, y0 + ny); push(x1 - nx, y1 - ny); push(x0 - nx, y0 - ny)
    }

    // ---- atlas slots (icons, tiles) -------------------------------------------------
    private var freeSlots: [(Int, Int)] = []

    /// resource-pack swap: drop every cached icon/tile cell, recycling the space
    public func resetIconSlots() {
        freeSlots.append(contentsOf: slots.values)
        slots.removeAll()
    }

    private func allocSlot(_ key: String, _ pixels: [UInt8]) -> (Int, Int) {
        if let s = slots[key] { return s }
        let cols = UICanvas.ATLAS_SIZE / 16
        let origin: (Int, Int)
        if let reused = freeSlots.popLast() {
            origin = reused
        } else {
            let cell = nextSlot
            nextSlot += 1
            origin = ((cell % cols) * 16, (cell / cols) * 16)
        }
        for row in 0..<16 {
            let src = row * 16 * 4
            let dst = ((origin.1 + row) * UICanvas.ATLAS_SIZE + origin.0) * 4
            for b in 0..<64 { atlasPixels[dst + b] = pixels[src + b] }
        }
        atlasDirty.append((origin.0, origin.1, 16, 16))
        slots[key] = origin
        return origin
    }

    /// draw an item icon (uses the shared icon cache)
    public func drawItemIcon(_ itemId: Int, _ data: StackData?, _ x: Double, _ y: Double, _ w: Double = 16, _ h: Double = 16) {
        let key = "i\(itemId)|\(data?.potion ?? "")"
        let origin = slots[key] ?? allocSlot(key, itemIconPixels(itemId, data))
        quad(Float(x), Float(y), Float(w), Float(h),
             Float(origin.0) / 1024, Float(origin.1) / 1024,
             Float(origin.0 + 16) / 1024, Float(origin.1 + 16) / 1024,
             SIMD4<Float>(1, 1, 1, 1), SIMD4<Float>(1, 1, 1, 1))
    }

    /// draw a terrain atlas tile (dirt background etc.), tinted
    public func drawTile(_ name: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double, brightness: Float = 1) {
        let key = "t" + name
        let origin: (Int, Int)
        if let s = slots[key] {
            origin = s
        } else {
            let id = tileId(name)
            let built = uiAtlasPixels(id)
            origin = allocSlot(key, built)
        }
        let c = SIMD4<Float>(brightness, brightness, brightness, 1)
        quad(Float(x), Float(y), Float(w), Float(h),
             Float(origin.0) / 1024, Float(origin.1) / 1024,
             Float(origin.0 + 16) / 1024, Float(origin.1 + 16) / 1024, c, c)
    }

    // ---- pixel font ----------------------------------------------
    @discardableResult
    public func drawText(_ text: String, _ x: Double, _ y: Double, _ s: Double, _ color: String = "#FFFFFF", shadow: Bool = true) -> Double {
        var curColor = UICanvas.parse(color)
        var curShadow = shadowOf(curColor)
        var cx = x
        let startX = x
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if ch == "§" {
                let next = text.index(after: i)
                if next < text.endIndex {
                    let code = String(text[next]).lowercased()
                    if let mc = MC_COLORS[code] {
                        curColor = UICanvas.parse(mc)
                        curShadow = shadowOf(curColor)
                    } else if code == "r" {
                        curColor = UICanvas.parse(color)
                        curShadow = shadowOf(curColor)
                    }
                    i = text.index(after: next)
                    continue
                }
            }
            // pack bitmap font: ASCII via the composite ascii.png cell (8×8 glyphs at 2×)
            if let pf = hasGuiSheet ? packFontWidths : nil,
               ch.unicodeScalars.count == 1, let code = ch.unicodeScalars.first?.value,
               code >= 32, code < 127 {
                let c = Int(code)
                if c != 32 {
                    let ax = 1024.0 + Double(c % 16) * 16, ay = Double(c / 16) * 16
                    if shadow {
                        guiQuad(ax, ay, 16, 16, cx + s, y + s, 8 * s, 8 * s, curShadow)
                    }
                    guiQuad(ax, ay, 16, 16, cx, y, 8 * s, 8 * s, curColor)
                }
                cx += pf[c] * s
                i = text.index(after: i)
                continue
            }
            let g = GLYPHS[ch] ?? GLYPHS["?"]!
            for (col, bits) in g.enumerated() {
                for row in 0..<8 where bits & (1 << row) != 0 {
                    if shadow {
                        let save = fillStyle
                        fillStyle = curShadow
                        fillRect(cx + Double(col + 1) * s, y + Double(row + 1) * s, s, s)
                        fillStyle = save
                    }
                    let save = fillStyle
                    fillStyle = curColor
                    fillRect(cx + Double(col) * s, y + Double(row) * s, s, s)
                    fillStyle = save
                }
            }
            cx += Double(g.count + 1) * s
            i = text.index(after: i)
        }
        return cx - startX
    }
    public func drawTextCentered(_ text: String, _ cx: Double, _ y: Double, _ s: Double, _ color: String = "#FFFFFF", shadow: Bool = true) {
        drawText(text, cx - Double(textWidth(text)) * s / 2, y, s, color, shadow: shadow)
    }
    private func shadowOf(_ c: SIMD4<Float>) -> SIMD4<Float> {
        SIMD4<Float>(c.x / 4, c.y / 4, c.z / 4, c.w)
    }

    // ---- frame -----------------------------------------------------------------------
    public func begin(_ w: Double, _ h: Double) {
        width = w
        height = h
        verts.removeAll(keepingCapacity: true)
        segments.removeAll(keepingCapacity: true)
        curGui = false
        resetTransform()
    }
}

/// column-major 2D affine transform (the simd float3x3 the canvas used,
/// minus Apple simd): col0 (a,b), col1 (c,d), col2 (tx,ty)
public struct UIAffine {
    var a: Float = 1, b: Float = 0
    var c: Float = 0, d: Float = 1
    var tx: Float = 0, ty: Float = 0

    static func * (l: UIAffine, r: UIAffine) -> UIAffine {
        UIAffine(a: l.a * r.a + l.c * r.b, b: l.b * r.a + l.d * r.b,
                 c: l.a * r.c + l.c * r.d, d: l.b * r.c + l.d * r.d,
                 tx: l.a * r.tx + l.c * r.ty + l.tx, ty: l.b * r.tx + l.d * r.ty + l.ty)
    }
    @inline(__always) func apply(_ x: Float, _ y: Float) -> SIMD2<Float> {
        SIMD2<Float>(a * x + c * y + tx, b * x + d * y + ty)
    }
}

/// 16×16 RGBA pixels of a terrain atlas tile, for UI blits (dirt bg etc.)
private var uiAtlasCache: BuiltAtlas?
public func setUIAtlas(_ atlas: BuiltAtlas) { uiAtlasCache = atlas }
public func uiAtlasPixels(_ tile: Int) -> [UInt8] {
    if uiAtlasCache == nil { uiAtlasCache = buildAtlas() }
    let atlas = uiAtlasCache!
    guard tile >= 0, tile < atlas.pixels.count else { return [UInt8](repeating: 255, count: 16 * 16 * 4) }
    // tiles are TILE×TILE; downsample to 16×16 by stride
    let src = atlas.pixels[tile]
    if TILE == 16 { return src }
    var out = [UInt8](repeating: 0, count: 16 * 16 * 4)
    let step = TILE / 16
    for y in 0..<16 {
        for x in 0..<16 {
            let si = ((y * step) * TILE + x * step) * 4
            let di = (y * 16 + x) * 4
            out[di] = src[si]; out[di + 1] = src[si + 1]; out[di + 2] = src[si + 2]; out[di + 3] = src[si + 3]
        }
    }
    return out
}

// ---------------------------------------------------------------------------
// 5×7 bitmap glyphs + MC color codes
// ---------------------------------------------------------------------------
public let MC_COLORS: [String: String] = [
    "0": "#000000", "1": "#0000AA", "2": "#00AA00", "3": "#00AAAA",
    "4": "#AA0000", "5": "#AA00AA", "6": "#FFAA00", "7": "#AAAAAA",
    "8": "#555555", "9": "#5555FF", "a": "#55FF55", "b": "#55FFFF",
    "c": "#FF5555", "d": "#FF55FF", "e": "#FFFF55", "f": "#FFFFFF",
]

public let GLYPHS: [Character: [Int]] = [
    " ": [0, 0, 0], "!": [0x5f], "\"": [0x03, 0x00, 0x03], "#": [0x14, 0x7f, 0x14, 0x7f, 0x14],
    "$": [0x24, 0x2a, 0x7f, 0x2a, 0x12], "%": [0x23, 0x13, 0x08, 0x64, 0x62],
    "&": [0x36, 0x49, 0x55, 0x22, 0x50], "'": [0x03], "(": [0x1c, 0x22, 0x41], ")": [0x41, 0x22, 0x1c],
    "*": [0x14, 0x08, 0x3e, 0x08, 0x14], "+": [0x08, 0x08, 0x3e, 0x08, 0x08], ",": [0x50, 0x30],
    "-": [0x08, 0x08, 0x08, 0x08], ".": [0x60, 0x60], "/": [0x20, 0x10, 0x08, 0x04, 0x02],
    "0": [0x3e, 0x51, 0x49, 0x45, 0x3e], "1": [0x44, 0x42, 0x7f, 0x40, 0x40],
    "2": [0x42, 0x61, 0x51, 0x49, 0x46], "3": [0x21, 0x41, 0x45, 0x4b, 0x31],
    "4": [0x18, 0x14, 0x12, 0x7f, 0x10], "5": [0x27, 0x45, 0x45, 0x45, 0x39],
    "6": [0x3c, 0x4a, 0x49, 0x49, 0x30], "7": [0x01, 0x71, 0x09, 0x05, 0x03],
    "8": [0x36, 0x49, 0x49, 0x49, 0x36], "9": [0x06, 0x49, 0x49, 0x29, 0x1e],
    ":": [0x36, 0x36], ";": [0x56, 0x36], "<": [0x08, 0x14, 0x22, 0x41], "=": [0x14, 0x14, 0x14, 0x14],
    ">": [0x41, 0x22, 0x14, 0x08], "?": [0x02, 0x01, 0x51, 0x09, 0x06], "@": [0x32, 0x49, 0x79, 0x41, 0x3e],
    "A": [0x7e, 0x09, 0x09, 0x09, 0x7e], "B": [0x7f, 0x49, 0x49, 0x49, 0x36],
    "C": [0x3e, 0x41, 0x41, 0x41, 0x22], "D": [0x7f, 0x41, 0x41, 0x22, 0x1c],
    "E": [0x7f, 0x49, 0x49, 0x49, 0x41], "F": [0x7f, 0x09, 0x09, 0x09, 0x01],
    "G": [0x3e, 0x41, 0x49, 0x49, 0x7a], "H": [0x7f, 0x08, 0x08, 0x08, 0x7f], "I": [0x41, 0x7f, 0x41],
    "J": [0x20, 0x40, 0x41, 0x3f, 0x01], "K": [0x7f, 0x08, 0x14, 0x22, 0x41],
    "L": [0x7f, 0x40, 0x40, 0x40, 0x40], "M": [0x7f, 0x02, 0x0c, 0x02, 0x7f],
    "N": [0x7f, 0x04, 0x08, 0x10, 0x7f], "O": [0x3e, 0x41, 0x41, 0x41, 0x3e],
    "P": [0x7f, 0x09, 0x09, 0x09, 0x06], "Q": [0x3e, 0x41, 0x51, 0x21, 0x5e],
    "R": [0x7f, 0x09, 0x19, 0x29, 0x46], "S": [0x46, 0x49, 0x49, 0x49, 0x31],
    "T": [0x01, 0x01, 0x7f, 0x01, 0x01], "U": [0x3f, 0x40, 0x40, 0x40, 0x3f],
    "V": [0x1f, 0x20, 0x40, 0x20, 0x1f], "W": [0x3f, 0x40, 0x38, 0x40, 0x3f],
    "X": [0x63, 0x14, 0x08, 0x14, 0x63], "Y": [0x07, 0x08, 0x70, 0x08, 0x07],
    "Z": [0x61, 0x51, 0x49, 0x45, 0x43], "[": [0x7f, 0x41, 0x41],
    "\\": [0x02, 0x04, 0x08, 0x10, 0x20], "]": [0x41, 0x41, 0x7f], "^": [0x04, 0x02, 0x01, 0x02, 0x04],
    "_": [0x40, 0x40, 0x40, 0x40, 0x40], "`": [0x01, 0x02],
    "a": [0x20, 0x54, 0x54, 0x54, 0x78], "b": [0x7f, 0x48, 0x44, 0x44, 0x38],
    "c": [0x38, 0x44, 0x44, 0x44, 0x28], "d": [0x38, 0x44, 0x44, 0x48, 0x7f],
    "e": [0x38, 0x54, 0x54, 0x54, 0x18], "f": [0x08, 0x7e, 0x09, 0x01, 0x02],
    "g": [0x18, 0xa4, 0xa4, 0xa4, 0x7c], "h": [0x7f, 0x08, 0x04, 0x04, 0x78], "i": [0x44, 0x7d, 0x40],
    "j": [0x20, 0x40, 0x44, 0x3d], "k": [0x7f, 0x10, 0x28, 0x44], "l": [0x41, 0x7f, 0x40],
    "m": [0x7c, 0x04, 0x18, 0x04, 0x78], "n": [0x7c, 0x08, 0x04, 0x04, 0x78],
    "o": [0x38, 0x44, 0x44, 0x44, 0x38], "p": [0xfc, 0x24, 0x24, 0x24, 0x18],
    "q": [0x18, 0x24, 0x24, 0x28, 0xfc], "r": [0x7c, 0x08, 0x04, 0x04, 0x08],
    "s": [0x48, 0x54, 0x54, 0x54, 0x24], "t": [0x04, 0x3f, 0x44, 0x40, 0x20],
    "u": [0x3c, 0x40, 0x40, 0x20, 0x7c], "v": [0x1c, 0x20, 0x40, 0x20, 0x1c],
    "w": [0x3c, 0x40, 0x30, 0x40, 0x3c], "x": [0x44, 0x28, 0x10, 0x28, 0x44],
    "y": [0x1c, 0xa0, 0xa0, 0xa0, 0x7c], "z": [0x44, 0x64, 0x54, 0x4c, 0x44],
    "{": [0x08, 0x36, 0x41], "|": [0x7f], "}": [0x41, 0x36, 0x08], "~": [0x08, 0x04, 0x08, 0x10, 0x08],
    "♥": [0x06, 0x0f, 0x1e, 0x0f, 0x06], "•": [0x18, 0x18], "★": [0x24, 0x18, 0x7e, 0x18, 0x24],
    "✔": [0x10, 0x20, 0x10, 0x08, 0x04], "▶": [0x7f, 0x3e, 0x1c, 0x08], "◀": [0x08, 0x1c, 0x3e, 0x7f],
]

/// per-character advances from the active resource pack's ascii.png (base px);
/// set alongside the backend's GUI sheet so drawing and measurement stay in sync
public var packFontWidths: [Double]?

public func glyphWidth(_ ch: Character) -> Int {
    (GLYPHS[ch] ?? GLYPHS["?"]!).count + 1
}
public func textWidth(_ text: String) -> Int {
    var w = 0.0
    var skip = false
    for ch in text {
        if skip { skip = false; continue }
        if ch == "§" { skip = true; continue }
        if let pf = packFontWidths, ch.unicodeScalars.count == 1,
           let code = ch.unicodeScalars.first?.value, code >= 32, code < 127 {
            w += pf[Int(code)]
        } else {
            w += Double(glyphWidth(ch))
        }
    }
    return Int(w.rounded())
}
public func wrapText(_ text: String, _ maxWidth: Int) -> [String] {
    let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
    var lines: [String] = []
    var cur = ""
    for w in words {
        let tryLine = cur.isEmpty ? w : cur + " " + w
        if textWidth(tryLine) > maxWidth && !cur.isEmpty {
            lines.append(cur)
            cur = w
        } else {
            cur = tryLine
        }
    }
    if !cur.isEmpty { lines.append(cur) }
    return lines
}
