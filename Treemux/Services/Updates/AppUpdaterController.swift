//
//  AppUpdaterController.swift
//  Treemux
//

import Foundation
import Sparkle

@MainActor
private final class SparkleUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        AppUpdaterController.resolveFeedURLString(infoDictionary: Bundle.main.infoDictionary)
    }
}

@MainActor
final class AppUpdaterController {
    static let shared = AppUpdaterController()

    nonisolated static let repository = "BatchZero/Treemux"
    nonisolated static let feedURLInfoPlistKey = "SUFeedURL"
    nonisolated static let defaultFeedURLString =
        "https://raw.githubusercontent.com/\(repository)/stable/appcast.xml"

    private let delegate = SparkleUpdaterDelegate()
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: delegate,
        userDriverDelegate: nil
    )

    func configure(
        automaticallyChecks: Bool,
        automaticallyDownloads: Bool,
        checkInBackground: Bool = false
    ) {
        let updater = controller.updater
        updater.automaticallyChecksForUpdates = automaticallyChecks
        updater.automaticallyDownloadsUpdates = automaticallyDownloads
        updater.updateCheckInterval = 3600

        if checkInBackground, automaticallyChecks {
            updater.checkForUpdatesInBackground()
        }
    }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }

    nonisolated static func resolveFeedURLString(infoDictionary: [String: Any]?) -> String {
        guard
            let value = infoDictionary?[feedURLInfoPlistKey] as? String,
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return defaultFeedURLString
        }
        return value
    }
}
