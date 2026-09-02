import SwiftUI

struct FilterSwatch: View {
    let recipe: FilterRecipe
    var size: CGFloat = 34

    var body: some View {
        let (r, g, b) = recipe.swatch
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(
                recipe.id == FilterRecipe.original.id
                ? AnyShapeStyle(LinearGradient(colors: [Color(white: 0.28), Color(white: 0.62)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing))
                : AnyShapeStyle(Color(red: r, green: g, blue: b))
            )
            .frame(width: size, height: size)
    }
}

/// Horizontal preset picker. In the editor each chip renders a *live* preview of the
/// photo through that filter — 12 simultaneous renders of the same source, which is
/// exactly where the decode cache and request coalescing earn their keep.
struct FilterStrip: View {
    @Binding var selection: FilterRecipe
    var previewPhoto: Photo?
    var intensity: Double = 1

    private let thumb: CGFloat = 56

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(FilterRecipe.all) { recipe in
                    Button {
                        selection = recipe
                    } label: {
                        VStack(spacing: 6) {
                            ZStack {
                                if let previewPhoto {
                                    RenderedImageView(
                                        photo: previewPhoto,
                                        recipe: recipe,
                                        intensity: intensity,
                                        targetPoints: thumb,
                                        priority: .userInitiated
                                    )
                                } else {
                                    FilterSwatch(recipe: recipe, size: thumb)
                                }
                            }
                            .frame(width: thumb, height: thumb)
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .strokeBorder(.white, lineWidth: selection.id == recipe.id ? 1.5 : 0)
                            }

                            Text(recipe.name)
                                .font(.system(size: 10, weight: selection.id == recipe.id ? .semibold : .regular, design: .monospaced))
                                .foregroundStyle(selection.id == recipe.id ? .white : Color(white: 0.55))
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .background(.black.opacity(0.92))
    }
}
