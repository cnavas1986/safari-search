//
//  SearchView.swift
//  Tab Search
//

import SwiftUI

struct SearchView: View {
    @Bindable var model: SearchModel
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Search Safari tabs", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22))
                    .focused($fieldFocused)
            }
            .padding(.horizontal, 18)
            .frame(height: SearchModel.headerHeight)

            if !model.results.isEmpty {
                Divider()
                results
            } else if let text = model.emptyText {
                Divider()
                Text(text)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.horizontal, 18)
                    .frame(maxWidth: .infinity, minHeight: SearchModel.messageHeight)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .glassEffect(.regular, in: .rect(cornerRadius: SearchModel.cornerRadius))
        .onChange(of: model.showCount, initial: true) { fieldFocused = true }
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.results.enumerated()), id: \.element.tab.id) { i, match in
                        TabRow(match: match, isSelected: i == model.selection) { model.close(match.tab) }
                            .id(match.tab.id)
                            .contentShape(Rectangle())
                            .onTapGesture { model.activate(match.tab) }
                    }
                }
                .padding(SearchModel.listPadding)
            }
            .onChange(of: model.selection) { _, i in
                guard model.results.indices.contains(i) else { return }
                proxy.scrollTo(model.results[i].tab.id)
            }
        }
    }
}

private struct TabRow: View {
    let match: TabMatch
    let isSelected: Bool
    let onClose: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Favicon(tab: match.tab)
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(highlighted(match.tab.title, match.titleHits))
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                    if match.tab.isCurrent && match.tab.inFrontWindow {
                        Circle().fill(.tint).frame(width: 6, height: 6).help("Current tab")
                    }
                }
                Text(highlighted(match.tab.displayURL, match.urlHits))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if hovering || isSelected {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help("Close tab")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: SearchModel.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.accentColor.opacity(0.22) : hovering ? Color.primary.opacity(0.06) : .clear)
        )
        .onHover { hovering = $0 }
    }

    /// Bolds and tints the matched characters.
    private func highlighted(_ text: String, _ hits: Set<Int>) -> AttributedString {
        guard !hits.isEmpty else { return AttributedString(text) }
        var result = AttributedString()
        for (i, ch) in text.enumerated() {
            var piece = AttributedString(String(ch))
            if hits.contains(i) {
                piece.inlinePresentationIntent = .stronglyEmphasized
                piece.swiftUI.foregroundColor = .accentColor
            }
            result += piece
        }
        return result
    }
}

/// Favicons kept in memory for as long as the app runs, so after the first
/// open they appear instantly instead of flashing the letter tile while they
/// re-download. Sites without one are remembered too, and not retried.
@MainActor
private final class FaviconCache {
    static let shared = FaviconCache()

    private var images: [URL: NSImage] = [:]
    private var missing: Set<URL> = []
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]

    func cached(_ url: URL) -> NSImage? { images[url] }

    func load(_ url: URL) async -> NSImage? {
        if let image = images[url] { return image }
        if missing.contains(url) { return nil }
        if let task = inFlight[url] { return await task.value }

        let task = Task { () -> NSImage? in
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = NSImage(data: data), image.size.width > 1 else { return nil }
            return image
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image { images[url] = image } else { missing.insert(url) }
        return image
    }
}

/// The site's /favicon.ico, or a coloured letter tile when there isn't one.
private struct Favicon: View {
    let tab: SafariTab
    @State private var image: NSImage?

    init(tab: SafariTab) {
        self.tab = tab
        _image = State(initialValue: tab.faviconURL.flatMap { FaviconCache.shared.cached($0) })
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                letterTile
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: tab.faviconURL) {
            guard image == nil, let url = tab.faviconURL else { return }
            image = await FaviconCache.shared.load(url)
        }
    }

    private var seed: String { tab.displayURL.isEmpty ? tab.title : tab.displayURL }

    private var letterTile: some View {
        // Stable hash (unlike hashValue), so a site keeps its colour.
        let hash = seed.unicodeScalars.reduce(Int32(0)) { ($0 &* 31) &+ Int32(truncatingIfNeeded: $1.value) }
        return RoundedRectangle(cornerRadius: 4)
            .fill(Color(hue: Double(abs(Int(hash)) % 360) / 360, saturation: 0.55, brightness: 0.7))
            .overlay(
                Text(seed.prefix(1).uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            )
    }
}
