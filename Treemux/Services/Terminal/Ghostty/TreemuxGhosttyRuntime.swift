//
//  TreemuxGhosttyRuntime.swift
//  Treemux
//

@preconcurrency import AppKit
import Foundation
import GhosttyKit

/// Singleton runtime that manages ghostty_config_t and ghostty_app_t.
@MainActor
final class TreemuxGhosttyRuntime: NSObject {
    static let shared = TreemuxGhosttyRuntime()

    var config: ghostty_config_t!
    var app: ghostty_app_t!

    var needsConfirmQuit: Bool {
        guard let app else { return false }
        return ghostty_app_needs_confirm_quit(app)
    }

    private override init() {
        super.init()
        TreemuxGhosttyBootstrap.initialize()

        guard let configuration = ghostty_config_new() else {
            fatalError("Unable to allocate libghostty config")
        }
        ghostty_config_load_default_files(configuration)

        // Override with Treemux terminal settings
        let terminalSettings = AppSettingsPersistence().load().terminal
        if let tempURL = writeTemporaryGhosttyConfig(for: terminalSettings) {
            ghostty_config_load_file(configuration, tempURL.path)
            try? FileManager.default.removeItem(at: tempURL)
        }

        ghostty_config_finalize(configuration)
        config = configuration

        var runtimeConfiguration = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: true,
            wakeup_cb: treemuxGhosttyWakeupCallback,
            action_cb: treemuxGhosttyActionCallback,
            read_clipboard_cb: treemuxGhosttyReadClipboardCallback,
            confirm_read_clipboard_cb: treemuxGhosttyConfirmReadClipboardCallback,
            write_clipboard_cb: treemuxGhosttyWriteClipboardCallback,
            close_surface_cb: treemuxGhosttyCloseSurfaceCallback
        )

        guard let app = ghostty_app_new(&runtimeConfiguration, configuration) else {
            fatalError("Unable to initialize libghostty runtime")
        }
        self.app = app
        ghostty_app_set_focus(app, NSApp.isActive)
        installObservers()
    }

    /// Writes Treemux terminal settings as a temporary Ghostty config file.
    /// Caller must delete the returned URL after use.
    private func writeTemporaryGhosttyConfig(for terminal: TerminalSettings) -> URL? {
        let lines = [
            "cursor-style = \(terminal.cursorStyle)",
            "font-size = \(terminal.fontSize)",
        ]
        let content = lines.joined(separator: "\n") + "\n"
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("treemux-ghostty-\(UUID().uuidString).conf")
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    func tick() {
        ghostty_app_tick(app)
    }

    // MARK: - Notification observers

    private func installObservers() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(keyboardSelectionDidChange(_:)),
            name: NSTextInputContext.keyboardSelectionDidChangeNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(applicationDidResignActive(_:)),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
    }

    @objc private func keyboardSelectionDidChange(_ notification: Notification) {
        ghostty_app_keyboard_changed(app)
    }

    @objc private func applicationDidBecomeActive(_ notification: Notification) {
        ghostty_app_set_focus(app, true)
    }

    @objc private func applicationDidResignActive(_ notification: Notification) {
        ghostty_app_set_focus(app, false)
    }

    // MARK: - Callback implementations

    nonisolated fileprivate static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
        guard let userdata else { return }
        let runtime = Unmanaged<TreemuxGhosttyRuntime>.fromOpaque(userdata).takeUnretainedValue()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                runtime.tick()
            }
        }
    }

    nonisolated fileprivate static func handleAction(
        _ app: ghostty_app_t?,
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        let appAddress = pointerAddress(app)
        return onMainSync {
            switch target.tag {
            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else {
                    return false
                }
                let userdataAddress = pointerAddress(ghostty_surface_userdata(surface))
                guard let controller = TreemuxGhosttyControllerRegistry.shared.controller(for: userdataAddress) else {
                    return false
                }
                return controller.handleGhosttyAction(action, on: surface)

            case GHOSTTY_TARGET_APP:
                return handleAppAction(pointer(from: appAddress), action: action)

            default:
                return false
            }
        }
    }

    private static func handleAppAction(_ app: ghostty_app_t?, action: ghostty_action_s) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_OPEN_URL:
            guard let urlCString = action.action.open_url.url else { return false }
            let value = String(cString: urlCString)
            let url: URL
            if let candidate = URL(string: value), candidate.scheme != nil {
                url = candidate
            } else {
                url = URL(fileURLWithPath: NSString(string: value).expandingTildeInPath)
            }
            NSWorkspace.shared.open(url)
            return true

        case GHOSTTY_ACTION_RING_BELL:
            NSSound.beep()
            return true

        case GHOSTTY_ACTION_OPEN_CONFIG:
            if let app {
                ghostty_app_open_config(app)
                return true
            }
            return false

        default:
            return false
        }
    }

    nonisolated fileprivate static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?
    ) -> Bool {
        let controllerAddress = pointerAddress(userdata)
        let stateAddress = pointerAddress(state)
        return onMainSync {
            guard let controller = controller(fromAddress: controllerAddress),
                  let pasteboard = treemuxGhosttyPasteboard(for: location),
                  let value = pasteboard.treemuxGhosttyBestString else {
                return false
            }

            controller.completeClipboardRequest(
                value,
                state: pointer(from: stateAddress),
                confirmed: false
            )
            return true
        }
    }

    nonisolated fileprivate static func confirmReadClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        string: UnsafePointer<CChar>?,
        state: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        guard let string else { return }
        let text = String(cString: string)
        let controllerAddress = pointerAddress(userdata)
        let stateAddress = pointerAddress(state)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let controller = controller(fromAddress: controllerAddress) else { return }
                controller.confirmClipboardRead(
                    text: text,
                    state: pointer(from: stateAddress),
                    request: request
                )
            }
        }
    }

    nonisolated fileprivate static func writeClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        count: Int,
        confirm: Bool
    ) {
        guard let content, count > 0 else { return }

        let items = (0..<count).compactMap { index -> TreemuxGhosttyClipboardPayload? in
            let entry = content[index]
            guard let mime = entry.mime, let data = entry.data else { return nil }
            return TreemuxGhosttyClipboardPayload(mimeType: String(cString: mime), text: String(cString: data))
        }
        guard !items.isEmpty else { return }

        if confirm {
            let controllerAddress = pointerAddress(userdata)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let controller = controller(fromAddress: controllerAddress) else { return }
                    controller.confirmClipboardWrite(items: items, location: location)
                }
            }
            return
        }

        onMainSync {
            guard let pasteboard = treemuxGhosttyPasteboard(for: location) else { return }
            writeClipboard(items, to: pasteboard)
        }
    }

    private static func writeClipboard(_ items: [TreemuxGhosttyClipboardPayload], to pasteboard: NSPasteboard) {
        treemuxGhosttyWriteClipboard(items, to: pasteboard)
    }

    nonisolated fileprivate static func closeSurface(_ userdata: UnsafeMutableRawPointer?, processAlive: Bool) {
        let controllerAddress = pointerAddress(userdata)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let controller = controller(fromAddress: controllerAddress) else { return }
                controller.handleSurfaceClose(processAlive: processAlive)
            }
        }
    }

    // MARK: - Controller lookup helpers

    private static func controller(from userdata: UnsafeMutableRawPointer?) -> TreemuxGhosttyController? {
        TreemuxGhosttyControllerRegistry.shared.controller(for: pointerAddress(userdata))
    }

    private static func controller(fromAddress address: UInt?) -> TreemuxGhosttyController? {
        controller(from: pointer(from: address))
    }

    // MARK: - Pointer address utilities

    nonisolated private static func pointerAddress<T>(_ pointer: UnsafeMutablePointer<T>?) -> UInt? {
        pointer.map { UInt(bitPattern: $0) }
    }

    nonisolated private static func pointerAddress<T>(_ pointer: UnsafePointer<T>?) -> UInt? {
        pointer.map { UInt(bitPattern: $0) }
    }

    nonisolated private static func pointerAddress(_ pointer: UnsafeMutableRawPointer?) -> UInt? {
        pointer.map { UInt(bitPattern: $0) }
    }

    nonisolated private static func pointer<T>(from address: UInt?) -> UnsafeMutablePointer<T>? {
        guard let address else { return nil }
        return UnsafeMutablePointer<T>(bitPattern: address)
    }

    nonisolated private static func pointer(from address: UInt?) -> UnsafeMutableRawPointer? {
        guard let address else { return nil }
        return UnsafeMutableRawPointer(bitPattern: address)
    }

    // MARK: - Main thread synchronization

    nonisolated private static func onMainSync<T: Sendable>(_ body: @MainActor () -> T) -> T {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                body()
            }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                body()
            }
        }
    }
}

// MARK: - C callback trampolines

nonisolated private func treemuxGhosttyWakeupCallback(_ userdata: UnsafeMutableRawPointer?) {
    TreemuxGhosttyRuntime.wakeup(userdata)
}

nonisolated private func treemuxGhosttyActionCallback(
    _ app: ghostty_app_t?,
    _ target: ghostty_target_s,
    _ action: ghostty_action_s
) -> Bool {
    TreemuxGhosttyRuntime.handleAction(app, target: target, action: action)
}

nonisolated private func treemuxGhosttyReadClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ state: UnsafeMutableRawPointer?
) -> Bool {
    TreemuxGhosttyRuntime.readClipboard(userdata, location: location, state: state)
}

nonisolated private func treemuxGhosttyConfirmReadClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ string: UnsafePointer<CChar>?,
    _ state: UnsafeMutableRawPointer?,
    _ request: ghostty_clipboard_request_e
) {
    TreemuxGhosttyRuntime.confirmReadClipboard(userdata, string: string, state: state, request: request)
}

nonisolated private func treemuxGhosttyWriteClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ content: UnsafePointer<ghostty_clipboard_content_s>?,
    _ count: Int,
    _ confirm: Bool
) {
    TreemuxGhosttyRuntime.writeClipboard(userdata, location: location, content: content, count: count, confirm: confirm)
}

nonisolated private func treemuxGhosttyCloseSurfaceCallback(_ userdata: UnsafeMutableRawPointer?, processAlive: Bool) {
    TreemuxGhosttyRuntime.closeSurface(userdata, processAlive: processAlive)
}
