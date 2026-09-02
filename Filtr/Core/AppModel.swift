import Foundation
import SwiftUI

@MainActor
@Observable
final class AppModel {
    let photos = PhotoLibrary.all

    /// The filter applied to the whole library. Changing this is the stress test:
    /// every visible tile's render identity changes at once.
    var globalRecipe: FilterRecipe = FilterRecipe.recipe(
        id: ProcessInfo.processInfo.environment["FILTR_RECIPE"] ?? "A6"
    )
    var intensity: Double = 1.0

    /// Per-photo overrides, so "Scramble" can give all 96 photos different filters and
    /// remove any chance of coalescing.
    var overrides: [Int: String] = [:]

    var config = PipelineConfig() {
        didSet {
            guard config != oldValue else { return }
            let snapshot = config
            Task { await RenderCoordinator.shared.update(config: snapshot) }
        }
    }

    var showHUD = true
    var showLab = false

    func recipe(for photo: Photo) -> FilterRecipe {
        if let id = overrides[photo.id] { return FilterRecipe.recipe(id: id) }
        return globalRecipe
    }

    func restyleAll() {
        let pool = FilterRecipe.all.filter { $0.id != globalRecipe.id && $0.id != FilterRecipe.original.id }
        overrides.removeAll()
        globalRecipe = pool.randomElement() ?? FilterRecipe.all[1]
    }

    func scramble() {
        let pool = FilterRecipe.all.filter { $0.id != FilterRecipe.original.id }
        var seed = SplitMix64(seed: UInt64(UInt32.random(in: .min ... .max)))
        overrides = Dictionary(uniqueKeysWithValues: photos.map { photo in
            (photo.id, pool[Int(seed.nextUnit() * Double(pool.count)) % pool.count].id)
        })
    }

    func resetLibrary() {
        overrides.removeAll()
        Task { await RenderCoordinator.shared.purge() }
    }

    func apply(_ preset: PipelineConfig) {
        var next = preset
        next.maxConcurrentRenders = config.maxConcurrentRenders
        next.workMultiplier = config.workMultiplier
        config = next
        Task { await RenderCoordinator.shared.purge() }
    }
}
