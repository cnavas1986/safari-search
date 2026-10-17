//
//  AppDelegate.swift
//  Tab Search
//
//  Created by Carlos Navas on 16/10/26.
//
//  Runs as a menu-bar app (LSUIElement) so ⌘⇧F can open the search panel.
//  The setup window from the Safari extension template opens on first launch,
//  when the app is opened again, or from the menu.
//

import Carbon.HIToolbox
import Cocoa
import ServiceManagement

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    private static let safariBundleID = "com.apple.Safari"

    private var searchPanel: SearchPanelController!
    private var hotKey: HotKey!
    private var statusItem: NSStatusItem!
    private var setupWindow: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        searchPanel = SearchPanelController()

        hotKey = HotKey(keyCode: kVK_ANSI_F, modifiers: cmdKey | shiftKey) { [weak self] in
            MainActor.assumeIsolated { self?.searchPanel.toggle() }
        }
        // Only take ⌘⇧F while Safari is in front, so other apps keep it.
        updateHotKey(for: NSWorkspace.shared.frontmostApplication)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.updateHotKey(for: app) }
        }

        setUpStatusItem()

        if !UserDefaults.standard.bool(forKey: "hasLaunched") {
            UserDefaults.standard.set(true, forKey: "hasLaunched")
            showSetupWindow()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSetupWindow()
        return false
    }

    private func updateHotKey(for app: NSRunningApplication?) {
        // Our own app becomes active while the setup window is in front.
        hotKey.isEnabled = app?.bundleIdentifier == Self.safariBundleID
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: "Tab Search")

        let menu = NSMenu()
        let search = menu.addItem(withTitle: "Search Safari Tabs", action: #selector(searchTabs), keyEquivalent: "f")
        search.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open at Login", action: #selector(toggleOpenAtLogin), keyEquivalent: "")
        menu.addItem(withTitle: "Safari Extension Settings…", action: #selector(openSetupWindow), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Tab Search", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.delegate = self
        statusItem.menu = menu
    }

    @objc private func searchTabs() {
        searchPanel.show()
    }

    @objc private func toggleOpenAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc private func openSetupWindow() {
        showSetupWindow()
    }

    private func showSetupWindow() {
        if setupWindow == nil {
            setupWindow = NSStoryboard(name: "Main", bundle: nil)
                .instantiateController(withIdentifier: "SetupWindow") as? NSWindowController
        }
        setupWindow?.showWindow(nil)
        NSApp.activate()
    }

}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.item(withTitle: "Open at Login")?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
}
