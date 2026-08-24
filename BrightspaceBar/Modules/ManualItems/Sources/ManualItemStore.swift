import Foundation
import CoursePipeline

/// The disk home of the student's own items: `$BSB_ROOT/manual-items.json`.
///
/// Root resolution is `DaemonPaths.resolve` — reused, not mirrored, because
/// CoursePipeline is already the shared-vocabulary module every backend module
/// imports, and two transcriptions of `paths.mjs` would be two places to drift.
/// The file sits at the root, **not** under `cache/`: `cache/` is the daemon's
/// output directory (it may clear or rewrite it wholesale), while this file is
/// user data the daemon must never touch. Same reasoning that keeps
/// `session.json` at the root on the Node side.
///
/// Invariants, in priority order — the same ones `CourseCache` lives by:
///
///   P1. NEVER LOSE WHAT THE STUDENT TYPED. Every write is temp+rename in the
///       same directory (the `atomic-write.mjs` pattern), so a crash mid-save
///       leaves either the old file or the new file, never a truncated one.
///       A file that fails to decode is quarantined aside as
///       `manual-items.json.corrupt` *before* any save can overwrite it.
///
///   P2. NEVER BLANK THE MENU. A missing, unreadable, or corrupt file loads
///       as an empty list — the corruption is *reported* in the snapshot, not
///       thrown, because no caller has a better recovery than "show what we
///       have and say so".
///
/// The store is stateless (a path plus codecs); every operation reads the file
/// fresh, so two windows into the same root cannot hold divergent memories.
public struct ManualItemStore: Sendable {

    /// What a read found: the items, plus — when the file existed but did not
    /// decode — where its bytes were preserved. `quarantined == nil` is the
    /// healthy case (including the missing-file case).
    public struct Snapshot: Equatable, Sendable {
        public let items: [ManualItem]
        /// Non-nil exactly when a malformed file was found and moved aside to
        /// this URL. The caller may surface it; the data is safe either way.
        public let quarantined: URL?
    }

    /// `manual-items.json` under the resolved root.
    public let fileURL: URL

    /// Production wiring: the same root the daemon and the cache reader use.
    public init(paths: DaemonPaths = .resolve()) {
        self.fileURL = paths.root.appending(path: "manual-items.json")
    }

    /// Test seam: point the store anywhere (a temp directory in tests).
    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    // ── Reading ──────────────────────────────────────────────────────────────

    /// The simple read: items only. Missing, unreadable, or corrupt → `[]`.
    public func load() -> [ManualItem] {
        self.snapshot().items
    }

    /// The full read. A corrupt file is moved aside (quarantined) here, at
    /// first contact, so no later save can destroy the only copy of whatever
    /// it held. Quarantine overwrites any previous quarantine: one bad file
    /// aside is a breadcrumb, a pile of them is litter.
    public func snapshot() -> Snapshot {
        guard let data = try? Data(contentsOf: self.fileURL) else {
            return Snapshot(items: [], quarantined: nil)   // missing/unreadable → empty
        }
        if let items = try? Self.decoder.decode([ManualItem].self, from: data) {
            return Snapshot(items: items, quarantined: nil)
        }
        // The file exists but is not our JSON. Preserve the bytes verbatim.
        let aside = URL(fileURLWithPath: self.fileURL.path + ".corrupt")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: self.fileURL, to: aside)
        return Snapshot(items: [], quarantined: aside)
    }

    // ── Mutating ─────────────────────────────────────────────────────────────

    /// Append one item and persist. Returns the full list as saved, so a
    /// caller can refresh a menu without a second read.
    @discardableResult
    public func add(_ item: ManualItem) throws -> [ManualItem] {
        var items = self.snapshot().items   // quarantines a corrupt file first (P1)
        items.append(item)
        try self.write(items)
        return items
    }

    /// Remove the item with `id` and persist. Returns the removed item —
    /// that value *is* the undo: re-`add` it and the same UUID comes back,
    /// so identity survives the round trip. No history stack, by design.
    /// Returns nil (and writes nothing) when no such item exists.
    @discardableResult
    public func delete(id: UUID) throws -> ManualItem? {
        var items = self.snapshot().items
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = items.remove(at: index)
        try self.write(items)
        return removed
    }

    // ── The one write path ───────────────────────────────────────────────────

    /// Temp file in the SAME directory, then rename — `atomic-write.mjs`
    /// transcribed. Same directory because rename is only atomic within one
    /// filesystem; cleanup on failure so the root never accumulates debris.
    private func write(_ items: [ManualItem]) throws {
        let directory = self.fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = directory.appending(
            path: ".\(self.fileURL.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier).tmp"
        )
        do {
            try Self.encoder.encode(items).write(to: temp)
            // rename(2) directly — it replaces any existing destination
            // atomically, which `FileManager.moveItem` refuses to do and
            // `replaceItemAt` only does when a destination already exists.
            guard rename(temp.path, self.fileURL.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    // ── Codecs — fixed, so files are stable across OS versions ───────────────

    /// ISO-8601 dates and sorted keys: the file is meant to be readable (and
    /// diffable) by a human with a text editor, like everything else in
    /// `$BSB_ROOT`.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
