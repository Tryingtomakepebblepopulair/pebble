// Every mob part must actually be visible. A rig samples its skin at fixed
// UVs; if the procedural paint writes somewhere else, the part still renders
// — as nothing. Hoglins lost all four legs that way, ghasts every tentacle,
// vexes an arm, and nobody noticed until someone looked at a hoglin.
//
// This is invisible to every other suite: the geometry is correct, the
// animator poses it correctly, and the frame draws without error.

import Foundation
import PebbleCoreBase

/// the six rects EntitySkin.box writes, in its own order. A flat box (w or d
/// zero) collapses some of them, which is exactly where these bugs hide: the
/// visible faces of a w=0 quad sit at v + d, not at v.
private func unwrapRects(_ b: ModelBox) -> [(u: Int, v: Int, w: Int, h: Int)] {
    let u = Int(b.u), v = Int(b.v)
    let w = Int(b.w.rounded()), h = Int(b.h.rounded()), d = Int(b.d.rounded())
    return [
        (u + d, v, w, d),                 // top
        (u + d + w, v, w, d),             // bottom
        (u, v + d, d, h),                 // right
        (u + d, v + d, w, h),             // front
        (u + d + w, v + d, d, h),         // left
        (u + d + w + d, v + d, w, h),     // back
    ]
}

public func smokeSkinCoverageSuite() {
    section("mob skins (every part is visible)")
    ensureModels()

    var blank: [String] = []
    var offSheet: [String] = []
    var checked = 0

    for type in entityTypes().sorted() where hasModel(type) {
        let model = getModel(type)
        let skin = buildEntityGeometry(type).skin
        for (pi, part) in model.parts.enumerated() where pi < 24 {
            if part.boxes.isEmpty { continue }
            checked += 1
            var opaque = 0, inside = 0, outside = 0
            for box in part.boxes {
                for r in unwrapRects(box) where r.w > 0 && r.h > 0 {
                    for y in r.v..<(r.v + r.h) {
                        for x in r.u..<(r.u + r.w) {
                            if x < 0 || y < 0 || x >= skin.w || y >= skin.h {
                                outside += 1
                                continue
                            }
                            inside += 1
                            if skin.data[(y * skin.w + x) * 4 + 3] > 8 { opaque += 1 }
                        }
                    }
                }
            }
            if inside > 0 && opaque == 0 { blank.append("\(type).\(part.name)") }
            // a rig whose UVs fall off its own sheet samples the clamp edge
            if outside > inside { offSheet.append("\(type).\(part.name)") }
        }
    }

    check("every rig has parts to check", checked > 200, "\(checked) parts")
    check("no part renders fully transparent", blank.isEmpty,
          blank.isEmpty ? "" : "invisible: \(blank.joined(separator: ", "))")
    check("no part samples mostly off its sheet", offSheet.isEmpty,
          offSheet.isEmpty ? "" : "off-sheet: \(offSheet.joined(separator: ", "))")
}

/// What a resource pack has to install, beyond the terrain tiles. The Windows
/// client used to take only the tiles: no item icons, no UI sheet, and no
/// tint gate — so every pack-supplied tile still got the procedural biome
/// tint painted over art that was already coloured, and the whole world came
/// out a different shade from the Mac's.
public func smokePackInstallSuite() {
    section("resource pack (icons + tint gate)")
    let candidates = [
        ProcessInfo.processInfo.environment["PEBBLE_PACK_ZIP"],
        "packaging/Faithful 32x - 1.20.1.zip",
        "../packaging/Faithful 32x - 1.20.1.zip",
    ].compactMap { $0 }
    guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }),
          let zip = FileManager.default.contents(atPath: path),
          let pack = buildPackTerrainAtlas(zip: zip) else {
        check("pack zip found", false, "looked in: \(candidates.joined(separator: ", "))")
        return
    }
    check("pack zip found", true)
    check("terrain tiles resolved", pack.appliedTiles > 500,
          "\(pack.appliedTiles)/\(pack.slices.count)")

    // the icon sheet the inventory and the UI canvas draw from
    check("icon16 covers every tile", pack.icon16.count == pack.slices.count,
          "\(pack.icon16.count) vs \(pack.slices.count)")
    let wrongSize = pack.icon16.pixels.filter { $0.count != 16 * 16 * 4 }.count
    check("every icon is 16x16 RGBA", wrongSize == 0, "\(wrongSize) wrong")

    // the gate: pack art is already coloured, so only the handful of tiles
    // vanilla tints at render time may keep the biome tint
    check("tint gate covers every tile", pack.tintGate.count == pack.slices.count)
    let tinted = pack.tintGate.filter { $0 == 1 }.count
    check("most pack tiles are gated off", tinted < pack.tintGate.count / 4,
          "\(tinted) of \(pack.tintGate.count) still tinted")
    check("some tiles still take the biome tint", tinted > 0,
          "grass and foliage must stay tintable")

    // the interface art: menus, containers and the bitmap font
    guard let gui = pebPackUISheet(zip: zip) else {
        check("pack GUI sheet composes", false)
        return
    }
    check("pack GUI sheet composes", true)
    check("GUI sheet is the expected size",
          gui.width == PEB_PACK_UI_W && gui.height == PEB_PACK_UI_H,
          "\(gui.width)x\(gui.height)")
    check("every container sheet made it in", gui.sheets.count >= 19,
          "\(gui.sheets.count) sheets")
    check("the bitmap font came with it", gui.fontWidths?.count == 256)
    // a proportional font: 'i' must be narrower than 'A', or every menu
    // lays out at the wrong width
    if let w = gui.fontWidths {
        check("font advances are proportional", w[105] < w[65] && w[32] > 0,
              "i=\(w[105]) A=\(w[65]) space=\(w[32])")
    }
    let filled = stride(from: 3, to: gui.pixels.count, by: 4).lazy.filter { gui.pixels[$0] > 0 }.count
    check("GUI sheet is actually painted", filled > gui.width * gui.height / 10,
          "\(filled * 100 / (gui.width * gui.height))% non-empty")

    // the pack's own item art, keyed by item name
    let items = pebPackItemIcons(zip: zip)
    check("pack item icons load", items.count > 300, "\(items.count) icons")
    check("item icons are 16x16 RGBA",
          items.values.allSatisfy { $0.count == 16 * 16 * 4 })
    check("a known item resolves", items["diamond_sword"] != nil,
          items["diamond_sword"] == nil ? "no diamond_sword" : "")
}
