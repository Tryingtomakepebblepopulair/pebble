// PebbleWin — the Windows client shell (PORTING modules 09/07, bootstrap
// slice): a Win32 window + message pump driving the C Vulkan backend. This
// first artifact proves the whole risky foundation on real hardware:
// window, input pump, Vulkan instance/device/swapchain, vsync present.
// It clears the window with Pebble's animated day-cycle sky. World and UI
// rendering land next session; everything logs to pebble-log.txt.

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

plog("Pebble \(PEBBLE_VERSION) — Windows bootstrap (Vulkan clear + day-sky)")

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

// ---- main loop: pump messages, present the animated day sky --------------------
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
    // one Pebble day in 60 seconds: night → dawn → noon → dusk
    let t = (monotonicNow() - t0) / 60.0
    let day = 0.5 - 0.5 * cos(t * 2 * .pi)         // 0 = midnight, 1 = noon
    let dawn = max(0.0, 1.0 - abs(sin(t * 2 * .pi)) * 3) * 0.5
    let r = Float(0.02 + 0.50 * day + 0.45 * dawn)
    let g = Float(0.03 + 0.63 * day + 0.20 * dawn)
    let b = Float(0.08 + 0.82 * day)
    _ = pb_vk_frame(r, g, b)
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
