import Foundation

/// What the menu-bar icon is showing: the book, or a verification number.
///
/// Two cases and nothing else — there is no "expired" or "unreadable" state,
/// because everything the app cannot draw a number from means the same thing to
/// the icon, and a third case would only invite a caller to treat them
/// differently.
public enum IconState: Equatable, Sendable {
    case logo
    case code(String)
}

/// The icon, as a pure function of `cache/mfa.json`'s bytes and the clock.
///
/// The daemon writes that file while an Entra number-matching challenge is up
/// (`{"number":"20","mintedAt":"<ISO>"}`) and deletes it on every exit path. It
/// would be simpler to treat that deletion as the "challenge over" message and
/// keep the number on screen until it arrives — and a rung that crashed
/// mid-challenge would then wedge a dead number in the menu bar until the app
/// was quit. So the deletion is the daemon's courtesy and the TTL is the app's
/// guarantee: the answer is recomputed from scratch at render time, the file
/// carries no state the app has to remember, and nothing that goes wrong on the
/// other side of the boundary can outlive sixty seconds here.
///
/// The other half of the job is refusing to draw. The number is
/// display-by-design — useless without the phone in David's hand — but it is
/// still a string another program put in a file and this one paints into the
/// system UI. Anything that is not a short run of ASCII digits is not an MFA
/// number, and "I do not understand this file" gets the same answer as "there
/// is no file": the logo.
public enum MfaBadge {

    /// How long a number is worth showing. Published because phase C's E2E and
    /// the daemon's resend policy both have to name the same sixty seconds.
    public static let ttl: TimeInterval = 60

    /// What to draw, given the file (or nil when there is no readable one).
    ///
    /// `ttl` is a parameter only so a test can run the whole mechanism in a
    /// second instead of a minute; every caller in the app takes the default.
    public static func state(
        fileContents: Data?, now: Date, ttl: TimeInterval = Self.ttl
    ) -> IconState {
        guard let challenge = Self.challenge(fileContents, now: now, ttl: ttl) else { return .logo }
        return .code(challenge.number)
    }

    /// How long until the shown number lapses, or nil when nothing is shown.
    ///
    /// The revert has no filesystem event behind it: when a challenge simply
    /// times out, the daemon may already be gone and nothing will ever touch the
    /// file again. So whoever is drawing has to schedule its own re-check, and
    /// this is the pure half of that decision — a delay is offered exactly when
    /// `state` put something on screen to take back down.
    public static func revertDelay(
        fileContents: Data?, now: Date, ttl: TimeInterval = Self.ttl
    ) -> TimeInterval? {
        guard let challenge = Self.challenge(fileContents, now: now, ttl: ttl) else { return nil }
        return ttl - now.timeIntervalSince(challenge.mintedAt)
    }

    /// The challenge those two agree on: readable, plausible, and still young.
    /// A stamp from the *future* is the clock-skew case — both processes read
    /// the same machine clock, so it is a fraction of a second in practice, and
    /// a negative age being under the TTL is the safe direction anyway.
    private static func challenge(
        _ fileContents: Data?, now: Date, ttl: TimeInterval
    ) -> (number: String, mintedAt: Date)? {
        guard
            let fileContents,
            let file = try? JSONDecoder().decode(ChallengeFile.self, from: fileContents),
            Self.isPlausibleNumber(file.number),
            let mintedAt = Self.date(from: file.mintedAt),
            now.timeIntervalSince(mintedAt) < ttl
        else {
            return nil
        }
        return (file.number, mintedAt)
    }

    /// One to four ASCII digits. Entra shows two today; the range is loose
    /// enough that a change on Microsoft's side does not silently blank the
    /// icon, and tight enough that nothing absurd can widen the menu bar.
    ///
    /// ASCII specifically — `CharacterSet.decimalDigits` accepts Arabic-indic
    /// and fullwidth digits, which are not what a phone is showing.
    private static func isPlausibleNumber(_ number: String) -> Bool {
        (1...4).contains(number.count) && number.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Both ISO-8601 shapes, because the two writers disagree: Node's
    /// `toISOString()` always emits milliseconds, and a Swift reader that
    /// accepted only whole seconds (which is what `JSONDecoder`'s stock
    /// `.iso8601` strategy does) would work in every test and never in
    /// production.
    private static func date(from text: String) -> Date? {
        (try? Self.fractional.parse(text)) ?? (try? Self.wholeSeconds.parse(text))
    }

    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let wholeSeconds = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

    /// `mfa.json`, as written. `mintedAt` is decoded as text and parsed
    /// afterwards so that a writer emitting a JSON *number* for either field
    /// fails the decode rather than being guessed at — the contract says both
    /// are strings. Unknown fields are ignored, the rule `DaemonCache` already
    /// follows: the daemon will grow a challenge id or a rung name, and a reader
    /// that failed on them would make every daemon release a breaking one.
    private struct ChallengeFile: Decodable {
        let number: String
        let mintedAt: String
    }
}
