import CoreGraphics
import Foundation

/// A `CGImage` crossing an isolation boundary.
///
/// `CGImage` is immutable once created, so passing one between actors is safe — but
/// the compiler can't prove that for an imported C type, so under strict concurrency
/// this box is where we make the promise explicitly rather than sprinkling
/// `nonisolated(unsafe)` around the pipeline.
struct ImageBox: @unchecked Sendable {
    let cgImage: CGImage

    init(_ cgImage: CGImage) { self.cgImage = cgImage }

    var pixelSize: CGSize { CGSize(width: cgImage.width, height: cgImage.height) }

    /// What this bitmap actually costs in memory — the number the HUD reports, and the
    /// number that makes the downsampling argument concrete.
    var byteCount: Int { cgImage.height * cgImage.bytesPerRow }
}
