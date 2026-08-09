import Foundation

struct AsyncTimeoutError: Error {}

enum AsyncTimeout {
    static func value<T>(within seconds: TimeInterval, task: Task<T, Error>) async throws -> T {
        let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
        do {
            return try await withThrowingTaskGroup(of: T.self) { group in
                group.addTask {
                    try await task.value
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: nanoseconds)
                    throw AsyncTimeoutError()
                }
                guard let value = try await group.next() else {
                    throw AsyncTimeoutError()
                }

                group.cancelAll()
                return value
            }
        } catch {
            if error is AsyncTimeoutError {
                task.cancel()
            }
            throw error
        }
    }
}
