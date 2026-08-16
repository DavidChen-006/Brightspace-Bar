import Foundation
import Testing
import CoursePipeline

// ═════════════════════════════════════════════════════════════════════════════
// MfaBadge — the heart of BUILD 2, and the only part of it with no I/O.
//
// The daemon writes `cache/mfa.json` = `{"number":"20","mintedAt":"<ISO>"}` while
// a login challenge is up, and deletes it on every exit path. What the icon shows
// is a PURE FUNCTION of that file's bytes and the current time:
//
//     state(fileContents:now:) -> .code(number) | .logo
//
// PRIORITIES (the two carrying the value here):
//
//   1. STATELESSNESS. There is no "challenge finished" message, and there does
//      not need to be, because the answer is recomputed from scratch every time.
//      The TTL is applied at RENDER time, not at write time, which is what makes
//      a crashed rung unable to wedge a stale number in the menu bar forever —
//      the deletion is the daemon's courtesy, the TTL is the app's guarantee.
//      Every boundary below is a statement about that guarantee.
//
//   2. WHAT REACHES THE MENU BAR. The number is display-by-design (useless
//      without the phone), but it is still a string another program wrote into a
//      file, rendered into the system UI. Anything that is not a short run of
//      ASCII digits is not an MFA number and must not be drawn: the icon falls
//      back to the logo, which is the correct behaviour for "I do not understand
//      this file" as well as for "there is no file".
//
// SCOPE: small. Bytes in, enum out — no filesystem, no clock, no AppKit.
// The reading of those bytes off a real disk is `MfaWatcherTests`' business.
// ═════════════════════════════════════════════════════════════════════════════

/// The instant the fixture challenge was minted. `now` in every test below is
/// this plus an explicit age, so the age is visible in the test rather than
/// buried in two timestamps the reader has to subtract.
private let minted = MfaFixture.mintedAt

/// Files that are not a challenge. `(why, bytes)` — the reason travels with the
/// case so a failure names it.
private let notAChallenge: [(String, String)] = [
    ("empty file", ""),
    ("whitespace only", "   \n"),
    ("truncated json", "{\"number\": \"20\", "),
    ("not json at all", "20"),
    ("a json array", "[{\"number\": \"20\"}]"),
    ("a bare json string", "\"20\""),
    ("json null", "null"),
    ("no number field", "{ \"mintedAt\": \"\(MfaFixture.mintedAtLiteral)\" }"),
    ("no mintedAt field", "{ \"number\": \"20\" }"),
    ("an empty object", "{}"),
    // The contract says the number is a STRING. A writer that emits `20` has
    // broken the contract, and the app's job is to notice rather than to guess.
    ("number as a json number", "{ \"number\": 20, \"mintedAt\": \"\(MfaFixture.mintedAtLiteral)\" }"),
    ("number as null", "{ \"number\": null, \"mintedAt\": \"\(MfaFixture.mintedAtLiteral)\" }"),
    ("mintedAt as a json number", "{ \"number\": \"20\", \"mintedAt\": 1786802400 }"),
    ("mintedAt is not a date", "{ \"number\": \"20\", \"mintedAt\": \"yesterday\" }"),
    ("mintedAt is a date but not ISO-8601", "{ \"number\": \"20\", \"mintedAt\": \"08/15/2026 14:00\" }"),
    ("mintedAt is empty", "{ \"number\": \"20\", \"mintedAt\": \"\" }"),
]

/// Strings that are not an MFA number. The real Entra display sign is two ASCII
/// digits; anything wilder is either a bug upstream or something that has no
/// business being drawn into the menu bar.
private let notANumber: [(String, String)] = [
    ("empty", ""),
    ("a letter for a digit", "2O"),
    ("letters", "ab"),
    ("an inner space", "1 2"),
    ("padded with spaces", " 20 "),
    ("a newline", "2\n0"),
    ("a sign", "-1"),
    ("a decimal point", "2.0"),
    ("five digits", "12345"),
    ("far too long", "01234567890123456789"),
    // Non-ASCII digits: `CharacterSet.decimalDigits` accepts these, which is
    // precisely why they are pinned — the check must be ASCII 0-9.
    ("arabic-indic digits", "٢٠"),
    ("fullwidth digits", "２０"),
    ("emoji", "2️⃣0️⃣"),
]

/// `(age in seconds, whether the number is still shown)`. The rule is
/// `now - mintedAt < 60`, so 60 exactly is already too old.
private let ages: [(TimeInterval, Bool)] = [
    (0, true),        // the instant it was written
    (1, true),
    (59, true),
    (59.999, true),   // the last moment it is shown
    (60, false),      // the boundary itself: strictly less than, so this is out
    (60.001, false),
    (120, false),
    (86_400, false),  // a file the daemon crashed without deleting, a day later
    // A stamp from the future is the clock-skew case. Both processes read the
    // same machine clock, so this is a fraction of a second in practice; the
    // formula's own reading of it (a negative age is less than the TTL) is the
    // safe direction — the number shows.
    (-0.5, true),
    (-5, true),
]

@Suite("MfaBadge — what the icon shows, computed from nothing but the file and the clock")
struct MfaBadgeTests {

    // MARK: - The happy path

    @Test("a fresh challenge file shows its number")
    func aFreshFileShowsTheNumber() {
        // Arrange — exactly what the daemon writes, milliseconds and all.
        let bytes = MfaFixture.data(MfaFixture.fresh)

        // Act
        let state = MfaBadge.state(fileContents: bytes, now: minted.addingTimeInterval(3))

        // Assert
        #expect(state == .code("20"))
    }

    @Test("a timestamp without milliseconds is still a timestamp")
    func secondsPrecisionIsAccepted() {
        // Arrange — `JSONDecoder`'s stock `.iso8601` strategy accepts this one and
        // rejects the millisecond form the daemon actually writes, so a reader
        // that passes only this test is a reader that never works in production.
        let bytes = MfaFixture.data(
            MfaFixture.json(number: "\"20\"", mintedAtLiteral: "2026-08-15T14:00:00Z")
        )

        // Act
        let state = MfaBadge.state(fileContents: bytes, now: minted.addingTimeInterval(3))

        // Assert
        #expect(state == .code("20"))
    }

    @Test("fields the app does not know about are ignored")
    func unknownFieldsAreTolerated() {
        // Arrange — the daemon will grow fields (a challenge id, a rung name).
        // A reader that failed on them would make every daemon release a
        // breaking one, which is the rule `DaemonCache` already follows.
        let bytes = MfaFixture.data("""
            { "number": "20", "mintedAt": "\(MfaFixture.mintedAtLiteral)",
              "challengeId": "abc", "attempt": 2 }
            """)

        // Act
        let state = MfaBadge.state(fileContents: bytes, now: minted.addingTimeInterval(3))

        // Assert
        #expect(state == .code("20"))
    }

    @Test("a one-digit number is shown", arguments: ["7", "0", "20", "99", "007", "1234"])
    func plausibleNumbersAreShown(_ number: String) {
        // Arrange — Entra shows two digits today. One to four ASCII digits are
        // accepted so a change on Microsoft's side does not silently blank the
        // icon, and five is refused so nothing absurd can widen the menu bar.
        let bytes = MfaFixture.data(MfaFixture.json(number: number, mintedAt: minted))

        // Act
        let state = MfaBadge.state(fileContents: bytes, now: minted)

        // Assert
        #expect(state == .code(number))
    }

    // MARK: - Nothing to show

    @Test("no file means the logo")
    func aMissingFileShowsTheLogo() {
        // Arrange — nil is "there is no readable file", which is the state the
        // app is in for all but a few seconds of its life.

        // Act
        let state = MfaBadge.state(fileContents: nil, now: minted)

        // Assert
        #expect(state == .logo)
    }

    @Test("a file that is not a challenge means the logo", arguments: notAChallenge)
    func unreadableFilesShowTheLogo(_ why: String, _ json: String) {
        // Arrange — half of these are what a reader sees mid-write if it ever
        // read a file that was not renamed into place atomically.
        let bytes = MfaFixture.data(json)

        // Act
        let state = MfaBadge.state(fileContents: bytes, now: minted)

        // Assert
        #expect(state == .logo, "\(why) should not reach the menu bar")
    }

    @Test("a number that is not a number means the logo", arguments: notANumber)
    func implausibleNumbersShowTheLogo(_ why: String, _ number: String) {
        // Arrange — a well-formed file whose only problem is what it wants drawn.
        let bytes = MfaFixture.data(MfaFixture.json(number: number, mintedAt: minted))

        // Act
        let state = MfaBadge.state(fileContents: bytes, now: minted)

        // Assert
        #expect(state == .logo, "\(why) is not an MFA number")
    }

    // MARK: - The TTL, applied at render time

    @Test("the number lasts sixty seconds and not a moment longer", arguments: ages)
    func theTtlIsCheckedWhenTheIconIsDrawn(_ age: TimeInterval, _ isShown: Bool) {
        // Arrange — one file, many `now`s. Nothing about the file changes; the
        // clock moving is the entire mechanism by which the icon reverts.
        let bytes = MfaFixture.data(MfaFixture.fresh)

        // Act
        let state = MfaBadge.state(fileContents: bytes, now: minted.addingTimeInterval(age))

        // Assert
        #expect(state == (isShown ? .code("20") : .logo), "at age \(age)s")
    }

    @Test("the sixty seconds is the published constant, not a number in two places")
    func theTtlIsSixtySeconds() {
        // Arrange / Act — the daemon's resend policy and phase C's E2E both need
        // to name this, and a TTL duplicated between them drifts.

        // Assert
        #expect(MfaBadge.ttl == 60)
    }

    // MARK: - When to look again (the revert with no filesystem event behind it)

    @Test("a shown number asks to be re-checked when it expires")
    func revertDelayIsWhatIsLeftOfTheTtl() {
        // Arrange — nothing will touch the file when the challenge lapses: the
        // daemon may be gone. The app therefore has to schedule its own revert,
        // and this is the pure half of that decision.
        let bytes = MfaFixture.data(MfaFixture.fresh)

        // Act
        let delay = MfaBadge.revertDelay(fileContents: bytes, now: minted.addingTimeInterval(10))

        // Assert
        #expect(delay == 50)
    }

    @Test("a challenge just written asks for the whole sixty seconds")
    func revertDelayAtZeroAgeIsTheWholeTtl() {
        // Arrange
        let bytes = MfaFixture.data(MfaFixture.fresh)

        // Act
        let delay = MfaBadge.revertDelay(fileContents: bytes, now: minted)

        // Assert
        #expect(delay == 60)
    }

    @Test("a challenge about to lapse asks for the fraction that is left")
    func revertDelayNearTheBoundaryIsSmall() {
        // Arrange
        let bytes = MfaFixture.data(MfaFixture.fresh)

        // Act
        let delay = MfaBadge.revertDelay(fileContents: bytes, now: minted.addingTimeInterval(59.5))

        // Assert
        #expect(delay != nil)
        #expect(abs((delay ?? 0) - 0.5) < 0.001, "expected about half a second, got \(delay ?? -1)")
    }

    @Test("nothing on the icon means nothing to schedule")
    func revertDelayIsNilWhenTheLogoIsShowing() {
        // Arrange — a revert timer for a logo is a wakeup that can only decide
        // to do nothing. Each of these already renders `.logo`.
        let expired = MfaFixture.data(MfaFixture.fresh)
        let malformed = MfaFixture.data("{ not json")
        let implausible = MfaFixture.data(MfaFixture.json(number: "ab", mintedAt: minted))

        // Act / Assert
        #expect(MfaBadge.revertDelay(fileContents: nil, now: minted) == nil)
        #expect(MfaBadge.revertDelay(fileContents: expired, now: minted.addingTimeInterval(60)) == nil)
        #expect(MfaBadge.revertDelay(fileContents: malformed, now: minted) == nil)
        #expect(MfaBadge.revertDelay(fileContents: implausible, now: minted) == nil)
    }

    @Test("state and revertDelay never disagree", arguments: ages)
    func theTwoAnswersAreConsistent(_ age: TimeInterval, _ isShown: Bool) {
        // Arrange — the invariant tying the pair together: a delay is scheduled
        // exactly when something is on screen to take back down.
        let bytes = MfaFixture.data(MfaFixture.fresh)
        let now = minted.addingTimeInterval(age)

        // Act
        let delay = MfaBadge.revertDelay(fileContents: bytes, now: now)

        // Assert
        #expect((delay != nil) == isShown, "at age \(age)s")
    }
}

@Suite("DaemonPaths — where the challenge file lives")
struct MfaPathTests {

    @Test("mfa.json sits in the cache directory the daemon writes")
    func theChallengeFileIsUnderCache() {
        // Arrange — the app watches `cache/`; a challenge file resolved anywhere
        // else would be written into a directory nobody is watching. Spelled out
        // rather than derived, so a change to either side fails here.
        let paths = DaemonPaths(root: URL(fileURLWithPath: "/tmp/bsb-root"))

        // Act
        let file = paths.mfaFile

        // Assert
        #expect(file.path == "/tmp/bsb-root/cache/mfa.json")
        #expect(file.deletingLastPathComponent().path == paths.cacheDirectory.path)
    }
}
