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
            // tiles were instantiated at once instead of the ~24 on screen.
            //
            // Measuring the ScrollView itself and holding the grid back until the
            // width is real fixes both.
            ScrollView {
                if side > 0 {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.fixed(side), spacing: spacing), count: columns),
                        spacing: spacing
                    ) {
                        ForEach(Array(model.photos.enumerated()), id: \.element.id) { index, photo in
                            Button {
                                selected = photo
                            } label: {
                                RenderedImageView(
                                    photo: photo,
                                    recipe: model.recipe(for: photo),
                                    intensity: model.intensity,
                                    targetPoints: side
                                )
                                .frame(width: side, height: side)
                                .clipped()
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .onAppear { prefetchAhead(of: index) }
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
            .safeAreaInset(edge: .bottom, spacing: 0) {
                FilterStrip(selection: $model.globalRecipe)
                    .onChange(of: model.globalRecipe) { model.overrides.removeAll() }
            }
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
                LabView()
                    .presentationDetents([.large])
            }
        }
        .tint(.white)
    }

    /// Warm a short runway of tiles below the fold.
    ///
    /// This is where request coalescing earns its place: by the time a prefetched tile
    /// scrolls into view its render is usually already in flight, and the visible
    /// request joins that job instead of starting a second identical one.
    ///
    /// Deliberately short. Lookahead is a bet, and every prefetched render competes
    /// for the same permits as the tile the user is looking at — which is exactly why
    /// prefetch goes in the semaphore's background lane and gets `.utility`.
    private func prefetchAhead(of index: Int) {
        let start = index + 1
        let end = min(start + 6, model.photos.count)
        guard start < end, side > 0 else { return }

        let keys = model.photos[start..<end].map { photo in
            RenderCoordinator.Key(
                photo: photo,
                recipe: model.recipe(for: photo),
                intensity: model.intensity,
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
            // The stress test: 96 tiles change render identity in one frame.
            Button {
                model.restyleAll()
            } label: {
                Image(systemName: "wand.and.stars")
            }
            .accessibilityLabel("Restyle all")

            // Same load, but every key is unique — nothing can be coalesced.
            Button {
                model.scramble()
            } label: {
                Image(systemName: "shuffle")
            }
            .accessibilityLabel("Scramble")

            Button {
                model.showLab = true
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .accessibilityLabel("Pipeline lab")
        }
    }
}
