import Foundation
import Testing
import ManualItems

// ─────────────────────────────────────────────────────────────────────────────
// The store's contract, in the module's priority order:
//
//   P1. NEVER LOSE WHAT THE STUDENT TYPED — atomic writes leave no debris and
//       no half-file; a corrupt file is quarantined, never overwritten.
//   P2. NEVER BLANK THE MENU — missing/unreadable/corrupt all load as [].
//   P3. Identity round-trips — delete hands back the exact item, and
//       re-adding it restores the same UUID (that IS the undo).
//
// Everything is hermetic: each test gets its own temp root, so no test can see
// the real $BSB_ROOT or another test's file.
// ─────────────────────────────────────────────────────────────────────────────

/// A fresh directory per test, torn down after.
private func withTempStore(_ body: (ManualItemStore, URL) throws -> Void) throws {
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "manual-items-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(ManualItemStore(fileURL: dir.appending(path: "manual-items.json")), dir)
}

/// A valid item; dates are fixed so encoded files are deterministic.
private func makeItem(
    name: String = "Ch. 4 problem set",
    kind: ManualItem.Kind = .assignment,
    due: Date = Date(timeIntervalSince1970: 1_760_000_000)
) -> ManualItem {
    ManualItem(courseId: 12345, kind: kind, name: name, link: "https://example.edu/x", due: due)!
}

@Suite struct ManualItemStoreTests {

    // ── P2: absence is emptiness, never an error ─────────────────────────────

    @Test func missingFileLoadsAsEmpty() throws {
        try withTempStore { store, _ in
            #expect(store.load() == [])
            #expect(store.snapshot().quarantined == nil)
        }
    }

    // ── Round trip ───────────────────────────────────────────────────────────

    @Test func addedItemsRoundTripThroughDisk() throws {
        try withTempStore { store, _ in
            let a = makeItem(name: "Quiz 3", kind: .quiz)
            let b = makeItem(name: "Midterm", kind: .test)
            try store.add(a)
            try store.add(b)
            // A brand-new store over the same file — nothing lives in memory.
            let reread = ManualItemStore(fileURL: store.fileURL)
            #expect(reread.load() == [a, b])
        }
    }

    @Test func datesSurviveEncodingToTheSecond() throws {
        // ISO-8601 carries whole seconds; the store must not depend on
        // sub-second Date precision to consider items equal after a reload.
        try withTempStore { store, _ in
            let item = makeItem(due: Date(timeIntervalSince1970: 1_760_000_000))
            try store.add(item)
            #expect(ManualItemStore(fileURL: store.fileURL).load() == [item])
        }
    }

    // ── P1: atomicity — temp+rename, observable from the outside ─────────────

    @Test func saveLeavesExactlyOneFileNoTempDebris() throws {
        try withTempStore { store, dir in
            try store.add(makeItem())
            let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            #expect(names == ["manual-items.json"])   // no .tmp survived the rename
        }
    }

    @Test func failedWriteCleansUpItsTempAndPreservesTheOldFile() throws {
        try withTempStore { store, dir in
            let survivor = makeItem(name: "survivor")
            try store.add(survivor)
            // Make the destination un-replaceable: rename(2) onto a path inside
            // a read-only directory fails, which is the crash-adjacent case the
            // temp+rename dance exists for.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o555], ofItemAtPath: dir.path)
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755], ofItemAtPath: dir.path)
            }
            #expect(throws: (any Error).self) { try store.add(makeItem(name: "doomed")) }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: dir.path)
            // Old data intact, and no temp debris left in the watched directory.
            #expect(store.load() == [survivor])
            let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            #expect(names == ["manual-items.json"])
        }
    }

    // ── P1+P2: corruption is quarantined, reported, and non-fatal ────────────

    @Test func corruptFileLoadsEmptyAndIsPreservedAside() throws {
        try withTempStore { store, dir in
            let garbage = "{ not json ["
            try garbage.write(to: store.fileURL, atomically: true, encoding: .utf8)

            let snapshot = store.snapshot()
            #expect(snapshot.items == [])
            let aside = try #require(snapshot.quarantined)
            #expect(aside.lastPathComponent == "manual-items.json.corrupt")
            // The bytes are preserved verbatim — nothing rewrote them.
            #expect(try String(contentsOf: aside, encoding: .utf8) == garbage)
            _ = dir
        }
    }

    @Test func saveAfterCorruptionDoesNotDestroyTheCorruptBytes() throws {
        try withTempStore { store, _ in
            let garbage = "]]]]"
            try garbage.write(to: store.fileURL, atomically: true, encoding: .utf8)

            let item = makeItem()
            try store.add(item)   // must quarantine first, then start fresh

            #expect(store.load() == [item])
            let aside = URL(fileURLWithPath: store.fileURL.path + ".corrupt")
            #expect(try String(contentsOf: aside, encoding: .utf8) == garbage)
        }
    }

    @Test func healthySnapshotReportsNoQuarantine() throws {
        try withTempStore { store, _ in
            try store.add(makeItem())
            #expect(store.snapshot().quarantined == nil)
        }
    }

    // ── P3: add / delete / undo ──────────────────────────────────────────────

    @Test func deleteReturnsTheRemovedItemAndPersists() throws {
        try withTempStore { store, _ in
            let keep = makeItem(name: "keep")
            let drop = makeItem(name: "drop")
            try store.add(keep)
            try store.add(drop)

            let removed = try store.delete(id: drop.id)
            #expect(removed == drop)
            #expect(ManualItemStore(fileURL: store.fileURL).load() == [keep])
        }
    }

    @Test func deleteOfUnknownIdIsANoOp() throws {
        try withTempStore { store, _ in
            let item = makeItem()
            try store.add(item)
            #expect(try store.delete(id: UUID()) == nil)
            #expect(store.load() == [item])
        }
    }

    @Test func undoIsReAddingWhatDeleteReturned() throws {
        try withTempStore { store, _ in
            let item = makeItem(name: "oops")
            try store.add(item)
            let removed = try #require(try store.delete(id: item.id))
            try store.add(removed)   // the undo
            // Same UUID, same everything — identity survived the round trip.
            #expect(store.load() == [item])
        }
    }

    // ── The value type's one validation ──────────────────────────────────────

    @Test func emptyLinkRefusesToConstruct() {
        #expect(ManualItem(
            courseId: 1, kind: .test, name: "x", link: "  \n", due: .distantFuture) == nil)
    }
}
