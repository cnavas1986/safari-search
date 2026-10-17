//
//  SearchPanel.swift
//  Tab Search
//
//  The Spotlight-style panel: a borderless, non-activating floating panel
//  centred near the top of the screen. Non-activating means Safari stays the
//  active app while you type, so nothing flickers and switching tabs is instant.
//

import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor @Observable
final class SearchModel {
    static let width: CGFloat = 640
    static let cornerRadius: CGFloat = 20
    static let headerHeight: CGFloat = 56
    static let rowHeight: CGFloat = 48
    static let messageHeight: CGFloat = 44
    static let listPadding: CGFloat = 6
    static let maxVisibleRows = 8

    var query = "" { didSet { refilter() } }
    var selection = 0
    var message: String?
    /// Bumped every time the panel is shown, so the view can refocus the field.
    private(set) var showCount = 0
    private(set) var results: [TabMatch] = []
    private var tabs: [SafariTab] = []

    @ObservationIgnored var onDismiss: () -> Void = {}
    @ObservationIgnored var onLayoutChange: () -> Void = {}

    var preferredHeight: CGFloat {
        if !results.isEmpty {
            let rows = CGFloat(min(results.count, Self.maxVisibleRows))
            return Self.headerHeight + 1 + rows * Self.rowHeight + Self.listPadding * 2
        }
        if message != nil || !query.isEmpty { return Self.headerHeight + 1 + Self.messageHeight }
        return Self.headerHeight
    }

    func reset(with tabs: [SafariTab], message: String? = nil) {
        // Frontmost window first, each in tab order, with the tab you're on at
        // the bottom (like Chrome) so the top row is a different tab.
        self.tabs = tabs.filter { !($0.isCurrent && $0.inFrontWindow) } + tabs.filter { $0.isCurrent && $0.inFrontWindow }
        self.message = message
        selection = 0
        query = "" // refilters
        showCount += 1
    }

    func move(by delta: Int) {
        guard !results.isEmpty else { return }
        selection = (selection + delta + results.count) % results.count
    }

    func activateSelection() {
        guard results.indices.contains(selection) else { return }
        activate(results[selection].tab)
    }

    func activate(_ tab: SafariTab) {
        onDismiss()
        Task {
            do { try await SafariTabs.activate(tab) } catch { NSSound.beep() }
        }
    }

    func closeSelection() {
        guard results.indices.contains(selection) else { return }
        close(results[selection].tab)
    }

    func close(_ tab: SafariTab) {
        // Update locally right away. Later tabs in that window move up one.
        tabs = tabs.compactMap { other in
            guard other.windowID == tab.windowID else { return other }
            if other.index == tab.index { return nil }
            guard other.index > tab.index else { return other }
            return SafariTab(windowID: other.windowID, index: other.index - 1, title: other.title, url: other.url,
                             isCurrent: other.isCurrent, inFrontWindow: other.inFrontWindow)
        }
        refilter()
        Task {
            do { try await SafariTabs.close(tab) } catch { NSSound.beep() }
        }
    }

    private func refilter() {
        results = TabMatcher.search(tabs, query: query)
        selection = min(selection, max(results.count - 1, 0))
        onLayoutChange()
    }
}

final class SearchPanel: NSPanel {
    /// Return true to swallow the key event.
    var keyHandler: ((NSEvent) -> Bool)?
    var onResignKey: (() -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        // Show over full-screen Safari and on whichever Space is active.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyHandler?(event) == true { return }
        super.sendEvent(event)
    }

    // Clicking anywhere else dismisses it, like Spotlight.
    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

@MainActor
final class SearchPanelController {
    private let model = SearchModel()
    private let panel = SearchPanel()

    init() {
        let host = NSHostingView(rootView: SearchView(model: model))
        host.sizingOptions = [] // the controller sizes the panel
        host.autoresizingMask = [.width, .height]

        // Clip everything to the rounded shape, so no square corners show
        // around the glass and the shadow follows the rounded outline.
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = SearchModel.cornerRadius
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        container.addSubview(host)
        panel.contentView = container

        model.onDismiss = { [weak self] in self?.hide() }
        model.onLayoutChange = { [weak self] in self?.resize() }
        panel.onResignKey = { [weak self] in self?.hide() }
        panel.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        Task {
            do {
                model.reset(with: try await SafariTabs.fetch())
            } catch {
                model.reset(with: [], message: error.localizedDescription)
            }
            place()
            panel.makeKeyAndOrderFront(nil)
            // The shadow is computed from what's drawn; redo it once the
            // rounded content is on screen, or it comes out square.
            DispatchQueue.main.async { self.panel.invalidateShadow() }
        }
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// Centred horizontally, upper part of the screen, like Spotlight.
    private func place() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let area = screen.visibleFrame
        let height = model.preferredHeight
        let top = area.maxY - area.height * 0.2
        panel.setFrame(NSRect(x: area.midX - SearchModel.width / 2, y: top - height,
                              width: SearchModel.width, height: height), display: true)
    }

    /// Grows or shrinks downward, keeping the search field in place.
    private func resize() {
        guard panel.isVisible else { return }
        var frame = panel.frame
        let height = model.preferredHeight
        frame.origin.y = frame.maxY - height
        frame.size.height = height
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch Int(event.keyCode) {
        case kVK_DownArrow:
            model.move(by: 1)
        case kVK_UpArrow:
            model.move(by: -1)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            model.activateSelection()
        case kVK_Escape:
            hide()
        case kVK_Delete where modifiers == .command && model.query.isEmpty:
            model.closeSelection() // ⌘⌫ with an empty search field
        default:
            return false
        }
        return true
    }
}
