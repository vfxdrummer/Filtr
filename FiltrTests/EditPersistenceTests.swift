import Foundation
import Testing
@testable import Filtr

@Suite("Edit persistence")
struct EditPersistenceTests {

    private func temporaryURL() -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FiltrTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("edits.json")
    }

    @Test("Edits survive a save/load round trip")
    func roundTrip() async throws {
        let url = temporaryURL()
        let store = EditStore(url: url)

        let edits: [Int: Edit] = [
            3: Edit(recipeID: "A6", intensity: 0.75,
                    adjustments: Adjustments(exposure: 0.4, vignette: 0.2)),
            11: Edit(recipeID: "OG", intensity: 1.0, adjustments: Adjustments(shadows: -0.3)),
        ]
        await store.save(edits)

        let loaded = try #require(EditStore.loadSync(from: url))
        #expect(loaded == edits)
    }

    @Test("No file yet means first launch, not an empty library")
    func missingFileIsDistinguishableFromEmpty() {
        // nil tells AppModel to seed; [:] would mean "the user deleted everything".
        #expect(EditStore.loadSync(from: temporaryURL()) == nil)
    }

    /// The regression this locks down: Swift's synthesised `Decodable` throws on a
    /// missing key even when the property has a default, so adding a thirteenth tool
    /// would otherwise make every previously-saved file undecodable.
    @Test("A file written before a tool existed still loads")
    func olderFilesDecodeWithDefaults() throws {
        let url = temporaryURL()
        let json = """
        {
          "version": 1,
          "records": [
            {
              "photoID": 7,
              "edit": {
                "recipeID": "C1",
                "intensity": 0.5,
                "adjustments": { "exposure": 0.25, "contrast": -0.1 }
              }
            }
          ]
        }
        """
        try Data(json.utf8).write(to: url)

        let loaded = try #require(EditStore.loadSync(from: url))
        let edit = try #require(loaded[7])
        #expect(edit.recipeID == "C1")
        #expect(edit.adjustments.exposure == 0.25)
        #expect(edit.adjustments.vignette == 0, "an absent tool must default to neutral")
        #expect(edit.adjustments.grain == 0)
    }

    @Test("A corrupt file starts clean instead of crashing at launch")
    func corruptFileIsSurvivable() throws {
        let url = temporaryURL()
        try Data("{ this is not json".utf8).write(to: url)
        #expect(EditStore.loadSync(from: url) == [:])
    }

    @Test("A file from a future schema is ignored rather than misread")
    func futureVersionIsIgnored() throws {
        let url = temporaryURL()
        try Data(#"{"version": 99, "records": []}"#.utf8).write(to: url)
        #expect(EditStore.loadSync(from: url) == [:])
    }

    @Test("Saving replaces rather than merges")
    func savingReplaces() async throws {
        let url = temporaryURL()
        let store = EditStore(url: url)
        await store.save([1: Edit(recipeID: "A6", intensity: 1)])
        await store.save([2: Edit(recipeID: "C1", intensity: 1)])

        let loaded = try #require(EditStore.loadSync(from: url))
        #expect(loaded.keys.sorted() == [2])
    }
}

@Suite("Edit semantics")
struct EditSemanticsTests {

    @Test("An edit with no preset and no adjustments is not worth storing")
    func identityDetection() {
        #expect(Edit.none.isIdentity)
        #expect(!Edit(recipeID: "A6", intensity: 1).isIdentity)
        #expect(!Edit(recipeID: "OG", intensity: 1, adjustments: Adjustments(grain: 0.3)).isIdentity)
    }

    @Test("The feed badge reflects what was actually applied")
    func badgeReflectsContent() {
        #expect(Edit.none.badge == "")
        #expect(Edit(recipeID: "A6", intensity: 1).badge == "A6")
        #expect(Edit(recipeID: "OG", intensity: 1,
                     adjustments: Adjustments(exposure: 0.3, grain: 0.2)).badge == "ADJ 2")
        #expect(Edit(recipeID: "A6", intensity: 1,
                     adjustments: Adjustments(exposure: 0.3)).badge == "A6+1")
    }

    @Test("Active tool count ignores sub-threshold values")
    func activeCountIgnoresNoise() {
        #expect(Adjustments.neutral.activeCount == 0)
        #expect(Adjustments(exposure: 0.0001).activeCount == 0)
        #expect(Adjustments(exposure: 0.5, shadows: -0.2).activeCount == 2)
    }
}
