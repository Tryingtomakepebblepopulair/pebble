// The pack's interface art: every GUI sheet blitted into one composite
// texture, plus the bitmap font's per-glyph advances. The canvas emits its
// vertex stream in segments — some sampling the icon atlas, some this sheet —
// and a backend switches texture per segment.
//
// Extracted from the Metal PackUI so the Vulkan client gets the same
// interface instead of falling back to the procedural one.

import Foundation

public struct PebPackUI {
    public let pixels: [UInt8]
    public let width: Int
    public let height: Int
    public let sheets: Set<String>
    /// per-character advance in base px (8px grid) from font/ascii; nil = the
    /// pack ships no font and the built-in metrics stay
    public let fontWidths: [Double]?
}

public let PEB_PACK_UI_W = 2048
public let PEB_PACK_UI_H = 2560

/// which sheet goes in which cell, and the base size its content scales to
private let PEB_PACK_UI_SOURCES: [(key: String, rel: String, base: Int)] = [
    ("icons", "gui/icons", 256), ("widgets", "gui/widgets", 256),
    ("bg", "gui/options_background", 16),
    ("inventory", "gui/container/inventory", 256),
    ("generic_54", "gui/container/generic_54", 256),
    ("crafting_table", "gui/container/crafting_table", 256),
    ("furnace", "gui/container/furnace", 256),
    ("brewing_stand", "gui/container/brewing_stand", 256),
    ("enchanting_table", "gui/container/enchanting_table", 256),
    ("anvil", "gui/container/anvil", 256),
    ("hopper", "gui/container/hopper", 256),
    ("dispenser", "gui/container/dispenser", 256),
    ("shulker_box", "gui/container/shulker_box", 256),
    ("grindstone", "gui/container/grindstone", 256),
    ("stonecutter", "gui/container/stonecutter", 256),
    ("smithing", "gui/container/smithing", 256),
    ("cartography_table", "gui/container/cartography_table", 256),
    ("beacon", "gui/container/beacon", 256),
    ("horse", "gui/container/horse", 256),
]

/// compose the sheet. `load` resolves a relative path (no .png) to an image,
/// so the caller decides whether that means one zip or a stack of packs.
public func pebComposePackUI(_ load: (String) -> RGBAImage?) -> PebPackUI? {
    let W = PEB_PACK_UI_W, H = PEB_PACK_UI_H
    var pixels = [UInt8](repeating: 0, count: W * H * 4)
    var sheets: Set<String> = []
    var fontWidths: [Double]? = nil

    func blit(_ img: RGBAImage, _ cellX: Int, _ cellY: Int, baseSize: Int) {
        // rescale so content occupies baseSize*2 px in the cell
        let target = baseSize * 2
        let scaled = img.width == target ? img.pixels : scaleTo(img, target)
        for y in 0..<min(target, 512) {
            let dst = ((cellY + y) * W + cellX) * 4
            let src = y * target * 4
            pixels.replaceSubrange(dst..<(dst + min(target, 512) * 4),
                                   with: scaled[src..<(src + min(target, 512) * 4)])
        }
    }

    for (key, rel, base) in PEB_PACK_UI_SOURCES {
        guard let img = load(rel), let cell = PACK_UI_CELLS[key] else { continue }
        blit(img, cell.0, cell.1, baseSize: base)
        sheets.insert(key)
    }

    // bitmap font: 16x16 grid of 8x8 glyphs; advance = trailing edge + 1
    if let ascii = load("font/ascii"), let cell = PACK_UI_CELLS["ascii"] {
        blit(ascii, cell.0, cell.1, baseSize: 128)
        sheets.insert("ascii")
        let g = ascii.width / 16    // native glyph cell size
        var widths = [Double](repeating: 6, count: 256)
        for c in 0..<256 {
            let gx = (c % 16) * g, gy = (c / 16) * g
            var maxX = -1
            for y in 0..<g {
                for x in 0..<g {
                    if ascii.pixels[((gy + y) * ascii.width + gx + x) * 4 + 3] > 32 {
                        if x > maxX { maxX = x }
                    }
                }
            }
            let base = 8.0 / Double(g)
            widths[c] = maxX < 0 ? 4 : (Double(maxX + 1) * base + 1)
        }
        widths[32] = 4   // space
        fontWidths = widths
    }

    guard !sheets.isEmpty else { return nil }
    return PebPackUI(pixels: pixels, width: W, height: H, sheets: sheets, fontWidths: fontWidths)
}

/// the single-zip form the Windows client uses
public func pebPackUISheet(zip: Data) -> PebPackUI? {
    pebComposePackUI { rel in
        guard let img = packTexture(zip: zip, rel: rel + ".png") else { return nil }
        return RGBAImage(width: img.width, height: img.height, pixels: img.pixels)
    }
}
