//
//  TabMatcher.swift
//  Tab Search
//
//  Swift port of the matcher in extension/popup.js, which mirrors Chrome's tab
//  search (chrome/browser/resources/tab_group_shared/search.ts): exact, case-
//  and accent-insensitive substring matching; every occurrence scores
//  (distance - position) / distance * field weight; results are bucketed as
//  match-at-start > match-at-word-start > other, then sorted by score. Unlike
//  Chrome, each whitespace-separated word is matched on its own.
//

import Foundation

struct SafariTab: Identifiable, Hashable {
    let windowID: Int
    /// 1-based position in its window, as AppleScript counts tabs.
    let index: Int
    let title: String
    let url: URL?
    /// The selected tab of its window.
    let isCurrent: Bool
    /// Its window is Safari's frontmost.
    let inFrontWindow: Bool

    var id: String { "\(windowID)-\(index)" }

    /// Hostname without "www." for web pages, otherwise the full URL.
    var displayURL: String {
        guard let url else { return "" }
        if let host = url.host(), url.scheme == "http" || url.scheme == "https" {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        return url.absoluteString
    }

    var faviconURL: URL? {
        guard let url, url.scheme == "http" || url.scheme == "https", let host = url.host() else { return nil }
        return URL(string: "\(url.scheme!)://\(host)/favicon.ico")
    }
}

/// Lowercased, accent-stripped text, plus for each folded character the index
/// of the original character it came from, so highlights land correctly.
struct FoldedText {
    let chars: [Character]
    let source: [Int]

    init(_ text: String) {
        var chars: [Character] = []
        var source: [Int] = []
        for (i, ch) in text.enumerated() {
            for folded in String(ch).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) {
                chars.append(folded)
                source.append(i)
            }
        }
        self.chars = chars
        self.source = source
    }
}

struct TabMatch {
    let tab: SafariTab
    var score: Double = 0
    /// 0 = start of a field, 1 = start of a word, 2 = anywhere.
    var bucket = 0
    /// Highlighted character indices in `tab.title` / `tab.displayURL`.
    var titleHits: Set<Int> = []
    var urlHits: Set<Int> = []
}

enum TabMatcher {
    private static let distance = 200.0
    private static let titleWeight = 2.0
    private static let urlWeight = 1.0

    static func terms(for query: String) -> [[Character]] {
        FoldedText(query).chars.split(whereSeparator: \.isWhitespace).map(Array.init)
    }

    /// Matches and ranks `tabs`; with no terms, returns them all in order.
    static func search(_ tabs: [SafariTab], query: String) -> [TabMatch] {
        let terms = terms(for: query)
        guard !terms.isEmpty else { return tabs.map { TabMatch(tab: $0) } }

        return tabs.enumerated()
            .compactMap { order, tab in match(tab, terms).map { (order, $0) } }
            .sorted { a, b in
                if a.1.bucket != b.1.bucket { return a.1.bucket < b.1.bucket }
                if a.1.score != b.1.score { return a.1.score > b.1.score }
                return a.0 < b.0
            }
            .map(\.1)
    }

    /// Every term must occur in the title or the hostname.
    private static func match(_ tab: SafariTab, _ terms: [[Character]]) -> TabMatch? {
        let fields: [(FoldedText, Double, WritableKeyPath<TabMatch, Set<Int>>)] = [
            (FoldedText(tab.title), titleWeight, \.titleHits),
            (FoldedText(tab.displayURL), urlWeight, \.urlHits),
        ]
        var result = TabMatch(tab: tab)

        for term in terms {
            var termBucket = 3 // no match yet
            for (text, weight, hits) in fields {
                for at in occurrences(of: term, in: text.chars) {
                    result.score += max((distance - Double(at)) / distance, 0) * weight
                    termBucket = min(termBucket, at == 0 ? 0 : isWordStart(text.chars, at) ? 1 : 2)
                    for j in at..<(at + term.count) { result[keyPath: hits].insert(text.source[j]) }
                }
            }
            if termBucket == 3 { return nil }
            // A tab ranks by its weakest word, so all words must line up to rank first.
            result.bucket = max(result.bucket, termBucket)
        }
        return result
    }

    private static func occurrences(of term: [Character], in chars: [Character]) -> [Int] {
        guard !term.isEmpty, term.count <= chars.count else { return [] }
        return (0...(chars.count - term.count)).filter { start in
            chars[start..<(start + term.count)].elementsEqual(term)
        }
    }

    private static func isWordStart(_ chars: [Character], _ at: Int) -> Bool {
        at == 0 || !(chars[at - 1].isLetter || chars[at - 1].isNumber)
    }
}
