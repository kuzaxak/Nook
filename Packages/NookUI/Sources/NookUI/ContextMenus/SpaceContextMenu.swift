// Licensed under GPL-3.0. See LICENSE.
//
//  SpaceContextMenu.swift
//  Nook
//
//  Created by Aether on 15/11/2025.
//

import SwiftUI
import NookTabsCore
import NookWeb

/// Shared context menu for spaces (used in SpacesList)
struct SpaceContextMenu: View {
    @Environment(TabsController.self) private var tabs
    @Environment(\.tabActions) private var actions
    let space: SpaceRecord
    let canDelete: Bool
    let onEditThemeColor: () -> Void
    let onOpenSettings: () -> Void
    let onDeleteSpace: () -> Void

    init(
        space: SpaceRecord,
        onEditThemeColor: @escaping () -> Void,
        canDelete: Bool,
        onOpenSettings: @escaping () -> Void,
        onDeleteSpace: @escaping () -> Void
    ) {
        self.space = space
        self.canDelete = canDelete
        self.onEditThemeColor = onEditThemeColor
        self.onOpenSettings = onOpenSettings
        self.onDeleteSpace = onDeleteSpace
    }

    var body: some View {
        Group {
            // Space settings
            Button {
                onOpenSettings()
            } label: {
                Label("Space Settings", systemImage: "gear")
            }

            if !space.isAgent {
                Button {
                    onEditThemeColor()
                } label: {
                    Label("Edit Theme Color…", systemImage: "paintpalette")
                }
            }

            if !space.isAgent, let sync = actions?.spaceSync, sync.status.availability.takesLevels {
                Picker(selection: Binding(get: { sync.level(of: space.id) }, set: { sync.setLevel($0, for: space.id) })) {
                    ForEach(SpaceSyncLevel.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: {
                    Label("iCloud Sync", systemImage: sync.level(of: space.id).symbol)
                }
                .pickerStyle(.menu)
            }

            if actions?.supportsSpaceFiles == true, tabs.canExportSpace(space.id) {
                Button {
                    actions?.exportSpace(space.id)
                } label: {
                    Label("Export Space…", systemImage: "square.and.arrow.up")
                }
            }

            Divider()

            // Delete space
            if canDelete {
                Button(role: .destructive) {
                    showDeleteConfirmation()
                } label: {
                    Label("Delete Space", systemImage: "trash")
                }
            }
        }
    }

    // MARK: - Helper Methods

    private func showDeleteConfirmation() {
        actions?.confirmSpaceDeletion(
            spaceName: space.name,
            tabCount: tabs.tabCount(inSpace: space.id),
            isLastSpace: !canDelete,
            onDelete: onDeleteSpace
        )
    }
}
