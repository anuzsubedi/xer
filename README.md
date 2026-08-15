# xer

A native macOS workbench for building and running one Xcode project across multiple destinations.

xer brings project discovery, scheme selection, destination readiness, builds, installation, launch, and live output into one focused workspace—without replacing Apple’s developer tools.

## Highlights

- Discover `.xcodeproj` and `.xcworkspace` containers
- Select shared Xcode schemes
- Run on This Mac, simulators, and connected physical devices
- Build for multiple destinations in one operation
- Inspect device readiness before running
- Install and launch built applications
- Stream build and application output
- Search and filter destinations and console messages
- Cancel active operations
- Remember trusted project folders
- Native SwiftUI interface with light and dark appearance support

## Requirements

- macOS 14 Sonoma or newer
- Xcode and its command-line developer tools
- Shared schemes for projects you want xer to discover
- Developer Mode and pairing configured for physical devices when required

## Getting Started

1. Clone the repository:

   ```bash
   git clone https://github.com/anuzsubedi/xer.git
   cd xer
   ```

2. Open the Xcode project:

   ```bash
   open xer.xcodeproj
   ```

3. Select the `xer` scheme and run the app on your Mac.

4. In xer, choose a parent folder containing your Xcode projects or workspaces.

5. Trust a project, select its scheme and destinations, then run it.

## How It Works

xer invokes Apple’s developer tools directly using argument arrays rather than shell-interpreted commands.

Depending on the selected destination, it coordinates tools such as:

- `xcodebuild`
- `simctl`
- `devicectl`

Local Mac applications are launched directly from their built app bundles. Simulator and physical-device applications are installed and launched using the appropriate Apple tooling.

## Trust and Security

Xcode projects can contain build phases that execute arbitrary scripts.

For that reason, xer requires projects to be explicitly trusted before invoking `xcodebuild` or executing project-defined build phases. Only trust repositories you have reviewed and would build directly in Xcode.

xer does not route developer-tool commands through a shell. Paths, schemes, and other values are passed as individual process arguments.

## Project Structure

```text
xer/
├── AppIcon.icon/           # Layered release application icon
├── DebugAppIcon.icon/      # Layered debug application icon
├── Tests/                  # XCTest and tooling fixtures
├── docs/                   # Documentation assets and benchmarks
├── scripts/                # Project utility scripts
├── xer/                    # Swift application source
│   ├── Application/        # App state, stores, and build coordination
│   ├── DeveloperTools/     # Xcode, device, simulator, and deployment clients
│   ├── Models/             # Projects, destinations, artifacts, and operations
│   ├── Persistence/        # Security-scoped bookmark persistence
│   ├── Projects/           # Project and icon discovery
│   ├── Views/              # Feature-organized SwiftUI views
│   ├── AppModel.swift      # Root observable application model
│   ├── ContentView.swift   # Root application view
│   └── ProcessRunner.swift # Process execution and lifecycle management
├── xer.xcodeproj/          # Xcode project and shared schemes
├── DESIGN.md               # Interface design system
└── PRODUCT.md              # Product principles and constraints
```

## Contributing

Issues and focused pull requests are welcome.

When contributing:

1. Keep the interface native and keyboard accessible.
2. Preserve the explicit project-trust boundary.
3. Pass command arguments directly—never construct shell commands from project data.
4. Keep diagnostics attached to the operation that produced them.

## License

xer is available under the [MIT License](LICENSE).
