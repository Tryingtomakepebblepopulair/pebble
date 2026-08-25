// Armour and held items on a posed body. The rigs share the biped's part
// names, so the shared animator poses a chestplate exactly like the chest
// underneath; a held item rides part 0 on the arm matrix the body pose
// produced. Extracted verbatim from GearRenderM (PORTING module 07 gear
// slice) — the Vulkan client hangs the same sword off the same wrist.

import Foundation

let pebArmorColors: [String: Int] = [
    "leather": 0x8a5a33, "chainmail": 0x9a9a9a, "iron": 0xd8d8d8,
    "gold": 0xecc540, "diamond": 0x4dede0, "netherite": 0x443c3f, "turtle": 0x3aa746,
]

public func pebArmorMaterial(_ s: ItemStack) -> String? {
    let name = itemDef(s.id).name
    guard name.hasSuffix("_helmet") || name.hasSuffix("_chestplate")
        || name.hasSuffix("_leggings") || name.hasSuffix("_boots") else { return nil }
    let mat = String(name.split(separator: "_").first ?? "")
    return mat == "golden" ? "gold" : mat
}

public func pebArmorModel(_ piece: Int, _ mat: String) -> MobModel {
    let color = pebArmorColors[mat] ?? 0x9a9a9a
    func P(_ name: String, _ pivot: (Double, Double, Double), _ boxes: ModelBox...) -> ModelPart {
        ModelPart(name: name, pivot: pivot, boxes: boxes)
    }
    switch piece {
    case 0: // helmet
        return MobModel(texW: 64, texH: 32, parts: [
            P("head", (0, 24, 0), ModelBox(-4, 0, -4, 8, 8, 8, 0, 0, 0.75)),
        ], anim: "biped", scale: 1, paint: { s in s.box(0, 0, 8, 8, 8, color, 0.06) })
    case 1: // chestplate + shoulders
        return MobModel(texW: 64, texH: 32, parts: [
            P("body", (0, 24, 0), ModelBox(-4, -12, -2, 8, 12, 4, 16, 16, 0.51)),
            P("armR", (-5, 22, 0), ModelBox(-3, -10, -2, 4, 12, 4, 40, 16, 0.6)),
            P("armL", (5, 22, 0), ModelBox(-1, -10, -2, 4, 12, 4, 40, 16, 0.6)),
        ], anim: "biped", scale: 1, paint: { s in
            s.box(16, 16, 8, 12, 4, color, 0.06)
            s.box(40, 16, 4, 12, 4, color, 0.06)
        })
    case 2: // leggings (vanilla layer_2)
        return MobModel(texW: 64, texH: 32, parts: [
            P("body", (0, 24, 0), ModelBox(-4, -12, -2, 8, 12, 4, 16, 16, 0.26)),
            P("legR", (-2, 12, 0), ModelBox(-2, -12, -2, 4, 12, 4, 0, 16, 0.26)),
            P("legL", (2, 12, 0), ModelBox(-2, -12, -2, 4, 12, 4, 0, 16, 0.26)),
        ], anim: "biped", scale: 1, paint: { s in
            s.box(16, 16, 8, 12, 4, color, 0.06)
            s.box(0, 16, 4, 12, 4, color, 0.06)
        })
    default: // boots
        return MobModel(texW: 64, texH: 32, parts: [
            P("legR", (-2, 12, 0), ModelBox(-2, -12, -2, 4, 12, 4, 0, 16, 0.76)),
            P("legL", (2, 12, 0), ModelBox(-2, -12, -2, 4, 12, 4, 0, 16, 0.76)),
        ], anim: "biped", scale: 1, paint: { s in s.box(0, 16, 4, 12, 4, color, 0.06) })
    }
}

/// where a held item sits relative to the arm matrix the body pose produced
public func pebHeldMatrix(_ armMat: Mat4f, right: Bool, shield: Bool, raised: Bool) -> Mat4f {
    var m = armMat
    if shield {
        // strapped flat to the forearm; swings up-front when blocking
        m = m * mat4fTranslation(right ? -1.0 / 16 : 1.0 / 16, -9.0 / 16, raised ? -3.5 / 16 : 3.0 / 16)
        m = m * mat4fRotateY(right ? 0.12 : -0.12)
        if raised { m = m * mat4fRotateX(-0.15) }
    } else {
        // vanilla-style hold: blade plane slices forward, tilted ~55°
        // up-forward and a touch outward so it reads from behind
        m = m * mat4fTranslation(right ? -1.5 / 16 : 1.5 / 16, -9.5 / 16, -1.0 / 16)
        m = m * mat4fRotateZ(right ? 0.25 : -0.25)   // outward = -X for the right arm
        m = m * mat4fRotateX(-0.7)
        m = m * mat4fRotateY(right ? -.pi / 2 : .pi / 2)
        m = m * mat4fScale(0.7, 0.7, 0.7)
        m = m * mat4fTranslation(0, -0.12, 0)
    }
    return m
}

/// what to draw on top of a posed player
public enum PebGearGeom {
    case armor(piece: Int, material: String)
    case held(ItemStack)
}

public struct PebGearPiece {
    public let geom: PebGearGeom
    /// the 24 part matrices this piece draws with
    public let parts: [Mat4f]
}

/// the armour and held items for a posed player. `bodyParts` is that player's
/// own posed rig — parts 2 and 3 are the arms the held items ride.
public func pebPlayerGear(_ player: Player, pose: EntityPose, bodyParts: [Mat4f],
                          time: Double) -> [PebGearPiece] {
    var out: [PebGearPiece] = []
    let identity = [Mat4f](repeating: Mat4f(), count: 24)
    let armR = bodyParts.count > 2 ? bodyParts[2] : Mat4f()
    let armL = bodyParts.count > 3 ? bodyParts[3] : Mat4f()

    // held items: part 0 of the item mesh rides the captured arm matrix
    if let s = player.mainHand {
        var mats = identity
        mats[0] = pebHeldMatrix(armR, right: true,
                                shield: itemDef(s.id).name == "shield",
                                raised: pose.blockingHand == "main")
        out.append(PebGearPiece(geom: .held(s), parts: mats))
    }
    if let s = player.offHand {
        var mats = identity
        mats[0] = pebHeldMatrix(armL, right: false,
                                shield: itemDef(s.id).name == "shield",
                                raised: pose.blockingHand == "off")
        out.append(PebGearPiece(geom: .held(s), parts: mats))
    }

    // armour overlays: each piece re-runs the shared animator on its own rig
    for piece in 0..<4 {
        guard player.armor.indices.contains(piece), let s = player.armor[piece],
              let material = pebArmorMaterial(s) else { continue }
        let mats = pebPoseParts(pebArmorModel(piece, material), pose, time)
        out.append(PebGearPiece(geom: .armor(piece: piece, material: material), parts: mats))
    }
    return out
}
