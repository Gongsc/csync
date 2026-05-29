import CoreServices
import Foundation

final class FileSystemEventWatcher {
    typealias EventHandler = @Sendable ([String]) -> Void

    private let rootPath: String
    private let latency: CFTimeInterval
    private let handler: EventHandler
    private let callbackQueue: DispatchQueue

    private var stream: FSEventStreamRef?

    init(rootPath: String, latency: CFTimeInterval = 0.3, handler: @escaping EventHandler) {
        self.rootPath = rootPath
        self.latency = latency
        self.handler = handler
        self.callbackQueue = DispatchQueue(label: "csync.fs-events.\(UUID().uuidString)")
    }

    deinit {
        stop()
    }

    @discardableResult
    func start() -> Bool {
        if stream != nil {
            return true
        }

        var context = FSEventStreamContext(
            version: 0,
            info: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let paths = [rootPath] as CFArray
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer
        )

        guard let stream = FSEventStreamCreate(
            nil,
            fsEventsCallback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            return false
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, callbackQueue)

        guard FSEventStreamStart(stream) else {
            stop()
            return false
        }

        return true
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    fileprivate func handle(eventPaths: [String], eventCount: Int) {
        if eventPaths.isEmpty {
            handler([])
            return
        }
        let bounded = Array(eventPaths.prefix(eventCount))
        handler(bounded)
    }
}

private let fsEventsCallback: FSEventStreamCallback = { _, info, numEvents, eventPathsPointer, _, _ in
    guard let info else {
        return
    }

    let watcher = Unmanaged<FileSystemEventWatcher>.fromOpaque(info).takeUnretainedValue()

    let paths: [String]
    if let array = unsafeBitCast(eventPathsPointer, to: CFArray.self) as? [String] {
        paths = array
    } else {
        paths = []
    }

    watcher.handle(eventPaths: paths, eventCount: Int(numEvents))
}
