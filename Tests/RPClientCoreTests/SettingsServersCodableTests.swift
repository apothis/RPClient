import Foundation
@testable import RPClientCore

func settingsServersCodableTests() -> TestSuite {
    let s = TestSuite("SettingsServersCodable")

    let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    s.test("default settings round-trip preserves servers and ids") {
        let original = Settings.default
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(Settings.self, from: data)
        try expectEqual(decoded.servers.count, 1)
        try expectEqual(decoded.servers[0].id, original.servers[0].id)
        try expectEqual(decoded.servers[0].name, "Default")
        try expectEqual(decoded.defaultServerId, original.defaultServerId)
        try expectEqual(decoded.serverURL, "http://localhost:5001")
        try expectNil(decoded.summarizerServerId)
    }

    s.test("legacy serverURL migrates into single Default profile") {
        // Simulates a pre-Phase-4 Settings JSON: bare `serverURL` field, no
        // `servers` array.
        let legacyJSON = """
        {
          "serverURL": "http://192.168.1.50:5001",
          "userName": "Kev",
          "defaultTemplateId": "qwen",
          "defaultSamplerPresetId": "balanced",
          "voiceEnabled": false,
          "maxContextOverride": 0,
          "retrieval": {
            "enabled": true,
            "topK": 6,
            "minScore": 0.2,
            "tokenCap": 2000,
            "embeddingDim": 0,
            "embeddingDimLocked": false,
            "embeddingModel": ""
          },
          "uiFontOffset": 1,
          "replyTokensOverride": 0,
          "factExtractionEnabled": true,
          "factExtractionEveryNTurns": 4,
          "priorityTopicLibrary": [],
          "qwenThinkingEnabled": false
        }
        """.data(using: .utf8)!

        let decoded = try decoder.decode(Settings.self, from: legacyJSON)
        try expectEqual(decoded.servers.count, 1)
        try expectEqual(decoded.servers[0].name, "Default")
        try expectEqual(decoded.servers[0].baseURL.absoluteString, "http://192.168.1.50:5001")
        try expectEqual(decoded.defaultServerId, decoded.servers[0].id)
        try expectEqual(decoded.serverURL, "http://192.168.1.50:5001")
        try expectEqual(decoded.userName, "Kev")
        try expectEqual(decoded.defaultTemplateId, "qwen")
    }

    s.test("legacy decode falls back when serverURL missing") {
        let bareJSON = """
        {
          "userName": "",
          "defaultTemplateId": "gemma",
          "defaultSamplerPresetId": "balanced",
          "voiceEnabled": false,
          "maxContextOverride": 0,
          "retrieval": {
            "enabled": true,
            "topK": 6,
            "minScore": 0.2,
            "tokenCap": 2000,
            "embeddingDim": 0,
            "embeddingDimLocked": false,
            "embeddingModel": ""
          },
          "uiFontOffset": 1,
          "replyTokensOverride": 0,
          "factExtractionEnabled": true,
          "factExtractionEveryNTurns": 4,
          "priorityTopicLibrary": [],
          "qwenThinkingEnabled": false
        }
        """.data(using: .utf8)!

        let decoded = try decoder.decode(Settings.self, from: bareJSON)
        try expectEqual(decoded.servers.count, 1)
        try expectEqual(decoded.servers[0].baseURL.absoluteString, "http://localhost:5001")
        try expectEqual(decoded.defaultServerId, decoded.servers[0].id)
    }

    s.test("multi-server settings round-trip preserves all profiles and role ids") {
        let g = ServerProfile(name: "Fast",
                              baseURL: URL(string: "http://localhost:5001")!)
        let big = ServerProfile(
            name: "Beefy",
            baseURL: URL(string: "http://192.168.1.99:5001")!,
            capabilities: ServerCapabilities(modelName: "llama-70b",
                                             trueMaxContext: 32768,
                                             version: "1.84.1"),
            lastProbed: Date(timeIntervalSince1970: 1_750_000_000)
        )
        var s2 = Settings.default
        s2.servers = [g, big]
        s2.defaultServerId = g.id
        s2.summarizerServerId = big.id
        s2.extractorServerId = big.id
        s2.embeddingsServerId = nil

        let data = try encoder.encode(s2)
        let decoded = try decoder.decode(Settings.self, from: data)
        try expectEqual(decoded.servers.count, 2)
        try expectEqual(decoded.servers[1].name, "Beefy")
        try expectEqual(decoded.servers[1].capabilities?.modelName, "llama-70b")
        try expectEqual(decoded.servers[1].capabilities?.trueMaxContext, 32768)
        try expectEqual(decoded.defaultServerId, g.id)
        try expectEqual(decoded.summarizerServerId, big.id)
        try expectEqual(decoded.extractorServerId, big.id)
        try expectNil(decoded.embeddingsServerId)
    }

    s.test("serverURL setter mutates the default profile baseURL") {
        var s2 = Settings.default
        s2.serverURL = "http://10.0.0.7:5001"
        try expectEqual(s2.defaultServer?.baseURL.absoluteString, "http://10.0.0.7:5001")
        try expectEqual(s2.servers.count, 1)
    }

    // MARK: - voiceModelPath (Phase 6 §7.1b)

    s.test("voiceModelPath defaults to nil") {
        try expectNil(Settings.default.voiceModelPath)
    }

    s.test("voiceModelPath round-trips through Codable") {
        var s2 = Settings.default
        s2.voiceModelPath = "/Volumes/SSD1/voice-models"
        let data = try encoder.encode(s2)
        let decoded = try decoder.decode(Settings.self, from: data)
        try expectEqual(decoded.voiceModelPath, "/Volumes/SSD1/voice-models")
    }

    s.test("legacy settings without voiceModelPath decode as nil") {
        let legacyJSON = """
        {
          "serverURL": "http://localhost:5001",
          "userName": "",
          "defaultTemplateId": "gemma",
          "defaultSamplerPresetId": "balanced",
          "voiceEnabled": false,
          "maxContextOverride": 0,
          "retrieval": {
            "enabled": true,
            "topK": 6,
            "minScore": 0.2,
            "tokenCap": 2000,
            "embeddingDim": 0,
            "embeddingDimLocked": false,
            "embeddingModel": ""
          },
          "uiFontOffset": 1,
          "replyTokensOverride": 0,
          "factExtractionEnabled": true,
          "factExtractionEveryNTurns": 4,
          "priorityTopicLibrary": [],
          "qwenThinkingEnabled": false
        }
        """.data(using: .utf8)!
        let decoded = try decoder.decode(Settings.self, from: legacyJSON)
        try expectNil(decoded.voiceModelPath)
    }

    // MARK: - voiceActive (Phase 6 §7.1f)

    s.test("voiceActive defaults to true") {
        try expectEqual(Settings.default.voiceActive, true)
    }

    s.test("voiceActive round-trips through Codable") {
        var s2 = Settings.default
        s2.voiceActive = false
        let data = try encoder.encode(s2)
        let decoded = try decoder.decode(Settings.self, from: data)
        try expectEqual(decoded.voiceActive, false)
    }

    s.test("legacy settings without voiceActive decode as true (default)") {
        let legacyJSON = """
        {
          "serverURL": "http://localhost:5001",
          "userName": "",
          "defaultTemplateId": "gemma",
          "defaultSamplerPresetId": "balanced",
          "voiceEnabled": true,
          "maxContextOverride": 0,
          "retrieval": {
            "enabled": true,
            "topK": 6,
            "minScore": 0.2,
            "tokenCap": 2000,
            "embeddingDim": 0,
            "embeddingDimLocked": false,
            "embeddingModel": ""
          },
          "uiFontOffset": 1,
          "replyTokensOverride": 0,
          "factExtractionEnabled": true,
          "factExtractionEveryNTurns": 4,
          "priorityTopicLibrary": [],
          "qwenThinkingEnabled": false
        }
        """.data(using: .utf8)!
        let decoded = try decoder.decode(Settings.self, from: legacyJSON)
        try expectEqual(decoded.voiceActive, true)
    }

    s.test("decode tolerates servers array missing default id by re-migrating") {
        // If somehow `servers` is present but `defaultServerId` doesn't match
        // any of them, decode should fall back to the legacy migration path.
        let weirdJSON = """
        {
          "servers": [
            {"id": "11111111-1111-1111-1111-111111111111",
             "name": "Stranger",
             "baseURL": "http://example.com:5001"}
          ],
          "defaultServerId": "22222222-2222-2222-2222-222222222222",
          "serverURL": "http://localhost:5001",
          "userName": "",
          "defaultTemplateId": "gemma",
          "defaultSamplerPresetId": "balanced",
          "voiceEnabled": false,
          "maxContextOverride": 0,
          "retrieval": {
            "enabled": true, "topK": 6, "minScore": 0.2, "tokenCap": 2000,
            "embeddingDim": 0, "embeddingDimLocked": false, "embeddingModel": ""
          },
          "uiFontOffset": 1, "replyTokensOverride": 0,
          "factExtractionEnabled": true, "factExtractionEveryNTurns": 4,
          "priorityTopicLibrary": [], "qwenThinkingEnabled": false
        }
        """.data(using: .utf8)!

        let decoded = try decoder.decode(Settings.self, from: weirdJSON)
        try expectEqual(decoded.servers.count, 1)
        try expectEqual(decoded.servers[0].name, "Default")
        try expectEqual(decoded.servers[0].baseURL.absoluteString, "http://localhost:5001")
        try expectEqual(decoded.defaultServerId, decoded.servers[0].id)
    }

    return s
}
