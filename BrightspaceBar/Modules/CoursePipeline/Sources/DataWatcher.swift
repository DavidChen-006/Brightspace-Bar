import Foundation

/// Watches the install and says when `cache/data.json` — or the student's own
/// `manual-items.json` at the root — has been published anew.
///
/// The one-command start flow launches the app FIRST and runs the login/fetch
/// after it, so the freshest courses land on disk minutes after the launch read
/// — and the 30-minute poll is the only thing that would ever notice. This
/// watcher closes that gap: when the daemon renames a new `data.json` into
/// place, the callback fires and the composition root re-runs the same cheap,
/// idempotent reload the poll uses.
///
/// The second file is the agent's. `bsb add` (session-capture/src/bsb.mjs)
/// writes `manual-items.json` from a terminal the app cannot see, and the
/// whole promise of that surface is that the square appears *now* — an agent
/// that imported a syllabus and a student who then opens the menu must see
/// the same thing. The file is at the root, which this watcher already holds
/// a descriptor on (the "nearest living ancestor" of `cache/`), so the cost of
/// watching it is one more `stat` per event and no more sources.
///
/// The watching itself is `MfaWatcher`'s, trap for trap (experiment 17 — read
/// that file's header for the measurements):
///
///   - **The directory, never the file.** The daemon publishes by renaming a
///     new inode over `data.json`, which unlinks the one a file watcher holds.
///     A directory descriptor survives, because the directory is never
///     replaced — only its entries are.
///   - **Re-read, never trust the event.** One atomic write is two directory
///     events and the first is a lie (the temp file appearing). No event says
///     *what* changed; each one means "look again". This watcher looks again by
///     fingerprinting both files (identity + mtime + size) and stays silent
///     when the pair is the one it last reported — which also silences every
///     event for OTHER files in either directory (`mfa.json`, `status.json`,
///     `session.json`, temp files) without reading a byte of the payload.
///   - **The directory can be replaced under us.** `reset.sh --cache` removes
///     `cache/` wholesale; each source remembers which inode it was armed on
///     and re-arms when the path names a different one, with a second source on
///     the nearest living ancestor so a not-yet-existing `cache/` is picked up
///     when it appears.
///
/// One thing `MfaWatcher` does not need but this one does: a **debounce**. The
/// consumer's reaction is a full model rebuild rather than an icon repaint, and
/// a single daemon run can touch the directory several times in quick
/// succession — so events are coalesced for a beat and the fingerprint is
/// checked once, after the dust settles. Deliveries ride the main queue, same
/// as `MfaWatcher` and for the same reason: the reaction ends in AppKit.
@MainActor
public final class DataWatcher {

    private let paths: DaemonPaths
    private let debounce: TimeInterval

    private var onChange: (() -> Void)?
    private var reported: Published?
    private var cache: DirectoryWatch?
    private var ancestor: DirectoryWatch?
    private var pending: DispatchWorkItem?

    /// `debounce` is a parameter only so a test can settle in milliseconds; the
    /// app takes the default.
    public init(paths: DaemonPaths, debounce: TimeInterval = 0.2) {
        self.paths = paths
        self.debounce = debounce
    }

    /// Begins watching. Unlike `MfaWatcher.start`, nothing is reported for the
    /// state already on disk: the caller's launch path reads `data.json` itself,
    /// and this watcher's whole job is *changes after that*. What is on disk
    /// right now is recorded as the baseline the first change is measured from.
    public func start(onChange: @escaping () -> Void) {
        self.stop()
        self.onChange = onChange
        self.rearm()
        self.reported = self.published()
    }

    /// Ends the reports and releases everything they held. Safe to call before
    /// `start`, and twice: the composition root may tear down in any order.
    public func stop() {
        self.cache?.source.cancel()
        self.cache = nil
        self.ancestor?.source.cancel()
        self.ancestor = nil
        self.pending?.cancel()
        self.pending = nil
        self.onChange = nil
        self.reported = nil
    }

    // MARK: - Coalescing and deciding

    /// Something happened, or might have. Re-arm immediately — a dead directory
    /// descriptor must not wait out the debounce — and push the *decision* past
    /// the debounce window, replacing any decision already queued.
    private func wake() {
        self.rearm()
        self.pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.publish() }
        }
        self.pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + self.debounce, execute: work)
    }

    /// Looks at both files from scratch and tells the caller only if either is
    /// a different published file than the one last reported. The comparison
    /// is what keeps the temp-file event, and every event about a *different*
    /// file in either directory, from triggering a reload. Nothing at all on
    /// disk is never reported: there is nothing new to show.
    private func publish() {
        self.pending = nil
        guard let onChange = self.onChange else { return }
        let now = self.published()
        guard now != self.reported, !now.isEmpty else { return }
        self.reported = now
        onChange()
    }

    /// The two files that repaint the menu, as they stand — nil for one that
    /// is not there.
    private struct Published: Equatable {
        let data: Fingerprint?
        let manualItems: Fingerprint?
        var isEmpty: Bool { self.data == nil && self.manualItems == nil }
    }

    private func published() -> Published {
        Published(
            data: self.fingerprint(of: self.paths.dataFile),
            manualItems: self.fingerprint(of: self.paths.manualItemsFile)
        )
    }

    /// What one file is right now: which inode, written when, how big.
    /// An atomic publish always changes the inode; mtime and size are belt and
    /// braces for an editor that rewrote in place.
    private struct Fingerprint: Equatable {
        let device: dev_t
        let inode: ino_t
        let modified: timespec
        let size: off_t

        static func == (lhs: Fingerprint, rhs: Fingerprint) -> Bool {
            lhs.device == rhs.device && lhs.inode == rhs.inode
                && lhs.modified.tv_sec == rhs.modified.tv_sec
                && lhs.modified.tv_nsec == rhs.modified.tv_nsec
                && lhs.size == rhs.size
        }
    }

    private func fingerprint(of file: URL) -> Fingerprint? {
        var info = stat()
        guard stat(file.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }
        return Fingerprint(
            device: info.st_dev, inode: info.st_ino,
            modified: info.st_mtimespec, size: info.st_size
        )
    }

    // MARK: - Staying armed (MfaWatcher's mechanism, transcribed)

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
    /// recreated, or has never existed yet all resolve themselves. Once the
    /// root exists, the ancestor source IS the root — which is what makes a
    /// rename of `manual-items.json` into it an event this watcher hears.
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

    /// The deepest directory above `cache/` that exists.
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
