// Licensed under GPL-3.0. See LICENSE.
//
//  HistorySuggestionItem.swift
//  Nook
//
//  Created by Maciek Bagiński on 18/08/2025.
//

import SwiftUI
import NookDesign
import NookWeb
import NookUI

struct HistorySuggestionItem: View {
    let entry: HistoryEntry
    /// Held Command on the highlighted row shows the whole address instead of the short one.
    var showsFullURL: Bool = false

    @State private var resolvedFavicon: SwiftUI.Image? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            SuggestionIcon(image: resolvedFavicon ?? Image(systemName: "globe"))
            SuggestionLines(title: entry.displayTitle, detail: showsFullURL ? entry.url.absoluteString : PaletteText.shortURL(entry.url))
            Spacer()
        }
        .frame(maxWidth: .infinity)
        // Rows are keyed by index, so a row is reused for the next entry as the query changes.
        .task(id: entry.url) {
            resolvedFavicon = nil
            let image = await fetchFavicon(for: entry.url)
            if !Task.isCancelled { resolvedFavicon = image.map(SwiftUI.Image.init(nsImage:)) }
        }
    }

    private func fetchFavicon(for url: URL) async -> NSImage? {
        guard url.scheme == "http" || url.scheme == "https", let cacheKey = url.host else { return nil }
        // Cache only: a row shown for one keystroke must not start a network fetch.
        return await FaviconCache.shared.cachedImage(for: cacheKey)
    }
}

/// The favicon tile at the start of a row.
struct SuggestionIcon: View {
    let image: SwiftUI.Image

    var body: some View {
        image
            .resizable()
            .scaledToFit()
            .foregroundStyle(.secondary)
            .frame(width: 14, height: 14)
            .frame(width: 24, height: 24)
            .background(NookDesign.Surface.fill)
            .clipShape(NookDesign.Radius.shape(NookDesign.Radius.xs))
    }
}

/// A row's title over its short address.
struct SuggestionLines: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(NookDesign.Font.label)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(detail)
                .font(NookDesign.Font.secondary)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
