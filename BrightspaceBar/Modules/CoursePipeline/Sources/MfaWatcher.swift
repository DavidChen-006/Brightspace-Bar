import Foundation

/// Watches `cache/` and says what the icon should be showing.
///
/// The transport half of the MFA badge: one program renames a sixty-byte file
/// into place, and this one has to have reported it before David has finished
/// picking up his phone. Experiment 17 measured the three candidates and this is
/// its verdict — a kqueue source on the cache DIRECTORY, 2.6 ms median with no
/// cold-start tail, which matters because one-write-after-hours-idle is this
/// feature's entire traffic pattern.
///
/// Nearly everything here is one of that experiment's traps, and every one of
/// them fails silently — the menu bar simply keeps showing what it was showing:
///
///   - **The directory, never the file.** An atomic publish renames a new inode
///     over `mfa.json`, which unlinks the one a file watcher holds: exp 17 armed
///     one deliberately and measured a single delete event across nineteen
///     further writes. A directory descriptor survives, because the directory is
///     never replaced — only its entries are.
///   - **Re-read, never trust the event.** One atomic write is two directory
///     events and the first is a lie (the temp file appearing, when `mfa.json`
///     is still the old file or no file). No event here says *what* changed;
///     they all mean "look again", and what is published is compared with what
///     is already on screen before anyone is told.
///   - **The directory can be replaced under us.** `reset.sh --cache` removes
///     `cache/` wholesale, and a source left on the dead inode is deaf for the
///     life of the process. Each source therefore remembers which inode it was
///     armed on and is re-armed when the path starts naming a different one.
///     A second source sits on the nearest living ancestor, so a `cache/` that
///     does not exist yet — a fresh install, the app up before the daemon has
///     ever run — is picked up when it appears.
///   - **Delete is a first-class event.** The daemon deleting `mfa.json` *is*
///     the "challenge is over" message. There is no other one.
///   - **And the event that never comes.** A rung that crashes mid-challenge
///     leaves its file behind with nobody left to delete it. Nothing will move
///     on disk when those sixty seconds are up, so the watcher schedules its own
///     re-check from `MfaBadge.revertDelay`.
///
/// Everything is delivered on the main queue, which is where the caller wants to
/// be: the report ends at an `NSStatusItem`, and AppKit is main-thread-only.
@MainActor
public final class MfaWatcher {

    private let paths: DaemonPaths
    private let ttl: TimeInterval

    private var onChange: ((IconState) -> Void)?
    private var shown: IconState?
    private var cache: DirectoryWatch?
    private var ancestor: DirectoryWatch?
    private var lapse: DispatchWorkItem?

    /// `ttl` is a parameter only so a test can run the lapse in a second instead
    /// of a minute; the app takes the default.
    public init(paths: DaemonPaths, ttl: TimeInterval = MfaBadge.ttl) {
        self.paths = paths
        self.ttl = ttl
    }

    /// Begins watching, and reports the state as it is right now **before
    /// returning** — synchronously, so the caller never has a frame in which the
    /// icon and the disk disagree. A terminal-initiated login can be mid-
    /// challenge when the app starts (D8: the app is not always the spawner),
    /// and an ordinary launch still has to be told there is nothing to show.
    public func start(onChange: @escaping (IconState) -> Void) {
        self.stop()
        self.onChange = onChange
        self.rearm()
        self.publish()
    }

    /// Ends the reports and releases everything they held. Safe to call before
    /// `start`, and twice: the composition root may tear down in any order.
    public func stop() {
        self.cache?.source.cancel()
        self.cache = nil
        self.ancestor?.source.cancel()
        self.ancestor = nil
        self.lapse?.cancel()
        self.lapse = nil
        self.onChange = nil
        self.shown = nil
    }

    // MARK: - What to show

    /// Something happened, or might have. The only trustworthy move is to check
    /// the watch is still pointed at the live directory and then read the file
    /// from scratch.
    private func wake() {
        self.rearm()
        self.publish()
    }

    /// Reads the file, decides, and tells the caller only if the answer changed.
    ///
    /// The comparison is what makes the two-events-per-write harmless, and what
    /// keeps a rewrite of an identical challenge from repainting a menu bar that
    /// already says the right thing.
    private func publish() {
        guard let onChange = self.onChange else { return }
        let bytes = try? Data(contentsOf: self.paths.mfaFile)
        let now = Date()
        self.scheduleLapse(MfaBadge.revertDelay(fileContents: bytes, now: now, ttl: self.ttl))
        let state = MfaBadge.state(fileContents: bytes, now: now, ttl: self.ttl)
        guard state != self.shown else { return }
        self.shown = state
        onChange(state)
    }

    /// Arranges the wakeup that takes an expired number back down.
    ///
    /// A dispatch block rather than a `Timer`, and deliberately: while a menu is
    /// open the run loop runs in `.eventTracking`, where a `.default`-mode timer
    /// does not fire — and the menu being open is exactly when someone is
    /// looking at the icon. The main *queue* is drained in all the common modes,
    /// which is the same reason the kqueue sources above target it, so the
    /// revert and the pickup keep working under a tracking menu together.
    ///
    /// The extra hundredth of a second puts the wakeup just past the boundary,
    /// so it finds the challenge already expired instead of rescheduling itself
    /// for the last microsecond of it.
    private func scheduleLapse(_ delay: TimeInterval?) {
        self.lapse?.cancel()
        self.lapse = nil
        guard let delay else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.publish() }
        }
        self.lapse = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.01, execute: work)
    }

    // MARK: - Staying armed

    /// A live source, paired with the identity of the directory it was armed on.
    private struct DirectoryWatch {
        let source: DispatchSourceFileSystemObject
        let identity: DirectoryIdentity
    }

    /// Which directory a descriptor is actually watching. A path is not enough:
    /// after `cache/` is removed and remade, the path is the same and the
    /// descriptor is watching a corpse.
    private struct DirectoryIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    /// Points both sources at whatever exists right now. Called before the first
    /// read and on every event, which is what lets a directory that is deleted,
    /// recreated, or has never existed yet all resolve themselves.
    private func rearm() {
        self.ancestor = self.arm(on: self.nearestLivingAncestor(), keeping: self.ancestor)
        self.cache = self.arm(on: self.paths.cacheDirectory.path, keeping: self.cache)
    }

    /// Keeps `current` when it is still watching the directory `path` names, and
    /// otherwise arms a fresh source — or none, when there is no directory there.
    private func arm(on path: String, keeping current: DirectoryWatch?) -> DirectoryWatch? {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else {
            current?.source.cancel()
            return nil
        }
        // Identity taken from the descriptor rather than from the path, so it
        // describes the thing that will be delivering the events even if the
        // path is replaced in between.
        guard let identity = Self.identity(of: descriptor) else {
            close(descriptor)
            current?.source.cancel()
            return nil
        }
        if let current, current.identity == identity {
            close(descriptor)
            return current
        }
        current?.source.cancel()
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            // `.write` on a directory means an entry was added, removed or
            // renamed — an atomic publish is all three. The others are the
            // directory losing itself, which is the re-arm announcing itself.
            eventMask: [.write, .delete, .rename, .revoke],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            // The source's queue is the main one, so this is the main actor.
            MainActor.assumeIsolated { self?.wake() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return DirectoryWatch(source: source, identity: identity)
    }

    /// The deepest directory above `cache/` that exists. Usually `BSB_ROOT`
    /// itself; on a fresh install where the daemon has never run it is whichever
    /// ancestor got as far as existing, and the walk down happens as the missing
    /// ones appear.
    private func nearestLivingAncestor() -> String {
        var directory = self.paths.cacheDirectory.deletingLastPathComponent().standardizedFileURL
        while directory.path != "/" && !FileManager.default.fileExists(atPath: directory.path) {
            directory = directory.deletingLastPathComponent().standardizedFileURL
        }
        return directory.path
    }

    private static func identity(of descriptor: Int32) -> DirectoryIdentity? {
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
        return DirectoryIdentity(device: info.st_dev, inode: info.st_ino)
    }
}
