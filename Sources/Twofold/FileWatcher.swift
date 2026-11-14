import Foundation

/// Watches files for writes, renames and deletes. Editors often save by replacing the file,
/// so the watch is re-established after every event.
@MainActor
final class FileWatcher {
    private let urls: [URL]
    private let onChange: () -> Void
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pending: Task<Void, Never>?

    init(urls: [URL], onChange: @escaping () -> Void) {
        self.urls = urls
        self.onChange = onChange
        start()
    }

    private func start() {
        for url in urls {
            let fd = open(url.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.fire() }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            sources.append(source)
        }
    }

    private func fire() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            self.stop()
            self.start()
            self.onChange()
        }
    }

    func stop() {
        sources.forEach { $0.cancel() }
        sources.removeAll()
    }

    func invalidate() {
        pending?.cancel()
        stop()
    }
}
