import Foundation
import Testing
import BrightspaceSession

/// A scratch directory that deletes itself, so no test shares state with another.
private struct TempDir: ~Copyable {
    let url: URL

    init() throws {
        self.url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "brightspacesession-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: self.url, withIntermediateDirectories: true)
    }

    func write(_ json: String, to name: String = "session.json") throws -> URL {
        let file = self.url.appending(path: name)
        try Data(json.utf8).write(to: file)
        return file
    }

    deinit {
        try? FileManager.default.removeItem(at: self.url)
    }
}

/// A capture in the exact shape experiment 1 writes — including the extra fields
/// (`capturedAt`, `cookies`) the provider must tolerate and ignore.
private let capturedShape = """
{
  "capturedAt": 1786230000000,
  "baseUrl": "https://purdue.brightspace.com",
  "cookieHeader": "d2lSessionVal=AAAA; d2lSecureSessionVal=BBBB",
  "csrfToken": "CCCC",
  "cookies": [{"name": "d2lSessionVal", "value": "AAAA"}],
  "landedUrl": "https://purdue.brightspace.com/d2l/home"
}
"""

@Suite("FileSessionProvider — the file-backed session seam")
struct FileSessionProviderTests {

    @Test("a real capture yields all three fields")
    func readsARealCapture() async throws {
        // Arrange
        let dir = try TempDir()
        let provider = FileSessionProvider(fileURL: try dir.write(capturedShape))

        // Act
        let session = try await provider.session()

        // Assert
        #expect(session.baseUrl == "https://purdue.brightspace.com")
        #expect(session.cookieHeader == "d2lSessionVal=AAAA; d2lSecureSessionVal=BBBB")
        #expect(session.csrfToken == "CCCC")
    }

    @Test("a capture without a CSRF token still loads, with nil")
    func csrfTokenIsOptional() async throws {
        // Arrange
        let dir = try TempDir()
        let provider = FileSessionProvider(fileURL: try dir.write(
            #"{"baseUrl": "https://x.example", "cookieHeader": "a=b"}"#
        ))

        // Act
        let session = try await provider.session()

        // Assert
        #expect(session.csrfToken == nil)
    }

    @Test("a missing file is .unavailable, not a crash and not .malformed")
    func missingFileIsUnavailable() async throws {
        // Arrange
        let dir = try TempDir()
        let provider = FileSessionProvider(fileURL: dir.url.appending(path: "does-not-exist.json"))

        // Act / Assert
        await #expect(throws: SessionError.unavailable("no session file at does-not-exist.json")) {
            _ = try await provider.session()
        }
    }

    @Test("a file that is not the expected shape is .malformed")
    func garbageIsMalformed() async throws {
        // Arrange
        let dir = try TempDir()
        let provider = FileSessionProvider(fileURL: try dir.write("<html>login page</html>"))

        // Act / Assert
        await #expect(throws: SessionError.malformed("session file was not the expected shape")) {
            _ = try await provider.session()
        }
    }

    @Test("the file is re-read on every call — a refreshed capture wins without a relaunch")
    func rereadsOnEveryCall() async throws {
        // Arrange — same path, contents replaced between calls, exactly what
        // Scripts/refresh-session.sh does to a running app.
        let dir = try TempDir()
        let file = try dir.write(#"{"baseUrl": "https://x.example", "cookieHeader": "cookie=v1"}"#)
        let provider = FileSessionProvider(fileURL: file)
        let first = try await provider.session()

        // Act
        try Data(#"{"baseUrl": "https://x.example", "cookieHeader": "cookie=v2"}"#.utf8)
            .write(to: file)
        let second = try await provider.session()

        // Assert
        #expect(first.cookieHeader == "cookie=v1")
        #expect(second.cookieHeader == "cookie=v2")
    }

    @Test("errors never carry the credential")
    func errorsCarryNoSecret() async throws {
        // Arrange — a file whose *content* is secret-shaped but malformed enough
        // to throw. If the error ever echoes the body, this catches it.
        let dir = try TempDir()
        let provider = FileSessionProvider(fileURL: try dir.write("d2lSessionVal=SECRETSECRET"))

        // Act
        var thrown: SessionError?
        do { _ = try await provider.session() } catch let error as SessionError { thrown = error }

        // Assert
        let description = String(describing: try #require(thrown))
        #expect(!description.contains("SECRET"))
    }
}

@Suite("StaticSessionProvider")
struct StaticSessionProviderTests {

    @Test("returns exactly the value it was given")
    func returnsItsValue() async throws {
        // Arrange
        let value = BrightspaceSession(baseUrl: "https://x.example", cookieHeader: "a=b", csrfToken: nil)

        // Act / Assert
        #expect(try await StaticSessionProvider(value).session() == value)
    }
}
