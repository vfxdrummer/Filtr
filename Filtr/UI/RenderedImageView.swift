import CoreGraphics
import SwiftUI

/// The one place a rendered image is requested, anywhere in the app.
///
/// `.task(id:)` is doing the heavy lifting and is worth reading carefully. SwiftUI
/// starts the task when the view appears, **cancels it when the view disappears**, and
/// cancels-then-restarts it whenever `id` changes. That single line gives us:
///
/// * scroll-away cancellation, for free, with no reuse token to get wrong;
/// * correct behaviour when the filter changes under a tile that is still on screen —
///   the stale render is cancelled rather than racing the new one to the same `@State`.
///
/// The classic UIKit bug this design eliminates is the wrong image landing in a
/// recycled cell. Here there is no recycled cell: the identity *is* the request.
struct RenderedImageView<Placeholder: View>: View {
    let photo: Photo
    let recipe: FilterRecipe
    let intensity: Double
    var adjustments: Adjustments = .neutral
    let targetPoints: CGFloat
    var priority: TaskPriority = .userInitiated
    @ViewBuilder var placeholder: () -> Placeholder

    @Environment(\.displayScale) private var displayScale
    @Environment(AppModel.self) private var model

    @State private var rendered: CGImage?
    @State private var failed = false

    private struct Identity: Hashable {
        let photoID: Int
        let recipeID: String
        let intensityBucket: Int
        let adjustments: Adjustments
        let points: Int
        let work: Int
        let downsample: Bool
    }

    private var identity: Identity {
        Identity(
            photoID: photo.id,
            recipeID: recipe.id,
            intensityBucket: Int((intensity * 20).rounded()),
            adjustments: adjustments.quantized(),
            points: Int(targetPoints.rounded()),
            work: model.config.workMultiplier,
            downsample: model.config.downsampleSources
        )
    }

    var body: some View {
        ZStack {
            if let rendered {
                Image(decorative: rendered, scale: displayScale, orientation: .up)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                placeholder()
            }
        }
        .animation(.easeOut(duration: 0.18), value: rendered != nil)
        .task(id: identity) {
            #if DEBUG
            if ProcessInfo.processInfo.environment["FILTR_TRACE"] != nil {
                print("TASK photo=\(photo.id) recipe=\(recipe.id) pts=\(identity.points) scale=\(displayScale)")
            }
            #endif
            await load()
        }
    }

    private func load() async {
        guard targetPoints >= 1 else { return }
        let key = RenderCoordinator.Key(
            photo: photo,
            recipe: recipe,
            intensity: intensity,
            adjustments: adjustments,
            maxPixel: targetPoints * displayScale,
            workMultiplier: model.config.workMultiplier
        )
        do {
            let box = try await RenderCoordinator.shared.image(for: key, priority: priority)
            // If we were cancelled while suspended, don't publish. Writing to @State
            // here would resurrect a tile the user has already scrolled past.
            guard !Task.isCancelled else { return }
            rendered = box.cgImage
            failed = false
        } catch is CancellationError {
            // Expected and normal. Cancellation is the pipeline working, not failing.
        } catch {
            guard !Task.isCancelled else { return }
            failed = true
        }
    }
}

extension RenderedImageView where Placeholder == TilePlaceholder {
    init(
        photo: Photo,
        recipe: FilterRecipe,
        intensity: Double,
        adjustments: Adjustments = .neutral,
        targetPoints: CGFloat,
        priority: TaskPriority = .userInitiated
    ) {
        self.init(photo: photo, recipe: recipe, intensity: intensity, adjustments: adjustments,
                  targetPoints: targetPoints, priority: priority) {
            TilePlaceholder(seed: photo.id)
        }
    }
}

/// A cheap, deterministic stand-in so the grid has structure before anything renders.
struct TilePlaceholder: View {
    let seed: Int

    var body: some View {
        let shade = 0.10 + Double((seed &* 37) % 7) / 60
        Rectangle()
            .fill(Color(white: shade))
            .overlay(alignment: .center) {
                ProgressView()
                    .controlSize(.mini)
                    .tint(Color(white: 0.45))
            }
    }
}
