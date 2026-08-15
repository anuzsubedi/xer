import AppKit
import SwiftUI

struct LogLine: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.date, format: .dateTime.hour().minute().second())
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            Text(levelTitle)
                .foregroundStyle(levelColor)
                .frame(width: 42, alignment: .leading)
            Text(entry.message)
                .foregroundStyle(Color.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(.caption, design: .monospaced))
    }

    private var levelTitle: String {
        switch entry.level {
        case .info: "INFO"
        case .warning: "WARN"
        case .error: "ERROR"
        case .command: "CMD"
        }
    }

    private var levelColor: Color {
        switch entry.level {
        case .info: .secondary
        case .warning: .orange
        case .error: .red
        case .command: .blue
        }
    }
}

enum LogFilter: String, CaseIterable, Identifiable {
    case all
    case commands
    case warnings
    case errors

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .commands: "Commands"
        case .warnings: "Warnings"
        case .errors: "Errors"
        }
    }

    func includes(_ level: LogEntry.Level) -> Bool {
        switch self {
        case .all: true
        case .commands: level == .command
        case .warnings: level == .warning
        case .errors: level == .error
        }
    }
}
