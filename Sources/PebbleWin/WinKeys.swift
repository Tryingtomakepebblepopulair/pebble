// Win32 virtual-key codes → Pebble's internal key-code strings (the same
// ones the macOS NSEvent layer produces, so keybinds.json stays portable —
// PORTING module 09 input contract).

#if os(Windows)

import WinSDK

func pebKeyName(_ vk: WPARAM, _ lParam: LPARAM) -> String? {
    let v = Int32(vk)
    switch v {
    case 0x41...0x5A:   // A..Z
        return "Key" + String(UnicodeScalar(UInt8(v)))
    case 0x30...0x39:   // 0..9
        return "Digit" + String(UnicodeScalar(UInt8(v)))
    case VK_SPACE: return "Space"
    case VK_ESCAPE: return "Escape"
    case VK_RETURN: return "Enter"
    case VK_TAB: return "Tab"
    case VK_BACK: return "Backspace"
    case VK_UP: return "ArrowUp"
    case VK_DOWN: return "ArrowDown"
    case VK_LEFT: return "ArrowLeft"
    case VK_RIGHT: return "ArrowRight"
    case VK_OEM_2: return "Slash"
    case VK_OEM_MINUS: return "Minus"
    case VK_OEM_PLUS: return "Equal"
    case VK_F1...VK_F12:
        return "F\(v - VK_F1 + 1)"
    case VK_SHIFT:
        // distinguish left/right via the scancode in lParam
        let scan = UInt32((lParam >> 16) & 0xFF)
        return scan == 0x36 ? "ShiftRight" : "ShiftLeft"
    case VK_CONTROL:
        return (lParam & (1 << 24)) != 0 ? "ControlRight" : "ControlLeft"
    case VK_MENU:
        return (lParam & (1 << 24)) != 0 ? "AltRight" : "AltLeft"
    default:
        return nil
    }
}

/// keys the world/player may see — screens (inventory, chat, pause) have no
/// portable UI yet, so keys that would open one stay client-side for now
let worldSafeKeys: Set<String> = [
    "KeyW", "KeyA", "KeyS", "KeyD",       // move
    "Space",                              // jump
    "ShiftLeft", "ShiftRight",            // sneak
    "ControlLeft", "ControlRight",        // sprint
    "Digit1", "Digit2", "Digit3", "Digit4", "Digit5",
    "Digit6", "Digit7", "Digit8", "Digit9",   // hotbar
    "KeyQ",                               // drop
    "KeyF",                               // swap offhand
]

#endif
