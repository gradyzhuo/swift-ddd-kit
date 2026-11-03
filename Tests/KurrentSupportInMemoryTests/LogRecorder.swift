import Logging
import Synchronization

/// Records what a `Logger` from `logger` logs, at every level.
final class LogRecorder: Sendable {
    struct Entry: Equatable, Sendable {
        let level: Logger.Level
        let message: String
    }

    private let entries = Mutex<[Entry]>([])

    /// A logger whose every message, at every level, is recorded here.
    var logger: Logger {
        Logger(label: "LogRecorder") { _ in RecordingLogHandler(recorder: self) }
    }

    /// The recorded messages at `.warning` or above, in the order they were logged.
    var warnings: [Entry] {
        entries.withLock { $0.filter { $0.level >= .warning } }
    }

    func record(_ entry: Entry) {
        entries.withLock { $0.append(entry) }
    }
}

private struct RecordingLogHandler: LogHandler {
    let recorder: LogRecorder
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        recorder.record(.init(level: event.level, message: event.message.description))
    }
}
