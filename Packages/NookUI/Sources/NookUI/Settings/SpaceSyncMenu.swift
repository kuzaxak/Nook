// Licensed under GPL-3.0. See LICENSE.
//
//  SpaceSyncMenu.swift
//  NookUI
//
//  The cloud in a space's Settings row: it shows how much of the space syncs through iCloud,
//  and its menu sets the level.
//

import NookTabsCore
import SwiftUI

struct SpaceSyncMenu: View {
    let space: SpaceRecord
    let sync: any SpaceSyncControls

    var body: some View {
        let level = sync.level(of: space.id)
        Menu {
            Picker("iCloud Sync", selection: Binding(get: { level }, set: { sync.setLevel($0, for: space.id) })) {
                ForEach(SpaceSyncLevel.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: level.symbol)
        }
        .menuStyle(.borderlessButton)
        // Under any ToggleStyle but automatic, such as the Settings window's switch style, macOS
        // draws a Picker's choices in a menu greyed out and they cannot be picked.
        .toggleStyle(.automatic)
        .fixedSize()
        .help("iCloud Sync: \(level.title)")
        .accessibilityLabel("iCloud Sync for \(space.name): \(level.title)")
    }
}
