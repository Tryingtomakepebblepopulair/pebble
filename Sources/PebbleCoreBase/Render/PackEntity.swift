// Loading a mob's texture out of a resource pack. The Metal client has done
// this since packs existed; without it the Vulkan client fell back to the
// procedural skins, so the same creeper looked different on the two
// platforms. Same loader now, same creeper.

import Foundation

/// composite pack layers into one sheet the way vanilla entity art expects:
/// `stack` appends them vertically (sheep + its fur), otherwise each overlay
/// is alpha-blended onto the base (a villager's profession over its body).
public func pebCompositeEntityLayers(_ layers: [RGBAImage], stack: Bool) -> RGBAImage? {
    guard var base = layers.first else { return nil }
    if stack {
        for next in layers.dropFirst() {
            guard next.width == base.width else { return nil }
            base = RGBAImage(width: base.width, height: base.height + next.height,
                             pixels: base.pixels + next.pixels)
        }
        return base
    }
    for over in layers.dropFirst() {
        guard over.width == base.width, over.height == base.height else { continue }
        for i in stride(from: 0, to: base.pixels.count, by: 4) {
            let a = Int(over.pixels[i + 3])
            if a == 0 { continue }
            for c in 0..<3 {
                let o = Int(over.pixels[i + c]), b = Int(base.pixels[i + c])
                base.pixels[i + c] = UInt8((o * a + b * (255 - a)) / 255)
            }
            base.pixels[i + 3] = 255
        }
    }
    return base
}

/// a mob's sheet from one resource pack zip, tints baked and layers merged.
/// nil means the pack does not carry it — the caller keeps its procedural skin.
public func pebPackEntityImage(zip: Data, rels: [String], stack: Bool = false,
                               tints: [Int] = []) -> RGBAImage? {
    guard !rels.isEmpty else { return nil }
    var layers: [RGBAImage] = []
    for (i, rel) in rels.enumerated() {
        guard let img = packTexture(zip: zip, rel: rel) else {
            // the first layer is the mob itself; without it there is nothing
            if i == 0 { return nil }
            continue
        }
        var px = img.pixels
        // vanilla ships some art greyscale for render-time tinting
        if i < tints.count && tints[i] != 0xFFFFFF { bakeTint(&px, tints[i]) }
        layers.append(RGBAImage(width: img.width, height: img.height, pixels: px))
    }
    return pebCompositeEntityLayers(layers, stack: stack)
}

/// every textures/item/*.png in a pack, at 16px, keyed by its base name —
/// what the inventory and hotbar draw instead of the procedural icons. The
/// Metal client has always installed these; without them the same diamond
/// sword was hand-drawn on one platform and the pack's art on the other.
public func pebPackItemIcons(zip: Data) -> [String: [UInt8]] {
    guard let prefix = packTexPrefix(zip), let names = pebZipList(zip) else { return [:] }
    let root = prefix + "item/"
    var icons: [String: [UInt8]] = [:]
    for path in names where path.hasPrefix(root) && path.hasSuffix(".png") {
        guard let file = path.components(separatedBy: "/").last else { continue }
        let base = String(file.dropLast(4))
        guard let d = pebZipExtract(zip, name: path), let decoded = pebDecodePNG(d) else { continue }
        var img = RGBAImage(width: decoded.width, height: decoded.height, pixels: decoded.pixels)
        // animated items ship as a vertical strip; the first frame is the icon
        if img.height > img.width, img.width > 0, img.height % img.width == 0 {
            img = stripFrame(img, 0)
        }
        guard img.width == img.height else { continue }
        icons[base] = scaleBox(img, to: 16)
    }
    return icons
}
