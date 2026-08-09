import Foundation
import CoursePipeline

/// A scriptable `CourseSource` for tests.
///
/// Three things make it useful beyond "returns canned data":
///
/// 1. **It can be scripted with raw bytes.** `.bytes` runs the response through the
///    real `EnrollmentParser`, exactly as the real adapter does with a network body.
///    That keeps the fake honest: the parser is genuinely in the chain, so the fake
///    cannot drift from reality by skipping decoding.
/// 2. **It counts calls.** "Polling works" is not a statement about wall-clock time,
///    it is a statement about how many times the network was touched.
/// 3. **It measures overlap.** `maxConcurrentFetches` is the deterministic way to
///    test that concurrent triggers never produce two in-flight fetches — no sleeping,
///    no timing assumptions, no flakiness.
///
/// On "delay": the SPEC asks for an optional delay, but tests may never sleep. So a
/// fetch instead suspends cooperatively `yieldsPerFetch` times. That creates real
/// suspension points where a reentrant call *can* slip in — which is precisely the
/// Swift actor-reentrancy trap a naive `Poller` falls into — while staying wall-clock
/// free and deterministic.
public actor FakeCourseSource: CourseSource {

    public enum Response: Sendable {
        /// Hand back these courses directly.
        case courses([Course])
        /// Hand back a raw payload; parsed with the real `EnrollmentParser`.
        case bytes(Data)
        /// Throw this error.
        case failure(CourseSourceError)
    }

    private var scripted: [Response]
    /// Once the script runs dry the last response repeats, so a test that ticks many
    /// times need not enqueue N copies. Safe because every test asserts `callCount`
    /// explicitly rather than relying on the script running out.
    private var lastServed: Response?
    private let yieldsPerFetch: Int

    public private(set) var callCount = 0
    /// The high-water mark of simultaneously in-flight fetches. Must stay at 1.
    public private(set) var maxConcurrentFetches = 0
    private var inFlight = 0

    public init(_ scripted: [Response] = [], yieldsPerFetch: Int = 4) {
        self.scripted = scripted
        self.yieldsPerFetch = yieldsPerFetch
    }

    public func enqueue(_ response: Response) {
        self.scripted.append(response)
    }

    public func fetchCourses() async throws -> [Course] {
        self.callCount += 1
        self.inFlight += 1
        self.maxConcurrentFetches = max(self.maxConcurrentFetches, self.inFlight)
        defer { self.inFlight -= 1 }

        // Suspension points: a reentrant caller can enter here. If the poller
        // serialises correctly, `inFlight` never exceeds 1.
        for _ in 0 ..< self.yieldsPerFetch {
            await Task.yield()
        }
        self.maxConcurrentFetches = max(self.maxConcurrentFetches, self.inFlight)

        let response = self.scripted.isEmpty
            ? (self.lastServed ?? .courses([]))
            : self.scripted.removeFirst()
        self.lastServed = response

        switch response {
        case .courses(let courses):
            return courses
        case .failure(let error):
            throw error
        case .bytes(let data):
            return try EnrollmentParser().parse(data)
        }
    }
}
