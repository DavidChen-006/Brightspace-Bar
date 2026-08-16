import CoreServices
import Foundation

// ═════════════════════════════════════════════════════════════════════════════
// The three pickup techniques under test.
//
// All three answer the same question — "may the file have changed?" — and none
// of them tells us WHAT changed. That is deliberate: the daemon writes
// atomically (temp file + rename), so the only trustworthy move on any event is
// to re-read the path from scratch. A watcher that reported "modified" would be
// lying anyway; the inode under the path is a different one after each write.
// ═════════════════════════════════════════════════════════════════════════════

/// 1 — kqueue, via `DispatchSource.makeFileSystemObjectSource`, on the cache
/// DIRECTORY.
///
/// The directory is the only stable thing to watch. `mfa.json` is created,
/// replaced by rename, and finally unlinked; a descriptor on the file itself
/// stops being the file the path names the moment the daemon renames over it
/// (see `DoomedFileKqueueWatcher` below, which measures exactly that).
/// A directory descriptor survives all of it, because the directory is never
/// replaced — only its entries are.
@MainActor
final class DirectoryKqueueWatcher {
    private var source: DispatchSourceFileSystemObject?

    func start(directory: String) {
        let fd = open(directory, O_EVTONLY)
        guard fd >= 0 else {
            FileHandle.standardError.write(Data("exp17: cannot open \(directory)\n".utf8))
            exit(1)
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            // .write is the one that matters: on a directory it means an entry
            // was added, removed, or renamed. The rest are here so a run that
            // loses its directory reports something instead of going quiet.
            eventMask: [.write, .delete, .rename, .revoke],
            queue: .main
        )
        source.setEventHandler {
            MainActor.assumeIsolated { probe.poke(.event) }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }
}

/// The trap, instrumented. A kqueue descriptor opened on `mfa.json` ITSELF —
/// armed the first time the file is seen, then left running for the rest of the
/// run. Every subsequent atomic write renames a new inode over the path, which
/// unlinks the one this descriptor holds: it should report a single delete and
/// then never speak again, while nineteen more writes sail past. The counter is
/// the evidence.
@MainActor
final class DoomedFileKqueueWatcher {
    private var source: DispatchSourceFileSystemObject?
    private(set) var isArmed = false
    private(set) var eventCount = 0
    private(set) var flagsSeen: [String] = []

    func armIfNeeded(file: String) {
        guard !isArmed else { return }
        let fd = open(file, O_EVTONLY)
        guard fd >= 0 else { return }
        isArmed = true
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .link, .rename, .delete, .revoke],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let source = self.source else { return }
                self.eventCount += 1
                if self.flagsSeen.count < 8 {
                    self.flagsSeen.append(Self.describe(source.data))
                }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    private static func describe(_ data: DispatchSource.FileSystemEvent) -> String {
        var names: [String] = []
        if data.contains(.write) { names.append("write") }
        if data.contains(.extend) { names.append("extend") }
        if data.contains(.attrib) { names.append("attrib") }
        if data.contains(.link) { names.append("link") }
        if data.contains(.rename) { names.append("rename") }
        if data.contains(.delete) { names.append("delete") }
        if data.contains(.revoke) { names.append("revoke") }
        return names.isEmpty ? "none" : names.joined(separator: "|")
    }
}

/// 2 — FSEvents on the directory, latency 0.1 s.
///
/// `kFSEventStreamCreateFlagNoDefer` is the difference between "0.1 s is a
/// coalescing window" and "0.1 s is a floor": with NoDefer the first event of a
/// quiet period is delivered immediately and the 0.1 s becomes the debounce
/// applied to what follows. Without it, every single pickup would pay 100 ms,
/// which would make this measurement a measurement of the parameter.
@MainActor
final class FSEventsWatcher {
    private var stream: FSEventStreamRef?

    func start(directory: String) {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, _, _, _, _, _ in
            MainActor.assumeIsolated { probe.poke(.event) }
        }
        // FSEvents resolves symlinks internally and reports realpath'd paths.
        // The driver hands us an already-resolved root for that reason — under
        // TMPDIR the honest path is /private/var/folders/…, not /var/folders/….
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [directory] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1,
            UInt32(
                kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagNoDefer
                    | kFSEventStreamCreateFlagUseCFTypes
            )
        ) else {
            FileHandle.standardError.write(Data("exp17: FSEventStreamCreate failed\n".utf8))
            exit(1)
        }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }
}

/// 3 — the dumb baseline: read the path every 500 ms and compare.
///
/// No kernel involvement, no watcher to go stale, nothing to re-arm. Its cost
/// is 120 wakeups a minute forever, and its latency is a uniform draw from
/// [0, interval] — which is the whole point of measuring it.
@MainActor
final class PollWatcher {
    private var timer: Timer?

    func start(interval: TimeInterval) {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { probe.poke(.tick) }
        }
        // .common, not .default (the exp-12 lesson): a .default-mode timer stops
        // firing while a menu is open, and the menu being open is exactly when
        // someone is looking at the icon.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
