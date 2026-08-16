import Foundation
import Testing

import CourseMenu

// ═════════════════════════════════════════════════════════════════════════════
// StatusText — the pure formatter the GUI calls at menu-open.
//
// PRIORITY: HONESTY AT THE MOMENT OF DISPLAY. These strings are the only place
// the app talks about time, and they are minted against the `now` of the person
// actually looking — so every rule is pinned as (dates in, string out) with no
// clock anywhere. The "Updated" table is experiment 5's, moved here verbatim;
// the "Refreshes" table is experiment 18's addition.
//
// SCOPE: Google-small. Pure function, plain values.
// ═════════════════════════════════════════════════════════════════════════════

private let epoch = Date(timeIntervalSince1970: 1_786_230_000)

@Suite("StatusText — stamps to display strings")
struct StatusTextTests {

    // ── Updated (rules unchanged from experiment 5) ──────────────────────────

    @Test(
        "the updated line reports how long ago the data was fetched",
        arguments: [
            (TimeInterval(0), "Updated just now"),
            (TimeInterval(59), "Updated just now"),
            (TimeInterval(60), "Updated 1 minute ago"),
            (TimeInterval(120), "Updated 2 minutes ago"),
            (TimeInterval(3599), "Updated 59 minutes ago"),
            (TimeInterval(3600), "Updated 1 hour ago"),
            (TimeInterval(7200), "Updated 2 hours ago"),
        ]
    )
    func updatedReflectsAge(age: TimeInterval, expected: String) {
        let title = StatusText.title(for: .updated(epoch), now: epoch.addingTimeInterval(age))
        #expect(title == expected)
    }

    @Test("a nil fetch date says never updated")
    func nilFetchDateSaysNever() {
        #expect(StatusText.title(for: .updated(nil), now: epoch) == "Never updated")
    }

    @Test("a future fetch date does not render negative arithmetic")
    func futureFetchDateFoldsIntoJustNow() {
        // Clock skew and waking from sleep both produce this; the menu must not
        // display arithmetic ("Updated -3 minutes ago") at the user.
        let title = StatusText.title(for: .updated(epoch.addingTimeInterval(600)), now: epoch)
        #expect(title == "Updated just now")
        #expect(!title.contains("-"))
    }

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
