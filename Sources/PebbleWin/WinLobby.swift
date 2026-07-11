// Windows shell helpers. The old native-dialog lobby is gone — the REAL
// Pebble title screen (shared with the Mac) handles everything now.

#if os(Windows)

import Foundation
import PebbleCoreBase

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
