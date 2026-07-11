// PebbleWin — the playable Windows client (PORTING modules 09/07).
// A Win32 window + message pump around the REAL GameCore: the same
// simulation, worldgen, saves, and multiplayer sessions as the Mac build —
// GameCore even does its own chunk streaming and meshing; this shell just
// feeds input and forwards finished meshes to the Vulkan backend.
//
//   Pebble.exe                     singleplayer (world saved in .\PebbleData)
//   Pebble.exe --new [--seed x]    start a fresh world
//   Pebble.exe --join <ip[:port]> [--name <naam>]   join a friend's world
//
// Controls: click = capture mouse · WASD/space/shift/ctrl · left dig,
// right place · 1-9 hotbar · Q drop · F offhand · Esc releases the mouse.
// No audio and no menus yet (those modules come next); pebble-log.txt
// records everything.

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
var playerName = "Speler"
var seedText = ""
var forceNew = false
var skipLobby = false
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
            playerName = String(args[i + 1].prefix(16))
            i += 1
        case "--seed" where i + 1 < args.count:
            seedText = args[i + 1]
            i += 1
        case "--new":
            forceNew = true
        case "--solo":
            skipLobby = true
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

// ---- lobby ----------------------------------------------------------------------
if joinTarget == nil && !skipLobby && !forceNew {
    var prefs = loadClientPrefs()
    if playerName == "Speler" { playerName = prefs.name }
    let (choice, chosenName) = runLobby(defaultName: playerName, defaultServer: prefs.server)
    playerName = chosenName
    switch choice {
    case .quit:
        exit(0)
    case .single:
        break
    case .join(let h, let prt):
        joinTarget = (h, prt)
        prefs.server = prt == 25585 ? h : "\(h):\(prt)"
    }
    prefs.name = playerName
    saveClientPrefs(prefs)
}

// ---- window + input -------------------------------------------------------------
var resizedW: Int32 = 1280
var resizedH: Int32 = 760
var gGame: GameCore?
var gCaptured = false
var gHwnd: HWND?

func setCapture(_ on: Bool) {
    if on == gCaptured { return }
    gCaptured = on
    ShowCursor(on ? false : true)
    if !on, let g = gGame {
        for k in worldSafeKeys { g.keyUp(k) }   // no stuck movement keys
    }
    if on { recenterCursor() }
}

func recenterCursor() {
    guard let hwnd = gHwnd else { return }
    var r = RECT()
    GetClientRect(hwnd, &r)
    var c = POINT(x: (r.right - r.left) / 2, y: (r.bottom - r.top) / 2)
    ClientToScreen(hwnd, &c)
    SetCursorPos(c.x, c.y)
}

let wndProc: WNDPROC = { hwnd, msg, wParam, lParam in
    switch Int32(msg) {
    case WM_SIZE:
        resizedW = Int32(UInt16(truncatingIfNeeded: lParam))
        resizedH = Int32(UInt16(truncatingIfNeeded: lParam >> 16))
        pb_vk_resize(resizedW, resizedH)
        return 0
    case WM_KEYDOWN:
        if (lParam & (1 << 30)) == 0 {   // ignore auto-repeat
            if Int32(wParam) == VK_ESCAPE {
                setCapture(false)
            } else if let name = pebKeyName(wParam, lParam), worldSafeKeys.contains(name) {
                gGame?.keyDown(name, now: nowMs())
            }
        }
        return 0
    case WM_KEYUP:
        if let name = pebKeyName(wParam, lParam), worldSafeKeys.contains(name) {
            gGame?.keyUp(name)
        }
        return 0
    case WM_LBUTTONDOWN:
        if gCaptured { gGame?.mouseDown(0) } else { setCapture(true) }
        return 0
    case WM_LBUTTONUP:
        if gCaptured { gGame?.mouseUp(0) }
        return 0
    case WM_RBUTTONDOWN:
        if gCaptured { gGame?.mouseDown(2) }
        return 0
    case WM_RBUTTONUP:
        if gCaptured { gGame?.mouseUp(2) }
        return 0
    case WM_MBUTTONDOWN:
        if gCaptured { gGame?.mouseDown(1) }
        return 0
    case WM_MBUTTONUP:
        if gCaptured { gGame?.mouseUp(1) }
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

// ---- the game -------------------------------------------------------------------
let game = GameCore()
gGame = game
let host = WinHost()
game.host = host
let entityView = EntityView()
if !playerName.isEmpty { game.settings.playerName = playerName }

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

if let target = joinTarget {
    plog("joining \(target.host):\(target.port) as \(playerName)…")
    _ = game.joinLan(socketDial(host: target.host, port: target.port),
                     name: playerName, skin: loadSkinBlob())
    var waited = 0
    while !game.hasWorld() && waited < 900 {   // ~15s
        _ = game.frame(dtMs: 16)
        RunLoop.main.run(until: Date().addingTimeInterval(0.016))
        waited += 1
        if game.netGuest == nil { break }      // connection died
    }
    if !game.hasWorld() {
        alert("Kon niet joinen: \(game.netGuest?.status ?? "verbinding mislukt").\n"
            + "Check het IP-adres en of de wereld open staat (Open to LAN / pebserver).")
        exit(1)
    }
    plog("joined! world streaming in…")
} else {
    let existing = game.listWorlds().first { $0.name == "Windows Wereld" }
    if let rec = existing, !forceNew {
        plog("loading world '\(rec.name)' (seed \(rec.seed))")
        game.loadWorld(rec.id)
    } else {
        plog("creating a fresh world…")
        game.createWorld(name: "Windows Wereld", seedText: seedText, mode: 0, difficulty: 2)
    }
    if !game.hasWorld() {
        alert("could not open the world (data root: \(vcSupportDir().path))")
        exit(1)
    }
}

// ---- sky colors (Mac skyState constants) -----------------------------------------
func dayCurve(_ dayTime: Int) -> Double {
    let t = Double(dayTime % DAY_LENGTH)
    if t < 11000 { return 1 }
    if t < 13000 { return 1 - (t - 11000) / 2000 }
    if t < 22000 { return 0 }
    return (t - 22000) / 2000
}

// ---- main loop --------------------------------------------------------------------
plog("entering the world — click the window to grab the mouse, Esc to release")
let t0 = monotonicNow()
var lastFrame = t0
var frames = 0
var lastReport = t0
var deathAt: Double? = nil
var msg = MSG()

mainLoop: while true {
    while PeekMessageW(&msg, nil, 0, 0, UINT(PM_REMOVE)) {
        if msg.message == UINT(WM_QUIT) { break mainLoop }
        TranslateMessage(&msg)
        DispatchMessageW(&msg)
    }
    // drain the main queue: chunk generation + finished meshes publish here
    RunLoop.main.run(until: Date())

    // relative mouse look while captured
    if gCaptured, game.hasWorld() {
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

    // the shell owns what screens would: death → auto-respawn after 2.5s
    if host.deathMessage != nil {
        if deathAt == nil {
            deathAt = now
            plog("you died — respawning…")
        } else if now - (deathAt ?? now) > 2.5 {
            game.respawnPlayer()
            host.deathMessage = nil
            deathAt = nil
        }
    }
    if host.wantsPointerRelease {
        host.wantsPointerRelease = false
        setCapture(false)
    }

    // camera + sky
    if game.hasWorld(), let p = game.player {
        let xi = p.prevX + (p.x - p.prevX) * partial
        let yi = p.prevY + (p.y - p.prevY) * partial
        let zi = p.prevZ + (p.z - p.prevZ) * partial
        let eyeY = yi + (p.eyeY() - p.y)
        let dirX = Float(detCos(p.pitch) * -detSin(p.yaw))
        let dirY = Float(detSin(-p.pitch))
        let dirZ = Float(detCos(p.pitch) * detCos(p.yaw))

        let day = dayCurve(game.world.dayTime)
        let dayLight = Float(max(0.06, day))
        let d = Float(day)
        let zen = (0.012 + (0.45 - 0.012) * d, 0.015 + (0.65 - 0.015) * d, 0.04 + (1.0 - 0.04) * d)
        let hor = (0.04 + (0.74 - 0.04) * d, 0.05 + (0.84 - 0.05) * d, 0.1 + (1.0 - 0.1) * d)

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
                             hor.0, hor.1, hor.2)
        }
        entityView.frame(game: game, camX: xi, camY: eyeY, camZ: zi,
                         dayLight: dayLight, partial: partial)
        _ = pb_vk_frame(zen.0, zen.1, zen.2)
    } else {
        pb_vk_begin_entities()
        _ = pb_vk_frame(0.25, 0.4, 0.7)   // streaming in — plain sky
    }

    frames += 1
    if now - lastReport >= 5 {
        let p = game.player
        plog(String(format: "%.0f fps, pos %.1f %.1f %.1f, %@",
                    Double(frames) / (now - lastReport),
                    p?.x ?? 0, p?.y ?? 0, p?.z ?? 0,
                    gCaptured ? "mouse captured" : "click to play"))
        frames = 0
        lastReport = now
    }
}

plog("closing — saving world…")
game.exitToTitle()   // saves (and says goodbye to the host when joined)
pb_vk_destroy()
plog("clean exit")

#else

print("PebbleWin is the Windows client — on this platform, run Pebble instead.")

#endif
