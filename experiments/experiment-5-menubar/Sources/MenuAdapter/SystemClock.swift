import Foundation
import CoursePipeline

/// Production `Clock`. Experiment 4 defines the protocol but ships no concrete
/// implementation, because nothing in it was allowed to call `Date()` — this
/// property is the ONE place in either package where wall-clock time enters.
public struct SystemClock: Clock {
    public init() {}
    public var now: Date { Date() }
}
