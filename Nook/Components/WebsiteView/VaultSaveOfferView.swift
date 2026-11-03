// Licensed under GPL-3.0. See LICENSE.
//
//  VaultSaveOfferView.swift
//  Nook
//
//  The card offering to save a password typed on the page to Pawl Vault. It never holds the
//  password; AutofillManager's offer does, until the user answers or the offer expires.
//

import SwiftUI
import NookDesign
import NookUI

struct VaultSaveOfferView: View {
    let offer: AutofillManager.SaveOffer
    let answer: (Bool) -> Void

    var body: some View {
        HStack(spacing: NookDesign.Spacing.md) {
            VStack(alignment: .leading, spacing: NookDesign.Spacing.xxs) {
                Text("Save password to Pawl Vault?")
                    .font(NookDesign.Font.body)
                    .foregroundStyle(.primary)
                Text("\(offer.username) on \(offer.host)")
                    .font(NookDesign.Font.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.leading, NookDesign.Spacing.sm)
            HStack(spacing: NookDesign.Spacing.xxs) {
                Button("Not Now") { answer(false) }
                Button("Save") { answer(true) }
            }
            .buttonStyle(RectNavButtonStyle())
            .controlSize(.small)
        }
        .padding(NookDesign.Spacing.xxs)
        .nookFloatingSurface(in: NookDesign.Radius.shape(NookDesign.Radius.md))
    }
}
