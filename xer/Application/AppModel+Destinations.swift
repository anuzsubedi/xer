import AppKit
import Foundation

extension AppModel {

    func setDestinationSearchQuery(_ query: String) {
        destinationSearchQuery = query
    }

    func refreshDestinations() {
        guard !isBusy else { return }
        lastIssue = nil
        destinationWarning = nil
        operationState = .refreshingDestinations
        appendLog(.command, "Refreshing This Mac, simulators, and connected physical devices with Apple developer tools.")

        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performDestinationRefresh()
            self.operationTask = nil
        }
    }

    func setDestination(_ destinationID: String, isSelected: Bool) {
        if isSelected {
            selectedDestinationIDs.insert(destinationID)
        } else {
            selectedDestinationIDs.remove(destinationID)
        }
    }

    func openDeviceManager() {
        guard let xcodeURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode") else {
            presentError("Xcode could not be found. Install Xcode to manage Apple devices and simulators.")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        Task { @MainActor in
            do {
                _ = try await NSWorkspace.shared.openApplication(
                    at: xcodeURL,
                    configuration: configuration
                )
            } catch {
                presentError("Xcode could not be opened: \(error.localizedDescription)")
            }
        }
    }

    func performDestinationRefresh() async {
        var allDestinations: [Destination] = [.localMac]
        var failures: [String] = []

        appendLog(.info, "This Mac is available as a local macOS destination.")

        do {
            let simulators = try await tooling.listSimulators()
            allDestinations.append(contentsOf: simulators)
            appendLog(.info, "simctl found \(simulators.count) available simulator(s).")
        } catch is CancellationError {
            operationState = .cancelled
            appendLog(.warning, "Destination refresh cancelled.")
            return
        } catch {
            let message = UserFacingError.describe(error)
            failures.append("Simulators: \(message)")
            appendLog(.warning, failures.last ?? message)
        }

        do {
            let devices = try await tooling.listPhysicalDevices()
            allDestinations.append(contentsOf: devices)
            appendLog(.info, "devicectl found \(devices.count) physical device(s).")
        } catch is CancellationError {
            operationState = .cancelled
            appendLog(.warning, "Destination refresh cancelled.")
            return
        } catch {
            let message = UserFacingError.describe(error)
            failures.append("Physical devices: \(message)")
            appendLog(.warning, failures.last ?? message)
        }

        destinations = Destination.sorted(allDestinations)
        selectedDestinationIDs = selectedDestinationIDs.intersection(
            Set(destinations.filter(\.isReadyForDevelopment).map(\.id))
        )
        if automaticallySelectRunningDestination, selectedDestinationIDs.isEmpty {
            let preferred = destinations.first {
                $0.kind == .simulator
                    && $0.isReadyForDevelopment
                    && $0.state?.localizedCaseInsensitiveContains("booted") == true
            } ?? destinations.first(where: \.isReadyForDevelopment)
            if let preferred {
                selectedDestinationIDs = [preferred.id]
            }
        }
        var warnings = failures
        let unavailablePhysicalCount = destinations.count {
            $0.kind == .physicalDevice && !$0.isReadyForDevelopment
        }
        if unavailablePhysicalCount > 0 {
            warnings.append("\(unavailablePhysicalCount) physical device(s) remain unavailable after xer asked CoreDevice to prepare them. Unlock and reconnect the device, confirm trust, and enable Developer Mode before refreshing.")
        }
        destinationWarning = warnings.isEmpty ? nil : warnings.joined(separator: "\n")

        if destinations.isEmpty, !failures.isEmpty {
            presentOperationFailure(failures.joined(separator: "\n"))
        } else {
            operationState = failures.isEmpty ? .succeeded : .failed(failures.joined(separator: "\n"))
        }
    }
}
