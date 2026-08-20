import AppKit
import SwiftUI

extension ContentView {

    var commandBar: some View {
        HStack(spacing: 12) {
            Spacer()

            OperationStatus(state: model.operationState, isBusy: model.isBusy)

            Button {
                model.runOrRestart()
            } label: {
                Label("Run", systemImage: "play.fill")
                    .frame(minWidth: 88)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(!model.canRunOrRestart)
            .help(model.isAppActive
                ? "Rebuild, install, and relaunch on selected destinations (⌘Return)"
                : "Build, install, and launch on selected destinations (⌘Return)")
            .accessibilityLabel(model.isAppActive
                ? "Rebuild, install, and relaunch on selected destinations"
                : "Build, install, and launch on selected destinations")

            Button {
                model.cancelCurrentOperation()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .keyboardShortcut(".", modifiers: [.command])
            .disabled(!model.canStop)
            .help(model.canStop ? "Cancel the current operation (⌘.)" : "Nothing is currently running")

            terminalCommandMenu
                .labelStyle(.iconOnly)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(XerTheme.workspace)
    }

    func sectionHeading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    func issueBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Operation failed")
                    .font(.callout.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(4)
            }
            Spacer()
            Button("Dismiss") { model.clearError() }
        }
        .padding(12)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    func developerToolsCallout(_ warning: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: warningLooksLikeToolFailure(warning) ? "wrench.and.screwdriver.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(warningLooksLikeToolFailure(warning) ? "Developer tools need attention" : "Some destinations are unavailable")
                    .font(.callout.weight(.semibold))
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if warningLooksLikeToolFailure(warning) {
                    Text("Install Xcode, open Xcode › Settings › Locations, choose Command Line Tools, then refresh destinations.")
                        .font(.caption.weight(.medium))
                }
            }
            Spacer()
            Button("Refresh") { model.refreshDestinations() }
                .disabled(model.isBusy)
        }
        .padding(12)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
