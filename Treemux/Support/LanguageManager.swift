//
//  LanguageManager.swift
//  Treemux
//

import Combine
import CoreFoundation
import Foundation
import Observation
import SwiftUI

/// Manages application language override and publishes a Locale
/// for SwiftUI environment injection.
@MainActor
@Observable
final class LanguageManager {

    /// The active locale derived from the language setting.
    /// Bind this to `.environment(\.locale)` on the root view.
    private(set) var locale: Locale {
        didSet { localeSubject.send(locale) }
    }

    @ObservationIgnored private let localeSubject = PassthroughSubject<Locale, Never>()
    @ObservationIgnored private let systemLanguages: () -> [String]
    /// Bridge for WindowContext's root-view rebuild. Delivers the new locale
    /// as payload; never replays — subscriber needs no `.dropFirst()`.
    var localePublisher: AnyPublisher<Locale, Never> { localeSubject.eraseToAnyPublisher() }

    init(
        languageCode: String,
        systemLanguages: @escaping () -> [String] = LanguageManager.systemPreferredLanguages
    ) {
        self.systemLanguages = systemLanguages
        Self.persistOverride(languageCode)
        self.locale = Self.resolveLocale(languageCode, systemLanguages: systemLanguages())
    }

    /// Apply a new language setting at runtime.
    /// Updates the published locale (immediate SwiftUI effect)
    /// and persists the override for next launch.
    func apply(languageCode: String) {
        Self.persistOverride(languageCode)
        locale = Self.resolveLocale(languageCode, systemLanguages: systemLanguages())
    }

    // MARK: - Private

    private static func resolveLocale(_ code: String, systemLanguages: [String]) -> Locale {
        guard code == "system" else {
            return Locale(identifier: code)
        }
        guard let identifier = systemLanguages.first else {
            return Locale.autoupdatingCurrent
        }
        return Locale(identifier: identifier)
    }

    private static func systemPreferredLanguages() -> [String] {
        let value = CFPreferencesCopyValue(
            "AppleLanguages" as CFString,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        return value as? [String] ?? Locale.preferredLanguages
    }

    private static func persistOverride(_ code: String) {
        guard code != "system" else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            return
        }
        UserDefaults.standard.set([code], forKey: "AppleLanguages")
    }
}
