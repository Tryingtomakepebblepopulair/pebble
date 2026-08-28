// Starting up, and surviving not starting up. Everything here runs before the
// window exists, and every piece of it exists because of the same two
// complaints: Pebble sometimes vanishes, and the Pebble you start afterwards
// behaves like a different game.
//
// The second complaint had the simpler cause. Worlds, settings and the
// texture pack were all resolved against the CURRENT WORKING DIRECTORY, which
// is only the folder holding Pebble.exe when Explorer happens to launch it
// that way. From a shortcut, from a terminal, from the "restart" button on a
// crash dialog, or from inside the downloaded zip, the working directory is
// somewhere else entirely — so Pebble made a second, empty PebbleData, found
// no resource pack, and looked to a player exactly like a game that had
// forgotten everything. Now every path hangs off the exe itself.
//
// The first complaint gets what it needs to be diagnosed: the log survives
// the restart that used to overwrite it, Swift's own crash text is captured
// into it, and an unhandled exception writes down what it was instead of
// closing the window.

#if os(Windows)

import WinSDK
import CRT
import Foundation
import PebbleCoreBase

// ---- where we are ------------------------------------------------------------

/// The folder Pebble.exe lives in. Not the working directory: those two agree
/// only some of the time, and the times they disagree are the bug reports.
func exeDir() -> String {
    var buf = [UInt16](repeating: 0, count: 32768)
    let n = GetModuleFileNameW(nil, &buf, DWORD(buf.count))
    guard n > 0 else { return FileManager.default.currentDirectoryPath }
    let full = String(decodingCString: buf, as: UTF16.self)
    guard let cut = full.lastIndex(of: "\\") else { return full }
    return String(full[full.startIndex..<cut])
}

/// can we actually create files here? Program Files, a network share and the
/// temp folder Explorer unpacks a zip into all say no
private func canWrite(_ dir: String) -> Bool {
    let fm = FileManager.default
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { return false }
    let probe = dir + "\\.pebble-write-test"
    guard fm.createFile(atPath: probe, contents: Data([0])) else { return false }
    try? fm.removeItem(atPath: probe)
    return true
}

/// PebbleData beside the exe when that folder is writable, %LOCALAPPDATA%
/// otherwise — so a Pebble unzipped into Program Files keeps its worlds
/// instead of losing them to a folder Windows silently refuses to write.
func chooseDataRoot() -> (path: String, why: String) {
    if let raw = getenv("PEBBLE_DATA_DIR"), raw.pointee != 0 {
        return (String(cString: raw), "PEBBLE_DATA_DIR")
    }
    let beside = exeDir() + "\\PebbleData"
    if canWrite(beside) { return (beside, "beside Pebble.exe") }
    if let local = ProcessInfo.processInfo.environment["LOCALAPPDATA"], !local.isEmpty {
        let fallback = local + "\\Pebble"
        if canWrite(fallback) {
            return (fallback, "AppData — the folder holding Pebble.exe is read-only")
        }
    }
    return (beside, "beside Pebble.exe (and it is not writable — saving will fail)")
}

// ---- the log -------------------------------------------------------------------

private var logFile: UnsafeMutablePointer<FILE>?
private(set) var logPath = "pebble-log.txt"

func plog(_ s: String) {
    print(s)
    if let logFile {
        fputs(s + "\r\n", logFile)
        fflush(logFile)
    }
}

/// Opens the log beside the exe, keeping the previous run's as
/// pebble-log-prev.txt.
///
/// This used to truncate on every launch, which meant the restart after a
/// crash destroyed the only record of the crash — and the restart is the
/// first thing anybody does. Swift's own trap messages (a nil unwrap, an
/// index out of range) go to stderr, so stderr is pointed at the same file:
/// without that the log ends mid-sentence and never says why.
func openLog(dataRoot: String) {
    let fm = FileManager.default
    let dir = canWrite(exeDir()) ? exeDir() : dataRoot
    logPath = dir + "\\pebble-log.txt"
    let prev = dir + "\\pebble-log-prev.txt"
    if fm.fileExists(atPath: logPath) {
        try? fm.removeItem(atPath: prev)
        try? fm.moveItem(atPath: logPath, toPath: prev)
    }
    logFile = logPath.withCString(encodedAs: UTF16.self) { path in
        "w".withCString(encodedAs: UTF16.self) { mode in _wfopen(path, mode) }
    }
    if let logFile { _ = _dup2(_fileno(logFile), 2) }   // Swift's traps land here too
}

// ---- one Pebble at a time ------------------------------------------------------

private var instanceMutex: HANDLE?

/// Two Pebbles sharing one PebbleData is the other half of "it goes strange
/// after a restart": when the window freezes, the process is often still
/// alive, and the copy started next to it writes the same worlds, the same
/// settings and the same player file. Whichever exits last wins, and the
/// result looks like a corrupted save.
///
/// The claim is over the DATA ROOT, not over Pebble — two clients with
/// different PEBBLE_DATA_DIRs (host and guest on one machine, which is how
/// LAN gets tested) still both run.
func claimDataRoot(_ root: String) -> Bool {
    var h: UInt64 = 0xcbf2_9ce4_8422_2325          // FNV-1a: a name, not a secret
    for b in root.lowercased().utf8 {
        h = (h ^ UInt64(b)) &* 0x1000_0000_01b3
    }
    let name = "Local\\Pebble-" + String(h, radix: 16)
    var alreadyRunning = false
    instanceMutex = name.withCString(encodedAs: UTF16.self) { n -> HANDLE? in
        let handle = CreateMutexW(nil, true, n)
        // GetLastError has to be read HERE, on the next line, with nothing
        // in between. It was being read after the closure returned and after
        // a store to a global — and any of that may make a Win32 call of its
        // own and replace the code we came for. Reading a stale
        // ERROR_ALREADY_EXISTS means Pebble refuses to start, closes itself,
        // and never says why.
        alreadyRunning = GetLastError() == DWORD(ERROR_ALREADY_EXISTS)
        return handle
    }
    guard instanceMutex != nil else { return true }   // no mutex, no opinion
    if !alreadyRunning { return true }

    // Somebody holds it. Only refuse if we can actually put their window in
    // front of the player: a mutex held by a process with no window is a
    // zombie we cannot point at, and "Pebble closed itself and said nothing"
    // is a worse outcome than the double-write this guards against.
    guard focusRunningPebble() else {
        plog("data root claimed by a process with no window — starting anyway")
        return true
    }
    return false
}

/// bring the Pebble that is already running to the front. False when there is
/// no such window to find.
@discardableResult
func focusRunningPebble() -> Bool {
    guard let hwnd = ("PebbleWindow".withCString(encodedAs: UTF16.self) { FindWindowW($0, nil) })
    else { return false }
    if IsIconic(hwnd) { ShowWindow(hwnd, SW_RESTORE) }
    SetForegroundWindow(hwnd)
    return true
}

/// a plain message box — no "FATAL", because not everything worth saying is
func notice(_ text: String) {
    plog(text.replacingOccurrences(of: "\n", with: " "))
    "Pebble".withCString(encodedAs: UTF16.self) { title in
        text.withCString(encodedAs: UTF16.self) { body in
            _ = MessageBoxW(nil, body, title, UINT(MB_OK | MB_ICONINFORMATION))
        }
    }
}

// ---- crashes -------------------------------------------------------------------

/// what Windows means by the code in the crash log, in words
private func exceptionName(_ code: DWORD) -> String {
    switch code {
    case 0xC000_0005: return "access violation — read or wrote memory it doesn't own"
    case 0xC000_001D: return "illegal instruction — usually a Swift trap (nil, or an index past the end)"
    case 0xC000_0094: return "integer divide by zero"
    case 0xC000_0096: return "privileged instruction"
    case 0xC000_00FD: return "stack overflow — runaway recursion"
    case 0xC000_0374: return "heap corruption"
    case 0x8000_0003: return "breakpoint"
    case 0xE06D_7363: return "C++ exception (the Vulkan loader or a driver)"
    default: return "see https://learn.microsoft.com/windows/win32/debug/getexceptioncode"
    }
}

private let crashFilter: @convention(c) (UnsafeMutablePointer<EXCEPTION_POINTERS>?) -> LONG = { info in
    let rec = info?.pointee.ExceptionRecord?.pointee
    let code = rec?.ExceptionCode ?? 0
    let addr = UInt(bitPattern: rec?.ExceptionAddress)
    plog("")
    plog("=== CRASH ===============================================")
    plog(String(format: "exception 0x%08X at 0x%016llX", code, UInt64(addr)))
    plog(exceptionName(code))
    plog("=========================================================")
    notice("""
        Pebble crashed.

        \(exceptionName(code))

        The world was saved at the last autosave — up to a minute of \
        building may be gone, but nothing else is.

        What happened is written down in:
        \(logPath)

        The run before this one is still there too, as pebble-log-prev.txt. \
        Send both, and say what you were doing.
        """)
    return LONG(EXCEPTION_EXECUTE_HANDLER)
}

/// Turn a vanishing window into a sentence. Without this the process simply
/// disappears: no message, and a log that stops mid-frame with no reason in
/// it — which is every crash report Pebble has ever received from Windows.
func installCrashHandler() {
    SetUnhandledExceptionFilter(crashFilter)
    // a crash inside the handler must not summon Windows' own "checking for a
    // solution" dialog on top of ours
    SetErrorMode(UINT(SEM_NOGPFAULTERRORBOX))
}

#endif
