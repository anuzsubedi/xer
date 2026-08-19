import Foundation

@main
struct ToolingFixtureCheck {
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 3 else {
            throw TestFailure("usage: ToolingFixtureCheck <simctl-json> <devicectl-json>")
        }

        let simulatorURL = URL(fileURLWithPath: arguments[1])
        let simulatorObject = try loadJSON(at: simulatorURL)
        let simulators = try DeveloperTooling.simulatorDestinations(from: simulatorObject)
        let isFixtureRun = simulatorURL.lastPathComponent == "simctl-devices.json"
        if isFixtureRun {
            expect(simulators.count == 2, "expected two available simulator fixtures")
            expect(simulators.contains { $0.name == "iPhone Fixture" && $0.platform == "iOS" && $0.osVersion == "26.5" }, "iOS simulator parsing failed")
            expect(simulators.contains { $0.name == "Apple TV Fixture" && $0.platform == "tvOS" }, "runtime/platform parsing failed")
        } else {
            expect(!simulators.isEmpty, "live simctl output should contain at least one available simulator")
        }

        let deviceURL = URL(fileURLWithPath: arguments[2])
        let deviceObject = try loadJSON(at: deviceURL)
        let devices = try DeveloperTooling.physicalDestinations(from: deviceObject)
        if isFixtureRun {
            expect(devices.count == 2, "simulated device should be filtered while physical devices remain visible")
            let connected = devices.first { $0.name == "Fixture iPhone" }
            expect(connected?.udid == "00008101-0000000000000001", "hardware UDID should be preferred")
            expect(connected?.isAvailable == true && connected?.isReadyForDevelopment == true, "connected paired device should be ready")
            expect(devices.contains { $0.name == "Offline Fixture" && !$0.isAvailable && !$0.isReadyForDevelopment }, "offline device should remain visible as unavailable")
        } else {
            // A Mac without a connected phone is valid; an empty result is not
            // an error for live devicectl parsing, so only exercise the parser.
            expect(devices.allSatisfy { $0.kind == .physicalDevice }, "live devicectl output produced a non-physical destination")
        }

        let project = ImportedProject(
            path: "/tmp/Folder With Spaces/My App.xcodeproj",
            kind: .project,
            schemes: [SharedScheme(name: "My App")],
            isTrusted: true,
            parentPath: "/tmp/Folder With Spaces"
        )
        let destination = Destination(
            udid: "11111111-1111-1111-1111-111111111111",
            name: "Fixture iPhone",
            platform: "iOS",
            osVersion: "26.5",
            state: "Shutdown",
            kind: .simulator,
            isAvailable: true
        )
        let derivedData = URL(fileURLWithPath: "/tmp/Derived Data/Folder")
        let buildArguments = DeveloperTooling.buildArguments(
            for: project,
            scheme: "My App",
            configuration: "Debug",
            destination: destination,
            derivedDataURL: derivedData
        )
        expect(buildArguments == [
            "xcodebuild", "-project", project.path,
            "-scheme", "My App",
            "-configuration", "Debug",
            "-destination", "id=11111111-1111-1111-1111-111111111111",
            "-derivedDataPath", derivedData.path,
            "build"
        ], "xcodebuild argv construction changed")
        expect(!buildArguments.joined(separator: " ").contains("'") && buildArguments.contains(project.path), "paths must remain individual argv values")

        let physicalArtifact = BuildArtifact(
            appURL: URL(fileURLWithPath: "/tmp/Build Products/My App.app"),
            bundleIdentifier: "com.example.my-app",
            destination: Destination(
                udid: "00008101-0000000000000001",
                name: "Fixture iPhone",
                platform: "iOS",
                osVersion: "26.5",
                state: "connected",
                kind: .physicalDevice,
                isAvailable: true
            )
        )
        let installArguments = DeveloperTooling.physicalDeviceInstallLaunchArguments(for: physicalArtifact)
        expect(installArguments.count == 2 && installArguments[0].contains(physicalArtifact.appURL.path), "physical install argv construction failed")
        expect(installArguments[1].last == physicalArtifact.bundleIdentifier, "physical launch argv construction failed")

        let displayed = ProcessRunner.displayCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["xcodebuild", "-project", project.path, "-scheme", "$(not-shell-expanded)"]
        )
        expect(displayed.contains("'/tmp/Folder With Spaces/My App.xcodeproj'"), "command display should quote paths")
        expect(displayed.contains("'$(not-shell-expanded)'"), "command display should not expose shell expansion")

        let macOnly = DeveloperTooling.schemeRunDestinations(in: """
        { platform:macOS, arch:arm64, id:00008142-000E69EC3A22401C, name:My Mac }
        { platform:macOS, name:Any Mac }
        """)
        expect(Destination.localMac.isCompatible(with: macOnly), "macOS-only schemes must accept This Mac")
        expect(!destination.isCompatible(with: macOnly), "macOS-only schemes must reject iOS simulators")

        try testProjectDiscoveryAndPersistence()
        let processResult = try await ProcessRunner().run(
            executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["%s", "argv-safe path"]
        )
        expect(processResult.succeeded && processResult.stdout == "argv-safe path", "direct Process argv execution failed")

        print("ToolingFixtureCheck passed: parsing, command argv construction, persistence, discovery, and direct process execution.")
    }

    private static func testProjectDiscoveryAndPersistence() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xer-fixture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let projectURL = root.appendingPathComponent("My App.xcodeproj", isDirectory: true)
        let workspaceURL = root.appendingPathComponent("Workspace.xcworkspace", isDirectory: true)
        let projectSchemes = projectURL.appendingPathComponent("xcshareddata/xcschemes", isDirectory: true)
        let workspaceSchemes = workspaceURL.appendingPathComponent("xcshareddata/xcschemes", isDirectory: true)
        try FileManager.default.createDirectory(at: projectSchemes, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspaceSchemes, withIntermediateDirectories: true)
        try Data("<Scheme />".utf8).write(to: projectSchemes.appendingPathComponent("My App.xcscheme"))
        try Data("<Scheme />".utf8).write(to: workspaceSchemes.appendingPathComponent("Workspace.xcscheme"))
        try Data("not a container".utf8).write(to: root.appendingPathComponent("notes.txt"))

        let discovery = ProjectDiscovery()
        let found = discovery.discover(in: root)
        expect(found.count == 2, "project discovery should find both supported container types")
        let discoveredProject = found.first { $0.kind == .project }
        expect(discoveredProject?.url == projectURL.standardizedFileURL, "project path discovery failed")
        expect(discovery.sharedSchemes(in: projectURL).map(\.name) == ["My App"], "shared scheme discovery failed")

        let defaultsName = "xer.fixture.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: defaultsName) else {
            throw TestFailure("could not create isolated UserDefaults suite")
        }
        defer {
            defaults.removePersistentDomain(forName: defaultsName)
        }

        let store = BookmarkStore(defaults: defaults)
        expect(store.saveParentFolder(root), "parent folder path persistence failed")
        expect(store.resolveParentFolder() == root.standardizedFileURL, "parent folder restoration failed")
        let imported = ImportedProject(
            path: projectURL.path,
            kind: .project,
            schemes: discovery.sharedSchemes(in: projectURL),
            isTrusted: false,
            parentPath: root.path
        )
        expect(store.saveProject(imported), "project persistence failed")
        expect(store.storedProjects().first?.path == projectURL.standardizedFileURL.path, "stored project normalization failed")
    }

    private static func loadJSON(at url: URL) throws -> Any {
        guard let data = try? Data(contentsOf: url),
              let object = DeveloperTooling.jsonObject(from: data) else {
            throw TestFailure("could not load JSON fixture at \(url.path)")
        }
        return object
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
}

private struct TestFailure: Error, LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
