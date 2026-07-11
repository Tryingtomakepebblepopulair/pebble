// The REAL Pebble UI on Windows (PORTING modules 08/09 finale): the same
// UIManager/screens/HUD as the Mac — title screen, world select, options,
// multiplayer tabs, containers, chat — drawn through the portable UICanvas
// into the Vulkan UI pipeline. This file owns the per-frame handoff and the
// WinHost's screen-opening bridge (mirroring the Mac's HostBridge).

#if os(Windows)

import Foundation
import PebbleCoreBase
import CPebbleVulkan

/// draw one UI frame and hand the canvas output to the Vulkan backend
func drawUIFrame(_ ui: UIManager, _ hud: HUD, _ game: GameCore) {
    ui.beginFrame()
    let screen = ui.current()
    if game.hasWorld() && (screen == nil || screen!.showHUD || !screen!.pausesGame) {
        hud.draw(ui, game, 0)
        if !(screen is ChatScreen) { drawChatOverlay(ui) }
    }
    screen?.draw(ui, game, 0)
    ui.endFrame()

    // dirty canvas-atlas cells → tight pixel rects → the GPU atlas
    let size = UICanvas.ATLAS_SIZE
    for r in ui.cv.takeAtlasDirty() {
        var tight = [UInt8](repeating: 0, count: r.w * r.h * 4)
        ui.cv.atlasPixels.withUnsafeBufferPointer { src in
            for row in 0..<r.h {
                let s = ((r.y + row) * size + r.x) * 4
                for b in 0..<(r.w * 4) { tight[row * r.w * 4 + b] = src[s + b] }
            }
        }
        tight.withUnsafeBufferPointer {
            pb_vk_ui_update_atlas(Int32(r.x), Int32(r.y), Int32(r.w), Int32(r.h), $0.baseAddress)
        }
    }
    ui.cv.verts.withUnsafeBufferPointer {
        pb_vk_ui_set_frame($0.baseAddress, Int32(ui.cv.verts.count),
                           Float(ui.cv.width), Float(ui.cv.height))
    }
}

extension WinHost {
    /// mirror of the Mac HostBridge screen routing — same screens, same rules
    func routeOpenScreen(_ kind: String, _ data: ScreenData?, _ ui: UIManager,
                         _ hud: HUD, _ game: GameCore) {
        switch kind {
        case "crafting": ui.open(CraftingScreen(), game)
        case "inventory": ui.open(InventoryScreen(), game)
        case "creative": ui.open(CreativeScreen(), game)
        case "chest":
            if let be = data?.be {
                ui.open(ChestScreen(be, data?.title ?? "Chest", data?.other), game)
            }
        case "ender_chest":
            let p = game.player!
            ui.open(ChestScreen(items: { p.enderChest }, set: { p.enderChest[$0] = $1 },
                                count: p.enderChest.count, "Ender Chest"), game)
        case "furnace":
            if let be = data?.be { ui.open(FurnaceScreen(be), game) }
        case "brewing":
            if let be = data?.be { ui.open(BrewingScreen(be), game) }
        case "enchanting":
            ui.open(EnchantingScreen((data?.x ?? 0, data?.y ?? 0, data?.z ?? 0)), game)
        case "anvil":
            ui.open(AnvilScreen((data?.x ?? 0, data?.y ?? 0, data?.z ?? 0, data?.damage ?? 0)), game)
        case "grindstone": ui.open(GrindstoneScreen(), game)
        case "stonecutter": ui.open(StonecutterScreen(), game)
        case "smithing": ui.open(SmithingScreen(), game)
        case "beacon":
            if let be = data?.be { ui.open(BeaconScreen(be), game) }
        case "sign":
            ui.open(SignScreen(data?.be, (data?.x ?? 0, data?.y ?? 0, data?.z ?? 0)), game)
        case "toast":
            hud.showActionBar(data?.text ?? "")
        default:
            break
        }
        if ui.hasScreen() { setCapture(false) }
    }
}

#endif
