// Platform services for the portable UI stack (PORTING module 09): the
// screens/menus/HUD run on every platform; these seams are the ONLY way
// they reach the shell. Each platform installs its implementations at
// startup (AppKit on macOS, Win32 on Windows); the defaults keep headless
// and test builds working.

import Foundation

/// monotonic seconds for UI timing — the CACurrentMediaTime the screens used
@inline(__always) public func uiNow() -> Double { monotonicNow() }

/// "Quit Game" — the shell terminates the process (saving first if it wants)
public var platformQuit: () -> Void = { exit(0) }

/// clipboard (friend codes, server addresses)
public var platformSetClipboard: (String) -> Void = { _ in }
public var platformGetClipboard: () -> String = { "" }

/// meshed sections within 2 chunks of (cx, cz) — the loading screen's
/// progress probe; default reports "plenty" so it never blocks headless
public var platformMeshedSectionsNear: (Int, Int) -> Int = { _, _ in Int.max }

/// re-layout the UI immediately after a GUI-scale change
public var platformRelayoutGUI: () -> Void = {}

/// fullscreen toggle (Options menu)
public var platformIsFullscreen: () -> Bool = { false }
public var platformToggleFullscreen: () -> Void = {}

/// the player's custom skin PNG bytes (empty = default skin)
public var platformLoadSkinBlob: () -> Data = { Data() }

/// the Skins screen lives with the shell (file dialogs); nil = no-op button
public var platformOpenSkinsScreen: ((UIManager, GameCore) -> Void)?

/// pack GUI composite metadata (module 11 ports the pixels later) — the
/// sheet names present in the active pack; cell origins are fixed
public protocol PackUISheets: AnyObject {
    var sheets: Set<String> { get }
}
public let PACK_UI_CELLS: [String: (Int, Int)] = [
    "icons": (0, 0), "widgets": (512, 0), "ascii": (1024, 0), "bg": (1536, 0),
    "inventory": (0, 512), "generic_54": (512, 512), "crafting_table": (1024, 512), "furnace": (1536, 512),
    "brewing_stand": (0, 1024), "enchanting_table": (512, 1024), "anvil": (1024, 1024), "hopper": (1536, 1024),
    "dispenser": (0, 1536), "shulker_box": (512, 1536), "grindstone": (1024, 1536), "stonecutter": (1536, 1536),
    "smithing": (0, 2048), "cartography_table": (512, 2048), "beacon": (1024, 2048), "horse": (1536, 2048),
]

// ---- LAN discovery (Bonjour on macOS; direct-IP elsewhere) --------------------

/// one discovered LAN game — dial() opens the connection however the
/// platform found it (no OS endpoint types cross this line)
public struct DiscoveredGame {
    public let name: String
    public let txt: [String: String]
    public let dial: () -> NetConnection
    public init(name: String, txt: [String: String], dial: @escaping () -> NetConnection) {
        self.name = name
        self.txt = txt
        self.dial = dial
    }
}

public protocol LanDiscovery: AnyObject {
    var onUpdate: (([DiscoveredGame]) -> Void)? { get set }
    func start()
    func stop()
}

/// nil = no discovery on this platform (direct IP still works)
public var makeLanDiscovery: () -> LanDiscovery? = { nil }
