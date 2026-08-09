import Foundation

actor AsyncPermitPool {
    private let limit: Int
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = max(1, limit)
        self.available = max(1, limit)
    }

    func acquire() async {
        if self.available > 0 {
            self.available -= 1
            return
        }

        await withCheckedContinuation { continuation in
            self.waiters.append(continuation)
        }
    }

    func release() {
        if self.waiters.isEmpty {
            self.available = min(self.available + 1, self.limit)
        } else {
            self.waiters.removeFirst().resume()
        }
    }
}
