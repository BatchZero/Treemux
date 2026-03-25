//
//  ShortcutRecorderButton.swift
//  Treemux
//

import AppKit
import SwiftUI

// MARK: - SwiftUI Wrapper

/// NSViewRepresentable that wraps a button for recording keyboard shortcuts.
struct ShortcutRecorderButton: NSViewRepresentable {
    @Binding var shortcut: StoredShortcut?
    let emptyTitle: String

    func makeNSView(context: Context) -> ShortcutRecorderNSButton {
        let button = ShortcutRecorderNSButton()
        button.shortcut = shortcut
        button.emptyTitle = emptyTitle
        button.onShortcutRecorded = { newShortcut in
            shortcut = newShortcut
        }
        return button
    }

    func updateNSView(_ nsView: ShortcutRecorderNSButton, context: Context) {
        nsView.shortcut = shortcut
        nsView.emptyTitle = emptyTitle
        nsView.updateTitle()
    }
}

// MARK: - AppKit Button

/// NSButton subclass that captures keyboard shortcuts when clicked.
/// Click to start recording, press any modifier+key combo to save,
/// press Escape to cancel.
final class ShortcutRecorderNSButton: NSButton {
    var shortcut: StoredShortcut?
    var emptyTitle = "Not Set"
    var onShortcutRecorded: ((StoredShortcut) -> Void)?

    private var isRecording = false
    private var eventMonitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(buttonClicked)
        updateTitle()
    }

    func updateTitle() {
        if isRecording {
            title = String(localized: "Press shortcut…")
        } else if let shortcut {
            title = shortcut.displayString
        } else {
            title = emptyTitle
        }
    }

    @objc private func buttonClicked() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        isRecording = true
        updateTitle()

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }

            // Escape cancels recording
            if event.keyCode == 53 {
                self.stopRecording()
                return nil
            }

            if let newShortcut = StoredShortcut.from(event: event) {
                self.shortcut = newShortcut
                self.onShortcutRecorded?(newShortcut)
                self.stopRecording()
                return nil
            }

            return nil
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowResigned),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
    }

    private func stopRecording() {
        isRecording = false
        updateTitle()

        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }

        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didResignKeyNotification,
            object: window
        )
    }

    @objc private func windowResigned() {
        stopRecording()
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }
}
