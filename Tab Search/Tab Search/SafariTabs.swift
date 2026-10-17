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

    /// Compiled once. Windows come back front to back. Windows without tabs
    /// (like Settings) are skipped by the `try`.
    private static let listScript: NSAppleScript = {
        let script = NSAppleScript(source: """
            tell application "Safari"
                set out to {}
                repeat with w in (every window)
                    try
                        set end of out to {id of w, index of current tab of w, name of every tab of w, URL of every tab of w}
                    end try
                end repeat
                return out
            end tell
            """)!
        script.compileAndReturnError(nil)
        return script
    }()

    static func fetch() async throws -> [SafariTab] {
        let descriptor = try await run(listScript)
        var tabs: [SafariTab] = []
        for w in 0..<descriptor.numberOfItems {
            guard let window = descriptor.atIndex(w + 1),
                  let titles = window.atIndex(3), let urls = window.atIndex(4),
                  titles.numberOfItems > 0 else { continue }
            let windowID = Int(window.atIndex(1)?.int32Value ?? 0)
            let current = Int(window.atIndex(2)?.int32Value ?? 0)
            for t in 1...titles.numberOfItems {
                let url = urls.atIndex(t)?.stringValue.flatMap(URL.init(string:))
                let title = titles.atIndex(t)?.stringValue ?? ""
                tabs.append(SafariTab(
                    windowID: windowID,
                    index: t,
                    title: title.isEmpty ? (url?.absoluteString ?? "Untitled") : title,
                    url: url,
                    isCurrent: t == current,
                    inFrontWindow: w == 0))
            }
        }
        return tabs
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
