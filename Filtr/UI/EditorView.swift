import SwiftUI

struct EditorView: View {
    let photo: Photo

    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var displayScale

    @State private var recipe: FilterRecipe = FilterRecipe.recipe(id: "A6")
    @State private var intensity: Double = 1.0
    @State private var exportState: ExportState = .idle

    enum ExportState: Equatable {
        case idle
        case working
        case done(millis: Double, pixels: String, megabytes: Double)
        case failed
    }

    var body: some View {
        GeometryReader { proxy in
            let side = proxy.size.width

            VStack(spacing: 0) {
                RenderedImageView(
                    photo: photo,
                    recipe: recipe,
                    intensity: intensity,
                    targetPoints: side
                )
                .frame(width: side, height: side)
                .clipped()

                intensityRow
                    .padding(.horizontal, 18)
                    .padding(.top, 18)

                exportRow
                    .padding(.horizontal, 18)
                    .padding(.top, 14)

                Spacer(minLength: 0)
            }
        }
        .background(.black)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Each chip is a live render of *this* photo. Twelve of them at once, all
            // sharing one decoded source — the decode cache turns 12 disk reads into 1.
            FilterStrip(selection: $recipe, previewPhoto: photo, intensity: intensity)
        }
        .navigationTitle(photo.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.black, for: .navigationBar)
        .onAppear { recipe = model.recipe(for: photo) }
        .onChange(of: recipe) { exportState = .idle }
        .onChange(of: intensity) { exportState = .idle }
    }

    private var intensityRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("INTENSITY")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(white: 0.5))
                Spacer()
                Text(String(format: "%.0f", intensity * 100))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(white: 0.75))
            }
            // The slider is continuous but the render key buckets to 5% steps, so a
            // full drag produces at most 20 distinct renders — and every one of them
            // is reusable on the way back.
            Slider(value: $intensity, in: 0...1)
                .tint(.white)
        }
        .disabled(recipe.id == FilterRecipe.original.id)
        .opacity(recipe.id == FilterRecipe.original.id ? 0.35 : 1)
    }

    private var exportRow: some View {
        HStack(spacing: 12) {
            Button {
                Task { await export(maxPixel: 2400) }
            } label: {
                HStack(spacing: 8) {
                    if exportState == .working {
                        ProgressView().controlSize(.mini).tint(.black)
                    }
                    Text(exportState == .working ? "RENDERING" : "EXPORT FULL SIZE")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(.white)
                .foregroundStyle(.black)
            }
            .buttonStyle(.plain)
            .disabled(exportState == .working)
        }
        .overlay(alignment: .bottom) {
            Group {
                if case let .done(millis, pixels, megabytes) = exportState {
                    Text(String(format: "%@ · %.0f ms · %.1f MB bitmap", pixels, millis, megabytes))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color(white: 0.55))
                        .offset(y: 20)
                } else if exportState == .failed {
                    Text("export failed")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.red.opacity(0.8))
                        .offset(y: 20)
                }
            }
        }
    }

    /// The second tier of the pipeline. Grid tiles render at ~120pt because that is all
    /// anyone can see; the full-size render only happens once, on demand, when the user
    /// actually commits. Doing this eagerly for every thumbnail is the mistake that
    /// makes photo grids feel broken.
    private func export(maxPixel: CGFloat) async {
        exportState = .working
        let key = RenderCoordinator.Key(
            photo: photo,
            recipe: recipe,
            intensity: intensity,
            maxPixel: maxPixel,
            workMultiplier: model.config.workMultiplier
        )
        let started = CFAbsoluteTimeGetCurrent()
        do {
            let box = try await RenderCoordinator.shared.image(for: key, priority: .userInitiated)
            exportState = .done(
                millis: (CFAbsoluteTimeGetCurrent() - started) * 1000,
                pixels: "\(box.cgImage.width)×\(box.cgImage.height)",
                megabytes: Double(box.byteCount) / 1_048_576
            )
        } catch is CancellationError {
            exportState = .idle
        } catch {
            exportState = .failed
        }
    }
}
