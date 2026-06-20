import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = appIcon()
        model.onStatusChanged = { [weak self] in
            self?.rebuildMenu()
            self?.settingsWindow?.title = L.str("window.settings.title")
        }
        setupStatusBar()
        if model.settings.autoStartServer {
            model.startServer()
        }
    }

    private func setupStatusBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "externaldrive.connected.to.line.below", accessibilityDescription: "PWebDAV")
        statusItem = item
        rebuildMenu()
    }

    private func appIcon() -> NSImage {
        if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            return image
        }

        if let url = Bundle.module.url(forResource: "PWebDAV", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }

        return NSImage(systemSymbolName: "externaldrive.connected.to.line.below", accessibilityDescription: "PWebDAV") ?? NSImage()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let status = NSMenuItem(title: model.status.menuTitle, action: nil, keyEquivalent: "")
        status.image = NSImage(systemSymbolName: model.status.menuSymbolName, accessibilityDescription: nil)
        menu.addItem(status)
        menu.addItem(NSMenuItem.separator())

        if model.status.isRunning {
            menu.addItem(NSMenuItem(title: L.str("action.stop"), action: #selector(stopServer), keyEquivalent: "s"))
        } else {
            menu.addItem(NSMenuItem(title: L.str("action.start"), action: #selector(startServer), keyEquivalent: "s"))
        }

        menu.addItem(NSMenuItem(title: L.str("action.settings"), action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: L.str("action.quit"), action: #selector(quit), keyEquivalent: "q"))

        for item in menu.items {
            item.target = self
        }
        statusItem?.menu = menu
    }

    @objc private func startServer() {
        model.startServer()
    }

    @objc private func stopServer() {
        model.stopServer()
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = L.str("window.settings.title")
            window.center()
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }

        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        model.stopServer()
        NSApp.terminate(nil)
    }
}
