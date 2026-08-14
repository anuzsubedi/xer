import Foundation
import XCTest
@testable import xer

final class XerToolingTests: XCTestCase {
    func testSimctlFixtureParsing() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/simctl-devices.json")
        let object = try XCTUnwrap(DeveloperTooling.jsonObject(from: try Data(contentsOf: fixtureURL)))
        let destinations = try DeveloperTooling.simulatorDestinations(from: object)

        XCTAssertEqual(destinations.count, 2)
        XCTAssertTrue(destinations.contains { $0.name == "iPhone Fixture" && $0.platform == "iOS" })
        XCTAssertTrue(destinations.contains { $0.name == "Apple TV Fixture" && $0.platform == "tvOS" })
    }

    func testDevicectlFixtureFiltersSimulatorsAndRetainsUnavailableDevices() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/devicectl-devices.json")
        let object = try XCTUnwrap(DeveloperTooling.jsonObject(from: try Data(contentsOf: fixtureURL)))
        let destinations = try DeveloperTooling.physicalDestinations(from: object)

        XCTAssertEqual(destinations.count, 2)
        XCTAssertEqual(destinations.first(where: { $0.name == "Fixture iPhone" })?.udid, "00008101-0000000000000001")
        XCTAssertTrue(destinations.contains { $0.name == "Fixture iPhone" && $0.isReadyForDevelopment })
        XCTAssertTrue(destinations.contains { $0.name == "Offline Fixture" && !$0.isAvailable && !$0.isReadyForDevelopment })
    }

    func testDestinationOrderingAndSearch() {
        let connected = Destination(
            udid: "connected",
            name: "Zebra iPhone",
            platform: "iOS",
            osVersion: "26.5",
            state: "connected",
            kind: .physicalDevice,
            isAvailable: true
        )
        let simulator = Destination(
            udid: "simulator",
            name: "Alpha Simulator",
            platform: "iOS",
            osVersion: "26.5",
            state: "Booted",
            kind: .simulator,
            isAvailable: true
        )
        let offline = Destination(
            udid: "offline",
            name: "Offline iPhone",
            platform: "iOS",
            osVersion: "26.5",
            state: "disconnected",
            kind: .physicalDevice,
            isAvailable: false
        )

        let ordered = Destination.sorted([offline, simulator, connected])
        XCTAssertEqual(ordered.map(\.id), [connected.id, simulator.id, offline.id])
        XCTAssertTrue(connected.matchesSearch("zebra connected"))
        XCTAssertTrue(offline.matchesSearch("offline"))
        XCTAssertFalse(simulator.matchesSearch("physical"))

        let stalePhysical = Destination(
            udid: "stale-physical",
            name: "Stale Physical",
            platform: "iOS",
            osVersion: "26.5",
            state: "unknown",
            kind: .physicalDevice,
            isAvailable: true
        )
        XCTAssertFalse(stalePhysical.isConnected)
        XCTAssertFalse(stalePhysical.isReadyForDevelopment)
        XCTAssertTrue(stalePhysical.matchesSearch("disconnected"))
        XCTAssertEqual(Destination.sorted([stalePhysical, simulator, connected]).first?.id, connected.id)
    }

    func testConsoleLaunchArgumentsRemainAttached() {
        let artifact = BuildArtifact(
            appURL: URL(fileURLWithPath: "/tmp/My App.app"),
            bundleIdentifier: "com.example.my-app",
            destination: Destination(
                udid: "device",
                name: "Fixture",
                platform: "iOS",
                osVersion: "26.5",
                state: "connected",
                kind: .physicalDevice,
                isAvailable: true
            )
        )

        XCTAssertTrue(DeveloperTooling.simulatorLaunchArguments(for: artifact).contains("--console"))
        XCTAssertTrue(DeveloperTooling.physicalDeviceLaunchArguments(for: artifact).contains("--console"))
        XCTAssertFalse(DeveloperTooling.physicalDeviceLaunchArguments(for: artifact).contains("--timeout"))
    }

    func testCommandsKeepPathsAndArgumentsSeparate() {
        let project = ImportedProject(
            path: "/tmp/Folder With Spaces/My App.xcodeproj",
            kind: .project,
            schemes: [SharedScheme(name: "My App")],
            isTrusted: true,
            parentPath: nil
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
        let derivedData = URL(fileURLWithPath: "/tmp/Derived Data")
        let arguments = DeveloperTooling.buildArguments(
            for: project,
            scheme: "My App",
            configuration: "Debug",
            destination: destination,
            derivedDataURL: derivedData
        )

        XCTAssertEqual(arguments[0], "xcodebuild")
        XCTAssertEqual(arguments[2], project.path)
        XCTAssertEqual(arguments[4], "My App")
        XCTAssertEqual(arguments[6], "Debug")
        XCTAssertEqual(arguments[8], destination.xcodebuildSpecifier)
        XCTAssertEqual(arguments[10], derivedData.path)
        XCTAssertEqual(arguments.last, "build")

        let display = ProcessRunner.displayCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: arguments
        )
        XCTAssertTrue(display.contains("'/tmp/Folder With Spaces/My App.xcodeproj'"))
    }

    func testAppIconMetadataReadsBundleIcon() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xer-icon-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let appURL = root.appendingPathComponent("Fixture.app", isDirectory: true)
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.example.fixture",
            "CFBundleDisplayName": "Fixture",
            "CFBundleIconFiles": ["AppIcon"]
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: appURL.appendingPathComponent("Info.plist"))
        let iconData = Data([0, 1, 2, 3])
        try iconData.write(to: appURL.appendingPathComponent("AppIcon.png"))

        let metadata = try DeveloperTooling.localAppMetadata(for: appURL)
        XCTAssertEqual(metadata.bundleIdentifier, "com.example.fixture")
        XCTAssertEqual(metadata.displayName, "Fixture")
        XCTAssertEqual(metadata.icon?.data, iconData)
    }

    func testProjectDiscoveryAndPersistence() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xer-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let projectURL = root.appendingPathComponent("App.xcodeproj", isDirectory: true)
        let schemesURL = projectURL.appendingPathComponent("xcshareddata/xcschemes", isDirectory: true)
        try FileManager.default.createDirectory(at: schemesURL, withIntermediateDirectories: true)
        try Data("<Scheme />".utf8).write(to: schemesURL.appendingPathComponent("App.xcscheme"))

        let discovery = ProjectDiscovery()
        let found = discovery.discover(in: root)
        XCTAssertEqual(found.map(\.kind), [.project])
        XCTAssertEqual(discovery.sharedSchemes(in: projectURL).map(\.name), ["App"])

        let suiteName = "xer.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = BookmarkStore(defaults: defaults)
        XCTAssertTrue(store.saveParentFolder(root))
        XCTAssertEqual(store.resolveParentFolder(), root.standardizedFileURL)
    }

    func testProjectAppIconDiscoveryPrefersConfiguredLargestRendition() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xer-project-icon-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let projectURL = root.appendingPathComponent("App.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try Data("ASSETCATALOG_COMPILER_APPICON_NAME = BrandIcon;".utf8)
            .write(to: projectURL.appendingPathComponent("project.pbxproj"))

        let iconSetURL = root.appendingPathComponent(
            "App/Assets.xcassets/BrandIcon.appiconset",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: iconSetURL, withIntermediateDirectories: true)
        let smallIcon = Data([1, 2, 3])
        let marketingIcon = Data([4, 5, 6, 7])
        try smallIcon.write(to: iconSetURL.appendingPathComponent("Icon-60.png"))
        let marketingURL = iconSetURL.appendingPathComponent("Icon-1024.png")
        try marketingIcon.write(to: marketingURL)
        let contents: [String: Any] = [
            "images": [
                ["filename": "Icon-60.png", "idiom": "iphone", "size": "60x60", "scale": "2x"],
                ["filename": "Icon-1024.png", "idiom": "ios-marketing", "size": "1024x1024", "scale": "1x"]
            ],
            "info": ["author": "xcode", "version": 1]
        ]
        try JSONSerialization.data(withJSONObject: contents)
            .write(to: iconSetURL.appendingPathComponent("Contents.json"))

        let icon = try XCTUnwrap(ProjectDiscovery().appIcon(in: projectURL))
        XCTAssertEqual(icon.data, marketingIcon)
        XCTAssertEqual(icon.sourceURL, marketingURL)
    }

    func testProjectAppIconDiscoverySupportsIconComposerSources() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xer-icon-composer-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let projectURL = root.appendingPathComponent("App.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try Data("ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;".utf8)
            .write(to: projectURL.appendingPathComponent("project.pbxproj"))

        let composerURL = root.appendingPathComponent("AppIcon.icon", isDirectory: true)
        let assetsURL = composerURL.appendingPathComponent("Assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)
        let defaultArtwork = Data("<svg width=\"1024\" height=\"1024\"></svg>".utf8)
        let darkArtwork = Data("<svg width=\"1024\" height=\"1024\"><!-- dark --></svg>".utf8)
        let defaultURL = assetsURL.appendingPathComponent("Default.svg")
        try defaultArtwork.write(to: defaultURL)
        try darkArtwork.write(to: assetsURL.appendingPathComponent("Dark.svg"))
        let metadata: [String: Any] = [
            "groups": [[
                "layers": [
                    ["image-name": "Default.svg", "hidden": false],
                    [
                        "image-name": "Dark.svg",
                        "hidden": false,
                        "opacity-specializations": [
                            ["value": 0],
                            ["appearance": "dark", "value": 1]
                        ]
                    ]
                ]
            ]]
        ]
        try JSONSerialization.data(withJSONObject: metadata)
            .write(to: composerURL.appendingPathComponent("icon.json"))

        let icon = try XCTUnwrap(ProjectDiscovery().appIcon(in: projectURL))
        XCTAssertEqual(icon.data, defaultArtwork)
        XCTAssertEqual(icon.sourceURL, defaultURL)
    }

    func testDirectProcessRunnerUsesArgv() async throws {
        let result = try await ProcessRunner().run(
            executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["%s", "path with spaces"]
        )
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.stdout, "path with spaces")
    }

    func testProcessRunnerCancellationTerminatesProcess() async throws {
        let task = Task {
            try await ProcessRunner().run(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["10"]
            )
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("cancelled process unexpectedly completed")
        } catch is CancellationError {
            // Expected: ProcessRunner terminates the child and propagates cancellation.
        }
    }
}
