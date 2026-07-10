// pebserver — a standalone Pebble world server (SMP-style). Runs a world
// headless at 20 TPS with no host player: friends join over LAN (Bonjour,
// macOS) or the internet (direct IP, every platform), and the world keeps
// running until you stop it. Portable: builds on macOS and Windows
// (PORTING module 12).
//
//   pebserver                          list worlds and usage
//   pebserver "My World"               serve an existing world (name or id)
//   pebserver --create "SMP" [--seed x] [--creative]
//   pebserver "My World" --port 25585
//   pebserver ... --port 0             pick a free port (prints READY line)
//   pebserver ... --data-dir <path>    keep worlds under a different folder
//
// Console commands while running: list, say <msg>, save, stop

import Foundation
import Dispatch
#if canImport(PebbleCore)
import PebbleCore
#else
import PebbleCoreBase
#endif
#if os(Windows)
import WinSDK
#endif

setbuf(stdout, nil)
#if canImport(PebbleCore)
installAppleNetTransport()   // macOS servers advertise on Bonjour too
#endif

// ---- tiny arg parser --------------------------------------------------------
let rawArgs = Array(CommandLine.arguments.dropFirst())
var flags: [String: String] = [:]
var switches = Set<String>()
var positional: [String] = []
var i = 0
while i < rawArgs.count {
    let a = rawArgs[i]
    if a == "--creative" || a == "--help" || a == "-h" {
        switches.insert(a)
    } else if a.hasPrefix("--") {
        if i + 1 < rawArgs.count {
            flags[a] = rawArgs[i + 1]
            i += 1
        }
    } else {
        positional.append(a)
    }
    i += 1
}

func stamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f.string(from: Date())
}
func log(_ s: String) {
    // strip §-color codes for the console
    var out = ""
    var skip = false
    for ch in s {
        if skip { skip = false; continue }
        if ch == "§" { skip = true; continue }
        out.append(ch)
    }
    print("[\(stamp())] \(out)")
}

let port = UInt16(flags["--port"] ?? "") ?? 25585

func usage(_ worlds: [WorldRecord]?) {
    print("""
    pebserver — standalone Pebble world server (Pebble \(PEBBLE_VERSION))

      pebserver "<world name or id>" [--port \(port)] [--data-dir <path>]
      pebserver --create "<name>" [--seed <seed>] [--creative] [--port \(port)]

    """)
    guard let worlds else { return }
    if worlds.isEmpty {
        print("No worlds yet — create one with --create.")
    } else {
        print("Your worlds:")
        for w in worlds.sorted(by: { $0.lastPlayed > $1.lastPlayed }) {
            print("  • \(w.name)  (id \(w.id), seed \(w.seed))")
        }
    }
}

// --help must not construct GameCore or touch storage (PORTING module 12)
if switches.contains("--help") || switches.contains("-h") {
    usage(nil)
    exit(0)
}

// the data root must be pinned BEFORE GameCore touches any store
if let dataDir = flags["--data-dir"] {
    vcOverrideDataDir(dataDir)
}

let game = GameCore()

// ---- resolve the world ------------------------------------------------------
var record: WorldRecord?
if let createName = flags["--create"] {
    // create through the normal path (also seeds a spawn player slot for the
    // world's owner), then re-open it headless
    game.createWorld(name: createName, seedText: flags["--seed"] ?? "",
                     mode: switches.contains("--creative") ? 1 : 0, difficulty: 2)
    let id = game.worldRec?.id
    game.exitToTitle()
    record = id.flatMap { game.db.getWorld($0) }
} else if let query = positional.first {
    let all = game.listWorlds()
    record = all.first { $0.id == query }
        ?? all.first { $0.name.lowercased() == query.lowercased() }
    if record == nil {
        print("error: no world named '\(query)'\n")
        usage(all)
        exit(1)
    }
} else {
    usage(game.listWorlds())
    exit(0)
}

guard let rec = record else {
    print("error: couldn't open the world record")
    exit(1)
}

// ---- start ------------------------------------------------------------------
do {
    // --port 0 means "pick a free port" (CI smokes use it)
    try game.enterWorldDedicated(rec, port: port == 0 ? nil : port)
} catch {
    print("error: couldn't listen on port \(port): \(error.localizedDescription)")
    exit(1)
}
game.netHost?.onLog = { line in log(line) }

log("Pebble server \(PEBBLE_VERSION) — serving '\(rec.name)' (seed \(rec.seed))")
#if canImport(PebbleCore)
log("Listening on port \(port == 0 ? "…" : String(port)) — LAN players see it under 'Join LAN Game';")
log("internet players add your address in Multiplayer → Servers.")
#else
log("Direct-IP server — players add your address in Multiplayer → Servers.")
#endif
log("Commands: list, say <message>, save, stop")

// ---- clean shutdown ---------------------------------------------------------
func shutdown() {
    log("Saving and stopping…")
    game.exitToTitle()   // shuts the session down + synchronous world save
    log("Goodbye.")
    exit(0)
}
#if os(Windows)
// Ctrl-C / Ctrl-Break / console close — save on the game queue, not in the
// handler (it runs on a system thread)
_ = SetConsoleCtrlHandler({ _ in
    DispatchQueue.main.async { shutdown() }
    Sleep(10_000)   // hold the handler thread; exit(0) lands first
    return true
}, true)
#else
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler { shutdown() }
sigint.resume()
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigterm.setEventHandler { shutdown() }
sigterm.resume()
#endif

// ---- console ------------------------------------------------------------------
Thread.detachNewThread {
    while let line = readLine(strippingNewline: true) {
        DispatchQueue.main.async {
            let parts = line.split(separator: " ", maxSplits: 1)
            switch parts.first.map(String.init)?.lowercased() {
            case "stop", "exit", "quit":
                shutdown()
            case "save":
                game.saveAndFlush(synchronous: true)
                log("Saved.")
            case "list":
                let names = game.netHost?.guestNames ?? []
                log("\(names.count) player(s) online" + (names.isEmpty ? "" : ": " + names.joined(separator: ", ")))
            case "say":
                let msg = parts.count > 1 ? String(parts[1]) : ""
                if !msg.isEmpty {
                    let text = "[Server] \(msg)"
                    log(text)
                    game.netHost?.broadcastChat("§d\(text)")
                }
            case "help":
                log("Commands: list, say <message>, save, stop")
            case .none:
                break
            default:
                log("Unknown command. Try: list, say <message>, save, stop")
            }
        }
    }
    // console EOF (stdin closed): keep serving — only an explicit stop,
    // Ctrl-C, or SIGTERM shuts the world down (PORTING module 12)
}

// ---- 20 TPS loop ----------------------------------------------------------------
var lastTick = monotonicNow()
var announcedReady = false
let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now(), repeating: .milliseconds(50), leeway: .milliseconds(5))
timer.setEventHandler {
    let now = monotonicNow()
    let dt = (now - lastTick) * 1000
    lastTick = now
    _ = game.frame(dtMs: dt)
    // one machine-readable line once the listener is up — smokes wait for it
    if !announcedReady, let p = game.netHost?.port, p != 0 {
        announcedReady = true
        print("READY port=\(p) world=\(rec.id)")
    }
}
timer.resume()

// park the main thread and drain the main queue (ticks, net callbacks,
// console commands, shutdown) — everything serializes there
#if os(Windows)
dispatchMain()
#else
RunLoop.main.run()
#endif
