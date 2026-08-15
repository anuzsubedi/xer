import Foundation

struct LogStore {
    private(set) var entries: [LogEntry] = []
    let capacity: Int

    init(capacity: Int = 4_000) {
        self.capacity = capacity
    }

    mutating func append(
        level: LogEntry.Level,
        message: String,
        preserveWhitespace: Bool = false
    ) {
        let normalizedMessage = preserveWhitespace ? message : message.xerTrimmed
        entries.append(LogEntry(level: level, message: normalizedMessage))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    mutating func clear() {
        entries.removeAll()
    }

    var text: String {
        entries.map { entry in
            let level: String
            switch entry.level {
            case .info: level = "INFO"
            case .warning: level = "WARN"
            case .error: level = "ERROR"
            case .command: level = "CMD"
            }
            return "[\(Self.dateFormatter.string(from: entry.date))] [\(level)] \(entry.message)"
        }.joined(separator: "\n")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
