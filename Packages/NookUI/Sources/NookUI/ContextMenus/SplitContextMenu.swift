// Licensed under GPL-3.0. See LICENSE.
//
//  SplitContextMenu.swift
//  NookUI
//
//  The menu of a split pair in the sidebar, as Arc has it: the pair's own actions, then each
//  tab's menu under Tab Options.
//

import SwiftUI
import NookWeb

public struct SplitContextMenu: View {
    @Environment(TabsController.self) private var tabs
    @Environment(BrowserWindowState.self) private var windowState: BrowserWindowState?
    @Environment(\.tabActions) private var actions

    public init() {}

    public var body: some View {
        if let windowState, let split = windowState.split {
            let ids = split.itemIDs
            Button {
                actions?.separateSplit(in: windowState)
            } label: {
                Label("Separate All Tabs", systemImage: "rectangle.split.2x1.slash")
            }
            Divider()
            Section("Tab Options") {
                ForEach(ids, id: \.self) { id in
                    if let item = tabs.item(id) {
                        Menu {
                            TabContextMenu(itemID: id, context: .split)
                        } label: {
                            Text(tabs.title(for: item))
                        }
                    }
                }
            }
            let spaces = tabs.spaces(visibleIn: windowState).filter { $0.id != windowState.spaceID }
            if !spaces.isEmpty {
                Divider()
                Menu {
                    ForEach(spaces) { space in
                        Button(space.name) {
                            for id in ids { tabs.move(id, to: .tabs(spaceID: space.id), after: nil) }
                        }
                    }
                } label: {
                    Label("Move to", systemImage: "arrow.right.square")
                }
            }
            Divider()
            Button(role: .destructive) {
                tabs.close(ids)
            } label: {
                Label("Close Split", systemImage: "xmark")
            }
        }
    }
}
