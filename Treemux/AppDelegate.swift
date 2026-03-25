// Treemux/AppDelegate.swift
import Cocoa

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var treemuxApp: TreemuxApp?

    func applicationDidFinishLaunching(_ notification: Notification) {
        TreemuxGhosttyBootstrap.initialize()
        let app = TreemuxApp()
        app.launch()
        self.treemuxApp = app
    }

    func applicationWillTerminate(_ notification: Notification) {
        treemuxApp?.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
