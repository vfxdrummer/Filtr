import SwiftUI

struct HUDView: View {
    @Environment(MetricsStore.self) private var metrics
    @Environment(AppModel.self) private var model
    @State private var expanded = true

    private var s: MetricsSnapshot { metrics.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    row("in flight", "\(s.inFlight)", detail: "peak \(s.peakInFlight)",
                        warn: s.inFlight > model.config.maxConcurrentRenders)
                    row("queued", "\(s.waiting)")
                    row("done", "\(s.completed)", detail: String(format: "avg %.0fms", s.averageRenderMillis))
                    row("cancelled", "\(s.cancelled)", detail: String(format: "%.0f%% waste", s.wasteRate * 100))
                    row("coalesced", "\(s.coalesced)")
                    row("cache", String(format: "%.0f%%", s.cacheHitRate * 100),
                        detail: "\(s.cacheHits)/\(s.cacheHits + s.cacheMisses)")
                    row("decoded", String(format: "%.0f MB", Double(s.bytesDecoded) / 1_048_576),
                        warn: !model.config.downsampleSources)
                    row("hitches", "\(s.hitches)", detail: String(format: "worst %.0fms", s.worstFrameMillis),
                        warn: s.hitches > 0)

                    Sparkline(values: s.recent)
                        .frame(height: 26)
                        .padding(.top, 5)

                    Text("render ms · last \(s.recent.count)")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(Color(white: 0.4))
                }
                .padding(.top, 7)
            }
        }
        .padding(9)
        .frame(width: expanded ? 186 : 120, alignment: .leading)
        .background(Color(white: 0.04).opacity(0.97), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color(white: 0.28), lineWidth: 0.5)
        }
        .animation(.easeInOut(duration: 0.18), value: expanded)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(s.inFlight > 0 ? Color.green : Color(white: 0.3))
                .frame(width: 5, height: 5)
            Text("PIPELINE")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color(white: 0.8))
            Spacer(minLength: 4)
            Button { metrics.reset() } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 8, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color(white: 0.5))
            Button { expanded.toggle() } label: {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color(white: 0.5))
        }
    }

    private func row(_ label: String, _ value: String, detail: String? = nil, warn: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Color(white: 0.45))
            Spacer(minLength: 2)
            if let detail {
                Text(detail)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(Color(white: 0.35))
            }
            Text(value)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(warn ? Color.orange : Color(white: 0.92))
                .monospacedDigit()
        }
    }
}

struct Sparkline: View {
    let values: [Double]

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let maxValue = max(values.max() ?? 1, 1)
            let step = size.width / CGFloat(max(values.count - 1, 1))

            var path = Path()
            for (index, value) in values.enumerated() {
                let x = CGFloat(index) * step
                let y = size.height - CGFloat(value / maxValue) * size.height
                if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }

            var fill = path
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()

            context.fill(fill, with: .linearGradient(
                Gradient(colors: [Color.green.opacity(0.28), Color.green.opacity(0.02)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)
            ))
            context.stroke(path, with: .color(.green.opacity(0.85)), lineWidth: 1)
        }
    }
}
