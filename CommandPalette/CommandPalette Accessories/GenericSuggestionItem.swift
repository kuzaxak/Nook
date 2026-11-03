// Licensed under GPL-3.0. See LICENSE.
//
//  GenericSuggestionItem.swift
//  Nook
//
//  Created by Maciek Bagiński on 18/08/2025.
//

import SwiftUI
import NookDesign
import NookWeb

struct GenericSuggestionItem: View {
    let icon: Image
    let text: String
    var isSelected: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                icon
                    .resizable()
                    .scaledToFit()
                    .frame(width: 14, height: 14)
                    .foregroundStyle(isSelected ? .white : .secondary)
            }
            .frame(width: 24, height: 24)
            .clipShape(NookDesign.Radius.shape(NookDesign.Radius.xs))

            Text(text)
                .font(NookDesign.Font.label)
                .foregroundStyle(isSelected ? .white : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// A command in the bar, with its shortcut on the right.
struct ActionSuggestionItem: View {
    let action: SearchManager.ActionMatch

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            SuggestionIcon(image: Image(systemName: action.icon))
            Text(action.title)
                .font(NookDesign.Font.label)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer()
            if let shortcut = action.detail {
                Text(shortcut)
                    .font(NookDesign.Font.secondary)
                    .foregroundStyle(.secondary)
            } else if action.takesChoice {
                Text("Tab to choose")
                    .font(NookDesign.Font.secondary)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
