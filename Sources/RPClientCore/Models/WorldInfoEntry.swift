import Foundation

struct WorldInfoEntry: Codable, Equatable {
    var keys: [String]
    var content: String
    var tokenCap: Int
}
