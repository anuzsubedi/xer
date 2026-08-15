import AppKit
import SwiftUI

extension ContentView {

    var logConsole: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                consoleToolbar(compact: false)
                consoleToolbar(compact: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(XerTheme.workspace)

            Divider()

            if filteredLogs.isEmpty {
                ContentUnavailableView {
                    Label(logQuery.isEmpty ? "No output yet" : "No matching output", systemImage: "text.alignleft")
                } description: {
                    Text(logQuery.isEmpty ? "Build commands and diagnostics will appear here." : "Try another search or log-level filter.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(XerTheme.inspector)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(filteredLogs) { entry in
                                LogLine(entry: entry)
                            }
                            Color.clear
                                .frame(width: 1, height: 1)
                                .id("console-bottom")
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onAppear {
                        guard autoScrollConsole else { return }
                        proxy.scrollTo("console-bottom", anchor: .bottom)
                    }
                    .onChange(of: filteredLogs.count) {
                        guard autoScrollConsole else { return }
                        proxy.scrollTo("console-bottom", anchor: .bottom)
                    }
                }
                .background(XerTheme.inspector)
                .accessibilityLabel("Build log output")
            }

            HStack {
                Spacer()
                Toggle("Auto-scroll", isOn: $autoScrollConsole)
                    .toggleStyle(.checkbox)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .background(.regularMaterial)
        }
        .background(XerTheme.inspector)
    }

    func consoleDivider(currentHeight: Double, maximumHeight: Double) -> some View {
        ZStack {
            Divider()
            Capsule()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 34, height: 3)
                .opacity(0.7)
        }
        .frame(height: 5)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { NSCursor.resizeUpDown.push() }
            else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if consoleResizeStart == nil {
                        consoleResizeStart = currentHeight
                    }
                    guard let consoleResizeStart else { return }
                    consoleDragHeight = min(
                        max(consoleResizeStart - Double(value.translation.height), 190),
                        maximumHeight
                    )
                }
                .onEnded { _ in
                    if let consoleDragHeight {
                        consoleHeight = min(max(consoleDragHeight, 190), maximumHeight)
                    }
                    consoleDragHeight = nil
                    consoleResizeStart = nil
                }
        )
        .accessibilityElement()
        .accessibilityLabel("Resize console")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                consoleHeight = min(currentHeight + 40, maximumHeight)
            case .decrement:
                consoleHeight = max(currentHeight - 40, 190)
            @unknown default:
                break
            }
        }
    }

    func consoleToolbar(compact: Bool) -> some View {
        HStack(spacing: compact ? 8 : 10) {
            Text("Console")
                .font(.headline)

            Spacer(minLength: 4)

            if compact {
                Button {
                    model.clearLogs()
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(model.logs.isEmpty)
                .accessibilityLabel("Clear console")
            } else {
                Button("Clear") {
                    model.clearLogs()
                }
                .disabled(model.logs.isEmpty)
            }

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    filteredLogs.map(\.message).joined(separator: "\n"),
                    forType: .string
                )
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .disabled(filteredLogs.isEmpty)
            .help("Copy visible console output")
            .accessibilityLabel("Copy visible console output")

            logLevelPicker
                .frame(width: compact ? 100 : 120)

            consoleSearchField(width: compact ? 140 : 190)
        }
        .frame(maxWidth: .infinity)
    }

    func consoleSearchField(width: CGFloat) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search output", text: $logQuery)
                .textFieldStyle(.plain)
                .focused($isLogSearchFocused)
                .onKeyPress(.escape) {
                    logQuery = ""
                    return .handled
                }
            if !logQuery.isEmpty {
                Button {
                    logQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear log search")
            }
        }
        .padding(.horizontal, 8)
        .frame(width: width, height: 26)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }

    var logLevelPicker: some View {
        Picker("Log level", selection: $logFilter) {
            ForEach(LogFilter.allCases) { filter in
                Text(filter.title).tag(filter)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        // AppKit's menu-backed picker can retain its initial appearance when
        // macOS changes themes while the app is open. Recreate only this
        // control so its label, arrows, and background resolve correctly.
        .id(colorScheme)
        .accessibilityLabel("Filter activity")
    }

    var filteredLogs: [LogEntry] {
        model.logs.filter { entry in
            logFilter.includes(entry.level)
                && (logQuery.isEmpty || entry.message.localizedCaseInsensitiveContains(logQuery))
        }
    }
}
