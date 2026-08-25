// The first-person viewmodel: what your own hands look like. The item mesh
// (an extruded icon), the empty fist and the placement matrices all come
// from here so the Metal and Vulkan clients hold the same pickaxe at the
// same angle (PORTING module 07 viewmodel slice). Extracted verbatim from
// GearRenderM.

import Foundation

/// the arm the empty fist draws: one box, textured from the player skin
public func pebFirstPersonArmModel() -> MobModel {
    MobModel(texW: 64, texH: 64, parts: [
        ModelPart(name: "arm", pivot: (0, 0, 0), boxes: [ModelBox(-2, -12, -2, 4, 12, 4, 40, 16)]),
    ], anim: "none", scale: 1, paint: { _ in })
}

/// a simple board shield (planks + iron boss), procedurally textured
public func pebShieldModel() -> MobModel {
    MobModel(texW: 32, texH: 32, parts: [
        ModelPart(name: "shield", pivot: (0, 0, 0), boxes: [ModelBox(-6, -11, -1, 12, 22, 1, 0, 0)]),
    ], anim: "none", scale: 1, paint: { s in
        s.box(0, 0, 12, 22, 1, 0x7a5b34, 0.1)      // oak planks
        s.rect(6, 2, 2, 22, 0x8a6b40)              // center plank stripe
        s.rect(5, 10, 4, 6, 0xb9bdc1)              // iron boss
        s.rect(6, 11, 2, 4, 0xd6dadd)
    })
}

/// a held item as a slab extruded from its icon: one cell per opaque pixel,
/// side faces only where the neighbour is transparent. The icon itself is
/// the texture. Returns nil for an icon that is empty or not square.
public func pebItemGeometry(_ stack: ItemStack) -> (geom: EntityGeometry, tex: [UInt8])? {
    let def = itemDef(stack.id)
    if def.name == "shield" {
        let built = buildEntityGeometry(from: pebShieldModel(), skinName: "shield")
        return (built, built.skin.data)
    }
    let key = "item:\(stack.id):\(stack.data.potion ?? "")"
    let rgba = itemIconPixels(stack.id, stack.data)
    // icons are square but pack-dependent in size (16× vanilla, 32× Faithful…)
    let n = Int(Double(rgba.count / 4).squareRoot().rounded())
    guard n >= 8, n * n * 4 == rgba.count else { return nil }
    func solid(_ c: Int, _ r: Int) -> Bool {
        c >= 0 && c < n && r >= 0 && r < n && rgba[(r * n + c) * 4 + 3] > 96
    }
    var verts: [Float] = []
    let t: Float = 1.0 / 16 / 2   // half thickness in blocks (1 sprite px slab)
    func quad(_ c0: SIMD3<Float>, _ c1: SIMD3<Float>, _ c2: SIMD3<Float>, _ c3: SIMD3<Float>,
              _ n: SIMD3<Float>, _ u: Float, _ v: Float) {
        let corners = [c0, c1, c2, c3]
        for i in [0, 2, 1, 0, 3, 2] {
            let p = corners[i]
            verts += [p.x, p.y, p.z, n.x, n.y, n.z, u, v, 0]
        }
    }
    let cell = 1.0 / Float(n)
    for r in 0..<n {
        for c in 0..<n where solid(c, r) {
            // sprite: column → x (centered), row 0 = top → y
            let x0 = Float(c) * cell - 0.5, x1 = x0 + cell
            let y1 = Float(n - r) * cell, y0 = y1 - cell
            let u = (Float(c) + 0.5) / Float(n), v = (Float(r) + 0.5) / Float(n)
            quad(.init(x0, y0, -t), .init(x1, y0, -t), .init(x1, y1, -t), .init(x0, y1, -t),
                 .init(0, 0, -1), u, v)
            quad(.init(x1, y0, t), .init(x0, y0, t), .init(x0, y1, t), .init(x1, y1, t),
                 .init(0, 0, 1), u, v)
            if !solid(c - 1, r) {
                quad(.init(x0, y0, t), .init(x0, y0, -t), .init(x0, y1, -t), .init(x0, y1, t),
                     .init(-1, 0, 0), u, v)
            }
            if !solid(c + 1, r) {
                quad(.init(x1, y0, -t), .init(x1, y0, t), .init(x1, y1, t), .init(x1, y1, -t),
                     .init(1, 0, 0), u, v)
            }
            if !solid(c, r - 1) {   // pixel above (higher y)
                quad(.init(x0, y1, -t), .init(x1, y1, -t), .init(x1, y1, t), .init(x0, y1, t),
                     .init(0, 1, 0), u, v)
            }
            if !solid(c, r + 1) {   // pixel below
                quad(.init(x0, y0, t), .init(x1, y0, t), .init(x1, y0, -t), .init(x0, y0, -t),
                     .init(0, -1, 0), u, v)
            }
        }
    }
    guard !verts.isEmpty else { return nil }
    let model = MobModel(texW: n, texH: n, parts: [ModelPart(name: "item", pivot: (0, 0, 0), boxes: [])],
                         anim: "none", scale: 1, paint: { _ in })
    let geom = EntityGeometry(verts: verts, vertexCount: verts.count / 9,
                              partNames: ["item"], model: model,
                              skin: EntitySkin(n, n, key))
    return (geom, rgba)
}

/// which piece of the viewmodel to draw, and where
public enum PebViewmodelPiece {
    case item(ItemStack)   // the held item, or a shield
    case offhand(ItemStack)
    case fist
}

public struct PebViewmodelPart {
    public let piece: PebViewmodelPiece
    public let model: Mat4f
}

/// the whole first-person viewmodel for this frame: the off-hand shield, the
/// held item (with its eat/drink wiggle and bow pull) or the empty fist,
/// each with its model matrix in VIEW space.
public func pebViewmodel(_ player: Player) -> [PebViewmodelPart] {
    var out: [PebViewmodelPart] = []
    let held = player.mainHand
    let heldDef = held.map { itemDef($0.id) }
    let isShield = heldDef?.name == "shield"
    let offShield = player.offHand.map { itemDef($0.id).name == "shield" } ?? false

    // swing arc: attackAnim decays 1 → 0, so progress f runs 0 → 1
    let f = max(0, 1 - Double(player.attackAnim))
    let swinging = player.attackAnim > 0.01
    let s1 = swinging ? Foundation.sin(f * .pi) : 0
    let s2 = swinging ? Foundation.sin(f.squareRoot() * .pi) : 0

    // off-hand shield sits on the left edge (raised when blocking)
    if offShield, let off = player.offHand {
        let raised = player.usingItem && player.useItemHand == "off"
        var m = mat4fTranslation(raised ? -0.35 : -0.6, raised ? -0.35 : -0.62, -0.85)
        m = m * mat4fRotateY(raised ? 0.55 : 0.85)
        m = m * mat4fRotateZ(raised ? 0.05 : 0.12)
        let s: Float = raised ? 0.55 : 0.5
        m = m * mat4fScale(s, s, s)
        out.append(PebViewmodelPart(piece: .offhand(off), model: m))
    }

    if let held {
        if isShield {
            let raised = player.usingItem && player.useItemHand == "main"
            var m = mat4fTranslation(raised ? 0.35 : 0.6, raised ? -0.35 : -0.62, -0.85)
            m = m * mat4fRotateY(raised ? -0.55 : -0.85)
            let s: Float = raised ? 0.55 : 0.5
            m = m * mat4fScale(s, s, s)
            out.append(PebViewmodelPart(piece: .item(held), model: m))
            return out
        }
        // eating / drinking wiggle, bow draw pull
        var eat = 0.0, pull: Double = 0
        if player.usingItem && player.useItemHand == "main" {
            if heldDef?.food != nil || heldDef?.name == "potion" || heldDef?.name == "milk_bucket" {
                eat = Foundation.sin(Double(player.useItemTicks) * 1.1) * 0.05 + 0.25
            } else if heldDef?.name == "bow" || heldDef?.name == "crossbow" {
                pull = min(1, Double(player.useItemTicks) / 20)
            }
        }
        var m = mat4fTranslation(Float(0.56 - s2 * 0.34 - eat * 0.9 - pull * 0.12),
                                 Float(-0.5 - s1 * 0.2 + eat * 0.35),
                                 Float(-0.72 - s1 * 0.05 + pull * 0.16))
        m = m * mat4fRotateY(Float(0.15 - s2 * 1.05 + pull * 0.45))
        m = m * mat4fRotateZ(Float(-s2 * 0.3))
        m = m * mat4fRotateX(Float(-s1 * 0.85 + eat * 0.8))
        m = m * mat4fScale(0.62, 0.62, 0.62)
        out.append(PebViewmodelPart(piece: .item(held), model: m))
    } else {
        // empty fist: shoulder anchored off-screen bottom-right, forearm
        // rising diagonally toward the center (hand = the box's -Y end)
        var m = mat4fTranslation(Float(0.78 - s2 * 0.35), Float(-0.9 - s1 * 0.18), -0.55)
        m = m * mat4fRotateY(Float(0.5 - s2 * 0.8))
        m = m * mat4fRotateX(Float(2.25 - s1 * 0.9))
        m = m * mat4fScale(1.1, 1.1, 1.1)
        out.append(PebViewmodelPart(piece: .fist, model: m))
    }
    return out
}
