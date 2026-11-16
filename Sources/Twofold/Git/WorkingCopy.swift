import CoreServices
import DiffCore
import Foundation

/// A Git working copy: what differs from the last commit, and the committed version of a file.
struct WorkingCopy: Sendable {
    let git: URL
    /// The top-level folder of the working copy.
    let root: URL

    struct Failure: Error {
        var message: String
    }

    /// The working copy that contains `url`, or nil when it is not in one or git is not installed.
    /// Runs git, so it takes a moment.
    static func locate(_ url: URL) -> WorkingCopy? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), let git = GitIntegration.findGit() else { return nil }
        let folder = isDirectory.boolValue ? url : url.deletingLastPathComponent()
        guard let result = try? GitIntegration.run(git, ["rev-parse", "--show-toplevel"], in: folder), result.status == 0 else { return nil }
        let path = result.output.trimmingCharacters(in: .newlines)
        return path.isEmpty ? nil : WorkingCopy(git: git, root: URL(fileURLWithPath: path, isDirectory: true))
    }

    var name: String { root.lastPathComponent }

    func status() throws(Failure) -> GitStatus {
        let result: GitIntegration.Output
        do {
            result = try GitIntegration.run(git, ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"], in: root)
        } catch {
            throw Failure(message: error.localizedDescription)
        }
        guard result.status == 0 else {
            throw Failure(message: result.error.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return GitStatus.parse(result.data)
    }

    /// Writes the committed version of a changed file below `folder` and returns where, or nil when
    /// HEAD has no such file. The copy keeps the file's name, so its language is still recognised.
    func headFile(for change: GitChange, in folder: URL) -> URL? {
        guard let id = change.headID,
              let result = try? GitIntegration.run(git, ["cat-file", "blob", id], in: root), result.status == 0 else { return nil }
        let url = folder.appendingPathComponent(change.originalPath ?? change.path)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Written in place: the diff view watches this file and should see one change, not a replacement.
            try result.data.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}

/// Reports changes anywhere below a folder, a little after they stop arriving.
@MainActor
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void

    init(folder: URL, onChange: @escaping () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let address = UInt(bitPattern: info)
            // The stream delivers on the main queue; see `FSEventStreamSetDispatchQueue` below.
            MainActor.assumeIsolated {
                guard let pointer = UnsafeRawPointer(bitPattern: address) else { return }
                Unmanaged<FolderWatcher>.fromOpaque(pointer).takeUnretainedValue().onChange()
            }
        }
        // The latency also gathers a burst of writes, such as a checkout, into one report.
        guard let stream = FSEventStreamCreate(nil, callback, &context, [folder.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    /// Must be called before the watcher is released: the stream holds an unretained pointer to it.
    func invalidate() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
