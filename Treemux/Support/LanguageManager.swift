//
//  LanguageManager.swift
//  Treemux
//

import Foundation

/// Manages application language override.
/// When language is "system", uses the OS locale. Otherwise, overrides
/// the app's preferred language to the specified code ("en" or "zh-Hans").
enum LanguageManager {

    /// Apply the language setting from AppSettings.
    /// Call this early in app launch before any UI is shown.
    static func apply(languageCode: String) {
        guard languageCode != "system" else {
            // Remove any override; follow system language
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            return
        }
        // Override the preferred language
        UserDefaults.standard.set([languageCode], forKey: "AppleLanguages")
    }
}
