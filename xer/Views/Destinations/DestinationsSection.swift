import AppKit
import SwiftUI

extension ContentView {

    var destinationsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    destinationSectionHeading
                    Spacer()
                    destinationSelectionStatus
                    destinationDeviceActions
                }

                VStack(alignment: .leading, spacing: 8) {
                    destinationSectionHeading
                    HStack {
                        destinationSelectionStatus
                        Spacer()
                        destinationDeviceActions
                    }
                }
            }

            HStack(spacing: 8) {
                DestinationSearchField(
                    text: Binding(
                        get: { model.destinationSearchQuery },
                        set: { query in
                            guard query != model.destinationSearchQuery else { return }
                            DispatchQueue.main.async {
                                model.setDestinationSearchQuery(query)
                            }
                        }
                    ),
                    isFocused: $isDestinationSearchFocused
                )

                Picker("Destination layout", selection: $destinationLayout) {
                    Label("List", systemImage: "list.bullet").tag(DestinationLayout.list)
                    Label("Grid", systemImage: "square.grid.2x2").tag(DestinationLayout.grid)
                }
                .labelsHidden()
                .labelStyle(.iconOnly)
                .pickerStyle(.segmented)
                .frame(width: 84)
            }

            ViewThatFits(in: .horizontal) {
                destinationFilterBar(compact: false)
                destinationFilterBar(compact: true)
            }

            if let warning = model.destinationWarning {
                developerToolsCallout(warning)
            }

            if model.isBusy && model.operationState == .refreshingDestinations && model.destinations.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Checking developer destinations…")
                            .font(.callout.weight(.medium))
                        Text("Reading Simulator and CoreDevice availability from Xcode tools.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 20)
            } else if model.destinations.isEmpty {
                ContentUnavailableView {
                    Label("No destinations available", systemImage: "iphone.slash")
                } description: {
                    Text("Open a simulator, or connect, pair, and enable Developer Mode on a physical device. Then refresh destinations.")
                } actions: {
                    Button("Refresh Destinations") { model.refreshDestinations() }
                        .disabled(model.isBusy)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } else if visibleDestinations.isEmpty {
                ContentUnavailableView {
                    Label("No matching destinations", systemImage: "magnifyingglass")
                } description: {
                    Text(destinationEmptyDescription)
                } actions: {
                    Button("Clear Filters") {
                        clearDestinationFilters(includeSearch: true)
                        isDestinationSearchFocused = true
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(destinationPresentationGroups.enumerated()), id: \.element.id) { index, group in
                        if index > 0 {
                            Divider()
                        }
                        destinationGroup(
                            title: group.title,
                            kind: group.kind,
                            destinations: group.destinations
                        )
                    }
                }
            }
        }
    }

    var destinationSectionHeading: some View {
        sectionHeading(
            "Destinations",
            detail: "Choose the ready devices that should receive this build. Up to two run in parallel."
        )
    }

    var destinationSelectionStatus: some View {
        HStack(spacing: 8) {
            if model.isBusy && model.operationState == .refreshingDestinations && !model.destinations.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Refreshing destinations")
            }
            Text("\(model.selectedDestinations.count) selected")
                .font(.callout.weight(.medium))
                .foregroundStyle(model.selectedDestinations.isEmpty ? .secondary : XerTheme.action)
        }
    }

    var destinationDeviceActions: some View {
        ControlGroup {
            Button {
                model.openDeviceManager()
            } label: {
                Label("Manage Devices", systemImage: "iphone.gen3")
            }
            .help("Open Xcode to manage devices and simulators")

            Button {
                model.refreshDestinations()
            } label: {
                Label("Refresh Devices", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(model.isBusy)
            .help("Refresh This Mac, simulators, and connected physical devices (⇧⌘R)")
        }
        .controlSize(.small)
    }

    func destinationFilterBar(compact: Bool) -> some View {
        HStack(spacing: compact ? 4 : 6) {
            destinationScopeButton(.all, compact: compact)
            destinationScopeButton(.favorites, compact: compact)
            destinationScopeButton(.physical, compact: compact)
            destinationScopeButton(.simulators, compact: compact)
            destinationMoreFiltersMenu(compact: compact)

            Spacer(minLength: 4)

            ForEach(Array(selectedDestinationOS.sorted().prefix(compact ? 1 : 2)), id: \.self) { os in
                DestinationFilterToken(title: os) {
                    selectedDestinationOS.remove(os)
                }
            }

            if selectedDestinationOS.count > (compact ? 1 : 2) {
                Text("+\(selectedDestinationOS.count - (compact ? 1 : 2))")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if readyDestinationsOnly {
                DestinationFilterToken(title: "Ready") {
                    readyDestinationsOnly = false
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    func destinationScopeButton(_ scope: DestinationScope, compact: Bool) -> some View {
        Button {
            destinationScope = scope
        } label: {
            if compact && scope != .all {
                Image(systemName: scope.symbol)
                    .frame(width: 14)
            } else if scope == .all {
                Text(scope.title)
            } else {
                Label(scope.title, systemImage: scope.symbol)
            }
        }
        .font(.caption.weight(.medium))
        .buttonStyle(DestinationScopeChipStyle(isSelected: destinationScope == scope))
        .help(scope.help)
        .accessibilityLabel(scope.title)
        .accessibilityAddTraits(destinationScope == scope ? .isSelected : [])
    }

    func destinationMoreFiltersMenu(compact: Bool) -> some View {
        Menu {
            Menu("Operating System") {
                ForEach(availableDestinationOS, id: \.self) { os in
                    Button {
                        toggleDestinationOS(os)
                    } label: {
                        Label(os, systemImage: selectedDestinationOS.contains(os) ? "checkmark" : "circle")
                    }
                }
            }

            Menu("Device Type") {
                ForEach([DestinationScope.all, .mac, .physical, .simulators]) { scope in
                    Button {
                        destinationScope = scope
                    } label: {
                        Label(scope.title, systemImage: destinationScope == scope ? "checkmark" : scope.symbol)
                    }
                }
            }

            Divider()
            Toggle("Ready only", isOn: $readyDestinationsOnly)

            if hasStructuredDestinationFilters {
                Divider()
                Button("Clear Filters") {
                    clearDestinationFilters(includeSearch: false)
                }
            }
        } label: {
            if compact {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.caption.weight(.medium))
            } else {
                Label("More", systemImage: "line.3.horizontal.decrease")
                    .font(.caption.weight(.medium))
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.75)
        }
        .help("More destination filters")
    }

    @ViewBuilder
    func destinationGroup(
        title: String,
        kind: DestinationKind,
        destinations matching: [Destination]
    ) -> some View {
        let readyCount = matching.count(where: \.isReadyForDevelopment)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: destinationSymbol(for: kind))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Text(title)
                    .font(.headline)
                Spacer()
                HealthBadge(
                    title: matching.isEmpty ? "None found" : "\(readyCount) of \(matching.count) ready",
                    isHealthy: !matching.isEmpty && readyCount == matching.count,
                    isEmpty: matching.isEmpty
                )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if matching.isEmpty {
                Text(emptyDestinationMessage(for: kind))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 13)
            } else if destinationLayout == .list {
                Divider()
                ForEach(Array(matching.enumerated()), id: \.element.id) { index, destination in
                    DestinationRow(
                        destination: destination,
                        isSelected: model.selectedDestinationIDs.contains(destination.id),
                        isFavorite: favoriteDestinationIDs.contains(destination.id),
                        setSelected: { isSelected in
                            DispatchQueue.main.async {
                                model.setDestination(destination.id, isSelected: isSelected)
                            }
                        },
                        setFavorite: { isFavorite in
                            setDestinationFavorite(destination.id, isFavorite: isFavorite)
                        }
                    )
                    if index < matching.count - 1 {
                        Divider().padding(.leading, 54)
                    }
                }
            } else {
                Divider()
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 210), spacing: 8)],
                    spacing: 8
                ) {
                    ForEach(matching) { destination in
                        DestinationGridCard(
                            destination: destination,
                            isSelected: model.selectedDestinationIDs.contains(destination.id),
                            isFavorite: favoriteDestinationIDs.contains(destination.id),
                            setSelected: { isSelected in
                                model.setDestination(destination.id, isSelected: isSelected)
                            },
                            setFavorite: { isFavorite in
                                setDestinationFavorite(destination.id, isFavorite: isFavorite)
                            }
                        )
                    }
                }
                .padding(10)
            }
        }
    }

    var favoriteDestinationIDs: Set<String> {
        Set(favoriteDestinationStorage.split(separator: "\n").map(String.init))
    }

    var availableDestinationOS: [String] {
        Set(model.destinations.map { destinationOSLabel($0) }).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    var hasStructuredDestinationFilters: Bool {
        destinationScope != .all || !selectedDestinationOS.isEmpty || readyDestinationsOnly
    }

    var visibleDestinations: [Destination] {
        let matches = model.filteredDestinations.filter { destination in
            let matchesScope: Bool
            switch destinationScope {
            case .all:
                matchesScope = true
            case .favorites:
                matchesScope = favoriteDestinationIDs.contains(destination.id)
            case .mac:
                matchesScope = destination.kind == .localMac
            case .physical:
                matchesScope = destination.kind == .physicalDevice
            case .simulators:
                matchesScope = destination.kind == .simulator
            }

            return matchesScope
                && (selectedDestinationOS.isEmpty || selectedDestinationOS.contains(destinationOSLabel(destination)))
                && (!readyDestinationsOnly || destination.isReadyForDevelopment)
        }

        let sorted = Destination.sorted(matches)
        return sorted.filter { favoriteDestinationIDs.contains($0.id) }
            + sorted.filter { !favoriteDestinationIDs.contains($0.id) }
    }

    var filteredSimulators: [Destination] {
        visibleDestinations.filter { $0.kind == .simulator }
    }

    var filteredLocalMacs: [Destination] {
        visibleDestinations.filter { $0.kind == .localMac }
    }

    var filteredConnectedDestinations: [Destination] {
        visibleDestinations.filter { $0.kind == .physicalDevice && $0.isConnected }
    }

    var destinationPresentationGroups: [DestinationPresentationGroup] {
        [
            DestinationPresentationGroup(id: "mac", title: "Mac", kind: .localMac, destinations: filteredLocalMacs),
            DestinationPresentationGroup(id: "physical", title: "iOS Devices", kind: .physicalDevice, destinations: filteredConnectedDestinations),
            DestinationPresentationGroup(id: "simulators", title: "Simulators", kind: .simulator, destinations: filteredSimulators),
            DestinationPresentationGroup(id: "unavailable", title: "Unavailable Devices", kind: .physicalDevice, destinations: filteredUnavailablePhysicalDevices)
        ]
        .filter { !$0.destinations.isEmpty }
    }

    func destinationSymbol(for kind: DestinationKind) -> String {
        switch kind {
        case .localMac: "desktopcomputer"
        case .simulator: "iphone.gen3"
        case .physicalDevice: "cable.connector.horizontal"
        }
    }

    func emptyDestinationMessage(for kind: DestinationKind) -> String {
        let searching = !model.destinationSearchQuery.isEmpty
        switch kind {
        case .localMac:
            return searching ? "This Mac does not match this search." : "This Mac is not available."
        case .simulator:
            return searching ? "No simulators match this search." : "No available Simulator runtimes were reported by simctl."
        case .physicalDevice:
            return searching ? "No connected physical devices match this search." : "No connected physical devices were reported by devicectl."
        }
    }

    var filteredUnavailablePhysicalDevices: [Destination] {
        visibleDestinations.filter {
            $0.kind == .physicalDevice && !$0.isConnected
        }
    }

    var destinationEmptyDescription: String {
        if destinationScope == .favorites && favoriteDestinationIDs.isEmpty {
            return "Favorite a device with its star button to keep it in this quick view."
        }
        if !model.destinationSearchQuery.isEmpty {
            return "No device matches “\(model.destinationSearchQuery)” and the active filters."
        }
        return "No destinations match the active OS, device type, favorites, or readiness filters."
    }

    func destinationOSLabel(_ destination: Destination) -> String {
        guard let version = destination.osVersion, !version.isEmpty else {
            return destination.platform
        }
        return "\(destination.platform) \(version)"
    }

    func toggleDestinationOS(_ os: String) {
        if selectedDestinationOS.contains(os) {
            selectedDestinationOS.remove(os)
        } else {
            selectedDestinationOS.insert(os)
        }
    }

    func clearDestinationFilters(includeSearch: Bool) {
        destinationScope = .all
        selectedDestinationOS.removeAll()
        readyDestinationsOnly = false
        if includeSearch {
            model.setDestinationSearchQuery("")
        }
    }

    func setDestinationFavorite(_ destinationID: String, isFavorite: Bool) {
        var favorites = favoriteDestinationIDs
        if isFavorite {
            favorites.insert(destinationID)
        } else {
            favorites.remove(destinationID)
        }
        favoriteDestinationStorage = favorites.sorted().joined(separator: "\n")
    }

    func warningLooksLikeToolFailure(_ warning: String) -> Bool {
        let value = warning.lowercased()
        return value.contains("developer tool") || value.contains("xcode") || value.contains("xcrun") || value.contains("command not found") || value.contains("no such file")
    }
}
