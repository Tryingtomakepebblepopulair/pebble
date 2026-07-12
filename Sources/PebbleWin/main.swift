// PebbleWin — the Windows client (PORTING modules 07/08/09). A Win32 window
// + message pump around the REAL game: the same GameCore simulation AND the
// same UIManager/screens/HUD as the Mac — title screen, world select,
// options, multiplayer tabs, containers, chat — drawn through the portable
// UICanvas into the Vulkan backend. No audio yet (module 10).
//
//   Pebble.exe                      starts at the title screen, like the Mac
//   Pebble.exe --join <ip[:port]> [--name <naam>]   scripted direct join
//
// pebble-log.txt records everything.

#if os(Windows)

import WinSDK
import Foundation
import PebbleCoreBase
import CPebbleVulkan

let logFile = fopen("pebble-log.txt", "w")
func plog(_ s: String) {
    print(s)
    if let logFile {
        fputs(s + "\r\n", logFile)
        fflush(logFile)
    }
}

func alert(_ text: String) {
    plog("FATAL: \(text)")
    "Pebble".withCString(encodedAs: UTF16.self) { title in
        text.withCString(encodedAs: UTF16.self) { body in
            _ = MessageBoxW(nil, body, title, UINT(MB_OK | MB_ICONERROR))
        }
    }
}

func nowMs() -> Double { monotonicNow() * 1000 }

plog("Pebble \(PEBBLE_VERSION) — Windows client (Vulkan)")

// ---- args ---------------------------------------------------------------------
var joinTarget: (host: String, port: UInt16)? = nil
var cliName: String? = nil
do {
    let args = Array(CommandLine.arguments.dropFirst())
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--join" where i + 1 < args.count:
            let parts = args[i + 1].split(separator: ":")
            joinTarget = (String(parts[0]), parts.count > 1 ? UInt16(parts[1]) ?? 25585 : 25585)
            i += 1
        case "--name" where i + 1 < args.count:
            cliName = String(args[i + 1].prefix(16))
            i += 1
        default: break
        }
        i += 1
    }
}

// worlds live beside the exe unless the caller pinned a data root
if getenv("PEBBLE_DATA_DIR") == nil {
    let root = FileManager.default.currentDirectoryPath + "\\PebbleData"
    vcOverrideDataDir(root)
}

// ---- globals the window procedure reaches --------------------------------------
var resizedW: Int32 = 1280
var resizedH: Int32 = 760
var gGame: GameCore?
var gUI: UIManager?
var gHud: HUD?
var gCaptured = false
var gHwnd: HWND?

let heldCleanupKeys = ["KeyW", "KeyA", "KeyS", "KeyD", "Space",
                       "ShiftLeft", "ShiftRight", "ControlLeft", "ControlRight"]

func setCapture(_ on: Bool) {
    if on == gCaptured { return }
    gCaptured = on
    ShowCursor(on ? false : true)
    if !on, let g = gGame {
        for k in heldCleanupKeys { g.keyUp(k) }   // no stuck movement keys
    }
    if on { recenterCursor() }
}

func recaptureIfClear() {
    if let ui = gUI, !ui.hasScreen(), let g = gGame, g.hasWorld() {
        setCapture(true)
    }
}

func recenterCursor() {
    guard let hwnd = gHwnd else { return }
    var r = RECT()
    GetClientRect(hwnd, &r)
    var c = POINT(x: (r.right - r.left) / 2, y: (r.bottom - r.top) / 2)
    ClientToScreen(hwnd, &c)
    SetCursorPos(c.x, c.y)
}

func resizeUI() {
    guard let ui = gUI, let g = gGame else { return }
    ui.resize(Double(max(1, resizedW)), Double(max(1, resizedH)),
              g.settings.guiScale, relayout: g)
}

/// client px → GUI units (the canvas's coordinate space)
func uiPos(_ lParam: LPARAM) -> (Double, Double) {
    let x = Double(Int16(truncatingIfNeeded: lParam))
    let y = Double(Int16(truncatingIfNeeded: lParam >> 16))
    guard let ui = gUI else { return (x, y) }
    return (x * ui.width / Double(max(1, resizedW)),
            y * ui.height / Double(max(1, resizedH)))
}

func routeMouseDown(_ lParam: LPARAM, _ btn: Int) {
    guard let g = gGame, let ui = gUI else { return }
    if let screen = ui.current() {
        let (mx, my) = uiPos(lParam)
        ui.mouseX = mx
        ui.mouseY = my
        _ = screen.onMouseDown(ui, g, mx, my, btn)
        recaptureIfClear()
        return
    }
    guard g.hasWorld() else { return }
    if !gCaptured {
        setCapture(true)
        return
    }
    g.mouseDown(btn)
}

let wndProc: WNDPROC = { hwnd, msg, wParam, lParam in
    switch Int32(msg) {
    case WM_SIZE:
        resizedW = Int32(UInt16(truncatingIfNeeded: lParam))
        resizedH = Int32(UInt16(truncatingIfNeeded: lParam >> 16))
        pb_vk_resize(resizedW, resizedH)
        resizeUI()
        return 0

    case WM_KEYDOWN:
        guard let g = gGame, let ui = gUI else { return 0 }
        let isRepeat = (lParam & (1 << 30)) != 0
        let code = pebKeyName(wParam, lParam) ?? ""
        if let screen = ui.current() {
            if isRepeat && code != "Backspace" && !code.hasPrefix("Arrow") { return 0 }
            if code == "Escape" {
                if screen.closeOnEsc {
                    ui.closeTop(g)
                    recaptureIfClear()
                }
                return 0
            }
            if screen.onKey(ui, g, code) { return 0 }
            if code == g.keybinds["inventory"], screen.closeOnEsc, !(screen is ChatScreen),
               !screen.fields.contains(where: { $0.focused }) {
                ui.closeTop(g)
                recaptureIfClear()
            }
            return 0
        }
        guard g.hasWorld(), !isRepeat else { return 0 }
        if code == "F3" { gHud?.debugVisible.toggle(); return 0 }
        if code == "F1" { gHud?.hideGui.toggle(); return 0 }
        if !code.isEmpty {
            g.keyDown(code, now: nowMs(), ctrlOrCmd: GetKeyState(Int32(VK_CONTROL)) < 0)
        }
        return 0

    case WM_CHAR:
        // text input for screens (name fields, chat, world names…)
        if let ui = gUI, let g = gGame, let screen = ui.current(),
           wParam >= 32, wParam != 127, let u = UnicodeScalar(UInt32(wParam)) {
            _ = screen.onChar(ui, g, String(Character(u)))
        }
        return 0

    case WM_KEYUP:
        if let name = pebKeyName(wParam, lParam) {
            gGame?.keyUp(name)
        }
        return 0

    case WM_MOUSEMOVE:
        if let ui = gUI, let g = gGame, ui.hasScreen() || !gCaptured {
            let (mx, my) = uiPos(lParam)
            ui.current()?.onMouseMove(ui, g, mx, my)
            ui.mouseX = mx
            ui.mouseY = my
        }
        return 0

    case WM_LBUTTONDOWN:
        routeMouseDown(lParam, 0)
        return 0
    case WM_LBUTTONUP:
        if let ui = gUI, let g = gGame, let screen = ui.current() {
            let (mx, my) = uiPos(lParam)
            screen.onMouseUp(ui, g, mx, my)
        }
        gGame?.mouseUp(0)
        return 0
    case WM_RBUTTONDOWN:
        routeMouseDown(lParam, 2)
        return 0
    case WM_RBUTTONUP:
        gGame?.mouseUp(2)
        return 0
    case WM_MBUTTONDOWN:
        routeMouseDown(lParam, 1)
        return 0
    case WM_MBUTTONUP:
        gGame?.mouseUp(1)
        return 0

    case WM_KILLFOCUS:
        setCapture(false)
        return 0
    case WM_DESTROY:
        PostQuitMessage(0)
        return 0
    default:
        return DefWindowProcW(hwnd, msg, wParam, lParam)
    }
}

// ---- window ----------------------------------------------------------------------
let hInstance = GetModuleHandleW(nil)
"PebbleWindow".withCString(encodedAs: UTF16.self) { className in
    var wc = WNDCLASSW()
    wc.style = UINT(CS_HREDRAW | CS_VREDRAW)
    wc.lpfnWndProc = wndProc
    wc.hInstance = hInstance
    wc.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))  // IDC_ARROW
    wc.lpszClassName = className
    if RegisterClassW(&wc) == 0 {
        alert("could not register the window class (error \(GetLastError()))")
        exit(1)
    }
    "Pebble".withCString(encodedAs: UTF16.self) { title in
        gHwnd = CreateWindowExW(0, className, title,
                                DWORD(WS_OVERLAPPEDWINDOW) | DWORD(WS_VISIBLE),
                                CW_USEDEFAULT, CW_USEDEFAULT, 1280, 760,
                                nil, nil, hInstance, nil)
    }
}
guard let hwnd = gHwnd else {
    alert("could not create the game window (error \(GetLastError()))")
    exit(1)
}

// ---- renderer -----------------------------------------------------------------
var rect = RECT()
GetClientRect(hwnd, &rect)
if pb_vk_create(UnsafeMutableRawPointer(hwnd), UnsafeMutableRawPointer(hInstance),
                rect.right - rect.left, rect.bottom - rect.top) != 0 {
    alert("Vulkan setup failed: \(String(cString: pb_vk_last_error()))\n\n"
        + "Try updating your graphics drivers, then run Pebble again.")
    exit(1)
}
plog("vulkan ready — GPU: \(String(cString: pb_vk_device_name()))")

// ---- the game + the real UI stack -------------------------------------------------
let game = GameCore()
gGame = game
let ui = UIManager(cv: UICanvas())
gUI = ui
let hud = HUD()
gHud = hud
let host = WinHost()
host.ui = ui
host.hud = hud
host.game = game
game.host = host
let entityView = EntityView()
if let n = cliName { game.settings.playerName = n }

// platform seams for the portable screens (PORTING module 09)
platformQuit = {
    game.exitToTitle()       // saves when a world is open
    plog("clean exit (quit)")
    exit(0)
}
platformMeshedSectionsNear = { pcx, pcz in host.meshedNear(pcx, pcz) }
platformRelayoutGUI = { resizeUI() }
platformLoadSkinBlob = { loadSkinBlob() }

// procedural atlas (the same tiles the atlas goldens pin)
let atlas = buildAtlas()
var flatAtlas = [UInt8]()
flatAtlas.reserveCapacity(atlas.count * TILE * TILE * 4)
for px in atlas.pixels { flatAtlas.append(contentsOf: px) }
if flatAtlas.withUnsafeBufferPointer(
    { pb_vk_upload_atlas($0.baseAddress, Int32(TILE), Int32(TILE), Int32(atlas.count)) }) != 0 {
    alert("atlas upload failed: \(String(cString: pb_vk_last_error()))")
    exit(1)
}
plog("atlas: \(atlas.count) tiles — data root: \(vcSupportDir().path)")
resizeUI()

// title art (the same PNGs the Mac bundles) from assets\ beside the exe
func loadImageAsset(_ name: String) -> PebImage? {
    let path = FileManager.default.currentDirectoryPath + "\\assets\\" + name
    guard let d = FileManager.default.contents(atPath: path) else { return nil }
    return pebDecodePNG(d)
}
var titleBgSize: (w: Int, h: Int)? = nil
var titleLogoSize: (w: Int, h: Int)? = nil
if let img = loadImageAsset("title-bg.png"),
   img.pixels.withUnsafeBufferPointer({ pb_vk_upload_image(0, $0.baseAddress, Int32(img.width), Int32(img.height)) }) == 0 {
    titleBgSize = (img.width, img.height)
}
if let img = loadImageAsset("logo.png"),
   img.pixels.withUnsafeBufferPointer({ pb_vk_upload_image(1, $0.baseAddress, Int32(img.width), Int32(img.height)) }) == 0 {
    titleLogoSize = (img.width, img.height)
}
ui.titlePhoto = titleBgSize != nil
ui.titleLogo = titleLogoSize != nil
plog("title art: photo=\(titleBgSize != nil) logo=\(titleLogoSize != nil)")

if let target = joinTarget {
    plog("joining \(target.host):\(target.port)…")
    _ = game.joinLan(socketDial(host: target.host, port: target.port),
                     name: game.settings.playerName ?? "Speler", skin: loadSkinBlob())
    var waited = 0
    while !game.hasWorld() && waited < 900 {
        _ = game.frame(dtMs: 16)
        RunLoop.main.run(until: Date().addingTimeInterval(0.016))
        waited += 1
        if game.netGuest == nil { break }
    }
    if !game.hasWorld() {
        alert("Kon niet joinen: \(game.netGuest?.status ?? "verbinding mislukt").")
        exit(1)
    }
} else {
    // the very same title screen as the Mac
    host.openTitleScreen()
}

// ---- main loop ---------------------------------------------------------------------
plog("ready — the title screen is the real Pebble UI now")
let t0 = monotonicNow()
var lastFrame = t0
var frames = 0
var lastReport = t0
var msg = MSG()

mainLoop: while true {
    while PeekMessageW(&msg, nil, 0, 0, UINT(PM_REMOVE)) {
        if msg.message == UINT(WM_QUIT) { break mainLoop }
        TranslateMessage(&msg)
        DispatchMessageW(&msg)
    }
    // drain the main queue: chunk generation + finished meshes publish here
    RunLoop.main.run(until: Date())

    // relative mouse look while captured (and no screen is open)
    if gCaptured, game.hasWorld(), !ui.hasScreen() {
        var pt = POINT()
        GetCursorPos(&pt)
        var r = RECT()
        GetClientRect(hwnd, &r)
        var c = POINT(x: (r.right - r.left) / 2, y: (r.bottom - r.top) / 2)
        ClientToScreen(hwnd, &c)
        let dx = Double(pt.x - c.x), dy = Double(pt.y - c.y)
        if dx != 0 || dy != 0 {
            game.mouseDelta(dx, dy)
            SetCursorPos(c.x, c.y)
        }
    }

    let now = monotonicNow()
    let dtMs = (now - lastFrame) * 1000
    lastFrame = now
    let partial = game.frame(dtMs: min(dtMs, 100))

    // camera + world + entities
    if game.hasWorld(), let p = game.player {
        let xi = p.prevX + (p.x - p.prevX) * partial
        let yi = p.prevY + (p.y - p.prevY) * partial
        let zi = p.prevZ + (p.z - p.prevZ) * partial
        let eyeY = yi + (p.eyeY() - p.y)
        let dirX = Float(detCos(p.pitch) * -detSin(p.yaw))
        let dirY = Float(detSin(-p.pitch))
        let dirZ = Float(detCos(p.pitch) * detCos(p.yaw))

        // the SAME sky/day-light computation as the Mac — synced worlds
        // look identical at the same moment
        let sky = pebSkyColors(game.world)
        let dayLight = Float(sky.dayLight)

        let aspect = Float(max(1, resizedW)) / Float(max(1, resizedH))
        let proj = mat4fPerspective(fovYRad: 70 * .pi / 180, aspect: aspect, near: 0.05, far: 800)
        let view = mat4fLookDir(eyeX: 0, eyeY: 0, eyeZ: 0,
                                dirX: dirX, dirY: dirY, dirZ: dirZ, upX: 0, upY: 1, upZ: 0)
        let viewProj = proj * view
        let fogEnd = Float(game.settings.renderDistance * 16)
        viewProj.m.withUnsafeBufferPointer {
            pb_vk_set_camera($0.baseAddress, xi, eyeY, zi,
                             Float(now - t0), dayLight, Float(game.settings.gamma), 0,
                             fogEnd * 0.65, fogEnd, 0.35,
                             sky.horizon.0, sky.horizon.1, sky.horizon.2)
        }
        entityView.frame(game: game, camX: xi, camY: eyeY, camZ: zi,
                         dayLight: dayLight, partial: partial)
        drawUIFrame(ui, hud, game)
        _ = pb_vk_frame(sky.zenith.0, sky.zenith.1, sky.zenith.2)
    } else {
        pb_vk_begin_entities()
        // the Mac's title backdrop: cover-fit photo + the wordmark on top
        if let bg = titleBgSize {
            let sA = Double(max(1, resizedW)) / Double(max(1, resizedH))
            let tA = Double(bg.w) / Double(bg.h)
            var u0: Float = 0, v0: Float = 0, u1: Float = 1, v1: Float = 1
            if tA > sA {
                let f = Float(sA / tA)
                u0 = (1 - f) / 2
                u1 = u0 + f
            } else {
                let f = Float(tA / sA)
                v0 = (1 - f) / 2
                v1 = v0 + f
            }
            pb_vk_ui_push_image(0, 0, 0, Float(ui.width), Float(ui.height), u0, v0, u1, v1)
        }
        if let lg = titleLogoSize {
            // mirror the Mac's renderTitle: auto-scale space, 52 GUI units tall
            let pw = Double(max(1, resizedW)), ph = Double(max(1, resizedH))
            let auto = max(1.0, min((pw / 380).rounded(.down), (ph / 240).rounded(.down)))
            let gw = pw / auto, gh = ph / auto
            let logoH = 52.0
            let logoW = logoH * Double(lg.w) / Double(lg.h)
            let kx = ui.width / gw, ky = ui.height / gh
            pb_vk_ui_push_image(1, Float((gw / 2 - logoW / 2) * kx), Float((gh / 4 - 34) * ky),
                                Float(logoW * kx), Float(logoH * ky), 0, 0, 1, 1)
        }
        drawUIFrame(ui, hud, game)
        _ = pb_vk_frame(0.02, 0.02, 0.05)   // the Mac's title clear color
    }

    frames += 1
    if now - lastReport >= 5 {
        let p = game.player
        plog(String(format: "%.0f fps, pos %.1f %.1f %.1f, screen=%@",
                    Double(frames) / (now - lastReport),
                    p?.x ?? 0, p?.y ?? 0, p?.z ?? 0,
                    ui.current().map { String(describing: type(of: $0)) } ?? "none"))
        frames = 0
        lastReport = now
    }
}

plog("closing — saving…")
game.exitToTitle()
pb_vk_destroy()
plog("clean exit")

#else

print("PebbleWin is the Windows client — on this platform, run Pebble instead.")

#endif
