// Licensed under GPL-3.0. See LICENSE.
//
//  CertificateWarningView.swift
//  Nook
//
//  "This Connection Is Not Private", as in Safari: the card over a page whose server's
//  certificate failed the check. Native buttons, so a page cannot visit itself past the card.
//

import SwiftUI
import NookDesign
import NookWeb

struct CertificateWarningView: View {
    let session: PageSession

    var body: some View {
        if let warning = session.certificateWarning {
            CertificateWarningCard(session: session, warning: warning)
                .id(warning)
        }
    }
}

private struct CertificateWarningCard: View {
    let session: PageSession
    let warning: CertificateWarning
    @State private var showsDetails = false

    var body: some View {
        StandardDialog {
            DialogHeader(
                icon: "exclamationmark.triangle",
                title: "This Connection Is Not Private",
                subtitle: "This website may be impersonating \(warning.host) to steal your personal or financial information. You should go back to the previous page."
            )
        } content: {
            if showsDetails {
                VStack(alignment: .leading, spacing: NookDesign.Spacing.md) {
                    ForEach(warning.details, id: \.self) { paragraph in
                        Text(paragraph)
                            .font(NookDesign.Font.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if warning.allowsVisit {
                        Button("Visit This Website") { session.visitDespiteCertificateWarning() }
                            .buttonStyle(.link)
                    }
                }
            }
        } footer: {
            DialogFooter(rightButtons: [
                DialogButton(text: showsDetails ? "Hide Details" : "Show Details") { showsDetails.toggle() },
                DialogButton(text: session.hasCommittedPage ? "Go Back" : "Close", variant: .primary) {
                    session.leaveBlockedPage()
                },
            ])
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
