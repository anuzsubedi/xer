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

        await refreshSchemeCompatibleDestinations()
    }

    func refreshSchemeCompatibleDestinations() async {
        schemeDestinationTask?.cancel()

        let project = selectedProject
        let scheme = selectedSchemeName
        let currentDestinations = destinations

        guard let project, project.isTrusted, let scheme, !scheme.isEmpty else {
            schemeCompatibleDestinationIDs = nil
            schemeDestinationNote = nil
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let schemeDestinations = try await self.tooling.listSchemeRunDestinations(
                    for: project,
                    scheme: scheme
                )
                guard !Task.isCancelled else { return }
                guard self.selectedProjectID == project.id, self.selectedSchemeName == scheme else { return }
                self.applySchemeDestinations(schemeDestinations, to: currentDestinations)
            } catch is CancellationError {
                return
            } catch {
                guard self.selectedProjectID == project.id, self.selectedSchemeName == scheme else { return }
                self.schemeCompatibleDestinationIDs = nil
                self.schemeDestinationNote = nil
                self.appendLog(.warning, "Could not read compatible destinations for \(scheme): \(UserFacingError.describe(error))")
            }
        }
        schemeDestinationTask = task
        await task.value
    }

    func applySchemeDestinations(_ schemeDestinations: [SchemeRunDestination], to available: [Destination]) {
        let compatibleIDs = SchemeDestinationSupport.compatibleIDs(
            in: available,
            schemeDestinations: schemeDestinations
        )
        schemeCompatibleDestinationIDs = compatibleIDs
        schemeDestinationNote = SchemeDestinationSupport.summary(for: schemeDestinations)

        let remaining = selectedDestinationIDs.intersection(compatibleIDs)
        if !remaining.isEmpty {
            selectedDestinationIDs = remaining
            return
        }

        let compatible = available.filter { compatibleIDs.contains($0.id) && $0.isReadyForDevelopment }
        let preferred: Destination?
        if SchemeDestinationSupport.prefersMobileDestinations(schemeDestinations) {
            preferred = compatible.first {
                $0.kind == .simulator
                    && $0.state?.localizedCaseInsensitiveContains("booted") == true
            }
            ?? compatible.first { $0.kind == .simulator }
            ?? compatible.first { $0.kind == .physicalDevice }
            ?? compatible.first
        } else {
            preferred = compatible.first { $0.kind == .localMac } ?? compatible.first
        }
        selectedDestinationIDs = Set([preferred?.id].compactMap { $0 })
        if let preferred {
            appendLog(.info, "Selected \(preferred.name) because it matches the \(selectedSchemeName ?? "current") scheme.")
        }
    }
}
