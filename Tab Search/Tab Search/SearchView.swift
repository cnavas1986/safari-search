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
            } else if let text = model.message ?? (model.query.isEmpty ? nil : "No results found") {
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

/// The site's /favicon.ico, or a coloured letter tile when there isn't one.
private struct Favicon: View {
    let tab: SafariTab

    var body: some View {
        AsyncImage(url: tab.faviconURL) { phase in
            if let image = phase.image {
                image.resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                letterTile
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
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
