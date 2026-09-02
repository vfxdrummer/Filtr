import CoreGraphics
import Foundation

/// A film-emulation preset, described entirely by value.
///
/// Deliberately plain data — no closures, no CIFilter references. That keeps it
/// `Sendable` and `Hashable`, which in turn lets it be half of a render cache key.
/// The interpretation lives in `FilterEngine`.
struct FilterRecipe: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var family: Family

    var temperature: Double = 6500   // Kelvin, neutral 6500
    var tint: Double = 0
    var exposure: Double = 0         // EV
    var contrast: Double = 1.0
    var saturation: Double = 1.0
    var brightness: Double = 0
    var vibrance: Double = 0
    var shadowLift: Double = 0       // raises the black point — the "faded" look
    var shadowAmount: Double = 0     // CIHighlightShadowAdjust
    var highlightAmount: Double = 1
    var monochrome: Bool = false
    var splitTone: RGB = RGB(1, 1, 1)  // multiplier applied to lifted shadows
    var grain: Double = 0
    var vignette: Double = 0

    struct RGB: Hashable, Sendable {
        var r: Double, g: Double, b: Double
        init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
    }

    enum Family: String, Sendable, CaseIterable {
        case none = "Original"
        case analog = "Analog"
        case chrome = "Chrome"
        case mono = "B&W"
        case fade = "Fade"
    }

    /// Roughly what this preset does to a neutral mid-grey — used for the swatch
    /// under each name in the picker, so the strip reads at a glance.
    var swatch: (Double, Double, Double) {
        let warm = (temperature - 6500) / 4000
        var r = 0.62 + warm * 0.18 + shadowLift * 0.4 * splitTone.r
        var g = 0.62 - abs(warm) * 0.02 + tint / 200 + shadowLift * 0.4 * splitTone.g
        var b = 0.62 - warm * 0.18 + shadowLift * 0.4 * splitTone.b
        if monochrome { let l = (r + g + b) / 3; r = l; g = l; b = l }
        let s = saturation
        let l = (r + g + b) / 3
        r = l + (r - l) * s; g = l + (g - l) * s; b = l + (b - l) * s
        r += brightness + exposure * 0.1
        g += brightness + exposure * 0.1
        b += brightness + exposure * 0.1
        return (min(max(r, 0), 1), min(max(g, 0), 1), min(max(b, 0), 1))
    }

    static let original = FilterRecipe(id: "OG", name: "Original", family: .none)

    static let all: [FilterRecipe] = [
        original,

        FilterRecipe(id: "A6", name: "A6", family: .analog,
                     temperature: 7300, tint: 4, exposure: 0.12, contrast: 1.06,
                     saturation: 0.88, vibrance: 0.18, shadowLift: 0.055,
                     shadowAmount: 0.207, highlightAmount: 0.82,
                     splitTone: .init(1.0, 0.94, 0.82), grain: 0.3, vignette: 0.45),

        FilterRecipe(id: "C1", name: "C1", family: .chrome,
                     temperature: 6100, tint: -6, exposure: 0.05, contrast: 1.16,
                     saturation: 1.14, vibrance: 0.30, shadowAmount: 0.0892,
                     highlightAmount: 0.92, grain: 0.1, vignette: 0.25),

        FilterRecipe(id: "F2", name: "F2", family: .fade,
                     temperature: 6800, tint: 8, exposure: 0.18, contrast: 0.88,
                     saturation: 0.80, shadowLift: 0.10, shadowAmount: 0.297,
                     highlightAmount: 0.7, splitTone: .init(0.92, 0.96, 1.0),
                     grain: 0.22, vignette: 0.10),

        FilterRecipe(id: "HB1", name: "HB1", family: .analog,
                     temperature: 7000, tint: -3, exposure: 0.22, contrast: 0.95,
                     saturation: 1.02, vibrance: 0.22, shadowLift: 0.045,
                     shadowAmount: 0.269, highlightAmount: 0.88,
                     splitTone: .init(1.0, 0.97, 0.90), grain: 0.18, vignette: 0.18),

        FilterRecipe(id: "M5", name: "M5", family: .mono,
                     temperature: 6500, exposure: 0.06, contrast: 1.22,
                     saturation: 0, shadowAmount: 0.149, highlightAmount: 0.85,
                     monochrome: true, grain: 0.42, vignette: 0.55),

        FilterRecipe(id: "B1", name: "B1", family: .mono,
                     temperature: 6500, exposure: 0.15, contrast: 0.92,
                     saturation: 0, shadowLift: 0.085, shadowAmount: 0.328,
                     highlightAmount: 0.72, monochrome: true,
                     splitTone: .init(0.96, 0.98, 1.0), grain: 0.3, vignette: 0.20),

        FilterRecipe(id: "KK2", name: "KK2", family: .chrome,
                     temperature: 7600, tint: 10, exposure: 0.10, contrast: 1.20,
                     saturation: 1.22, vibrance: 0.35, shadowAmount: 0.119,
                     highlightAmount: 0.95, splitTone: .init(1.0, 0.95, 0.88),
                     grain: 0.12, vignette: 0.35),

        FilterRecipe(id: "AL3", name: "AL3", family: .fade,
                     temperature: 5700, tint: -10, exposure: 0.14, contrast: 0.90,
                     saturation: 0.86, vibrance: 0.10, shadowLift: 0.095,
                     shadowAmount: 0.297, highlightAmount: 0.75,
                     splitTone: .init(0.86, 0.95, 1.0), grain: 0.26, vignette: 0.12),

        FilterRecipe(id: "G3", name: "G3", family: .analog,
                     temperature: 6900, tint: 2, exposure: -0.05, contrast: 1.10,
                     saturation: 0.92, vibrance: 0.14, shadowLift: 0.03,
                     shadowAmount: 0.178, highlightAmount: 0.80,
                     splitTone: .init(0.98, 1.0, 0.94), grain: 0.34, vignette: 0.50),

        FilterRecipe(id: "P4", name: "P4", family: .chrome,
                     temperature: 6300, tint: 14, exposure: 0.08, contrast: 1.05,
                     saturation: 1.08, vibrance: 0.28, shadowLift: 0.02,
                     shadowAmount: 0.167, highlightAmount: 0.90,
                     splitTone: .init(1.0, 0.93, 0.98), grain: 0.14, vignette: 0.22),

        FilterRecipe(id: "T2", name: "T2", family: .fade,
                     temperature: 7900, tint: -8, exposure: 0.20, contrast: 0.86,
                     saturation: 0.74, shadowLift: 0.12, shadowAmount: 0.357,
                     highlightAmount: 0.68, splitTone: .init(1.0, 0.90, 0.78),
                     grain: 0.36, vignette: 0.08),

        FilterRecipe(id: "X5", name: "X5", family: .mono,
                     temperature: 6500, exposure: 0.0, contrast: 1.45,
                     saturation: 0, shadowAmount: 0.0595, highlightAmount: 1.0,
                     monochrome: true, grain: 0.5, vignette: 0.65),
    ]

    static func recipe(id: String) -> FilterRecipe {
        all.first { $0.id == id } ?? original
    }
}
