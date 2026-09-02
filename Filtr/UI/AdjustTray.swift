import SwiftUI

/// The Adjust toolset: pick a tool, drag one slider.
///
/// One slider at a time is a deliberate copy of VSCO, and it happens to be the right
/// call for the pipeline too — a single continuously-changing parameter produces one
/// stream of render keys, so cancellation and coalescing have a clean job to do. A
/// panel of twelve live sliders would produce twelve interleaved streams and mostly
/// render frames nobody ever sees.
struct AdjustTray: View {
    @Binding var adjustments: Adjustments
    @State private var selected: AdjustTool = .exposure

    private var value: Binding<Double> {
        Binding(
            get: { adjustments[selected] },
            set: { adjustments[selected] = $0 }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            sliderRow
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 10)

            Divider().overlay(Color(white: 0.16))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(AdjustTool.allCases) { tool in
                        chip(tool)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .background(.black.opacity(0.94))
    }

    private var sliderRow: some View {
        VStack(spacing: 4) {
            HStack {
                Text(selected.title.uppercased())
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(white: 0.55))

                Spacer()

                Text(readout)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isNeutral ? Color(white: 0.55) : .white)
                    .monospacedDigit()

                Button {
                    adjustments[selected] = 0
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color(white: 0.5))
                .disabled(isNeutral)
                .opacity(isNeutral ? 0.3 : 1)
            }

            Slider(value: value, in: selected.range)
                .tint(.white)
        }
    }

    private var isNeutral: Bool { abs(adjustments[selected]) < 0.001 }

    private var readout: String {
        let scaled = adjustments[selected] * 100
        if selected.isBipolar {
            return scaled > 0.5 ? String(format: "+%.0f", scaled) : String(format: "%.0f", scaled)
        }
        return String(format: "%.0f", scaled)
    }

    private func chip(_ tool: AdjustTool) -> some View {
        let active = abs(adjustments[tool]) > 0.001
        let isSelected = tool == selected

        return Button {
            selected = tool
        } label: {
            VStack(spacing: 5) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: tool.symbol)
                        .font(.system(size: 17, weight: .light))
                        .frame(width: 46, height: 40)
                        .foregroundStyle(isSelected ? .white : Color(white: 0.6))

                    if active {
                        Circle()
                            .fill(.white)
                            .frame(width: 4, height: 4)
                            .padding(.top, 3)
                            .padding(.trailing, 5)
                    }
                }

                Text(tool.title)
                    .font(.system(size: 9, weight: isSelected ? .semibold : .regular, design: .monospaced))
                    .foregroundStyle(isSelected ? .white : Color(white: 0.5))
            }
            .frame(width: 62)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
