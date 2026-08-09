import Foundation
import Observation
import RepoBarCore

@MainActor
@Observable
final class RefreshScheduler {
    private var timer: Timer?
    private var interval: TimeInterval = RefreshInterval.fiveMinutes.seconds
    private var tickHandler: (() -> Void)?

    func configure(interval: TimeInterval, fireImmediately: Bool = true, tick: @escaping () -> Void) {
        self.interval = interval
        self.tickHandler = tick
        self.restart(fireImmediately: fireImmediately)
    }

    func restart(fireImmediately: Bool = true) {
        self.timer?.invalidate()
        self.timer = Timer.scheduledTimer(withTimeInterval: self.interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.tickHandler?() }
        }
        if fireImmediately {
            self.timer?.fire()
        }
    }

    func forceRefresh() {
        self.tickHandler?()
    }
}
