//
//  AppUpdaterController.swift
//  Treemux
//

import AppKit
import Foundation
import Sparkle

@MainActor
private final class SparkleUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        AppUpdaterController.resolveFeedURLString(infoDictionary: Bundle.main.infoDictionary)
    }

    /// Just before Sparkle relaunches to install an update, tear down any
    /// open window-modal sheet (most often the Settings sheet). A presented
    /// sheet keeps a modal session alive on its parent window, which prevents
    /// the app from terminating cleanly and stalls Sparkle's quit-and-relaunch
    /// handshake — the relaunch only succeeds if the sheet is closed first.
    /// Sparkle invokes this on the main thread.
    nonisolated func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        MainActor.assumeIsolated {
            for window in NSApp.windows {
                if let sheet = window.attachedSheet {
                    window.endSheet(sheet)
                }
            }
        }
    }
}

@MainActor
final class AppUpdaterController {
    static let shared = AppUpdaterController()

    nonisolated static let repository = "BatchZero/Treemux"
    nonisolated static let feedURLInfoPlistKey = "SUFeedURL"
    nonisolated static let defaultFeedURLString =
        "https://raw.githubusercontent.com/\(repository)/stable/sparkle-feed.xml"

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
