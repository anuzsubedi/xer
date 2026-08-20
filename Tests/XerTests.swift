import Foundation
import XCTest
@testable import xer

final class XerToolingTests: XCTestCase {
    func testSchemeDestinationCompatibilityFiltersMacOnlyProjects() {
        let output = """
        Available destinations for the "maill" scheme:
        \t{ platform:macOS, arch:arm64, id:00008142-000E69EC3A22401C, name:My Mac }
        \t{ platform:macOS, name:Any Mac }
        """
        let schemeDestinations = DeveloperTooling.schemeRunDestinations(in: output)
        XCTAssertEqual(schemeDestinations.count, 2)

        let mac = Destination.localMac
        let simulator = Destination(
            udid: "0B18E454-36FC-44F0-B134-1B4F59DA9CD5",
            name: "iPhone 17 Pro",
            platform: "iOS",
            osVersion: "27.0",
            state: "Shutdown",
            kind: .simulator,
            isAvailable: true
        )
        XCTAssertTrue(mac.isCompatible(with: schemeDestinations))
        XCTAssertFalse(simulator.isCompatible(with: schemeDestinations))
        XCTAssertEqual(
            SchemeDestinationSupport.summary(for: schemeDestinations),
            "This scheme only supports Mac destinations. Simulators and iOS devices are hidden."
        )
    }

    func testSchemeDestinationCompatibilityKeepsIOSSimulators() {
        let output = """
        \t{ platform:macOS, arch:arm64, variant:Mac Catalyst, id:00008142-000E69EC3A22401C, name:My Mac }
        \t{ platform:iOS Simulator, arch:arm64, id:0B18E454-36FC-44F0-B134-1B4F59DA9CD5, OS:27.0, name:iPhone 17 Pro }
        \t{ platform:iOS Simulator, id:dvtdevice-DVTiOSDeviceSimulatorPlaceholder-iphonesimulator:placeholder, name:Any iOS Simulator Device }
        """
        let schemeDestinations = DeveloperTooling.schemeRunDestinations(in: output)
        let matchingSimulator = Destination(
            udid: "0B18E454-36FC-44F0-B134-1B4F59DA9CD5",
            name: "iPhone 17 Pro",
            platform: "iOS",
            osVersion: "27.0",
            state: "Booted",
            kind: .simulator,
            isAvailable: true
        )
        let otherSimulator = Destination(
            udid: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            name: "iPhone 16",
            platform: "iOS",
            osVersion: "26.5",
            state: "Shutdown",
            kind: .simulator,
            isAvailable: true
        )
        XCTAssertTrue(Destination.localMac.isCompatible(with: schemeDestinations))
        XCTAssertTrue(matchingSimulator.isCompatible(with: schemeDestinations))
        XCTAssertTrue(otherSimulator.isCompatible(with: schemeDestinations))
        XCTAssertTrue(SchemeDestinationSupport.prefersMobileDestinations(schemeDestinations))
    }

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

        let userSchemes = projectURL.appendingPathComponent(
            "xcuserdata/tester.xcuserdatad/xcschemes",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: userSchemes, withIntermediateDirectories: true)
        try Data("<Scheme />".utf8).write(to: userSchemes.appendingPathComponent("Debug.xcscheme"))
        XCTAssertEqual(discovery.sharedSchemes(in: projectURL).map(\.name), ["App", "Debug"])

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

    func testProjectDiscoveryResolveImportRootFindsNestedProject() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        let nested = repo.appendingPathComponent("Sources/App", isDirectory: true)
        let project = repo.appendingPathComponent("Sample.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let discovery = ProjectDiscovery()
        let importRoot = discovery.resolveImportRoot(for: nested)
        XCTAssertEqual(importRoot?.standardizedFileURL.path, repo.standardizedFileURL.path)

        try FileManager.default.removeItem(at: root)
    }

    func testProjectDiscoveryMatchingProjectFindsImportedParent() {
        let parent = "/tmp/xer-cli-parent"
        let project = ImportedProject(
            path: "/tmp/xer-cli-parent/App.xcodeproj",
            kind: .project,
            schemes: [SharedScheme(name: "App")],
            isTrusted: true,
            parentPath: parent
        )
        let discovery = ProjectDiscovery()
        let match = discovery.matchingProject(
            in: [project],
            for: URL(fileURLWithPath: "/tmp/xer-cli-parent/Sources", isDirectory: true)
        )
        XCTAssertEqual(match?.id, project.id)
    }

    func testCLIRouteParserParsesOpenAndRunRequests() {
        let openURL = URL(string: "xer://open?path=/tmp/MyApp.xcodeproj")!
        let runURL = URL(string: "xer://run?path=/tmp/MyApp/Sources")!

        XCTAssertEqual(CLIRouteParser.request(from: openURL), .open(path: "/tmp/MyApp.xcodeproj"))
        XCTAssertEqual(CLIRouteParser.request(from: runURL), .run(path: "/tmp/MyApp/Sources"))
    }

    func testCLIInstallerDetectsZshProfile() {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shellName = URL(fileURLWithPath: shell).lastPathComponent
        let profile = CLIInstaller.detectedShellProfileURL

        switch shellName {
        case "zsh":
            XCTAssertEqual(profile?.lastPathComponent, ".zshrc")
        case "bash":
            XCTAssertTrue([".bash_profile", ".bashrc"].contains(profile?.lastPathComponent ?? ""))
        case "fish":
            XCTAssertEqual(profile?.lastPathComponent, "config.fish")
        default:
            XCTAssertEqual(profile?.lastPathComponent, ".profile")
        }
    }
}
