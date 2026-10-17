//
//  SafariTabs.swift
//  Tab Search
//
//  Reads and switches Safari's tabs through AppleScript. macOS asks the user
//  once to allow Tab Search to control Safari (Privacy & Security → Automation).
//

import Foundation

enum SafariTabsError: LocalizedError {
    case notAuthorized
    case script(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Tab Search isn't allowed to control Safari. Turn it on in System Settings → Privacy & Security → Automation."
        case .script(let message):
            return message
        }
    }
}

enum SafariTabs {
    /// NSAppleScript isn't thread-safe; every script runs on this queue.
    private static let queue = DispatchQueue(label: "TabSearch.AppleScript")

    /// Four Apple events no matter how many windows (~33 ms). Fails if any
    /// window has no tabs, like Settings; `perWindowScript` handles that.
    private static let bulkScript = compiled("""
        tell application "Safari"
            return {id of every window, index of current tab of every window, name of every tab of every window, URL of every tab of every window}
        end tell
        """)

    /// Four Apple events per window, skipping windows without tabs.
    private static let perWindowScript = compiled("""
        tell application "Safari"
            set out to {}
            repeat with w in (every window)
                try
                    set end of out to {id of w, index of current tab of w, name of every tab of w, URL of every tab of w}
                end try
            end repeat
            return out
        end tell
        """)

    private static func compiled(_ source: String) -> NSAppleScript {
        let script = NSAppleScript(source: source)!
        script.compileAndReturnError(nil)
        return script
    }

    /// Windows come back front to back.
    static func fetch() async throws -> [SafariTab] {
        do {
            let result = try await run(bulkScript)
            guard let ids = result.atIndex(1), let currents = result.atIndex(2),
                  let titles = result.atIndex(3), let urls = result.atIndex(4) else { return [] }
            return (0..<ids.numberOfItems).flatMap { w in
                tabs(windowID: ids.atIndex(w + 1), current: currents.atIndex(w + 1),
                     titles: titles.atIndex(w + 1), urls: urls.atIndex(w + 1), inFrontWindow: w == 0)
            }
        } catch SafariTabsError.notAuthorized {
            throw SafariTabsError.notAuthorized
        } catch {
            let result = try await run(perWindowScript)
            return (0..<result.numberOfItems).flatMap { w in
                let window = result.atIndex(w + 1)
                return tabs(windowID: window?.atIndex(1), current: window?.atIndex(2),
                            titles: window?.atIndex(3), urls: window?.atIndex(4), inFrontWindow: w == 0)
            }
        }
    }

    /// Compiles the scripts and opens the connection to Safari ahead of the
    /// first ⌘⇧F, which otherwise takes ~140 ms instead of ~35 ms.
    static func warmUp() {
        Task { _ = try? await fetch() }
    }

    private static func tabs(windowID: NSAppleEventDescriptor?, current: NSAppleEventDescriptor?,
                             titles: NSAppleEventDescriptor?, urls: NSAppleEventDescriptor?,
                             inFrontWindow: Bool) -> [SafariTab] {
        guard let titles, titles.numberOfItems > 0 else { return [] }
        let windowID = Int(windowID?.int32Value ?? 0)
        let current = Int(current?.int32Value ?? 0)
        return (1...titles.numberOfItems).map { t in
            let url = urls?.atIndex(t)?.stringValue.flatMap(URL.init(string:))
            let title = titles.atIndex(t)?.stringValue ?? ""
            return SafariTab(
                windowID: windowID,
                index: t,
                title: title.isEmpty ? (url?.absoluteString ?? "Untitled") : title,
                url: url,
                isCurrent: t == current,
                inFrontWindow: inFrontWindow)
        }
    }

    static func activate(_ tab: SafariTab) async throws {
        _ = try await run(source: """
            tell application "Safari"
                set w to window id \(tab.windowID)
                set current tab of w to tab \(tab.index) of w
                set index of w to 1
                activate
            end tell
            """)
    }

    static func close(_ tab: SafariTab) async throws {
        _ = try await run(source: """
            tell application "Safari" to close tab \(tab.index) of window id \(tab.windowID)
            """)
    }

    private static func run(source: String) async throws -> NSAppleEventDescriptor {
        try await run(NSAppleScript(source: source)!)
    }

    private static func run(_ script: NSAppleScript) async throws -> NSAppleEventDescriptor {
        // Safe to hand across: scripts only ever run on the serial queue.
        nonisolated(unsafe) let script = script
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                var error: NSDictionary?
                let result = script.executeAndReturnError(&error)
                if let error {
                    let code = error[NSAppleScript.errorNumber] as? Int
                    let message = error[NSAppleScript.errorMessage] as? String ?? "AppleScript error \(code ?? 0)"
                    continuation.resume(throwing: code == -1743 ? SafariTabsError.notAuthorized : SafariTabsError.script(message))
                } else {
                    continuation.resume(returning: result)
                }
            }
        }
    }
}
