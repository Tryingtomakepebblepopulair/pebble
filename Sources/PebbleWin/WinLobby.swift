// The start screen (PORTING module 09, lobby slice): a native Win32 window
// with name/server fields and play buttons — shown before the game window
// unless --join/--solo skip it. Remembers the last entries in
// PebbleData\client.json; picks up PebbleData\skin.png (64×64 PNG) so
// friends see your skin. A textured in-game title screen replaces this
// once the portable UI stack lands (module 08/11).

#if os(Windows)

import WinSDK
import Foundation
import PebbleCoreBase

enum LobbyChoice {
    case single
    case join(host: String, port: UInt16)
    case quit
}

private var lobbyDone: LobbyChoice? = nil
private var editName: HWND?
private var editServer: HWND?

private func readEdit(_ h: HWND?) -> String {
    guard let h else { return "" }
    var buf = [WCHAR](repeating: 0, count: 64)
    GetWindowTextW(h, &buf, 64)
    return String(decodingCString: buf, as: UTF16.self)
}

private let lobbyProc: WNDPROC = { hwnd, msg, wParam, lParam in
    switch Int32(msg) {
    case WM_COMMAND:
        let id = Int32(wParam & 0xFFFF)
        if id == 3 {
            lobbyDone = .single
        } else if id == 4 {
            let addr = readEdit(editServer).trimmingCharacters(in: .whitespaces)
            if !addr.isEmpty {
                let parts = addr.split(separator: ":")
                let host = String(parts[0])
                let port = parts.count > 1 ? UInt16(parts[1]) ?? 25585 : 25585
                lobbyDone = .join(host: host, port: port)
            }
        }
        return 0
    case WM_CLOSE, WM_DESTROY:
        if lobbyDone == nil { lobbyDone = .quit }
        PostQuitMessage(0)
        return 0
    default:
        return DefWindowProcW(hwnd, msg, wParam, lParam)
    }
}

private func makeControl(_ cls: String, _ text: String, _ style: DWORD,
                         _ x: Int32, _ y: Int32, _ w: Int32, _ h: Int32,
                         _ parent: HWND, _ id: Int32) -> HWND? {
    cls.withCString(encodedAs: UTF16.self) { c in
        text.withCString(encodedAs: UTF16.self) { t in
            CreateWindowExW(0, c, t, DWORD(WS_CHILD) | DWORD(WS_VISIBLE) | style,
                            x, y, w, h, parent,
                            HMENU(bitPattern: UInt(bitPattern: Int(id))), nil, nil)
        }
    }
}

/// blocks in its own message loop until the player picks a mode
func runLobby(defaultName: String, defaultServer: String) -> (LobbyChoice, String) {
    let hInst = GetModuleHandleW(nil)
    var lobby: HWND?
    "PebbleLobby".withCString(encodedAs: UTF16.self) { cls in
        var wc = WNDCLASSW()
        wc.lpfnWndProc = lobbyProc
        wc.hInstance = hInst
        wc.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))
        wc.hbrBackground = HBRUSH(bitPattern: UInt(COLOR_BTNFACE + 1))
        wc.lpszClassName = cls
        RegisterClassW(&wc)
        "Pebble".withCString(encodedAs: UTF16.self) { t in
            let sw = GetSystemMetrics(SM_CXSCREEN), sh = GetSystemMetrics(SM_CYSCREEN)
            lobby = CreateWindowExW(0, cls, t,
                                    DWORD(WS_OVERLAPPED) | DWORD(WS_CAPTION) | DWORD(WS_SYSMENU) | DWORD(WS_VISIBLE),
                                    (sw - 400) / 2, (sh - 270) / 2, 400, 270,
                                    nil, nil, hInst, nil)
        }
    }
    guard let lobby else { return (.single, defaultName) }

    _ = makeControl("STATIC", "PEBBLE", DWORD(SS_CENTER), 20, 15, 340, 28, lobby, 0)
    _ = makeControl("STATIC", "Naam:", 0, 30, 60, 90, 20, lobby, 0)
    editName = makeControl("EDIT", defaultName, DWORD(WS_BORDER) | DWORD(ES_AUTOHSCROLL),
                           130, 58, 220, 24, lobby, 1)
    _ = makeControl("STATIC", "Server (ip:poort):", 0, 30, 95, 95, 20, lobby, 0)
    editServer = makeControl("EDIT", defaultServer, DWORD(WS_BORDER) | DWORD(ES_AUTOHSCROLL),
                             130, 93, 220, 24, lobby, 2)
    _ = makeControl("BUTTON", "Speel alleen", 0, 45, 145, 140, 34, lobby, 3)
    _ = makeControl("BUTTON", "Join wereld", 0, 205, 145, 140, 34, lobby, 4)
    _ = makeControl("STATIC", "Tip: leg een skin.png (64×64) in PebbleData\\", 0, 30, 195, 330, 20, lobby, 0)

    var msg = MSG()
    while lobbyDone == nil, GetMessageW(&msg, nil, 0, 0) {
        // let Tab move between fields like a real dialog
        if IsDialogMessageW(lobby, &msg) { continue }
        TranslateMessage(&msg)
        DispatchMessageW(&msg)
    }
    let name = readEdit(editName).trimmingCharacters(in: .whitespaces)
    let choice = lobbyDone ?? .quit
    DestroyWindow(lobby)
    // drain the queue so the game window starts clean
    while PeekMessageW(&msg, nil, 0, 0, UINT(PM_REMOVE)) {
        TranslateMessage(&msg)
        DispatchMessageW(&msg)
    }
    return (choice, name.isEmpty ? defaultName : name)
}

// ---- remembered lobby entries + skin -------------------------------------------

struct ClientPrefs: Codable {
    var name = "Speler"
    var server = ""
}

func loadClientPrefs() -> ClientPrefs {
    let url = vcSupportDir().appendingPathComponent("client.json")
    if let d = try? Data(contentsOf: url),
       let p = try? JSONDecoder().decode(ClientPrefs.self, from: d) {
        return p
    }
    return ClientPrefs()
}

func saveClientPrefs(_ p: ClientPrefs) {
    let url = vcSupportDir().appendingPathComponent("client.json")
    if let d = try? JSONEncoder().encode(p) {
        try? d.write(to: url)
    }
}

/// PebbleData\skin.png → the hello blob (friends see it) — 64×64 only
func loadSkinBlob() -> Data {
    let url = vcSupportDir().appendingPathComponent("skin.png")
    guard let d = try? Data(contentsOf: url) else { return Data() }
    guard let img = pebDecodePNG(d), img.width == 64, img.height == 64 else {
        plog("skin.png ignored: not a 64×64 PNG")
        return Data()
    }
    plog("using custom skin from skin.png")
    return d
}

#endif
