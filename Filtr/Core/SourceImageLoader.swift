import CoreGraphics
import Foundation
import ImageIO

/// Decodes source JPEGs off disk, at the size we actually intend to draw.
///
/// This sits *under* the filter pipeline and is its own cache tier: 96 photos share
/// 14 files, so a decode hit here saves work even when every render key is unique.
actor SourceImageLoader {
    static let shared = SourceImageLoader()

    private struct Key: Hashable {
        let name: String
        let maxPixel: Int   // bucketed
    }

    private var decoded: [Key: ImageBox] = [:]
    private var inFlight: [Key: Task<ImageBox, any Error>] = [:]
    private var insertionOrder: [Key] = []
    private let cacheLimit = 24

    enum LoadError: Error { case missingFile(String), decodeFailed(String) }

    func image(named name: String, maxPixel: CGFloat, downsample: Bool) async throws -> ImageBox {
        // Bucket to 256pt steps. Without this, every slightly different tile size
        // mints a new cache entry and the cache stops being a cache.
        let bucket = downsample ? Int((maxPixel / 256).rounded(.up)) * 256 : 0
        let key = Key(name: name, maxPixel: bucket)

        if let hit = decoded[key] { return hit }

        // Decode coalescing: two tiles backed by the same file don't both hit the disk.
        if let existing = inFlight[key] { return try await existing.value }

        let task = Task<ImageBox, any Error>.detached(priority: Task.currentPriority) {
            try Self.decode(name: name, maxPixel: bucket > 0 ? CGFloat(bucket) : nil)
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }

        let box = try await task.value
        store(box, for: key)
        return box
    }

    private func store(_ box: ImageBox, for key: Key) {
        if decoded[key] == nil { insertionOrder.append(key) }
        decoded[key] = box
        while insertionOrder.count > cacheLimit {
            decoded.removeValue(forKey: insertionOrder.removeFirst())
        }
    }

    func purge() {
        decoded.removeAll()
        insertionOrder.removeAll()
    }

    /// The whole downsampling argument in one function.
    ///
    /// `CGImageSourceCreateThumbnailAtIndex` decodes straight to the target size — the
    /// full bitmap never exists. `CGImageSourceCreateImageAtIndex` materialises all
    /// 3000x2000 of it, ~24 MB, so it can be drawn into a 120pt square.
    private nonisolated static func decode(name: String, maxPixel: CGFloat?) throws -> ImageBox {
        guard let url = PhotoLibrary.url(forSource: name) else {
            throw LoadError.missingFile(name)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw LoadError.decodeFailed(name)
        }

        let image: CGImage?
        if let maxPixel {
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ] as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(source, 0, [
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary)
        }

        guard let image else { throw LoadError.decodeFailed(name) }
        let box = ImageBox(image)
        MetricsRecorder.shared.decoded(bytes: box.byteCount)
        return box
    }
}
