// The Windows GameHost (PORTING module 09): GameCore drives ALL meshing,
// chunk streaming, and gameplay itself — this bridge only forwards finished
// meshes to the Vulkan backend and remembers what the game asked the shell
// to do. Audio and particles are silent for now (module 10 comes later);
// screens have no portable UI yet, so death is handled by the main loop.

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
    /// set when the game wants the death screen — the loop auto-respawns
    var deathMessage: String?
    /// set when the game asks the shell to release the mouse
    var wantsPointerRelease = false
    var chatLines: [String] = []

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
    }

    func removeChunkMeshes(_ cx: Int, _ cz: Int, _ sections: Int) {
        for sy in 0..<sections {
            let id = sectionKey(cx, sy, cz)
            pb_vk_remove_section(id, 0)
            pb_vk_remove_section(id, 1)
            pb_vk_remove_section(id, 2)
        }
    }

    func clearAllSections() {
        pb_vk_clear_sections()
    }

    // ---- screens (no portable UI yet) ---------------------------------------
    func hasScreen() -> Bool { false }
    func screenPausesGame() -> Bool { false }
    func openScreen(_ kind: String, _ data: ScreenData?) {}
    func openTrading(_ villager: Mob) {}
    func openVehicleChest(_ kind: String, _ vehicle: Entity) {}
    func openChat(_ prefix: String) {}
    func openDeathScreen(_ message: String) { deathMessage = message }
    func openPauseScreen() {}
    func openTitleScreen() {}
    func closeAllScreens() {}
    func releasePointer() { wantsPointerRelease = true }

    // ---- HUD / chat ---------------------------------------------------------
    func showActionBar(_ text: String, _ time: Int) {}
    func pushChat(_ line: String) {
        chatLines.append(line)
        var out = ""
        var skip = false
        for ch in line {
            if skip { skip = false; continue }
            if ch == "§" { skip = true; continue }
            out.append(ch)
        }
        plog("[chat] \(out)")
    }
    func pushToast(_ adv: AdvancementDef) {}
    func setBossBars(_ bars: [BossBarInfo]) {}

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
