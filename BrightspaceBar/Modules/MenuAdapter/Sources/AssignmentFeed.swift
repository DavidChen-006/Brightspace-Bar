import Foundation
import AssignmentPipeline
import CoursePipeline

/// The assignments half of the backend, assembled as one thing.
///
/// `AssignmentFetcher` and `AssignmentStore` are always used together — the
/// fetcher writes what the store holds, and the adapter reads both — but they are
/// two objects, and a caller handed two parameters can pass a fetcher wired to a
/// *different* store than the one being read. That failure is silent: assignments
/// fetch successfully, land in the wrong store, and every submenu stays empty.
///
/// So the pair is built here, from the two things that genuinely vary per call (a
/// source and a clock), and the internal wiring is a decision this type makes once
/// rather than a decision every caller repeats. `MenuAdapter` takes one optional
/// `AssignmentFeed`, and `nil` means the app simply has no assignments feature —
/// which is exactly how every test written before this feature keeps passing.
public struct AssignmentFeed: Sendable {
    let fetcher: AssignmentFetcher
    let store: AssignmentStore

    public init(source: any AssignmentSource, clock: any Clock) {
        let store = AssignmentStore(clock: clock)
        self.store = store
        self.fetcher = AssignmentFetcher(source: source, store: store)
    }
}
