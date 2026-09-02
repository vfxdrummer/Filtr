import Foundation

/// The Adjust toolset, on top of whatever preset is selected.
///
/// Every value is normalised to a neutral 0. Bipolar tools run -1...1, unipolar ones
/// 0...1, so the UI can render every slider from the same description and "reset"
/// always means "back to zero".
///
/// Plain value type, `Hashable` and `Sendable` — which is what lets it be part of the
/// render cache key. That matters more than it looks: dragging a slider has to produce
/// keys that *repeat* as you drag back, or nothing is ever reusable.
struct Adjustments: Hashable, Sendable, Codable {
    var exposure: Double = 0        // -1...1  →  ±2 EV
    var contrast: Double = 0        // -1...1
    var saturation: Double = 0      // -1...1
    var temperature: Double = 0     // -1...1  →  ±2200 K
    var tint: Double = 0            // -1...1  →  ±40
    var highlights: Double = 0      // -1...1  recover / lift
    var shadows: Double = 0         // -1...1  crush / open
    var clarity: Double = 0         //  0...1  local contrast
    var sharpen: Double = 0         //  0...1
    var fade: Double = 0            //  0...1  lifted black point
    var grain: Double = 0           //  0...1
    var vignette: Double = 0        //  0...1

    static let neutral = Adjustments()

    init() {}

    /// Hand-written so a file saved by an older build — or by a newer one with tools
    /// this build doesn't know about — still decodes. Swift's synthesised `Decodable`
    /// throws on a missing key even when the property has a default, which would mean
    /// adding a thirteenth tool silently invalidated everyone's saved edits.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value(_ key: CodingKeys) throws -> Double {
            try container.decodeIfPresent(Double.self, forKey: key) ?? 0
        }
        exposure = try value(.exposure)
        contrast = try value(.contrast)
        saturation = try value(.saturation)
        temperature = try value(.temperature)
        tint = try value(.tint)
        highlights = try value(.highlights)
        shadows = try value(.shadows)
        clarity = try value(.clarity)
        sharpen = try value(.sharpen)
        fade = try value(.fade)
        grain = try value(.grain)
        vignette = try value(.vignette)
    }

    var isNeutral: Bool { self == .neutral }

    /// How many tools are away from neutral — drives the badge in the editor.
    var activeCount: Int {
        AdjustTool.allCases.reduce(into: 0) { count, tool in
            if abs(self[tool]) > 0.001 { count += 1 }
        }
    }

    subscript(tool: AdjustTool) -> Double {
        get { self[keyPath: tool.keyPath] }
        set { self[keyPath: tool.keyPath] = newValue }
    }

    /// Snap every value to 1/50 of its range.
    ///
    /// A continuous `Double` in a cache key means every pixel of slider drag mints a
    /// brand-new entry that can never be hit again — the cache degenerates into a
    /// memory leak. Quantising makes a full drag at most ~50 distinct renders per tool,
    /// every one of them reusable on the way back.
    func quantized() -> Adjustments {
        var copy = self
        for tool in AdjustTool.allCases {
            copy[tool] = (self[tool] * 50).rounded() / 50
        }
        return copy
    }

    /// Compact, stable string for the cache key.
    var keyFragment: String {
        AdjustTool.allCases
            .map { String(Int((self[$0] * 50).rounded())) }
            .joined(separator: ".")
    }
}

enum AdjustTool: String, CaseIterable, Identifiable, Sendable {
    case exposure, contrast, saturation, temperature, tint
    case highlights, shadows, clarity, sharpen, fade, grain, vignette

    var id: String { rawValue }

    var title: String {
        switch self {
        case .exposure: "Exposure"
        case .contrast: "Contrast"
        case .saturation: "Saturation"
        case .temperature: "Temp"
        case .tint: "Tint"
        case .highlights: "Highlights"
        case .shadows: "Shadows"
        case .clarity: "Clarity"
        case .sharpen: "Sharpen"
        case .fade: "Fade"
        case .grain: "Grain"
        case .vignette: "Vignette"
        }
    }

    var symbol: String {
        switch self {
        case .exposure: "sun.max"
        case .contrast: "circle.lefthalf.filled"
        case .saturation: "drop"
        case .temperature: "thermometer.medium"
        case .tint: "eyedropper.halffull"
        case .highlights: "sun.horizon"
        case .shadows: "moon"
        case .clarity: "sparkles"
        case .sharpen: "triangle"
        case .fade: "cloud.fog"
        case .grain: "circle.grid.3x3.fill"
        case .vignette: "smallcircle.filled.circle"
        }
    }

    /// Bipolar tools centre at zero and run both ways; unipolar ones only add.
    var isBipolar: Bool {
        switch self {
        case .exposure, .contrast, .saturation, .temperature, .tint, .highlights, .shadows:
            true
        case .clarity, .sharpen, .fade, .grain, .vignette:
            false
        }
    }

    var range: ClosedRange<Double> { isBipolar ? -1...1 : 0...1 }

    var keyPath: WritableKeyPath<Adjustments, Double> {
        switch self {
        case .exposure: \.exposure
        case .contrast: \.contrast
        case .saturation: \.saturation
        case .temperature: \.temperature
        case .tint: \.tint
        case .highlights: \.highlights
        case .shadows: \.shadows
        case .clarity: \.clarity
        case .sharpen: \.sharpen
        case .fade: \.fade
        case .grain: \.grain
        case .vignette: \.vignette
        }
    }
}
