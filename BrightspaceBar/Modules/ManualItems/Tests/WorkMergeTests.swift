import Foundation
import Testing
import ManualItems

// ─────────────────────────────────────────────────────────────────────────────
// The merge is pure, so the tests are arithmetic: lists in, order out.
// The stand-in fetched type proves the generic seam works without naming any
// adapter type — exactly how the adapter will use it later.
// ─────────────────────────────────────────────────────────────────────────────

/// The adapter's future item, in miniature.
private struct FakeFetched: Equatable, Sendable {
    let name: String
    let due: Date?
}

private func date(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSince1970: seconds)
}

private func merge(
    fetched: [FakeFetched], manual: [ManualItem]
) -> [MergedWorkItem<FakeFetched>] {
    mergeWorkItems(fetched: fetched, manual: manual, dueOf: \.due, nameOf: \.name)
}

private func manualItem(_ name: String, due: Date) -> ManualItem {
    ManualItem(courseId: 7, kind: .test, name: name, link: "https://x", due: due)!
}

@Suite struct WorkMergeTests {

    @Test func sortsByDueDateAcrossBothSources() {
        let out = merge(
            fetched: [FakeFetched(name: "later fetched", due: date(300))],
            manual: [
                manualItem("earliest manual", due: date(100)),
                manualItem("middle manual", due: date(200)),
            ]
        )
        #expect(out.map(\.isManual) == [true, true, false])
        guard case .manual(let first) = out[0] else { Issue.record("expected manual"); return }
        #expect(first.name == "earliest manual")
    }

    @Test func undatedFetchedItemsSortLast() {
        let out = merge(
            fetched: [
                FakeFetched(name: "undated", due: nil),
                FakeFetched(name: "dated", due: date(500)),
            ],
            manual: [manualItem("manual", due: date(400))]
        )
        #expect(out.map(\.isManual) == [true, false, false])
        #expect(out[1] == .fetched(FakeFetched(name: "dated", due: date(500))))
        #expect(out[2] == .fetched(FakeFetched(name: "undated", due: nil)))
    }

    @Test func equalDatesFallBackToCaseInsensitiveName() {
        let due = date(1000)
        let out = merge(
            fetched: [FakeFetched(name: "beta", due: due)],
            manual: [manualItem("Alpha", due: due)]
        )
        #expect(out.map(\.isManual) == [true, false])   // Alpha before beta
    }

    @Test func fullTieBreaksFetchedBeforeManual() {
        let due = date(1000)
        let out = merge(
            fetched: [FakeFetched(name: "Same", due: due)],
            manual: [manualItem("same", due: due)]
        )
        #expect(out.map(\.isManual) == [false, true])
    }

    @Test func isManualFlagsExactlyTheManualEntries() {
        let out = merge(
            fetched: [FakeFetched(name: "f", due: date(1))],
            manual: [manualItem("m", due: date(2))]
        )
        #expect(out.map(\.isManual) == [false, true])
    }

    @Test func emptyInputsAreFine() {
        #expect(merge(fetched: [], manual: []).isEmpty)
        #expect(merge(fetched: [], manual: [manualItem("m", due: date(1))]).count == 1)
        #expect(merge(fetched: [FakeFetched(name: "f", due: nil)], manual: []).count == 1)
    }
}
