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
