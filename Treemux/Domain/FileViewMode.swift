import Foundation

/// Persisted per-file rendering mode for the document viewer.
enum FileViewMode: String, Codable, Equatable, CaseIterable {
    case source
    case split
    case render
}
