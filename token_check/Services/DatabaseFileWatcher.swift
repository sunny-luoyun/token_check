import Combine
import Foundation

final class DatabaseFileWatcher: ObservableObject {
    static let shared = DatabaseFileWatcher()

    private var dbSource: DispatchSourceFileSystemObject?
    private var walSource: DispatchSourceFileSystemObject?
    private let subject = PassthroughSubject<Void, Never>()

    var publisher: AnyPublisher<Void, Never> {
        subject
            .debounce(for: .seconds(5), scheduler: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    private var dbPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/opencode.db")
            .path
    }

    private var walPath: String {
        dbPath + "-wal"
    }

    func startWatching() {
        stopWatching()
        watchFile(at: dbPath, source: &dbSource)
        watchFile(at: walPath, source: &walSource)
    }

    func stopWatching() {
        dbSource?.cancel()
        dbSource = nil
        walSource?.cancel()
        walSource = nil
    }

    private func watchFile(at path: String, source: inout DispatchSourceFileSystemObject?) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }

        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: .main
        )

        newSource.setEventHandler { [weak self] in
            self?.subject.send()
        }

        newSource.setCancelHandler {
            close(fd)
        }

        newSource.resume()
        source = newSource
    }

    deinit {
        stopWatching()
    }
}
