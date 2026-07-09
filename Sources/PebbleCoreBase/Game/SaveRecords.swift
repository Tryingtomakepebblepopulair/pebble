// Save records (portable): world/dimension metadata and chunk record
// value types shared by the SQLite store, the network protocol, and the
// server. No SQLite/platform imports (PORTING module 04).

import Foundation


public struct DimState: Codable {
    public var time: Int
    public var dayTime: Int
    public var raining: Bool
    public var thundering: Bool
    public var weatherTimer: Int

    public init(time: Int = 0, dayTime: Int = 1000, raining: Bool = false,
                thundering: Bool = false, weatherTimer: Int = 24000) {
        self.time = time
        self.dayTime = dayTime
        self.raining = raining
        self.thundering = thundering
        self.weatherTimer = weatherTimer
    }
}

/// single source of truth for the app version — the title screen, the F3
/// overlay and save records all read this (Info.plist is bumped separately
/// at packaging time)
public let PEBBLE_VERSION = "1.1.0"

/// WorldMeta + the global-state extension (baseline WorldRecord extends WorldMeta)
public struct WorldRecord: Codable {
    public var id: String
    public var name: String
    public var seed: Int32
    public var gameMode: Int
    public var difficulty: Int
    public var lastPlayed: Double      // ms epoch, like Date.now()
    public var version: String
    /// keyed by dim rawValue as a string — Swift encodes [Int:] dicts as JSON
    /// arrays, and the record should read as `{"0": {...}, "1": {...}}` on disk
    public var dims: [String: DimState]
    public var spawnX: Int
    public var spawnY: Int
    public var spawnZ: Int
    public var gameRules: [String: Double]
    public var dragonKilled: Bool
    public var gatewaysSpawned: Int
    public var nextEntityId: Int

    public init(id: String, name: String, seed: Int32, gameMode: Int, difficulty: Int) {
        self.id = id
        self.name = name
        self.seed = seed
        self.gameMode = gameMode
        self.difficulty = difficulty
        lastPlayed = Date().timeIntervalSince1970 * 1000
        version = "pebble-\(PEBBLE_VERSION)"
        dims = ["0": DimState(), "1": DimState(), "2": DimState()]
        spawnX = 0
        spawnY = 80
        spawnZ = 0
        gameRules = [:]
        dragonKilled = false
        gatewaysSpawned = 0
        nextEntityId = 1
    }
}

public struct ChunkRecord {
    public var key: String
    public var worldId: String
    public var dim: Int
    public var cx: Int
    public var cz: Int
    /// absent on entity-only records: the chunk itself regenerates from seed
    public var blocks: [UInt16]?
    public var biomes: [UInt8]?
    public var blockEntities: [BlockEntityData]?
    public var entities: [[String: Any]]

    public init(key: String, worldId: String, dim: Int, cx: Int, cz: Int,
                blocks: [UInt16]? = nil, biomes: [UInt8]? = nil,
                blockEntities: [BlockEntityData]? = nil, entities: [[String: Any]] = []) {
        self.key = key
        self.worldId = worldId
        self.dim = dim
        self.cx = cx
        self.cz = cz
        self.blocks = blocks
        self.biomes = biomes
        self.blockEntities = blockEntities
        self.entities = entities
    }
}

