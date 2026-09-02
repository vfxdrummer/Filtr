import SwiftUI

@main
struct FiltrApp: App {
    @State private var model = AppModel()
    @State private var metrics = MetricsStore()

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
        }
    }
}
