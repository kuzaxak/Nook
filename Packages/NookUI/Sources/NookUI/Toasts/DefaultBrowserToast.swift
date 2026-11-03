// Licensed under GPL-3.0. See LICENSE.
//
//  DefaultBrowserToast.swift
//  NookUI
//
//  Whether macOS opens web links in Nook, the request to make it, and the card that offers it.
//

#if os(macOS)
import AppKit
import NookDesign
import SwiftUI

@MainActor
public enum DefaultBrowser {
    public static var isNook: Bool {
        guard let handler = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!) else { return false }
        return Bundle(url: handler)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    /// macOS asks the person to confirm before it changes the default browser; `completion` gets
    /// whether Nook is the default afterwards.
    public static func makeNook(completion: @escaping @MainActor (Bool) -> Void) {
        let app = Bundle.main.bundleURL
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http") { _ in
            Task { @MainActor in
                // Changing the http handler usually moves https with it; only ask again if not.
                guard !isNook else { return completion(true) }
                NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "https") { _ in
                    Task { @MainActor in completion(isNook) }
                }
            }
        }
    }
}

public struct DefaultBrowserToast: View {
    let onMakeDefault: () -> Void
    let onNotNow: () -> Void

    public init(onMakeDefault: @escaping () -> Void, onNotNow: @escaping () -> Void) {
        self.onMakeDefault = onMakeDefault
        self.onNotNow = onNotNow
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: NookDesign.Spacing.md) {
            VStack(alignment: .leading, spacing: NookDesign.Spacing.xxs) {
                Text("Make Nook your default browser?")
                    .font(NookDesign.Font.secondary.weight(.semibold))
                Text("Links you open in other apps will open in Nook.")
                    .font(NookDesign.Font.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: NookDesign.Spacing.sm) {
                Spacer()
                Button("Not Now", action: onNotNow)
                Button("Make Default", action: onMakeDefault)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        }
        .padding(NookDesign.Spacing.lg)
        .frame(width: NookDesign.Size.accountPicker, alignment: .leading)
        .nookFloatingSurface(in: NookDesign.Radius.shape(NookDesign.Radius.xl))
    }
}
#endif
