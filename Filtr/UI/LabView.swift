import SwiftUI

/// Every switch here removes one real technique from the pipeline. Flip one, dismiss,
/// hit "Restyle All", and watch the HUD. That before/after is the whole demo.
struct LabView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            Form {
                Section {
                    Button("Everything on") { model.apply(.strict) }
                    Button("Everything off (naive)", role: .destructive) { model.apply(.naive) }
                } header: {
                    Text("Presets")
                } footer: {
                    Text("“Naive” is roughly what a first pass at this looks like: no cache, no coalescing, no cancellation, unbounded fan-out, full-resolution decodes.")
                }

                Section("Techniques") {
                    toggle($model.config.coalesceRequests,
                           "Coalesce duplicate requests",
                           "Callers asking for the same key share one Task. Off: identical work runs N times.")

                    toggle($model.config.boundConcurrency,
                           "Bound concurrency",
                           "Async semaphore in front of the renders. Off: a fling-scroll starts every render at once.")

                    toggle($model.config.honorCancellation,
                           "Honour cancellation",
                           "Drop work for tiles that scrolled away. Off: on-screen tiles wait behind invisible ones.")

                    toggle($model.config.useCache,
                           "Cache finished renders",
                           "Cost-limited NSCache. Off: scrolling back up re-renders everything.")

                    toggle($model.config.downsampleSources,
                           "Downsample on decode",
                           "ImageIO decodes straight to the target size. Off: full 3000px decode per photo — watch the “decoded” number.")

                    toggle($model.config.usePriorityHints,
                           "Priority hints",
                           "Visible work is .userInitiated, prefetch is .utility. Off: everything is .medium.")

                    toggle($model.config.renderOnMainThread,
                           "Render on the main thread",
                           "The cardinal sin. Leave this on for a few seconds of scrolling and watch the hitch counter.",
                           destructive: true)
                }

                Section("Load") {
                    Stepper(value: $model.config.maxConcurrentRenders, in: 1...16) {
                        LabeledContent("Max concurrent renders", value: "\(model.config.maxConcurrentRenders)")
                            .font(.system(.body, design: .default))
                    }
                    Stepper(value: $model.config.workMultiplier, in: 1...8) {
                        LabeledContent("Filter chain passes", value: "\(model.config.workMultiplier)×")
                    }
                    Text("This machine reports \(ProcessInfo.processInfo.activeProcessorCount) active cores.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button("Purge caches") { model.purgeCaches() }
                } footer: {
                    Text("Drops rendered images and decoded sources so the next scroll starts cold.")
                }
            }
            .navigationTitle("Pipeline Lab")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func toggle(_ binding: Binding<Bool>, _ title: String, _ explanation: String, destructive: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: binding)
                .tint(destructive ? .red : .green)
            Text(explanation)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
