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
import CPebbleAudio

func alert(_ text: String) {
    plog("FATAL: \(text)")
    "Pebble".withCString(encodedAs: UTF16.self) { title in
        text.withCString(encodedAs: UTF16.self) { body in
            _ = MessageBoxW(nil, body, title, UINT(MB_OK | MB_ICONERROR))
        }
    }
}

func nowMs() -> Double { monotonicNow() * 1000 }

// ---- startup, in this order ----------------------------------------------------
// The data root decides where everything else lives, so it is settled first.
// The claim on it comes before the log, because a second Pebble must not
// rotate away the log of the one already running. Then the log opens, and the
// crash handler goes in before anything can crash.
let dataRoot = chooseDataRoot()
if getenv("PEBBLE_DATA_DIR") == nil { vcOverrideDataDir(dataRoot.path) }

if !claimDataRoot(dataRoot.path) {
    focusRunningPebble()
    notice("""
        Pebble is already running.

        Its window should be in front of you now. If it is frozen, close it \
        with Task Manager (Ctrl+Shift+Esc) before starting a new one.

        Two copies sharing one set of worlds overwrite each other's saves, \
        which is why this one is stopping here.
        """)
    exit(0)
}

openLog(dataRoot: dataRoot.path)
installCrashHandler()

plog("Pebble \(PEBBLE_VERSION) — Windows client (Vulkan)")
plog("exe folder: \(exeDir())")
plog("data root:  \(dataRoot.path)  (\(dataRoot.why))")

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
if let why = game.db.openError {
    plog("SAVES UNAVAILABLE: \(why)")
    notice("""
        Pebble can't open its save file, so nothing you build this session \
        will be kept:

        \(why)

        This is almost always the folder: move the whole Pebble folder out of \
        Program Files (or out of the zip) — the Desktop is fine — and start it \
        again.
        """)
}
let ui = UIManager(cv: UICanvas())
gUI = ui
let hud = HUD()
gHud = hud
let host = WinHost()
let detail = DetailView()
let viewmodel = ViewmodelView()
let audioOut = WinAudio()
host.ui = ui
host.hud = hud
host.game = game
host.detail = detail
host.audio = audioOut

// sound (PORTING module 10): the same synthesized engine the Mac runs, fed
// to waveOut. A machine with no output device just stays quiet.
if let err = audioOut.start(volumes: game.settings.volumes) {
    plog("audio unavailable — playing silent: \(err)")
} else {
    plog("audio: waveOut at \(pb_audio_sample_rate()) Hz")
}
audioOut.synth.onSubtitle = { [weak hud] text in
    guard game.settings.subtitles else { return }
    hud?.pushSubtitle(text)
}
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
platformSetClipboard = { text in
    guard OpenClipboard(gHwnd) else { return }
    EmptyClipboard()
    let units = Array(text.utf16) + [0]
    if let mem = GlobalAlloc(UINT(GMEM_MOVEABLE), SIZE_T(units.count * 2)) {
        if let dst = GlobalLock(mem) {
            units.withUnsafeBufferPointer { src in
                memcpy(dst, src.baseAddress!, units.count * 2)
            }
            GlobalUnlock(mem)
            SetClipboardData(UINT(13 /* CF_UNICODETEXT */), mem)
        }
    }
    CloseClipboard()
}
platformGetClipboard = {
    guard OpenClipboard(gHwnd) else { return "" }
    defer { CloseClipboard() }
    guard let h = GetClipboardData(UINT(13 /* CF_UNICODETEXT */)),
          let p = GlobalLock(h) else { return "" }
    defer { GlobalUnlock(h) }
    return String(decodingCString: p.assumingMemoryBound(to: UInt16.self), as: UTF16.self)
}
platformRelayoutGUI = { resizeUI() }
platformLoadSkinBlob = { loadSkinBlob() }

// terrain: the Faithful pack when shipped, the procedural tiles otherwise
var terrainSlices: [[UInt8]]
var terrainRes: Int
let packPath = exeDir() + "\\assets\\Faithful 32x - 1.20.1.zip"
let packZip = FileManager.default.contents(atPath: packPath)
if let zipData = packZip, let pack = buildPackTerrainAtlas(zip: zipData) {
    terrainSlices = pack.slices
    terrainRes = pack.res
    // the same three things the Mac installs alongside the terrain: item
    // icons, the UI canvas's sheet, and the tint gate. Without the gate every
    // pack tile keeps the procedural biome tint and the world is miscoloured.
    initIcons(pack.icon16)
    setUIAtlas(pack.icon16)
    PACK_TINT_GATE = pack.tintGate
    // the pack's own item art (swords, tools) on top of the block icons
    let itemArt = pebPackItemIcons(zip: zipData)
    itemIconOverride = itemArt.isEmpty ? nil : { name in itemArt[name] }
    plog("icons: \(itemArt.count) item textures from the pack")
    plog("textures: Faithful — \(pack.appliedTiles)/\(pack.slices.count) tiles at \(pack.res)×")
} else {
    let atlas = buildAtlas()
    terrainSlices = atlas.pixels
    terrainRes = TILE
    plog("textures: procedural (no pack zip found)")
}
var flatAtlas = [UInt8]()
flatAtlas.reserveCapacity(terrainSlices.count * terrainRes * terrainRes * 4)
for px in terrainSlices { flatAtlas.append(contentsOf: px) }
if flatAtlas.withUnsafeBufferPointer(
    { pb_vk_upload_atlas($0.baseAddress, Int32(terrainRes), Int32(terrainRes), Int32(terrainSlices.count)) }) != 0 {
    alert("atlas upload failed: \(String(cString: pb_vk_last_error()))")
    exit(1)
}
plog("atlas ready — data root: \(vcSupportDir().path)")

// the sky (PORTING 07 sky slice): the shared star field and cloud mask, plus
// the pack's sun/moon art when it ships any. Without the art the sun and moon
// fall back to the same procedural discs the Mac draws.
let starField = pebStarField()
if starField.withUnsafeBufferPointer({
    pb_vk_upload_stars($0.baseAddress, Int32(PEB_STAR_COUNT)) }) != 0 {
    plog("stars: \(String(cString: pb_vk_last_error()))")
}
let cloudMask = pebCloudTexture()
if cloudMask.pixels.withUnsafeBufferPointer({
    pb_vk_upload_sky_tex(2, $0.baseAddress, Int32(cloudMask.width), Int32(cloudMask.height)) }) != 0 {
    plog("clouds: \(String(cString: pb_vk_last_error()))")
}
if let zipData = packZip {
    for (slot, rel, what) in [(Int32(0), "environment/sun.png", "sun"),
                              (Int32(1), "environment/moon_phases.png", "moon")] {
        guard let img = packTexture(zip: zipData, rel: rel) else {
            plog("sky: no \(what) art in the pack — procedural")
            continue
        }
        if img.pixels.withUnsafeBufferPointer({
            pb_vk_upload_sky_tex(slot, $0.baseAddress, Int32(img.width), Int32(img.height)) }) != 0 {
            plog("sky \(what): \(String(cString: pb_vk_last_error()))")
        }
    }
}

entityView.packZip = packZip   // armour sheets, when the pack ships them

// the pack's interface art: menus, containers and the bitmap font. Without
// this the Windows client drew the whole UI from the procedural atlas while
// the Mac showed the pack's.
if let zipData = packZip, let gui = pebPackUISheet(zip: zipData) {
    let rc = gui.pixels.withUnsafeBufferPointer {
        pb_vk_upload_gui_sheet($0.baseAddress, Int32(gui.width), Int32(gui.height))
    }
    if rc == 0 {
        ui.cv.hasGuiSheet = true
        packFontWidths = gui.fontWidths
        plog("GUI: pack sheet — \(gui.sheets.count) sheets\(gui.fontWidths != nil ? " + font" : "")")
    } else {
        plog("GUI: pack sheet upload failed: \(String(cString: pb_vk_last_error()))")
    }
}

/// hand the sky pass its environment — the same gates as the Mac's scene pass
func pushSky(_ game: GameCore, _ cam: CamState, _ sky: PebSky) {
    let w = game.world
    let sun = pebSunDirection(sunAngle: w.sunAngle())
    let overworld = w.dim == .overworld
    let drawSky = !cam.underwater && !cam.underLava && cam.blindness < 0.5
    let clouds = game.settings.clouds && overworld && !cam.underwater
    let zen: [Float] = [sky.zenith.0, sky.zenith.1, sky.zenith.2]
    let hor: [Float] = [sky.horizon.0, sky.horizon.1, sky.horizon.2]
    let dir: [Float] = [sun.0, sun.1, sun.2]
    zen.withUnsafeBufferPointer { z in
        hor.withUnsafeBufferPointer { h in
            dir.withUnsafeBufferPointer { s in
                pb_vk_set_sky(drawSky ? 1 : 0, overworld ? 1 : 0,
                              w.dim == .end ? 1 : 0, clouds ? 1 : 0,
                              z.baseAddress, h.baseAddress, Float(sky.sunGlow), s.baseAddress,
                              Float(w.rainLevel), Int32(w.time / 24000 % 8))
            }
        }
    }
}

/// no world on screen (title, loading): the sky pass sits the frame out
func silenceSky() {
    let zero: [Float] = [0, 0, 0]
    zero.withUnsafeBufferPointer { z in
        pb_vk_set_sky(0, 0, 0, 0, z.baseAddress, z.baseAddress, 0, z.baseAddress, 0, 0)
    }
}
resizeUI()

// title art (the same PNGs the Mac bundles) from assets\ beside the exe
func loadImageAsset(_ name: String) -> PebImage? {
    let path = exeDir() + "\\assets\\" + name
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
var lastVolumePoll = t0
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
        detail.particles.tick(game.world)
        // the shared camera: interpolation, view bobbing, the third-person
        // pull-back and its block clipping all live in camState. Deriving the
        // eye straight off the player skipped every one of them.
        let cam = game.camState(partial, timeSec: now - t0)
        let xi = cam.x, eyeY = cam.y, zi = cam.z
        let dirX = Float(detCos(cam.pitch) * -detSin(cam.yaw))
        let dirY = Float(detSin(-cam.pitch))
        let dirZ = Float(detCos(cam.pitch) * detCos(cam.yaw))

        // the SAME sky/day-light computation as the Mac — synced worlds
        // look identical at the same moment
        let sky = pebSkyColors(game.world, nightVision: cam.nightVision)
        let dayLight = Float(sky.dayLight)

        let aspect = Float(max(1, resizedW)) / Float(max(1, resizedH))
        // Both of these came from camState and the settings on the Mac and
        // were hard-coded here, which cost two things that look unrelated:
        //
        // the FOV carries the sprint kick (×1.15, eased), the elytra kick and
        // the bow's zoom-in, so pinning it at 70 removed every visual sign
        // that sprinting was happening at all — and made the Options FOV
        // slider do nothing;
        //
        // and a far plane of 800 against a near plane of 0.05 spends the
        // depth buffer's precision on distance nobody can see. The Mac ties
        // it to the render distance, which at the default is 256, and the
        // difference shows up close to the camera as surfaces flickering
        // against each other.
        let far = max(256, Float(game.settings.renderDistance) * 16 * 1.6)
        let proj = mat4fPerspective(fovYRad: Float(cam.fov * .pi / 180),
                                    aspect: aspect, near: 0.05, far: far)
        let view = mat4fLookDir(eyeX: 0, eyeY: 0, eyeZ: 0,
                                dirX: dirX, dirY: dirY, dirZ: dirZ, upX: 0, upY: 1, upZ: 0)
        let viewProj = proj * view
        let fogEnd = Float(game.settings.renderDistance * 16)
        viewProj.m.withUnsafeBufferPointer {
            pb_vk_set_camera($0.baseAddress, xi, eyeY, zi,
                             Float(now - t0), dayLight, Float(game.settings.gamma), 0,
                             fogEnd * 0.65, fogEnd, 0.35,
                             sky.fog.0, sky.fog.1, sky.fog.2)
        }
        pushSky(game, cam, sky)
        // sun shadows: the same gate and the same texel-snapped matrix as the
        // Mac (2048 is SHADOW_SIZE in the Vulkan backend)
        let sun = pebSunDirection(sunAngle: game.world.sunAngle())
        let shadowsOn = pebShadowsOn(game.world, settingOn: game.settings.shadows,
                                     dayLight: sky.dayLight, sunDirY: sun.1)
        if shadowsOn {
            let sm = pebShadowMatrix(sunDir: sun, camX: xi, camY: eyeY, camZ: zi,
                                     shadowSize: 2048)
            sm.m.withUnsafeBufferPointer { pb_vk_set_shadow($0.baseAddress, 1) }
        } else {
            pb_vk_set_shadow(nil, 0)
        }

        // ultra (SSAO + volumetric light) — the Mac's "ultra" shader preset.
        // The 256-byte block the pass marches through; off unless asked for.
        if game.settings.shader == "ultra", let invVP = mat4fInverse(viewProj) {
            let sm = shadowsOn
                ? pebShadowMatrix(sunDir: sun, camX: xi, camY: eyeY, camZ: zi, shadowSize: 2048)
                : Mat4f()
            var block = [Float]()
            block.reserveCapacity(64)
            block.append(contentsOf: invVP.m)
            block.append(contentsOf: viewProj.m)
            block.append(contentsOf: sm.m)
            block.append(contentsOf: [sun.0, sun.1, sun.2, dayLight])
            block.append(contentsOf: [Float(now - t0), far,           // time, far plane
                                      shadowsOn && !cam.underwater ? 1 : 0,
                                      cam.underwater ? 1 : 0])
            block.append(contentsOf: [sky.fog.0, sky.fog.1, sky.fog.2,
                                      Float(game.settings.renderDistance * 16)])
            // the ultra target is half the swapchain in each axis
            block.append(contentsOf: [2 / Float(max(1, resizedW)), 2 / Float(max(1, resizedH)), 0, 0])
            block.withUnsafeBufferPointer { pb_vk_set_ultra(1, $0.baseAddress) }
        } else {
            pb_vk_set_ultra(0, nil)
        }
        // the composite's knobs — the same tints and the same bloom amount
        // the Mac's composite pass uses
        var tint: (Float, Float, Float, Float) = (0, 0, 0, 0)
        if cam.underwater { tint = (0.1, 0.2, 0.45, 0.12) }
        if cam.underLava { tint = (0.9, 0.3, 0.05, 0.55) }
        if cam.powderSnow { tint = (0.95, 0.97, 1.0, 0.5) }
        pb_vk_set_post(game.settings.bloom ? 0.55 : 0,
                       game.settings.reduceMotion ? 0 : Float(cam.portalWarp),
                       Float(now - t0), Float(cam.darkness),
                       tint.0, tint.1, tint.2, tint.3)
        detail.pushLines(game, xi, eyeY, zi, partial: partial)
        detail.pushOverlays(game, camX: xi, camY: eyeY, camZ: zi, partial: partial)
        // the billboard basis comes from the camera, not the player — the same
        // source the Mac uses, so third person stays correct when it lands
        detail.pushParticles(camX: xi, camY: eyeY, camZ: zi, yaw: cam.yaw, pitch: cam.pitch)
        detail.pushSprites(game, camX: xi, camY: eyeY, camZ: zi, yaw: cam.yaw,
                           dayLight: sky.dayLight, partial: partial)
        entityView.frame(game: game, camX: xi, camY: eyeY, camZ: zi,
                         dayLight: dayLight, partial: partial, timeSec: now - t0)
        // the hand goes last, over everything, on the projection alone —
        // and only in first person, like the Mac
        if game.perspective == 0 {
            viewmodel.frame(game: game, proj: proj, dayLight: dayLight)
        } else {
            pb_vk_begin_viewmodel()
        }
        drawUIFrame(ui, hud, game)
        // the Mac clears its scene pass to the fog colour and paints the sky
        // dome over it; where the dome sits out a frame (underwater, lava,
        // blindness) this clear IS the backdrop, exactly as on the Mac
        _ = pb_vk_frame(sky.fog.0, sky.fog.1, sky.fog.2)
    } else {
        pb_vk_begin_entities()
        silenceSky()
        pb_vk_begin_lines()
        pb_vk_begin_viewmodel()
        pb_vk_set_post(0, 0, 0, 0, 0, 0, 0, 0)   // no post on the title screen
        pb_vk_set_shadow(nil, 0)
        pb_vk_set_ultra(0, nil)
        pb_vk_clear_overlay_mesh(0)
        pb_vk_clear_overlay_mesh(1)
        pb_vk_set_particles(nil, 0, nil, nil)
        pb_vk_set_sprites(nil, 0, nil)
        // the Mac's title backdrop: cover-fit photo + the wordmark on top
        // the canvas draws in PIXEL space (beginFrame scales GUI→px), so
        // image quads take pixel coordinates too
        let pw = Double(max(1, resizedW)), ph = Double(max(1, resizedH))
        if let bg = titleBgSize {
            let sA = pw / ph
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
            pb_vk_ui_push_image(0, 0, 0, Float(pw), Float(ph), u0, v0, u1, v1)
        }
        if let lg = titleLogoSize {
            // mirror the Mac's renderTitle: auto-scale space × auto = pixels
            let auto = max(1.0, min((pw / 380).rounded(.down), (ph / 240).rounded(.down)))
            let gw = pw / auto, gh = ph / auto
            let logoH = 52.0
            let logoW = logoH * Double(lg.w) / Double(lg.h)
            pb_vk_ui_push_image(1, Float((gw / 2 - logoW / 2) * auto), Float((gh / 4 - 34) * auto),
                                Float(logoW * auto), Float(logoH * auto), 0, 0, 1, 1)
        }
        drawUIFrame(ui, hud, game)
        _ = pb_vk_frame(0.02, 0.02, 0.05)   // the Mac's title clear color
    }

    // the Mac re-reads the volume sliders once a second; match that so a
    // change in Options takes effect while the screen is still open
    if now - lastVolumePoll >= 1 {
        lastVolumePoll = now
        audioOut.synth.applyVolumes(game.settings.volumes)
    }

    frames += 1
    if now - lastReport >= 5 {
        let p = game.player
        plog(String(format: "%.0f fps, pos %.1f %.1f %.1f, %d sections, screen=%@",
                    Double(frames) / (now - lastReport),
                    p?.x ?? 0, p?.y ?? 0, p?.z ?? 0,
                    Int(pb_vk_section_count()),
                    ui.current().map { String(describing: type(of: $0)) } ?? "none"))
        frames = 0
        lastReport = now
    }
}

plog("closing — saving…")
game.exitToTitle()
audioOut.stop()
pb_vk_destroy()
plog("clean exit")

#else

print("PebbleWin is the Windows client — on this platform, run Pebble instead.")

#endif
