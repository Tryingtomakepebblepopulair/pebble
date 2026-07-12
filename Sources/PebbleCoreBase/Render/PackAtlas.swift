// Portable resource-pack terrain atlas (PORTING module 11): the tile-name
// mapping tables, pixel scale/tint helpers, and the atlas composition —
// extracted from the Mac's ResourcePacks.swift so Windows builds the SAME
// Faithful terrain atlas through the portable zip/PNG codecs. Animations,
// item icons, and entity-texture crops stay Mac-side for now (v1 uses the
// first animation frame and procedural fallbacks for those tiles).

import Foundation

public struct RGBAImage {
    public var width: Int
    public var height: Int
    public var pixels: [UInt8]   // straight RGBA, width*height*4
    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}


public func scaleNearest(_ img: RGBAImage, to res: Int) -> [UInt8] {
    if img.width == res && img.height == res { return img.pixels }
    var out = [UInt8](repeating: 0, count: res * res * 4)
    for y in 0..<res {
        let sy = y * img.height / res
        for x in 0..<res {
            let sx = x * img.width / res
            let s = (sy * img.width + sx) * 4, d = (y * res + x) * 4
            out[d] = img.pixels[s]; out[d + 1] = img.pixels[s + 1]
            out[d + 2] = img.pixels[s + 2]; out[d + 3] = img.pixels[s + 3]
        }
    }
    return out
}

/// alpha-weighted box filter (downscale)
public func scaleBox(_ img: RGBAImage, to res: Int) -> [UInt8] {
    if img.width == res && img.height == res { return img.pixels }
    // either axis smaller than the target → box dims would hit zero (div-by-zero
    // on a wide-but-short pack texture); nearest handles upscale fine
    if img.width < res || img.height < res { return scaleNearest(img, to: res) }
    var out = [UInt8](repeating: 0, count: res * res * 4)
    let bx = img.width / res, by = img.height / res
    for y in 0..<res {
        for x in 0..<res {
            var r = 0, g = 0, b = 0, a = 0, n = 0
            for dy in 0..<by {
                for dx in 0..<bx {
                    let s = ((y * by + dy) * img.width + (x * bx + dx)) * 4
                    let pa = Int(img.pixels[s + 3])
                    r += Int(img.pixels[s]) * pa
                    g += Int(img.pixels[s + 1]) * pa
                    b += Int(img.pixels[s + 2]) * pa
                    a += pa
                    n += 1
                }
            }
            let d = (y * res + x) * 4
            if a > 0 {
                out[d] = UInt8(r / a); out[d + 1] = UInt8(g / a); out[d + 2] = UInt8(b / a)
            }
            out[d + 3] = UInt8(a / n)
        }
    }
    return out
}

public func scaleTo(_ img: RGBAImage, _ res: Int) -> [UInt8] {
    img.width > res ? scaleBox(img, to: res) : scaleNearest(img, to: res)
}

/// multiply RGB by a fixed color (bake a vanilla tint into the pixels)
public func bakeTint(_ px: inout [UInt8], _ rgb: Int) {
    let tr = (rgb >> 16) & 255, tg = (rgb >> 8) & 255, tb = rgb & 255
    var i = 0
    while i < px.count {
        px[i] = UInt8(Int(px[i]) * tr / 255)
        px[i + 1] = UInt8(Int(px[i + 1]) * tg / 255)
        px[i + 2] = UInt8(Int(px[i + 2]) * tb / 255)
        i += 4
    }
}

// =============================================================================
// pack handle (zip or folder) + discovery
// =============================================================================

public let NAME_MAP: [String: [String]] = [
    "grass_top": ["block/grass_block_top"],
    "grass_side": ["block/grass_block_side"],
    "farmland_dry": ["block/farmland"],
    "farmland_wet": ["block/farmland_moist"],
    "sandstone_side": ["block/sandstone"],
    "red_sandstone_side": ["block/red_sandstone"],
    "snow_block": ["block/snow"],
    "frosted_ice": ["block/frosted_ice_0"],
    "dried_kelp_block": ["block/dried_kelp_side"],
    "magma_block": ["block/magma"],
    "water": ["block/water_still"],
    "lava": ["block/lava_still"],
    "fire": ["block/fire_0"],
    "soul_fire": ["block/soul_fire_0"],
    "short_grass": ["block/short_grass", "block/grass"],
    "mangrove_roots": ["block/mangrove_roots_side", "block/mangrove_roots"],
    "suspicious_sand": ["block/suspicious_sand_0"],
    "suspicious_gravel": ["block/suspicious_gravel_0"],
    "bamboo": ["block/bamboo_stalk"],
    "bamboo_sapling": ["block/bamboo_stage0"],
    "big_dripleaf": ["block/big_dripleaf_top"],
    "small_dripleaf": ["block/small_dripleaf_top"],
    "azalea": ["block/azalea_top"],
    "flowering_azalea": ["block/flowering_azalea_top"],
    "pitcher_plant_top": ["block/pitcher_plant_top", "block/pitcher_crop_top"],
    "pitcher_plant_bottom": ["block/pitcher_plant_bottom", "block/pitcher_crop_bottom"],
    "pitcher_crop": ["block/pitcher_crop_top", "block/pitcher_crop_bottom"],
    "furnace_front_lit": ["block/furnace_front_on"],
    "blast_furnace_front_lit": ["block/blast_furnace_front_on"],
    "smoker_front_lit": ["block/smoker_front_on"],
    "observer_back_lit": ["block/observer_back_on"],
    "anvil_side": ["block/anvil"],
    "cartography_table_side": ["block/cartography_table_side3"],
    "lectern_side": ["block/lectern_sides"],
    "soul_campfire_log": ["block/soul_campfire_log_lit"],
    "respawn_anchor_side": ["block/respawn_anchor_side0"],
    "honey_block": ["block/honey_block_side"],
    "calibrated_sculk_sensor_side": ["block/calibrated_sculk_sensor_input_side"],
    "pointed_dripstone": ["block/pointed_dripstone_down_tip"],
    "sniffer_egg": ["block/sniffer_egg_not_cracked_north", "block/sniffer_egg_not_cracked"],
    "cocoa_stage3": ["block/cocoa_stage2"],
    "redstone_dust_line": ["block/redstone_dust_line0"],
    "stem_stage7": ["block/pumpkin_stem", "block/melon_stem"],
    "attached_stem": ["block/attached_pumpkin_stem", "block/attached_melon_stem"],
    // particle sprites (best-effort; procedural fallback is fine)
    "smoke_particle": ["particle/big_smoke_2", "particle/generic_3"],
    "flame_particle": ["particle/flame"],
    "heart_particle": ["particle/heart"],
    "angry_particle": ["particle/angry"],
    "crit_particle": ["particle/critical_hit"],
    "splash_particle": ["particle/splash_0"],
    "bubble_particle": ["particle/bubble"],
    "note_particle": ["particle/note"],
    "soul_particle": ["particle/soul_1", "particle/soul_0"],
    "sweep_particle": ["particle/sweep_2", "particle/sweep_0"],
    "slime_particle": ["item/slime_ball"],
    "snow_particle": ["particle/snowflake"],
    "petal_particle": ["particle/cherry_0", "particle/glow"],
    "portal_particle": ["particle/glow"],
    "redstone_particle": ["particle/glitter_0"],
    "enchant_particle": ["particle/sga_a"],
    // entity-textured / shader-effect blocks: stay procedural
    "air": [], "cave_air": [], "void_air": [],
    "end_portal": [], "chest_side": [], "ender_chest_side": [],
    "decorated_pot_side": [], "bell_body": [],
]

/// fixed vanilla tints to bake (engine renders these tiles untinted, MC art is grayscale)
public let BAKE_TINT: [String: Int] = [
    "birch_leaves": 0x80A755,
    "spruce_leaves": 0x619961,
    "redstone_dust_dot": 0xFF3030,
    "redstone_dust_line": 0xFF3030,
]

/// tiles whose MC art is grayscale-by-design and must KEEP the engine's biome
/// tint when a pack overrides them; every other overridden tile renders untinted
public let TINT_EXPECTED: Set<String> = [
    "grass_top", "water", "short_grass", "fern", "tall_grass", "large_fern",
    "sugar_cane", "vine", "lily_pad", "big_dripleaf", "small_dripleaf",
    "oak_leaves", "jungle_leaves", "acacia_leaves", "dark_oak_leaves", "mangrove_leaves",
]

public func candidates(_ tile: String) -> [String] {
    if let m = NAME_MAP[tile] { return m }
    if tile.hasPrefix("destroy_"), let n = Int(tile.dropFirst("destroy_".count)) {
        return ["block/destroy_stage_\(n)"]
    }
    if tile.hasPrefix("stem_stage"), Int(tile.dropFirst("stem_stage".count)) != nil {
        return ["block/pumpkin_stem", "block/melon_stem"]
    }
    return ["block/\(tile)"]
}

/// tiles built by stacking MC top/bottom halves into one square (door + 2-tall plants)
public func compositeHalves(_ tile: String) -> (top: String, bottom: String)? {
    if tile.hasSuffix("_door") {
        return ("block/\(tile)_top", "block/\(tile)_bottom")
    }
    if tile == "tall_grass" || tile == "large_fern" {
        return ("block/\(tile)_top", "block/\(tile)_bottom")
    }
    return nil
}

// vanilla stem age tint: r = age*32, g = 255-age*8, b = age*4
public func stemTint(_ age: Int) -> Int {
    (min(255, age * 32) << 16) | ((255 - age * 8) << 8) | (age * 4)
}


public func stripFrame(_ img: RGBAImage, _ i: Int) -> RGBAImage {
    let w = img.width
    let start = i * w * w * 4
    return RGBAImage(width: w, height: w, pixels: Array(img.pixels[start..<(start + w * w * 4)]))
}

/// nested-zip tolerant lookup root ("assets/minecraft/textures/")
private func packTexPrefix(_ zip: Data) -> String? {
    guard let names = pebZipList(zip) else { return nil }
    for n in names where n.contains("assets/minecraft/textures/") {
        return String(n[..<n.range(of: "assets/minecraft/textures/")!.upperBound])
    }
    return nil
}

public struct PackTerrainAtlas {
    public let res: Int
    public let slices: [[UInt8]]
    public let appliedTiles: Int
}

/// compose the terrain atlas from a resource-pack ZIP (Faithful) — same
/// tile order and mapping as the Mac; procedural art fills the gaps
public func buildPackTerrainAtlas(zip: Data) -> PackTerrainAtlas? {
    guard let prefix = packTexPrefix(zip) else { return nil }
    func tex(_ rel: String) -> RGBAImage? {
        guard let d = pebZipExtract(zip, name: prefix + rel + ".png"),
              let img = pebDecodePNG(d) else { return nil }
        return RGBAImage(width: img.width, height: img.height, pixels: img.pixels)
    }

    let base = buildAtlas()
    let names = allTileNames()
    var resolved: [Int: RGBAImage] = [:]
    var compositeSrcs: [Int: (RGBAImage, RGBAImage)] = [:]
    for (i, name) in names.enumerated() {
        if let halves = compositeHalves(name) {
            if var t = tex(halves.top), var b = tex(halves.bottom) {
                if t.height > t.width { t = stripFrame(t, 0) }
                if b.height > b.width { b = stripFrame(b, 0) }
                compositeSrcs[i] = (t, b)
            }
            continue
        }
        for c in candidates(name) {
            if let t = tex(c) { resolved[i] = t; break }
        }
    }

    var res = 16
    for t in resolved.values { res = max(res, min(128, t.width)) }
    for (a, b) in compositeSrcs.values { res = max(res, min(128, max(a.width, b.width))) }

    var slices: [[UInt8]] = []
    slices.reserveCapacity(names.count)
    var applied = 0
    for (i, name) in names.enumerated() {
        var px: [UInt8]
        if var img = resolved[i] {
            applied += 1
            if img.height > img.width { img = stripFrame(img, 0) }   // first anim frame
            px = scaleTo(img, res)
            if let bake = BAKE_TINT[name] { bakeTint(&px, bake) }
            if name.hasPrefix("stem_stage"), let age = Int(name.dropFirst("stem_stage".count)) {
                let keep = res * 2 * (age + 1) / 16
                for y in 0..<(res - keep) {
                    for x in 0..<res { px[(y * res + x) * 4 + 3] = 0 }
                }
                bakeTint(&px, stemTint(age))
            } else if name == "attached_stem" {
                bakeTint(&px, stemTint(7))
            }
        } else if let (top, bottom) = compositeSrcs[i] {
            applied += 1
            px = [UInt8](repeating: 0, count: res * res * 4)
            let half = res / 2
            let t = scaleTo(top, res), b = scaleTo(bottom, res)
            for y in 0..<half {
                for x in 0..<res {
                    let sT = ((y * 2) * res + x) * 4, dT = (y * res + x) * 4
                    px[dT] = t[sT]; px[dT + 1] = t[sT + 1]; px[dT + 2] = t[sT + 2]; px[dT + 3] = t[sT + 3]
                    let sB = ((y * 2) * res + x) * 4, dB = ((y + half) * res + x) * 4
                    px[dB] = b[sB]; px[dB + 1] = b[sB + 1]; px[dB + 2] = b[sB + 2]; px[dB + 3] = b[sB + 3]
                }
            }
        } else {
            px = scaleNearest(RGBAImage(width: 16, height: 16, pixels: base.pixels[i]), to: res)
        }
        slices.append(px)
    }
    return PackTerrainAtlas(res: res, slices: slices, appliedTiles: applied)
}
