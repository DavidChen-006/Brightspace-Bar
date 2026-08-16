import AppKit
import Foundation
import Testing

import BrightspaceBar
import CourseMenu

// ═════════════════════════════════════════════════════════════════════════════
// Menu-open freshness — the mechanism experiment 18 exists to prove.
//
// The claim: the time row ("Refreshes in N min") is
// correct AT THE MOMENT THE MENU OPENS, with no ticking display timer and no
// async race, because `NSMenuDelegate.menuWillOpen` is delivered synchronously
// before the menu is drawn and the titles are recomputed there from the dates
// riding in the items.
//
// These tests drive the delegate exactly as AppKit does — through the menu's own
// `delegate` property and the protocol method — so what is proven is the wiring
// the real app uses, not a test-only side door. What headless tests cannot prove
// is that AppKit *calls* `menuWillOpen` before drawing; that is documented
// behaviour, confirmed live by the run in the README.
//
// SCOPE: Google-small. In-process AppKit object graphs; the clock is a box the
// test advances by hand.
// ═════════════════════════════════════════════════════════════════════════════

/// The injectable clock: the assembler holds `{ box.now }`, the test moves time.
@MainActor
private final class ClockBox {
    var now: Date
    init(_ now: Date) { self.now = now }
}

private let epoch = Date(timeIntervalSince1970: 1_786_230_000)

@MainActor
@Suite("MenuAssembler — freshness at menu open")
struct MenuFreshnessTests {

    private static func assembled(clock: ClockBox, rows: [MenuRow]) -> NSMenu {
        let assembler = MenuAssembler(opener: FakeURLOpener(), now: { clock.now }) { _ in }
        return assembler.assemble(MenuModel(rows: rows))
    }

    @Test("an assembled menu carries a delegate, so opening can re-title at all")
    func assembledMenuHasADelegate() {
        let menu = Self.assembled(
            clock: ClockBox(epoch),
            rows: [.status(.nextRefresh(epoch.addingTimeInterval(15 * 60)))]
        )
        #expect(menu.delegate != nil)
    }

    @Test("opening the menu later re-titles the time row against the new now")
    func openingRefreshesTheTimeRows() throws {
        // Arrange — built at fetch time: 15 minutes on the countdown. This is the
        // exact repaint the timer path performs.
        let clock = ClockBox(epoch)
        let menu = Self.assembled(clock: clock, rows: [
            .status(.nextRefresh(epoch.addingTimeInterval(15 * 60))),
        ])
        try #require(menu.items.map(\.title) == ["Refreshes in 15 minutes"])

        // Act — fourteen minutes pass with NO repaint (the stale-at-open bug's
        // exact setup), then the user opens the menu.
        clock.now = epoch.addingTimeInterval(14 * 60)
        menu.delegate?.menuWillOpen?(menu)

        // Assert — the title is true for the moment of opening, not for the
        // moment the model was built.
        #expect(menu.items.map(\.title) == ["Refreshes in 1 minute"])
    }

    @Test("every open re-titles again — the second open is not served the first's string")
    func eachOpenIsFreshAgain() throws {
        // Arrange — a countdown 15 minutes out.
        let clock = ClockBox(epoch)
        let menu = Self.assembled(
            clock: clock, rows: [.status(.nextRefresh(epoch.addingTimeInterval(15 * 60)))]
        )

        // Act / Assert — two opens, minutes apart, each honest.
        clock.now = epoch.addingTimeInterval(2 * 60)
        menu.delegate?.menuWillOpen?(menu)
        #expect(menu.items.map(\.title) == ["Refreshes in 13 minutes"])

        clock.now = epoch.addingTimeInterval(9 * 60)
        menu.delegate?.menuWillOpen?(menu)
        #expect(menu.items.map(\.title) == ["Refreshes in 6 minutes"])
    }

    @Test("a countdown past its deadline clamps to soon at open, never negative")
    func pastDeadlineClampsAtOpen() {
        // Arrange — deadline 15 minutes out, but the Mac slept for 20: the open
        // happens after the deadline and before the coalesced timer fire.
        let clock = ClockBox(epoch)
        let menu = Self.assembled(
            clock: clock, rows: [.status(.nextRefresh(epoch.addingTimeInterval(15 * 60)))]
        )

        // Act
        clock.now = epoch.addingTimeInterval(20 * 60)
        menu.delegate?.menuWillOpen?(menu)

        // Assert
        #expect(menu.items.map(\.title) == ["Refreshes soon"])
        #expect(menu.items.allSatisfy { !$0.title.contains("-") })
    }

    @Test("opening touches only the time rows — courses, headers, commands keep their titles")
    func onlyTimeRowsAreRetitled() throws {
        // Arrange — the full interleaved shape, so a delegate that re-titles by
        // index instead of by stamp would hit a non-status row and fail here.
        let course = CourseRow(
            id: 1, title: "Data Engineering", subtitle: "CS 17600",
            url: URL(string: "https://purdue.brightspace.com/d2l/home/1")!
        )
        let clock = ClockBox(epoch)
        let menu = Self.assembled(clock: clock, rows: [
            .sectionHeader("Fall 2026"),
            .course(course),
            .separator,
            .status(.nextRefresh(epoch.addingTimeInterval(15 * 60))),
            .command(.refresh),
        ])
        let before = menu.items.map(\.title)

        // Act
        clock.now = epoch.addingTimeInterval(5 * 60)
        menu.delegate?.menuWillOpen?(menu)

        // Assert — exactly one title changed, and it is the status row's.
        let after = menu.items.map(\.title)
        try #require(before.count == after.count)
        let changed = zip(before, after).enumerated().filter { $1.0 != $1.1 }.map(\.offset)
        #expect(changed == [3])
        #expect(after[3] == "Refreshes in 10 minutes")
    }
}
