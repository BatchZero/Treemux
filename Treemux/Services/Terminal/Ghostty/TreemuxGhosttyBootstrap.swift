//
//  TreemuxGhosttyBootstrap.swift
//  Treemux
//

import Foundation
import GhosttyKit

/// One-time initialization of the libghostty runtime.
/// Must be called before any Ghostty surface or config is created.
enum TreemuxGhosttyBootstrap {
    private static let initialized: Void = {
        TreemuxGhosttyLogFilter.installIfNeeded()
        applyProcessEnvironment()
        let result = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        guard result == GHOSTTY_SUCCESS else {
            let message = """
            libghostty initialization failed before the app launched.
            This usually means the embedded Ghostty runtime could not initialize its global state.
            """
            FileHandle.standardError.write(Data(message.utf8))
            exit(1)
        }
    }()

    /// Trigger lazy initialization. Safe to call multiple times.
    static func initialize() {
        _ = initialized
    }

    /// Returns the environment variables needed by Ghostty subprocesses.
    static func processEnvironment(
        resourcePaths: TreemuxGhosttyResourcePaths = .bundleMain()
    ) -> [String: String] {
        guard let ghosttyResourcesDirectory = resourcePaths.ghosttyResourcesDirectory else {
            return [:]
        }
        return ["GHOSTTY_RESOURCES_DIR": ghosttyResourcesDirectory]
    }

    private static func applyProcessEnvironment(
        resourcePaths: TreemuxGhosttyResourcePaths = .bundleMain()
    ) {
        for (key, value) in processEnvironment(resourcePaths: resourcePaths) {
            setenv(key, value, 1)
        }
    }
}
