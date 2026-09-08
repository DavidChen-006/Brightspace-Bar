import Foundation
import Testing
import ManualItems

// ─────────────────────────────────────────────────────────────────────────────
// The cross-language contract: `bsb add` (session-capture/src/bsb.mjs) writes
// `manual-items.json`, and THIS store decodes it. The two are written in
// different languages by different code, and the store's own rule makes the
// seam unforgiving — one entry the decoder rejects quarantines the whole file
// and empties every hand-added square in the menu.
//
// `Fixtures/manual-items-from-bsb.json` is a file the CLI really wrote (three
// drafts through `bsb add --batch`, in the Indianapolis zone). If the CLI's
// shape drifts — a kind the enum lacks, fractional seconds, a lowercase key —
// this is the test that goes red, on the Swift side, before a student's file
// does.
// ─────────────────────────────────────────────────────────────────────────────

private enum AgentFixture {
    static var directory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures")
    }
    static var fromBsb: URL { self.directory.appending(path: "manual-items-from-bsb.json") }
}

@Suite struct AgentContractTests {

    @Test func theFileBsbWritesDecodesWithoutQuarantine() throws {
        let store = ManualItemStore(fileURL: AgentFixture.fromBsb)
        let snapshot = store.snapshot()
        #expect(snapshot.quarantined == nil, "the store moved the CLI's file aside as corrupt")
        #expect(snapshot.items.count == 3)
        // The quarantine path would have MOVED the fixture; make sure it is still there.
        #expect(FileManager.default.fileExists(atPath: AgentFixture.fromBsb.path))
    }

    @Test func everyFieldSurvivesTheSeam() throws {
        let items = ManualItemStore(fileURL: AgentFixture.fromBsb).load()
        let midterm = try #require(items.first { $0.name == "Midterm 1" })
        #expect(midterm.courseId == 1631476)
        #expect(midterm.kind == .test)                       // the CLI mapped "exam" → test
        #expect(midterm.link == "https://example.edu/midterm")
        #expect(midterm.due == Date(timeIntervalSince1970: 1_791_311_400))   // 2026-10-06T18:30:00Z
        #expect(midterm.id == UUID(uuidString: "C17A9177-BE73-43B4-843F-04CD67E3AC8C"))

        let quiz = try #require(items.first { $0.name == "Quiz 1" })
        #expect(quiz.kind == .quiz)
        // A bare "2026-09-15" became 23:59 Indianapolis = 03:59Z next day.
        #expect(quiz.due == Date(timeIntervalSince1970: 1_789_531_140))
        #expect(quiz.link == "https://purdue.brightspace.com/d2l/home/1631476")

        let reading = try #require(items.first { $0.name == "Reading response 2" })
        #expect(reading.kind == .assignment)                 // "homework" → assignment
        #expect(reading.courseId == 1641791)
    }

    /// The store re-encodes what it decoded; a CLI item that round-trips
    /// through the Swift encoder unchanged is one the add-form could have made.
    @Test func aBsbItemRoundTripsThroughTheSwiftEncoder() throws {
        let items = ManualItemStore(fileURL: AgentFixture.fromBsb).load()
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "agent-contract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let copy = ManualItemStore(fileURL: dir.appending(path: "manual-items.json"))
        for item in items { try copy.add(item) }
        #expect(ManualItemStore(fileURL: copy.fileURL).load() == items)
    }
}
