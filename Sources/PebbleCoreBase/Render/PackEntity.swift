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
