import Foundation
import SwiftUI

/// A committed edit. This is the document — the thing that survives leaving the editor
/// and the thing the feed thumbnail is derived from.
struct Edit: Equatable, Sendable, Codable {
    var recipeID: String
    var intensity: Double
    var adjustments: Adjustments = .neutral

    static let none = Edit(recipeID: FilterRecipe.original.id, intensity: 1.0)

    var recipe: FilterRecipe { FilterRecipe.recipe(id: recipeID) }
    var hasPreset: Bool { recipeID != FilterRecipe.original.id }
    /// An edit worth storing: either a preset or at least one slider off neutral.
    var isIdentity: Bool { !hasPreset && adjustments.isNeutral }

    /// Short label for the feed badge.
    var badge: String {
        let count = adjustments.activeCount
        if hasPreset { return count > 0 ? "\(recipeID)+\(count)" : recipeID }
        return count > 0 ? "ADJ \(count)" : ""
    }
}

@MainActor
@Observable
final class AppModel {
    let photos = PhotoLibrary.all

    /// Saved edits, keyed by photo. The feed renders from this and nothing else.
    private(set) var edits: [Int: Edit] = [:]

    /// The size the grid is currently drawing tiles at, so the editor can pre-render
    /// the feed thumbnail at exactly the right size before it commits.
    var gridTileSide: CGFloat = 0

    var config = PipelineConfig() {
        didSet {
            guard config != oldValue else { return }
            let snapshot = config
            Task { await RenderCoordinator.shared.update(config: snapshot) }
        }
    }

    var showHUD = true
    var showLab = false

    init() {
        // Read the document synchronously at launch.
        //
        // This is a deliberate exception to "no I/O on the main thread": the file is a
        // few KB and a single read, and doing it asynchronously would mean the feed
        // renders once with no edits and then visibly re-renders with them — paying a
        // guaranteed flash of wrong content plus 96 wasted renders to avoid a
        // sub-millisecond read. If this file ever grew to megabytes the trade would
        // flip, and the fix would be to show the feed from a small index while the
        // rest loads.
        if let stored = EditStore.loadSync() {
            edits = stored
        } else {
            seedLibrary()       // first launch only
            schedulePersist()
        }
    }

    func edit(for photo: Photo) -> Edit {
        edits[photo.id] ?? .none
    }

    func recipe(for photo: Photo) -> FilterRecipe {
        edit(for: photo).recipe
    }

    func isEdited(_ photo: Photo) -> Bool {
        guard let edit = edits[photo.id] else { return false }
        return !edit.isIdentity
    }

    /// Commit an edit. The only writer of `edits`, and it is `@MainActor`, so the feed
    /// can never observe a half-applied change.
    func commit(_ edit: Edit, for photo: Photo) {
        if edit.isIdentity {
            edits.removeValue(forKey: photo.id)
        } else {
            edits[photo.id] = edit
        }
        schedulePersist()
    }

    // MARK: - Bulk operations (also the load generator for the HUD)

    /// Apply one preset to every photo as a saved edit. 96 tiles change identity in a
    /// single frame — the worst case the pipeline has to survive.
    func restyleAll() {
        let current = edits[photos.first?.id ?? 0]?.recipeID
        let pool = FilterRecipe.all.filter { $0.id != current && $0.id != FilterRecipe.original.id }
        guard let pick = pool.randomElement() else { return }
        edits = Dictionary(uniqueKeysWithValues: photos.map {
            ($0.id, Edit(recipeID: pick.id, intensity: 1.0))
        })
        schedulePersist()
    }

    /// Same load, but every photo gets a different preset, so no two render keys match
    /// and coalescing has nothing to work with.
    func scramble() {
        let pool = FilterRecipe.all.filter { $0.id != FilterRecipe.original.id }
        var rng = SplitMix64(seed: UInt64(UInt32.random(in: .min ... .max)))
        edits = Dictionary(uniqueKeysWithValues: photos.map { photo in
            let recipe = pool[Int(rng.nextUnit() * Double(pool.count)) % pool.count]
            return (photo.id, Edit(recipeID: recipe.id, intensity: 0.6 + rng.nextUnit() * 0.4))
        })
        schedulePersist()
    }

    func revertAll() {
        edits.removeAll()
        schedulePersist()
    }

    // MARK: - Persistence

    private var persistTask: Task<Void, Never>?

    /// Debounced write.
    ///
    /// "Restyle all" changes 96 edits in one frame. Writing on every mutation would be
    /// 96 encodes and 96 file writes for one user action; coalescing them into a single
    /// write 400 ms later makes it one. The snapshot is taken at schedule time and the
    /// pending task is cancelled on every new change, so the write that eventually
    /// lands is always the newest state.
    private func schedulePersist() {
        persistTask?.cancel()
        let snapshot = edits
        persistTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await EditStore.shared.save(snapshot)
        }
    }

    /// Write immediately, skipping the debounce. Called when the app is backgrounded,
    /// because a debounce timer is no defence against being terminated 200 ms later.
    func flushEdits() async {
        persistTask?.cancel()
        persistTask = nil
        await EditStore.shared.save(edits)
    }

    func apply(_ preset: PipelineConfig) {
        var next = preset
        next.maxConcurrentRenders = config.maxConcurrentRenders
        next.workMultiplier = config.workMultiplier
        config = next
        Task { await RenderCoordinator.shared.purge() }
    }

    func purgeCaches() {
        Task { await RenderCoordinator.shared.purge() }
    }

    /// A feed you've already been using: most photos carry a saved edit, some don't.
    private func seedLibrary() {
        let pool = FilterRecipe.all.filter { $0.id != FilterRecipe.original.id }
        var rng = SplitMix64(seed: 0xF11732)
        for photo in photos {
            guard rng.nextUnit() < 0.7 else { continue }
            let recipe = pool[Int(rng.nextUnit() * Double(pool.count)) % pool.count]
            edits[photo.id] = Edit(recipeID: recipe.id, intensity: 0.7 + rng.nextUnit() * 0.3)
        }
    }
}
