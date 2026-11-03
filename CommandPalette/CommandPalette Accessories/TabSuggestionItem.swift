// Licensed under GPL-3.0. See LICENSE.
//
//  TabSuggestionItem.swift
//  Nook
//
//  Created by Maciek Bagiński on 18/08/2025.
//

import SwiftUI
import NookDesign
import NookWeb
import NookUI

struct TabSuggestionItem: View {
    let tab: SearchManager.TabMatch
    /// Held Command on the highlighted row shows the whole address instead of the short one.
    var showsFullURL: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            SuggestionIcon(image: tab.favicon)
            SuggestionLines(title: tab.title, detail: showsFullURL ? tab.url.absoluteString : PaletteText.shortURL(tab.url))
            Spacer()
            Text("Switch to Tab")
                .font(NookDesign.Font.secondary)
                .foregroundStyle(.secondary)
            Image(systemName: "arrow.right")
                .font(NookDesign.Font.label)
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(NookDesign.Surface.fill)
                .clipShape(NookDesign.Radius.shape(NookDesign.Radius.xs))
        }
        .frame(maxWidth: .infinity)
    }
}
