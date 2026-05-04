import Foundation
@testable import RPClientCore

func chatServerPickerTests() -> TestSuite {
    let s = TestSuite("ChatServerPicker")

    func makeProfile(_ name: String) -> ServerProfile {
        ServerProfile(name: name, baseURL: URL(string: "http://\(name.lowercased()):5001")!)
    }
    func makeSettings(_ profiles: [ServerProfile]) -> Settings {
        var out = Settings.default
        out.servers = profiles
        out.defaultServerId = profiles[0].id
        return out
    }

    s.test("selectedIndex returns 0 when chat.serverId is nil") {
        let st = makeSettings([makeProfile("A"), makeProfile("B")])
        try expectEqual(ChatServerPicker.selectedIndex(chatServerId: nil, settings: st), 0)
    }

    s.test("selectedIndex returns the profile's index + 1 when pinned") {
        // Index 0 in the popup is "(use default)"; servers occupy 1..n.
        let a = makeProfile("A")
        let b = makeProfile("B")
        let c = makeProfile("C")
        let st = makeSettings([a, b, c])
        try expectEqual(ChatServerPicker.selectedIndex(chatServerId: a.id, settings: st), 1)
        try expectEqual(ChatServerPicker.selectedIndex(chatServerId: b.id, settings: st), 2)
        try expectEqual(ChatServerPicker.selectedIndex(chatServerId: c.id, settings: st), 3)
    }

    s.test("selectedIndex falls back to 0 when chat.serverId points at a deleted profile") {
        let st = makeSettings([makeProfile("A")])
        try expectEqual(ChatServerPicker.selectedIndex(chatServerId: UUID(), settings: st), 0)
    }

    s.test("displayLabel says (use default) for nil or stale id") {
        let st = makeSettings([makeProfile("A")])
        try expectEqual(ChatServerPicker.displayLabel(chatServerId: nil, settings: st),
                        "(use default)")
        try expectEqual(ChatServerPicker.displayLabel(chatServerId: UUID(), settings: st),
                        "(use default)")
    }

    s.test("displayLabel returns the pinned profile's name") {
        let a = makeProfile("Beefy")
        let st = makeSettings([a])
        try expectEqual(ChatServerPicker.displayLabel(chatServerId: a.id, settings: st), "Beefy")
    }

    s.test("displayLabel handles unnamed profile by showing a sentinel") {
        let p = ServerProfile(name: "", baseURL: URL(string: "http://h:5001")!)
        let st = makeSettings([p])
        try expectEqual(ChatServerPicker.displayLabel(chatServerId: p.id, settings: st),
                        "(unnamed)")
    }

    s.test("idAtIndex maps popup index back to a profile id (or nil for default)") {
        let a = makeProfile("A")
        let b = makeProfile("B")
        let st = makeSettings([a, b])
        try expectNil(ChatServerPicker.idAtIndex(0, settings: st))
        try expectEqual(ChatServerPicker.idAtIndex(1, settings: st), a.id)
        try expectEqual(ChatServerPicker.idAtIndex(2, settings: st), b.id)
        // Out-of-range falls back to nil so the chat reverts to default.
        try expectNil(ChatServerPicker.idAtIndex(99, settings: st))
        try expectNil(ChatServerPicker.idAtIndex(-1, settings: st))
    }

    return s
}
