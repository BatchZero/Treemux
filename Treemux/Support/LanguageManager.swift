//
//  LanguageManager.swift
//  Treemux
//

import Combine
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
    /// Bridge for WindowContext's root-view rebuild. Delivers the new locale
    /// as payload; never replays — subscriber needs no `.dropFirst()`.
    var localePublisher: AnyPublisher<Locale, Never> { localeSubject.eraseToAnyPublisher() }

    init(languageCode: String) {
        self.locale = Self.resolveLocale(languageCode)
        Self.persistOverride(languageCode)
    }

    /// Apply a new language setting at runtime.
    /// Updates the published locale (immediate SwiftUI effect)
    /// and persists the override for next launch.
    func apply(languageCode: String) {
        locale = Self.resolveLocale(languageCode)
        Self.persistOverride(languageCode)
    }

    // MARK: - Private

    private static func resolveLocale(_ code: String) -> Locale {
        guard code != "system" else {
            return Locale.autoupdatingCurrent
        }
        return Locale(identifier: code)
    }

    private static func persistOverride(_ code: String) {
        guard code != "system" else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            return
        }
        UserDefaults.standard.set([code], forKey: "AppleLanguages")
    }
}
