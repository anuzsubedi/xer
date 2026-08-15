import AppKit
import SwiftUI

struct OperationStatus: View {
    let state: AppOperationState
    let isBusy: Bool

    var body: some View {
        HStack(spacing: 6) {
            if isBusy && state != .running {
                ProgressView()
                    .controlSize(.mini)
                    .tint(statusColor)
                    .frame(width: 12, height: 12)
                    .accessibilityLabel(state.title)
            } else {
                Image(systemName: statusSymbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .frame(width: 12, height: 12)
                    .accessibilityHidden(true)
            }

            Text(phaseTitle)
                .font(.caption.weight(.semibold))
                .lineLimit(1)

            if let progress {
                Divider()
                    .frame(height: 11)

                Text("\(progress.completed)/\(progress.total)")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(statusColor.opacity(backgroundOpacity), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(statusColor.opacity(borderOpacity), lineWidth: 0.75)
        }
        .fixedSize(horizontal: true, vertical: false)
        .help(state.title)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(state.title)
    }

    private var progress: (completed: Int, total: Int)? {
        switch state {
        case let .building(completed, total), let .installing(completed, total):
            return (completed, max(total, 1))
        default:
            return nil
        }
    }

    private var phaseTitle: String {
        switch state {
        case .idle: "Ready"
        case .importing: "Importing"
        case .refreshingDestinations: "Refreshing destinations"
        case .refreshingSchemes: "Refreshing schemes"
        case .preparingBuild: "Constructing build description"
        case .building: "Building"
        case .installing: "Installing"
        case .launching: "Launching"
        case .running: "Running"
        case .cancelling: "Cancelling"
        case .succeeded: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    private var statusSymbol: String {
        switch state {
        case .idle: "checkmark"
        case .succeeded: "checkmark.circle.fill"
        case .running: "circle.fill"
        case .failed: "xmark.octagon.fill"
        case .cancelled: "stop.circle.fill"
        default: "circle.fill"
        }
    }

    private var statusColor: Color {
        switch state {
        case .idle: .secondary
        case .succeeded, .running: .green
        case .failed: .red
        case .cancelled: .orange
        default: XerTheme.action
        }
    }

    private var backgroundOpacity: Double {
        switch state {
        case .idle: 0.06
        case .failed, .cancelled, .succeeded, .running: 0.10
        default: 0.09
        }
    }

    private var borderOpacity: Double {
        switch state {
        case .idle: 0.16
        default: 0.22
        }
    }
}

struct OperationIssueSheet: View {
    let issue: OperationIssue
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "xmark.octagon.fill")
                    .font(.title2)
                    .foregroundStyle(.red)

                VStack(alignment: .leading, spacing: 2) {
                    Text(issue.title)
                        .font(.title2.weight(.semibold))
                    Text("Review the summary and technical details below.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Summary")
                            .font(.headline)
                        Text(issue.summary)
                            .font(.body)
                            .textSelection(.enabled)
                    }

                    if let details = issue.details {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Technical Details")
                                .font(.headline)
                            Text(details)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(
                                    Color(nsColor: .textBackgroundColor),
                                    in: RoundedRectangle(cornerRadius: 8)
                                )
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                                }
                        }
                    }
                }
                .padding(20)
            }

            Divider()

            HStack {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(issue.message, forType: .string)
                } label: {
                    Label("Copy Error", systemImage: "doc.on.doc")
                }

                Spacer()

                Button("Done", action: dismiss)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 440, idealHeight: 560)
    }
}
