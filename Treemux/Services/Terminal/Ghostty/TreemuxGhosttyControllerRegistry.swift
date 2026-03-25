//
//  TreemuxGhosttyControllerRegistry.swift
//  Treemux
//

import Foundation

/// Maps opaque pointer tokens to controller instances for C callbacks.
@MainActor
final class TreemuxGhosttyControllerRegistry {
    static let shared = TreemuxGhosttyControllerRegistry()

    private final class WeakBox {
        weak var controller: TreemuxGhosttyController?

        init(controller: TreemuxGhosttyController) {
            self.controller = controller
        }
    }

    private var controllers: [UInt: WeakBox] = [:]

    /// Registers a controller and returns an opaque token for use as Ghostty surface userdata.
    func register(_ controller: TreemuxGhosttyController) -> UnsafeMutableRawPointer {
        let token = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
        controllers[UInt(bitPattern: token)] = WeakBox(controller: controller)
        return token
    }

    /// Looks up a controller by its pointer address.
    func controller(for address: UInt?) -> TreemuxGhosttyController? {
        guard let address else { return nil }
        return controllers[address]?.controller
    }

    /// Unregisters and deallocates the token.
    func unregister(_ token: UnsafeMutableRawPointer) {
        controllers.removeValue(forKey: UInt(bitPattern: token))
        token.deallocate()
    }
}
