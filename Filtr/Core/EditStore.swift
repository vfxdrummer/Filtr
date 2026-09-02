import Foundation

/// On-disk home for the edit document.
///
/// A single small JSON file in Application Support. Deliberately not SwiftData or Core
/// Data: what we're persisting is one flat map of value types, a few KB at most, and
/// the interesting problems here are *when* you write and how you survive being killed
/// mid-write — not object graphs or queries.
actor EditStore {
    static let shared = EditStore()

    private struct Record: Codable {
        var photoID: Int
        var edit: Edit
    }

    /// Versioned envelope so a future schema change has somewhere to branch.
    private struct Document: Codable {
        var version: Int
        var records: [Record]
    }

    private static let currentVersion = 1

    private let url: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Filtr", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("edits.json")
    }()

    var fileURL: URL { url }

    /// Synchronous on purpose — see `AppModel.init`.
    nonisolated static func loadSync() -> [Int: Edit]? {
        let store = EditStore()
        guard let data = try? Data(contentsOf: store.url) else { return nil }
        guard let document = try? JSONDecoder().decode(Document.self, from: data) else {
            // Corrupt or from a future build: start clean rather than crash on launch.
            return [:]
        }
        guard document.version == currentVersion else { return [:] }
        return Dictionary(uniqueKeysWithValues: document.records.map { ($0.photoID, $0.edit) })
    }

    func save(_ edits: [Int: Edit]) {
        let document = Document(
            version: Self.currentVersion,
            // Sorted so the file is stable and diffable rather than reshuffling on
            // every write.
            records: edits.sorted { $0.key < $1.key }.map { Record(photoID: $0.key, edit: $0.value) }
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(document)
            // `.atomic` writes a temp file and renames it. Without it, being killed
            // mid-write leaves a truncated file and the user loses every edit, not
            // just the one in flight.
            try data.write(to: url, options: .atomic)
        } catch {
            // Losing an edit is bad; crashing the app over it is worse.
            print("EditStore: save failed — \(error)")
        }
    }

    func deleteAll() {
        try? FileManager.default.removeItem(at: url)
    }
}
