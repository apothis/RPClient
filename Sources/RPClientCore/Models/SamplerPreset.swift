import Foundation

struct SamplerPreset: Codable, Equatable {
    var id: String
    var name: String
    var temperature: Double
    var topP: Double
    var topK: Int
    var minP: Double
    var repPen: Double
    var repPenRange: Int
    var maxLength: Int
    var samplerOrder: [Int]

    static let balanced = SamplerPreset(
        id: "balanced",
        name: "Balanced",
        temperature: 0.9,
        topP: 0.95,
        topK: 40,
        minP: 0.05,
        repPen: 1.07,
        repPenRange: 1024,
        maxLength: 2048,
        samplerOrder: [6, 0, 1, 3, 4, 2, 5]
    )

    static let creative = SamplerPreset(
        id: "creative",
        name: "Creative",
        temperature: 1.1,
        topP: 0.98,
        topK: 80,
        minP: 0.02,
        repPen: 1.05,
        repPenRange: 1024,
        maxLength: 2048,
        samplerOrder: [6, 0, 1, 3, 4, 2, 5]
    )

    static let precise = SamplerPreset(
        id: "precise",
        name: "Precise",
        temperature: 0.6,
        topP: 0.9,
        topK: 30,
        minP: 0.1,
        repPen: 1.1,
        repPenRange: 1024,
        maxLength: 2048,
        samplerOrder: [6, 0, 1, 3, 4, 2, 5]
    )

    static let presets: [SamplerPreset] = [.balanced, .creative, .precise]
}
