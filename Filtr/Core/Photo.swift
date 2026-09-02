import Foundation

/// One entry in the library. `sourceName` is the file on disk; `cropSeed` gives each
/// entry its own region of that file, so 96 photos means 96 genuinely distinct renders
/// even though they share 14 source JPEGs.
struct Photo: Identifiable, Hashable, Sendable {
    let id: Int
    let sourceName: String
    let cropSeed: Int

    var title: String { String(format: "IMG_%04d", 1200 + id) }

    /// Normalised crop rect, derived from the seed. Deterministic: the same photo
    /// always resolves to the same pixels, which is what makes the cache key honest.
    var normalizedCrop: CGRect {
        var rng = SplitMix64(seed: UInt64(cropSeed) &* 0x9E3779B97F4A7C15)
        let scale = 0.55 + rng.nextUnit() * 0.45
        let x = rng.nextUnit() * (1 - scale)
        let y = rng.nextUnit() * (1 - scale)
        return CGRect(x: x, y: y, width: scale, height: scale)
    }
}

enum PhotoLibrary {
    static let photoCount = 96

    static let all: [Photo] = {
        let urls = sourceURLs
        guard !urls.isEmpty else { return [] }
        return (0..<photoCount).map { index in
            Photo(
                id: index,
                sourceName: urls[index % urls.count].deletingPathExtension().lastPathComponent,
                cropSeed: index &* 7919 &+ 13
            )
        }
    }()

    static let sourceURLs: [URL] = {
        let bundled = Bundle.main.urls(forResourcesWithExtension: "jpg", subdirectory: nil) ?? []
        return bundled.filter { $0.lastPathComponent.hasPrefix("src_") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }()

    static func url(forSource name: String) -> URL? {
        sourceURLs.first { $0.deletingPathExtension().lastPathComponent == name }
    }
}

/// Small deterministic PRNG so crops are stable across launches.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func nextUnit() -> Double {
        Double(next() >> 11) * (1.0 / 9007199254740992.0)
    }
}
