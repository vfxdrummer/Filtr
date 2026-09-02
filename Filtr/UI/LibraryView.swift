import SwiftUI

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(MetricsStore.self) private var metrics
    @Environment(\.displayScale) private var displayScale

    @State private var selected: Photo?
    @State private var gridWidth: CGFloat = 0

    private let spacing: CGFloat = 2
    private let columns = 3

    private var side: CGFloat {
        guard gridWidth > 0 else { return 0 }
        return ((gridWidth - spacing * CGFloat(columns - 1)) / CGFloat(columns)).rounded(.down)
    }

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            // Deliberately *not* a GeometryReader wrapping the ScrollView. That
            // arrangement reports a zero-width first pass, which meant every tile
            // started a render at a nonsense size and then immediately restarted —
            // 96 wasted renders on every cold launch — and the unbounded height
            // proposal in that pass also defeated LazyVGrid's laziness, so all 96
            // tiles were instantiated at once instead of the ~18 on screen.
            ScrollView {
                if side > 0 {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.fixed(side), spacing: spacing), count: columns),
                        spacing: spacing
                    ) {
                        ForEach(Array(model.photos.enumerated()), id: \.element.id) { index, photo in
                            tile(for: photo, index: index)
                        }
                    }
                    .padding(.bottom, 8)
                } else {
                    Color.clear.frame(height: 1)
                }
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
            .background(.black)
            .overlay(alignment: .topLeading) {
                if model.showHUD {
                    HUDView()
                        .padding(12)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: model.showHUD)
            .navigationTitle("Filtr")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .navigationDestination(item: $selected) { photo in
                EditorView(photo: photo)
            }
            .sheet(isPresented: $model.showLab) {
                LabView().presentationDetents([.large])
            }
            .onChange(of: side) { model.gridTileSide = side }
        }
        .tint(.white)
    }

    /// The feed cell. Its render identity is the photo's *saved* edit, so committing an
    /// edit in the editor is all it takes for this to re-render — there is no
    /// invalidation call, no notification, and no image being pushed in from outside.
    private func tile(for photo: Photo, index: Int) -> some View {
        Button {
            selected = photo
        } label: {
            RenderedImageView(
                photo: photo,
                recipe: model.recipe(for: photo),
                intensity: model.edit(for: photo).intensity,
                targetPoints: side
            )
            .frame(width: side, height: side)
            .clipped()
            .overlay(alignment: .bottomLeading) {
                if model.isEdited(photo) {
                    Text(model.edit(for: photo).recipeID)
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 2))
                        .padding(4)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onAppear { prefetchAhead(of: index) }
    }

    /// Warm a short runway of tiles below the fold.
    ///
    /// This is where request coalescing earns its place: by the time a prefetched tile
    /// scrolls into view its render is usually already in flight, and the visible
    /// request joins that job instead of starting a second identical one.
    ///
    /// Deliberately short. Lookahead is a bet, and every prefetched render competes for
    /// the same permits as the tile the user is looking at — which is why prefetch goes
    /// in the semaphore's background lane and gets `.utility`.
    private func prefetchAhead(of index: Int) {
        let start = index + 1
        let end = min(start + 6, model.photos.count)
        guard start < end, side > 0 else { return }

        let keys = model.photos[start..<end].map { photo in
            let edit = model.edit(for: photo)
            return RenderCoordinator.Key(
                photo: photo,
                recipe: edit.recipe,
                intensity: edit.intensity,
                maxPixel: side * displayScale,
                workMultiplier: model.config.workMultiplier
            )
        }
        Task { await RenderCoordinator.shared.prefetch(keys) }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                model.showHUD.toggle()
            } label: {
                Image(systemName: model.showHUD ? "gauge.with.dots.needle.67percent" : "gauge.with.dots.needle.0percent")
            }
            .accessibilityLabel("Toggle instrumentation")
        }

        ToolbarItemGroup(placement: .topBarTrailing) {
            // Bulk edits — and the stress test. 96 saved edits change in one frame.
            Menu {
                Button("Restyle all (one preset)") { model.restyleAll() }
                Button("Scramble (all different)") { model.scramble() }
                Divider()
                Button("Revert all to original", role: .destructive) { model.revertAll() }
            } label: {
                Image(systemName: "wand.and.stars")
            }
            .accessibilityLabel("Bulk edit")

            Button {
                model.showLab = true
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .accessibilityLabel("Pipeline lab")
        }
    }
}
