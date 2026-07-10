// Shared smoke-test infrastructure: check counters, hermetic data root,
// golden-file loading, and FNV hashes. Lives in a PebbleCoreBase-only
// target so the deterministic golden suites run on every platform Pebble
// builds for (PORTING module 13).

import Foundation
import PebbleCoreBase
#if os(Windows)
import CRT
#endif

public var passed = 0
public var failed = 0

public func check(_ name: String, _ cond: Bool, _ detail: String = "") {
    if cond {
        passed += 1
        print("  ✓ \(name)")
    } else {
        failed += 1
        print("  ✗ \(name) \(detail)")
    }
}

public func checkD(_ name: String, _ got: Double, _ want: Double, tol: Double = 1e-12) {
    check(name, abs(got - want) <= tol, "got \(got) want \(want)")
}

public func section(_ name: String) { print("\n— \(name)") }

/// set an env var portably — setenv doesn't exist in the Windows CRT
public func smokeSetenv(_ key: String, _ value: String) {
    #if os(Windows)
    _ = _putenv_s(key, value)
    #else
    setenv(key, value, 1)
    #endif
}

// Hermetic data root: unless the caller pinned one, every store (saves,
// settings, social, skins) works under a throwaway temp dir — smoke runs
// must never touch real user data (PORTING modules 04/13).
public func smokeBootstrapDataRoot() {
    if getenv("PEBBLE_DATA_DIR") == nil {
        let root = NSTemporaryDirectory() + "pebsmoke-\(ProcessInfo.processInfo.processIdentifier)"
        smokeSetenv("PEBBLE_DATA_DIR", root)
    }
    print("[smoke] data root: \(vcSupportDir().path)")
}

/// candidate paths for a golden file — `PEBBLE_GOLDENS_DIR` wins (CI pins
/// it explicitly), then goldens/ beside the package manifest, tolerant of
/// being run from the repo root, its parent, or a subdirectory
public func goldenPaths(_ name: String) -> [String] {
    var paths: [String] = []
    if let raw = getenv("PEBBLE_GOLDENS_DIR"), raw.pointee != 0 {
        paths.append(String(cString: raw) + "/" + name)
    }
    paths += ["goldens/\(name)", "../goldens/\(name)", name]
    return paths
}

public func loadJSON(_ name: String) -> [String: Any]? {
    for p in goldenPaths(name) {
        if let d = FileManager.default.contents(atPath: p),
           let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            return obj
        }
    }
    return nil
}

// 1186 baseline items + 2 appended (weeping/twisting vines — their drop
// fns referenced items that never existed; appended at the END so every
// baseline id is unchanged)
public let BASE_ITEM_COUNT = 1186

public func fnvU16(_ arr: [UInt16]) -> UInt32 {
    var h: UInt32 = 2166136261
    for v in arr {
        h = (h ^ UInt32(v & 0xff)) &* 16777619
        h = (h ^ UInt32(v >> 8)) &* 16777619
    }
    return h
}
public func fnvI16(_ arr: [Int16]) -> UInt32 {
    var h: UInt32 = 2166136261
    for s in arr {
        let v = UInt16(bitPattern: s)
        h = (h ^ UInt32(v & 0xff)) &* 16777619
        h = (h ^ UInt32(v >> 8)) &* 16777619
    }
    return h
}
public func fnvU8(_ arr: [UInt8]) -> UInt32 {
    var h: UInt32 = 2166136261
    for b in arr { h = (h ^ UInt32(b)) &* 16777619 }
    return h
}
