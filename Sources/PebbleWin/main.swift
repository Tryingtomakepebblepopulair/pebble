// PebbleWin — the Windows client (PORTING modules 09/07, world slice): a
// Win32 window + message pump driving the C Vulkan backend. This artifact
// generates real Pebble terrain (same worldgen the goldens pin), meshes it
// with the shared mesher, uploads the procedural atlas, and orbits a camera
// over the world through a day/night cycle. Input + multiplayer join land
// in the next slice. Everything logs to pebble-log.txt.

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

plog("Pebble \(PEBBLE_VERSION) — Windows world demo (Vulkan)")

// ---- window ------------------------------------------------------------------
var resizedW: Int32 = 1280
var resizedH: Int32 = 760

let wndProc: WNDPROC = { hwnd, msg, wParam, lParam in
    switch Int32(msg) {
    case WM_SIZE:
        resizedW = Int32(UInt16(truncatingIfNeeded: lParam))
        resizedH = Int32(UInt16(truncatingIfNeeded: lParam >> 16))
        pb_vk_resize(resizedW, resizedH)
        return 0
    case WM_DESTROY:
        PostQuitMessage(0)
        return 0
    default:
        return DefWindowProcW(hwnd, msg, wParam, lParam)
    }
}

let hInstance = GetModuleHandleW(nil)
var hwnd: HWND? = nil
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
        hwnd = CreateWindowExW(0, className, title,
                               DWORD(WS_OVERLAPPEDWINDOW) | DWORD(WS_VISIBLE),
                               CW_USEDEFAULT, CW_USEDEFAULT, 1280, 760,
                               nil, nil, hInstance, nil)
    }
}
guard let hwnd else {
    alert("could not create the game window (error \(GetLastError()))")
    exit(1)
}
plog("window created (1280x760)")

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

// ---- the world: same registries, worldgen, and mesher the goldens pin ----------
let tGen0 = monotonicNow()
registerAllBlocks()
registerAllItems()
registerAllBiomes()

let atlas = buildAtlas()
var flatAtlas = [UInt8]()
flatAtlas.reserveCapacity(atlas.count * TILE * TILE * 4)
for px in atlas.pixels { flatAtlas.append(contentsOf: px) }
let atlasOK = flatAtlas.withUnsafeBufferPointer {
    pb_vk_upload_atlas($0.baseAddress, Int32(TILE), Int32(TILE), Int32(atlas.count))
}
if atlasOK != 0 {
    alert("atlas upload failed: \(String(cString: pb_vk_last_error()))")
    exit(1)
}
plog("atlas uploaded: \(atlas.count) tiles (\(TILE)×\(TILE))")

let SEED: UInt32 = 424242
let RADIUS = 3   // chunks each way — 7×7 island of terrain

struct LitChunk {
    let blocks: [UInt16]
    let sky: [UInt8]
    let blk: [UInt8]
    let biomes: [UInt8]
}
var litCache: [String: LitChunk] = [:]
func litChunk(_ cx: Int, _ cz: Int) -> LitChunk {
    let key = "\(cx),\(cz)"
    if let c = litCache[key] { return c }
    let out = generateOverworldChunk(SEED, cx, cz)
    let light = computeLocalLight(blocks: out.blocks, height: WORLD_H, hasSky: true)
    let c = LitChunk(blocks: out.blocks, sky: light.sky, blk: light.blk, biomes: out.biomes)
    litCache[key] = c
    return c
}
func chunkBiomeAt(_ c: LitChunk, _ lx: Int, _ y: Int, _ lz: Int) -> UInt8 {
    let qy = max(0, min((WORLD_H >> 2) - 1, (y - GEN_MIN_Y) >> 2))
    return c.biomes[(qy * 4 + (lz >> 2)) * 4 + (lx >> 2)]
}

/// 18³ snapshot around one 16³ section (same shape the mesher smoke uses)
func buildSnapshot(_ cx: Int, _ sy: Int, _ cz: Int) -> MeshInput {
    let P = 18
    var blocks = [UInt16](repeating: 0, count: P * P * P)
    var skyLight = [UInt8](repeating: 0, count: P * P * P)
    var blockLight = [UInt8](repeating: 0, count: P * P * P)
    var biomes = [UInt8](repeating: 0, count: P * P)
    let baseY = GEN_MIN_Y + sy * 16
    let baseX = cx * 16, baseZ = cz * 16
    for dz in -1...16 {
        for dx in -1...16 {
            let wx = baseX + dx, wz = baseZ + dz
            let c = litChunk(floorDiv(wx, 16), floorDiv(wz, 16))
            let lx = posMod(wx, 16), lz = posMod(wz, 16)
            biomes[(dz + 1) * P + (dx + 1)] = chunkBiomeAt(c, lx, min(GEN_MIN_Y + WORLD_H - 1, max(GEN_MIN_Y, baseY + 8)), lz)
            for dy in -1...16 {
                let wy = baseY + dy
                let idx = ((dy + 1) * P + (dz + 1)) * P + (dx + 1)
                if wy < GEN_MIN_Y || wy >= GEN_MIN_Y + WORLD_H {
                    blocks[idx] = 0
                    skyLight[idx] = wy >= GEN_MIN_Y + WORLD_H ? 15 : 0
                    blockLight[idx] = 0
                } else {
                    let ci = ((wy - GEN_MIN_Y) * 16 + lz) * 16 + lx
                    blocks[idx] = c.blocks[ci]
                    skyLight[idx] = c.sky[ci]
                    blockLight[idx] = c.blk[ci]
                }
            }
        }
    }
    return MeshInput(blocks: blocks, skyLight: skyLight, blockLight: blockLight, biomes: biomes)
}

func sectionHasBlocks(_ c: LitChunk, _ sy: Int) -> Bool {
    let base = sy * 16 * 256
    for i in base..<min(base + 16 * 256, c.blocks.count) where c.blocks[i] != 0 { return true }
    return false
}

var sectionCount = 0
var vertexTotal = 0
for cz in -RADIUS...RADIUS {
    for cx in -RADIUS...RADIUS {
        let c = litChunk(cx, cz)
        for sy in 0..<(WORLD_H / 16) {
            if !sectionHasBlocks(c, sy) { continue }
            let mesh = buildSectionMesh(buildSnapshot(cx, sy, cz))
            let id = UInt64(bitPattern: Int64((Int64(cx + 512) << 40) | (Int64(cz + 512) << 20) | Int64(sy)))
            let ox = Double(cx * 16), oy = Double(GEN_MIN_Y + sy * 16), oz = Double(cz * 16)
            for (pass, layer) in [(0, mesh.opaque), (1, mesh.cutout), (2, mesh.translucent)] {
                if layer.count == 0 { continue }
                let rc = layer.data.withUnsafeBufferPointer { vp in
                    layer.idx.withUnsafeBufferPointer { ip in
                        pb_vk_upload_section(id, Int32(pass), ox, oy, oz,
                                             vp.baseAddress, Int32(layer.count),
                                             ip.baseAddress, Int32(layer.idx.count))
                    }
                }
                if rc != 0 {
                    alert("mesh upload failed: \(String(cString: pb_vk_last_error()))")
                    exit(1)
                }
                vertexTotal += layer.count
            }
            sectionCount += 1
        }
    }
}
plog(String(format: "world ready: %d chunks, %d sections, %d vertices in %.1fs",
            (2 * RADIUS + 1) * (2 * RADIUS + 1), sectionCount, vertexTotal, monotonicNow() - tGen0))

// camera focus: the terrain surface at the center column
let center = litChunk(0, 0)
var topY = 80
var yy = WORLD_H - 1
scan: while yy > 0 {
    if center.blocks[(yy * 16 + 8) * 16 + 8] != 0 { topY = yy + GEN_MIN_Y; break scan }
    yy -= 1
}
plog("surface at y=\(topY); orbiting camera engaged")

// ---- main loop: orbit the world through a day cycle ----------------------------
let t0 = monotonicNow()
var frames = 0
var lastReport = t0
var msg = MSG()
mainLoop: while true {
    while PeekMessageW(&msg, nil, 0, 0, UINT(PM_REMOVE)) {
        if msg.message == UINT(WM_QUIT) { break mainLoop }
        TranslateMessage(&msg)
        DispatchMessageW(&msg)
    }
    let t = monotonicNow() - t0
    // one Pebble day in 120 seconds, starting mid-morning
    let dayPhase = 0.25 + t / 120.0
    let dayLight = Float(max(0.02, 0.5 - 0.5 * cos(dayPhase * 2 * .pi)))
    let skyR = 0.02 + 0.50 * dayLight
    let skyG = 0.03 + 0.63 * dayLight
    let skyB = 0.08 + 0.82 * dayLight

    let angle = Float(t) * 0.12
    let eyeX = Double(cos(angle)) * 42 + 8
    let eyeZ = Double(sin(angle)) * 42 + 8
    let eyeY = Double(topY) + 22
    let dirX = Float(8 - eyeX), dirY = Float(Double(topY) + 2 - eyeY), dirZ = Float(8 - eyeZ)

    let aspect = Float(max(1, resizedW)) / Float(max(1, resizedH))
    let proj = mat4fPerspective(fovYRad: 70 * .pi / 180, aspect: aspect, near: 0.05, far: 600)
    let view = mat4fLookDir(eyeX: 0, eyeY: 0, eyeZ: 0,
                            dirX: dirX, dirY: dirY, dirZ: dirZ,
                            upX: 0, upY: 1, upZ: 0)
    let viewProj = proj * view
    viewProj.m.withUnsafeBufferPointer {
        pb_vk_set_camera($0.baseAddress, eyeX, eyeY, eyeZ,
                         Float(t), dayLight, 0, 0,
                         70, 115, 0.5,
                         Float(skyR), Float(skyG), Float(skyB))
    }
    _ = pb_vk_frame(Float(skyR), Float(skyG), Float(skyB))
    frames += 1
    let now = monotonicNow()
    if now - lastReport >= 5 {
        plog(String(format: "%.0f fps (vsync), %dx%d", Double(frames) / (now - lastReport),
                    resizedW, resizedH))
        frames = 0
        lastReport = now
    }
}

pb_vk_destroy()
plog("clean exit")

#else

print("PebbleWin is the Windows client — on this platform, run Pebble instead.")

#endif
