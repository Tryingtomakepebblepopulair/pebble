// The Windows GameHost (PORTING modules 08/09): the full bridge between
// GameCore and the portable UI stack — the same screens, HUD, and chat as
// the Mac's HostBridge — plus the mesh handoff to the Vulkan backend.
// Audio stays silent until module 10.

#if os(Windows)

import Foundation
import PebbleCoreBase
import CPebbleVulkan

/// stable section key shared with the renderer slots
func sectionKey(_ cx: Int, _ sy: Int, _ cz: Int) -> UInt64 {
    UInt64(bitPattern: Int64((Int64(cx + 1 << 19) << 40)
        | (Int64(cz + 1 << 19) << 20) | Int64(sy)))
}

final class WinHost: GameHost {
    var ui: UIManager!
    var hud: HUD!
    weak var game: GameCore?
    /// uploaded sections by chunk — feeds the loading screen's progress
    private var meshedByChunk: [Int64: Set<Int>] = [:]

    private func chunkKey(_ cx: Int, _ cz: Int) -> Int64 {
        (Int64(cx) << 32) | Int64(UInt32(bitPattern: Int32(cz)))
    }

    func meshedNear(_ pcx: Int, _ pcz: Int) -> Int {
        var n = 0
        for dz in -2...2 {
            for dx in -2...2 {
                n += meshedByChunk[chunkKey(pcx + dx, pcz + dz)]?.count ?? 0
            }
        }
        return n
    }

    // ---- renderer ----------------------------------------------------------
    func uploadMesh(_ cx: Int, _ sy: Int, _ cz: Int, _ minY: Int, _ mesh: MeshOutput) {
        let id = sectionKey(cx, sy, cz)
        let ox = Double(cx * 16), oy = Double(minY + sy * 16), oz = Double(cz * 16)
        for (pass, layer) in [(Int32(0), mesh.opaque), (1, mesh.cutout), (2, mesh.translucent)] {
            _ = layer.data.withUnsafeBufferPointer { vp in
                layer.idx.withUnsafeBufferPointer { ip in
                    pb_vk_upload_section(id, pass, ox, oy, oz,
                                         vp.baseAddress, Int32(layer.count),
                                         ip.baseAddress, Int32(layer.idx.count))
                }
            }
        }
        meshedByChunk[chunkKey(cx, cz), default: []].insert(sy)
    }

    func removeChunkMeshes(_ cx: Int, _ cz: Int, _ sections: Int) {
        for sy in 0..<sections {
            let id = sectionKey(cx, sy, cz)
            pb_vk_remove_section(id, 0)
            pb_vk_remove_section(id, 1)
            pb_vk_remove_section(id, 2)
        }
        meshedByChunk.removeValue(forKey: chunkKey(cx, cz))
    }

    func clearAllSections() {
        pb_vk_clear_sections()
        meshedByChunk.removeAll()
    }

    // ---- screens: the SAME portable screens as the Mac ----------------------
    func hasScreen() -> Bool { ui?.hasScreen() ?? false }
    func screenPausesGame() -> Bool { ui?.current()?.pausesGame ?? false }

    func openScreen(_ kind: String, _ data: ScreenData?) {
        guard let game else { return }
        routeOpenScreen(kind, data, ui, hud, game)
    }
    func openTrading(_ villager: Mob) {
        guard let game else { return }
        ui.open(TradingScreen(villager), game)
        setCapture(false)
    }
    func openVehicleChest(_ kind: String, _ vehicle: Entity) {
        guard let game else { return }
        let title = kind == "boat_chest" ? "Chest Boat" : "Minecart with Chest"
        if let boat = vehicle as? Boat {
            ui.open(ChestScreen(vehicle: boat, title), game)
        } else if let cart = vehicle as? Minecart {
            ui.open(ChestScreen(vehicle: cart, title), game)
        }
        setCapture(false)
    }
    func openChat(_ prefix: String) {
        guard let game else { return }
        ui.open(ChatScreen({ [weak game] cmd in
            if let game { runCommand(game, cmd) }
        }, prefix), game)
        setCapture(false)
    }
    func openDeathScreen(_ message: String) {
        guard let game else { return }
        ui.open(DeathScreen(message), game)
        setCapture(false)
    }
    func openPauseScreen() {
        guard let game else { return }
        ui.open(PauseScreen(), game)
        setCapture(false)
    }
    func openTitleScreen() {
        guard let game else { return }
        ui.titlePhoto = false   // title art textures come with module 11
        ui.titleLogo = false
        ui.open(TitleScreen(), game)
        setCapture(false)
    }
    func closeAllScreens() {
        guard let game else { return }
        ui.closeAll(game)
    }
    func releasePointer() { setCapture(false) }

    // ---- HUD / chat ---------------------------------------------------------
    func showActionBar(_ text: String, _ time: Int) {
        hud.showActionBar(text)
        hud.actionBarTime = time
    }
    func pushChat(_ line: String) { PebbleCoreBase.pushChat(line) }
    func pushToast(_ adv: AdvancementDef) { hud.pushToast(adv) }
    func setBossBars(_ bars: [BossBarInfo]) { hud.bossBars = bars }

    // ---- audio: module 10 — silent for now -----------------------------------
    func playSound(_ name: String, _ x: Double, _ y: Double, _ z: Double, _ volume: Double, _ pitch: Double) {}
    func playUI(_ name: String) {}
    func setAudioEnvironment(_ underwater: Bool, _ caveFactor: Double) {}
    func setAudioListener(_ x: Double, _ y: Double, _ z: Double, _ yaw: Double) {}
    func tickMusic(_ mood: String, _ enabled: Bool) {}
    func stopDisc() {}

    // ---- particles: later renderer slice --------------------------------------
    func addParticles(_ type: String, _ x: Double, _ y: Double, _ z: Double, _ count: Int, _ spread: Double, _ cell: Int) {}
    func spawnPrecipitation(_ kind: String, _ x: Double, _ y: Double, _ z: Double, _ groundY: Double) {}
}

#endif
