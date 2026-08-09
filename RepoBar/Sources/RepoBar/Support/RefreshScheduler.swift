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
        let timer = Timer.scheduledTimer(withTimeInterval: self.interval, repeats: true) { [weak self] _ in
            guard let self else { return }

            Task { @MainActor in self.tickHandler?() }
        }
        timer.tolerance = min(max(self.interval * 0.1, 1), 30)
        self.timer = timer
        if fireImmediately {
            self.timer?.fire()
        }
    }

    func forceRefresh() {
        self.tickHandler?()
    }

    func stop() {
        self.timer?.invalidate()
        self.timer = nil
        self.tickHandler = nil
    }

    var isRunning: Bool {
        self.timer?.isValid == true
    }
}
