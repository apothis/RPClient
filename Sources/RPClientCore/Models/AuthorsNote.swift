import Foundation

struct AuthorsNote: Codable, Equatable {
    var text: String
    var depth: Int

    static let `default` = AuthorsNote(text: "", depth: 4)
}
