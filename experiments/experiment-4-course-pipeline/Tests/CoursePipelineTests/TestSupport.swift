import Foundation
import CoursePipeline

// ─────────────────────────────────────────────────────────────────────────────
// SHARED TEST SUPPORT — owned by the orchestrator, like Contracts.swift.
// Three test suites are being written in parallel against this. Do not edit it;
// add your own support files instead.
// ─────────────────────────────────────────────────────────────────────────────

/// A `Clock` you drive by hand. Nothing in this package may call `Date()`, and no
/// test may `sleep` — staleness and intervals are tested by advancing this.
public final class TestClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    /// Fixed default epoch so failures are reproducible.
    public init(_ start: Date = Date(timeIntervalSince1970: 1_786_230_000)) {
        self.current = start
    }

    public var now: Date {
        self.lock.withLock { self.current }
    }

    public func advance(by seconds: TimeInterval) {
        self.lock.withLock { self.current += seconds }
    }

    public func set(_ date: Date) {
        self.lock.withLock { self.current = date }
    }
}

/// Loads the real captured payloads in `Tests/CoursePipelineTests/Fixtures/`.
///
/// Resolved via `#filePath` rather than `Bundle.module` deliberately — it needs no
/// `resources:` entry in `Package.swift`, which three parallel agents would otherwise
/// contend on.
public enum Fixture {
    public static var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures")
    }

    public static func data(_ name: String) throws -> Data {
        try Data(contentsOf: self.directory.appending(path: name))
    }

    public static func string(_ name: String) throws -> String {
        try String(decoding: self.data(name), as: UTF8.self)
    }

    /// The genuine 27-course success body, 14,938 bytes.
    public static var enrollments: Data { get throws { try self.data("myenrollments-200.json") } }

    /// The 294-byte HTML stub the token mint returns at HTTP 200 for a dead session.
    public static var sessionExpiredStub: Data { get throws { try self.data("session-expired-stub.html") } }
}

/// A scratch directory that deletes itself. Cache tests must not share state.
public struct TempDir: ~Copyable {
    public let url: URL

    public init() throws {
        self.url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "coursepipeline-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: self.url, withIntermediateDirectories: true)
    }

    public func file(_ name: String = "courses.json") -> URL {
        self.url.appending(path: name)
    }

    deinit {
        try? FileManager.default.removeItem(at: self.url)
    }
}
