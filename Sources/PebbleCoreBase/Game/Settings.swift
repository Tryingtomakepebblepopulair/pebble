// Settings — JSON files under ~/Library/Application Support/Pebble/.
// Field names, defaults, and render-distance clamps are frozen; keybinds
// keep internal key-code strings so the app's NSEvent translation layer
// and saved configs stay engine-compatible.

import Foundation
#if os(Windows)
import CRT
#endif

/// point the data root somewhere else BEFORE any store is touched —
/// `pebserver --data-dir` and tests use this (PORTING module 04)
public func vcOverrideDataDir(_ path: String) {
    #if os(Windows)
    _ = _putenv_s("PEBBLE_DATA_DIR", path)
    #else
    setenv("PEBBLE_DATA_DIR", path, 1)
    #endif
}

public struct Settings: Codable {
    // video
    public var renderDistance = 8
    public var fov = 70
    public var fancyGraphics = true
    public var smoothLighting = true
    public var bloom = true
    public var shadows = true
    public var clouds = true
    public var particles = 2        // 0 minimal 1 decreased 2 all
    public var gamma = 0.5          // 0..1
    public var viewBobbing = true
    public var guiScale = 0         // 0 auto
    public var maxFps = 120         // 250 = unlimited/vsync-off; opt-in, not the default
    public var entityDistance = 64.0
    // audio
    public var volumes: [String: Double] = [
        "master": 0.8, "music": 0.5, "blocks": 1, "hostile": 1, "friendly": 1,
        "players": 1, "ambient": 1, "records": 1, "ui": 1,
    ]
    // controls
    public var sensitivity = 0.5    // 0..1
    public var invertY = false
    // accessibility
    public var subtitles = false
    public var autoJump = false
    public var reduceMotion = false
    public var reducedFlashes = false
    public var highContrast = false
    public var darknessPulse = 1.0
    /// per-block quads instead of greedy-merged spans (GPU driver workaround)
    public var simpleMesh = false
    /// enabled resource pack file names, index 0 = highest priority.
    /// optional so settings.json files written before this field still decode
    public var resourcePacks: [String]? = nil
    /// nil = off, "ultra" = built-in ultra preset, anything else = shader pack file name
    public var shader: String? = nil
    /// simulation speed multiplier, 0.5–3 (nil = 1×, normal speed).
    /// optional so settings.json files written before this field still decode
    public var gameSpeed: Double? = nil
    /// display name in LAN multiplayer (nil = "Player"); optional for old files
    public var playerName: String? = nil
    /// permanent random identity (like an XUID): names can change, this can't.
    /// servers key inventories by it; friends lists match on it.
    /// generated once at first boot (see GameCore.init); optional for old files
    public var playerId: String? = nil

    public init() {}
}

public let DEFAULT_KEYBINDS: [String: String] = [
    "forward": "KeyW",
    "back": "KeyS",
    "left": "KeyA",
    "right": "KeyD",
    "jump": "Space",
    "sneak": "ShiftLeft",
    "sprint": "ControlLeft",
    "inventory": "KeyE",
    "drop": "KeyQ",
    "chat": "KeyT",
    "command": "Slash",
    "perspective": "F5",
    "swapOffhand": "KeyF",
]

public func defaultSettings() -> Settings { Settings() }

/// ~/Library/Application Support/Pebble — created on first touch.
/// `PEBBLE_DATA_DIR` overrides the root (CI, tests, and servers point this at
/// temp dirs so they never touch real user data — PORTING module 04). Read
/// via getenv on every call so a process can set it before first storage use.
public func vcSupportDir() -> URL {
    let dir: URL
    if let raw = getenv("PEBBLE_DATA_DIR"), raw.pointee != 0 {
        dir = URL(fileURLWithPath: String(cString: raw), isDirectory: true)
    } else {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("Pebble", isDirectory: true)
    }
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private var settingsURL: URL { vcSupportDir().appendingPathComponent("settings.json") }
private var keybindsURL: URL { vcSupportDir().appendingPathComponent("keybinds.json") }

public func loadSettings() -> Settings {
    var s = Settings()
    if let data = try? Data(contentsOf: settingsURL),
       let saved = try? JSONDecoder().decode(Settings.self, from: data) {
        s = saved
        // merge any volume categories added since the file was written
        for (k, v) in Settings().volumes where s.volumes[k] == nil { s.volumes[k] = v }
    }
    // hard ceiling: above 16 the full-height chunk arrays + mesh pipeline
    // dominate memory; floor of 4 keeps the world visible
    s.renderDistance = min(16, max(4, s.renderDistance))
    if let g = s.gameSpeed { s.gameSpeed = min(3, max(0.5, g)) }
    return s
}

public func saveSettings(_ s: Settings) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? enc.encode(s) {
        try? data.write(to: settingsURL, options: .atomic)
    }
}

public func loadKeybinds() -> [String: String] {
    var binds = DEFAULT_KEYBINDS
    if let data = try? Data(contentsOf: keybindsURL),
       let saved = try? JSONDecoder().decode([String: String].self, from: data) {
        for (k, v) in saved { binds[k] = v }
    }
    return binds
}

public func saveKeybinds(_ binds: [String: String]) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? enc.encode(binds) {
        try? data.write(to: keybindsURL, options: .atomic)
    }
}

/// Turn down whatever a weak machine is most likely to have died on, one step
/// further for every launch in a row that ended badly. Returns what it
/// changed, in words, and an empty list when there is nothing left worth
/// turning off.
///
/// The point is the failures nobody can reproduce. A machine that dies once
/// in a world with shadows, bloom and a full render distance will do it again
/// on the next launch, and the player has no way of knowing which setting is
/// drowning their GPU. Pebble turns them down itself and says which ones —
/// changing someone's settings silently would be worse than the crash.
public func easeSettingsAfterCrash(_ settings: inout Settings, roughStarts: Int) -> [String] {
    var changed: [String] = []
    if settings.shadows {
        settings.shadows = false
        changed.append("shadows off")
    }
    if settings.bloom {
        settings.bloom = false
        changed.append("bloom off")
    }
    if settings.shader != nil {
        settings.shader = nil
        changed.append("shader off")
    }
    // 4 is the floor loadSettings enforces; stopping there keeps the world visible
    let cap = roughStarts >= 2 ? 4 : 6
    if settings.renderDistance > cap {
        settings.renderDistance = cap
        changed.append("render distance \(cap)")
    }
    if roughStarts >= 2 && !settings.simpleMesh {
        settings.simpleMesh = true
        changed.append("simple terrain")
    }
    return changed
}
