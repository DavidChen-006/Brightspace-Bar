import Foundation
import Testing

import CourseMenu

// ═════════════════════════════════════════════════════════════════════════════
// StatusText — the pure formatter the GUI calls at menu-open.
//
// PRIORITY: HONESTY AT THE MOMENT OF DISPLAY. This string is the only place the
// app talks about time, and it is minted against the `now` of the person
// actually looking — so every rule is pinned as (date in, string out) with no
// clock anywhere. The "Refreshes" table is experiment 18's.
//
// SCOPE: Google-small. Pure function, plain values.
// ═════════════════════════════════════════════════════════════════════════════

private let epoch = Date(timeIntervalSince1970: 1_786_230_000)

@Suite("StatusText — stamps to display strings")
struct StatusTextTests {

    // ── Refreshes (the countdown) ────────────────────────────────────────────

    @Test(
        "the countdown rounds to the nearest minute, so it is never more than 30s wrong",
        arguments: [
            (TimeInterval(60), "Refreshes in 1 minute"),
            (TimeInterval(89), "Refreshes in 1 minute"),
            (TimeInterval(90), "Refreshes in 2 minutes"),
            (TimeInterval(14 * 60 + 30), "Refreshes in 15 minutes"),
            (TimeInterval(15 * 60), "Refreshes in 15 minutes"),
            (TimeInterval(3600), "Refreshes in 60 minutes"),
        ]
    )
    func countdownRoundsToTheNearestMinute(remaining: TimeInterval, expected: String) {
        let title = StatusText.title(for: .nextRefresh(epoch.addingTimeInterval(remaining)), now: epoch)
        #expect(title == expected)
    }

    @Test(
        "under a minute — and past the deadline — the countdown folds into soon",
        arguments: [TimeInterval(59), TimeInterval(1), TimeInterval(0), TimeInterval(-300)]
    )
    func imminentOrPastDeadlineSaysSoon(remaining: TimeInterval) {
        // A deadline in the past is a timer about to fire (or a Mac waking from
        // sleep, where the coalesced fire is seconds away) — never an error, and
        // never "Refreshes in -5 minutes".
        let title = StatusText.title(for: .nextRefresh(epoch.addingTimeInterval(remaining)), now: epoch)
        #expect(title == "Refreshes soon")
        #expect(!title.contains("-"))
    }
}
