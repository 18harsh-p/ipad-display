// main.swift
// Entry point for a menu-bar-only app (no Dock icon). Also set "Application is agent (UIElement)"
// to YES in Info.plist so the Dock icon never flashes at launch.

import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var backend: DisplayStreamBackend?
    private var menu: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let support = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/ipad-display", isDirectory: true)
            let sunshine = try SunshineProcess(supportDirectory: support)
            let backend = DisplayStreamBackend(sunshine: sunshine)
            self.backend = backend

            let menu = MenuBarController(backend: backend)
            self.menu = menu
            menu.start()
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "iPad Display could not start"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        backend?.stop()  // removes the virtual display and stops Sunshine; safe if already stopped
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()  // kept alive on stack while app.run() executes
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
