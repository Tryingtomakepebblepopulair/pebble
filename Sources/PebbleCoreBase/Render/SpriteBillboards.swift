// Which entities draw as billboards, and how bright. Extracted verbatim
// from the Metal drawSprites so the Vulkan backend picks the same items,
// the same sizes and the same bob (PORTING module 07 detail slice).
// Assigning atlas slots stays platform-side — that is a texture concern.

import Foundation

public struct PebBillboard {
    public let x: Double, y: Double, z: Double
    public let stack: ItemStack
    public let size: Double
    public let bob: Double
    public let light: Double
    public let emissive: Double
}

/// every item / projectile entity within 64 blocks that draws as a billboard
public func pebBillboards(_ w: World, dayLight: Double, camX: Double, camZ: Double,
                          partial: Double) -> [PebBillboard] {
    let spriteMap: [String: String] = [
        "snowball": "snowball", "egg": "egg", "ender_pearl": "ender_pearl", "xp_bottle": "experience_bottle",
        "thrown_potion": "splash_potion", "firework": "firework_rocket", "eye_of_ender": "ender_eye",
        "fishing_bobber": "string", "wither_skull": "wither_skeleton_skull_item", "dragon_fireball": "fire_charge",
        "fireball": "fire_charge", "shulker_bullet": "shulker_shell", "llama_spit": "snowball",
    ]
    var items: [PebBillboard] = []
    for e in w.entities {
        if e.dead { continue }
        guard let ent = e as? Entity else { continue }
        var stack: ItemStack? = nil
        var size = 0.45
        var emissive = 0.0
        if ent.type == "item" {
            stack = (ent as? ItemEntity)?.stack
        } else if ent.type == "xp_orb" {
            stack = ItemStack(iid("experience_bottle"), 1)
            size = 0.3
            emissive = 1
        } else if SPRITE_TYPES.contains(ent.type) {
            let id = iidOpt(spriteMap[ent.type] ?? "snowball") ?? iid("snowball")
            stack = ItemStack(id, 1)
            size = 0.35
            if ent.type == "fireball" || ent.type == "dragon_fireball" || ent.type == "wither_skull" { emissive = 1 }
        }
        guard let stack else { continue }
        let dx = ent.x - camX, dz = ent.z - camZ
        if dx * dx + dz * dz > 64 * 64 { continue }
        let ix = ent.prevX + (ent.x - ent.prevX) * partial
        let iy = ent.prevY + (ent.y - ent.prevY) * partial
        let iz = ent.prevZ + (ent.z - ent.prevZ) * partial
        let bx = ifloor(ent.x), by = ifloor(ent.y + 0.3), bz = ifloor(ent.z)
        let sky = max(0, Double(w.getSkyLight(bx, by, bz)) - w.skyDarken())
        let light = max(Double(w.info.ambientLight),
                        max(sky * dayLight * 15 / max(1, 15 - w.skyDarken()), Double(w.getBlockLight(bx, by, bz))))
        items.append(PebBillboard(
            x: ix, y: iy, z: iz, stack: stack, size: size,
            bob: ent.type == "item" ? detSin((Double(ent.age) + partial) * 0.08) * 0.08 + 0.12 : 0,
            light: min(1, max(0.12, light / 15)), emissive: emissive))
    }
    return items
}
