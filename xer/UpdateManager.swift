import Combine
import Foundation
import Sparkle

@MainActor
final class UpdateManager: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let feedURL = "https://xer.anuz.dev/appcast.xml"

    @Published private(set) var updateAvailable = false
    @Published private(set) var isChecking = false

    private lazy var controller: SPUStandardUpdaterController = {
        SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }()

    override init() {
        super.init()
        _ = controller
    }

    func checkForUpdatesInBackground() {
        guard controller.updater.canCheckForUpdates else { return }
        isChecking = true
        controller.updater.checkForUpdatesInBackground()
    }

    func showUpdateCheck() {
        guard controller.updater.canCheckForUpdates else { return }
        isChecking = true
        controller.checkForUpdates(nil)
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        Self.feedURL
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        updateAvailable = true
        isChecking = false
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        updateAvailable = false
        isChecking = false
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        updateAvailable = false
        isChecking = false
    }
}
