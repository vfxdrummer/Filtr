import SwiftUI

/// An edit session. Everything here is a *draft* until Save commits it; Discard throws
/// it away and the feed never sees it.
struct EditorView: View {
    let photo: Photo

    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var displayScale
    @Environment(\.dismiss) private var dismiss

    @State private var draft: Edit = .none
    @State private var saved: Edit = .none
    @State private var isSaving = false
    @State private var confirmDiscard = false
    @State private var exportState: ExportState = .idle

    private var isDirty: Bool { draft != saved }

    enum ExportState: Equatable {
        case idle, working
        case done(millis: Double, pixels: String, megabytes: Double)
        case failed
    }

    var body: some View {
        GeometryReader { proxy in
            let side = proxy.size.width

            VStack(spacing: 0) {
                RenderedImageView(
                    photo: photo,
                    recipe: draft.recipe,
                    intensity: draft.intensity,
                    targetPoints: side
                )
                .frame(width: side, height: side)
                .clipped()
                .overlay(alignment: .topTrailing) {
                    if isDirty {
                        Text("UNSAVED")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.6), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(10)
                    }
                }

                intensityRow
                    .padding(.horizontal, 18)
                    .padding(.top, 18)

                exportRow
                    .padding(.horizontal, 18)
                    .padding(.top, 16)

                Spacer(minLength: 0)
            }
        }
        .background(.black)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            FilterStrip(
                selection: Binding(
                    get: { draft.recipe },
                    set: { draft.recipeID = $0.id }
                ),
                previewPhoto: photo,
                intensity: draft.intensity
            )
        }
        .navigationBarBackButtonHidden(true)
        .navigationTitle(photo.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.black, for: .navigationBar)
        .toolbar { toolbar }
        .onAppear {
            saved = model.edit(for: photo)
            draft = saved
        }
        .onChange(of: draft) { exportState = .idle }
        .confirmationDialog("Discard changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("Your edits to \(photo.title) won't be saved.")
        }
        .interactiveDismissDisabled(isDirty)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                if isDirty { confirmDiscard = true } else { dismiss() }
            } label: {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("Discard")
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button {
                Task { await save() }
            } label: {
                if isSaving {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Text("SAVE")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                }
            }
            .disabled(!isDirty || isSaving)
        }
    }

    // MARK: - The commit

    /// Save is the whole point of the exercise: the edit has to land on the feed
    /// thumbnail, not just in the editor.
    ///
    /// The ordering matters. We render the feed-sized thumbnail **before** writing the
    /// edit, so that by the time the grid tile's `.task(id:)` re-fires for the new
    /// identity, the render is already sitting in the cache and resolves in the same
    /// frame. Commit first and you get a guaranteed placeholder flash on the tile the
    /// user is looking straight at as the editor dismisses.
    ///
    /// Note what we are *not* doing: pushing a `CGImage` into a shared
    /// `[photoID: image]` dictionary. That is the version of this that has the classic
    /// bug — two saves in flight, the slower one lands last, and the feed shows the
    /// edit the user already replaced. Here the render key *is* the edit, so a stale
    /// render can only ever populate a stale cache entry that nothing asks for.
    private func save() async {
        isSaving = true
        defer { isSaving = false }

        let committed = draft

        if model.gridTileSide > 0 {
            let key = RenderCoordinator.Key(
                photo: photo,
                recipe: committed.recipe,
                intensity: committed.intensity,
                maxPixel: model.gridTileSide * displayScale,
                workMultiplier: model.config.workMultiplier
            )
            _ = try? await RenderCoordinator.shared.image(for: key, priority: .userInitiated)
        }

        model.commit(committed, for: photo)
        saved = committed
        dismiss()
    }

    // MARK: - Controls

    private var intensityRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("INTENSITY")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(white: 0.5))
                Spacer()
                Text(String(format: "%.0f", draft.intensity * 100))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(white: 0.75))
            }
            // Continuous slider, but the render key buckets to 5% steps: a full drag
            // is at most 20 distinct renders, and every one is reusable on the way back.
            Slider(value: Binding(get: { draft.intensity }, set: { draft.intensity = $0 }), in: 0...1)
                .tint(.white)
        }
        .disabled(draft.isIdentity)
        .opacity(draft.isIdentity ? 0.35 : 1)
    }

    private var exportRow: some View {
        VStack(spacing: 6) {
            Button {
                Task { await export(maxPixel: 2400) }
            } label: {
                HStack(spacing: 8) {
                    if exportState == .working {
                        ProgressView().controlSize(.mini).tint(.white)
                    }
                    Text(exportState == .working ? "RENDERING" : "EXPORT FULL SIZE")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .overlay { Rectangle().strokeBorder(Color(white: 0.3), lineWidth: 1) }
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(exportState == .working)

            Group {
                if case let .done(millis, pixels, megabytes) = exportState {
                    Text(String(format: "%@ · %.0f ms · %.1f MB bitmap", pixels, millis, megabytes))
                } else if exportState == .failed {
                    Text("export failed").foregroundStyle(.red.opacity(0.8))
                } else {
                    Text("feed thumbnails render at \(Int(model.gridTileSide))pt")
                }
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Color(white: 0.45))
        }
    }

    /// The second tier. Thumbnails render at ~130pt because that is all anyone can see;
    /// the full-size pass happens once, on demand, when the user actually commits.
    private func export(maxPixel: CGFloat) async {
        exportState = .working
        let key = RenderCoordinator.Key(
            photo: photo,
            recipe: draft.recipe,
            intensity: draft.intensity,
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
