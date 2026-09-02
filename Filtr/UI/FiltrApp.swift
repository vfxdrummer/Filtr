import SwiftUI

@main
struct FiltrApp: App {
    @State private var model = AppModel()
    @State private var metrics = MetricsStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(model)
                .environment(metrics)
                .preferredColorScheme(.dark)
                .task {
                    metrics.start()
                    await RenderCoordinator.shared.update(config: model.config)
                }
                .onChange(of: scenePhase) { _, phase in
                    // The debounce is a latency optimisation, not a durability
                    // guarantee. Leaving the foreground is the last reliable moment to
                    // get the document on disk.
                    if phase != .active {
                        Task { await model.flushEdits() }
                    }
                }
        }
    }
}
