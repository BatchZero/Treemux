//
//  TreemuxGhosttyResourcePaths.swift
//  Treemux
//

import Foundation

/// Locates Ghostty resources (shell-integration scripts, terminfo) within the app bundle.
struct TreemuxGhosttyResourcePaths: Equatable {
    var ghosttyResourcesDirectory: String?
    var terminfoDirectory: String?

    init(resourceRootURL: URL?, fileManager: FileManager = .default) {
        guard let resourceRootURL else {
            self.ghosttyResourcesDirectory = nil
            self.terminfoDirectory = nil
            return
        }

        let ghosttyURL = resourceRootURL.appendingPathComponent("ghostty", isDirectory: true)
        let terminfoURL = resourceRootURL.appendingPathComponent("terminfo", isDirectory: true)

        self.ghosttyResourcesDirectory = fileManager.fileExists(atPath: ghosttyURL.path)
            ? ghosttyURL.path
            : nil
        self.terminfoDirectory = fileManager.fileExists(atPath: terminfoURL.path)
            ? terminfoURL.path
            : nil
    }

    init(ghosttyResourcesDirectory: String?, terminfoDirectory: String?) {
        self.ghosttyResourcesDirectory = ghosttyResourcesDirectory
        self.terminfoDirectory = terminfoDirectory
    }

    static func bundleMain() -> TreemuxGhosttyResourcePaths {
        TreemuxGhosttyResourcePaths(resourceRootURL: Bundle.main.resourceURL)
    }
}
