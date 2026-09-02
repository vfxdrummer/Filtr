import CoreGraphics
import Foundation
import Testing
@testable import Filtr

/// Rendering tests run against a flat mid-grey source, so any deviation from 0.5 is
/// something the filter chain did rather than something the photograph already had.
@Suite("Filter engine")
struct FilterEngineTests {

    private let grey = ImageBox(makeSolidImage(width: 256, height: 256, grey: 0.5))

    @Test("A neutral request leaves the image alone")
    func neutralRequestIsIdentity() throws {
        let output = try FilterEngine.shared.render(grey, request: .stub())
        let result = stats(of: output.cgImage)
        #expect(abs(result.mean - 0.5) < 0.02)
        #expect(result.standardDeviation < 0.02)
    }

    @Test("Renders are deterministic, which is what makes them cacheable")
    func rendersAreDeterministic() throws {
        let request = FilterEngine.Request.stub(adjustments: Adjustments(exposure: 0.3, contrast: 0.2))
        let first = stats(of: try FilterEngine.shared.render(grey, request: request).cgImage)
        let second = stats(of: try FilterEngine.shared.render(grey, request: request).cgImage)
        #expect(first.mean == second.mean)
        #expect(first.standardDeviation == second.standardDeviation)
    }

    @Test("Output is rendered at the requested size, not the source size")
    func outputHonoursTargetSize() throws {
        let output = try FilterEngine.shared.render(grey, request: .stub(targetMaxPixel: 64))
        #expect(max(output.cgImage.width, output.cgImage.height) <= 66)
    }

    // MARK: Adjustments

    @Test("Exposure moves the image the way the label says")
    func exposureBrightensAndDarkens() throws {
        let brighter = stats(of: try FilterEngine.shared.render(
            grey, request: .stub(adjustments: Adjustments(exposure: 0.5))).cgImage)
        let darker = stats(of: try FilterEngine.shared.render(
            grey, request: .stub(adjustments: Adjustments(exposure: -0.5))).cgImage)

        #expect(brighter.mean > 0.55)
        #expect(darker.mean < 0.45)
    }

    @Test("Fade lifts the black point")
    func fadeLiftsShadows() throws {
        let dark = ImageBox(makeSolidImage(width: 128, height: 128, grey: 0.02))
        let faded = stats(of: try FilterEngine.shared.render(
            dark, request: .stub(adjustments: Adjustments(fade: 1.0))).cgImage)
        #expect(faded.mean > 0.1, "fade should raise near-black toward grey")
    }

    @Test("Temperature shifts colour, not just brightness")
    func temperatureIsChromatic() throws {
        let warm = stats(of: try FilterEngine.shared.render(
            grey, request: .stub(adjustments: Adjustments(temperature: 1.0))).cgImage)
        #expect(warm.meanChannelSpread > 0.03, "a temperature shift must separate the channels")
    }

    // MARK: Regressions

    /// Grain used to arrive as blown-out white blobs, because `CIRandomGenerator`
    /// emits *premultiplied* RGBA — its colour channels are skewed bright (measured
    /// mean 0.75) with several percent of samples clipped to pure white. The alpha
    /// channel is the uniform one. On flat grey, correct grain is symmetric noise
    /// around 0.5 that never clips.
    @Test("Grain is symmetric noise, not blown-out speckle")
    func grainDoesNotClip() throws {
        let grainOnly = FilterRecipe(id: "TEST_GRAIN", name: "Grain", family: .analog, grain: 0.6)
        let output = try FilterEngine.shared.render(grey, request: .stub(recipe: grainOnly))
        let result = stats(of: output.cgImage)

        #expect(result.standardDeviation > 0.005, "grain should actually be visible")
        #expect(abs(result.mean - 0.5) < 0.03, "grain must not shift overall exposure")
        #expect(result.max < 0.95, "grain must not blow out to white — the original bug")
        #expect(result.min > 0.05, "grain must not crush to black either")
    }

    /// `CIColorMatrix` with a bias vector returns an image of *infinite* extent,
    /// because the bias tints the whole plane. Anything downstream that derives its
    /// geometry from the extent then misbehaves — `CIVignette` most visibly. Fade uses
    /// a biased matrix, so fade-then-vignette is the combination that caught it.
    @Test("A vignette still darkens the corners after a biased-matrix stage")
    func vignetteSurvivesFade() throws {
        let output = try FilterEngine.shared.render(
            grey, request: .stub(adjustments: Adjustments(fade: 0.3, vignette: 1.0))
        )
        let corner = stats(of: output.cgImage, region: CGRect(x: 0, y: 0, width: 0.15, height: 0.15))
        let centre = stats(of: output.cgImage, region: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2))

        #expect(corner.mean < centre.mean - 0.02,
                "vignette geometry broke — the fade stage leaked an infinite extent")
    }

    @Test("Output extent stays finite and bounded for every preset")
    func everyPresetProducesABoundedImage() throws {
        for recipe in FilterRecipe.all {
            let output = try FilterEngine.shared.render(grey, request: .stub(recipe: recipe, targetMaxPixel: 128))
            #expect(output.cgImage.width > 0 && output.cgImage.width <= 130,
                    "\(recipe.id) produced a \(output.cgImage.width)px image")
        }
    }

    @Test("Intensity blends between the original and the preset")
    func intensityBlends() throws {
        let recipe = FilterRecipe.recipe(id: "M5")   // monochrome, strong
        let full = stats(of: try FilterEngine.shared.render(
            grey, request: .stub(recipe: recipe, intensity: 1.0)).cgImage)
        let none = stats(of: try FilterEngine.shared.render(
            grey, request: .stub(recipe: recipe, intensity: 0.0)).cgImage)

        #expect(abs(none.mean - 0.5) < 0.03, "zero intensity should look like the original")
        #expect(abs(full.mean - none.mean) > 0.01, "full intensity should not")
    }
}
