import CoreGraphics
import Foundation
import Testing
@testable import Filtr

/// The cache key is the load-bearing idea in the whole design: it *is* the edit, which
/// is what makes stale renders structurally impossible. These tests pin down the two
/// properties it needs — it must quantise, and it must never conflate two edits.
@Suite("Render key")
struct RenderKeyTests {

    @Test("Slider values inside one bucket produce the same key")
    func intensityQuantises() {
        let a = RenderCoordinator.Key.stub(intensity: 0.500)
        let b = RenderCoordinator.Key.stub(intensity: 0.502)
        #expect(a == b, "a continuous Double would make every drag frame uncacheable")
    }

    @Test("Slider values in different buckets produce different keys")
    func intensityStillDiscriminates() {
        let a = RenderCoordinator.Key.stub(intensity: 0.50)
        let b = RenderCoordinator.Key.stub(intensity: 0.60)
        #expect(a != b)
    }

    @Test("Adjustment values quantise the same way")
    func adjustmentsQuantise() {
        let negligible = RenderCoordinator.Key.stub(adjustments: Adjustments(exposure: 0.001))
        #expect(negligible == RenderCoordinator.Key.stub(), "sub-bucket noise must not mint a new key")

        let real = RenderCoordinator.Key.stub(adjustments: Adjustments(exposure: 0.4))
        #expect(real != RenderCoordinator.Key.stub())
    }

    @Test("Nearby target sizes share a key")
    func targetSizeBuckets() {
        #expect(RenderCoordinator.Key.stub(maxPixel: 100) == RenderCoordinator.Key.stub(maxPixel: 120))
        #expect(RenderCoordinator.Key.stub(maxPixel: 100) != RenderCoordinator.Key.stub(maxPixel: 400))
    }

    @Test("Every component of an edit changes the key")
    func distinctEditsNeverCollide() {
        let base = RenderCoordinator.Key.stub()
        let variants: [RenderCoordinator.Key] = [
            .stub(photo: .stub(id: 2)),
            .stub(recipe: FilterRecipe.recipe(id: "A6")),
            .stub(intensity: 0.2),
            .stub(adjustments: Adjustments(contrast: 0.5)),
            .stub(adjustments: Adjustments(vignette: 0.5)),
            .stub(maxPixel: 512),
        ]
        for variant in variants {
            #expect(variant != base)
            #expect(variant.cacheKey != base.cacheKey)
        }
        #expect(Set(variants.map(\.cacheKey)).count == variants.count)
    }

    @Test("Each adjustment tool occupies its own slot in the key")
    func everyToolIsRepresented() {
        for tool in AdjustTool.allCases {
            var adjustments = Adjustments.neutral
            adjustments[tool] = tool.isBipolar ? 0.5 : 0.5
            #expect(RenderCoordinator.Key.stub(adjustments: adjustments) != RenderCoordinator.Key.stub(),
                    "\(tool.rawValue) does not affect the cache key")
        }
    }
}
