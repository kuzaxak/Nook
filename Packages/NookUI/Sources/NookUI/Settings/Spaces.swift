// Licensed under GPL-3.0. See LICENSE.
//
//  Spaces.swift
//  Nook
//
//  Spaces: name, look and the profile each one uses. Profiles have their own pane.
//

import NookTabsCore
import SwiftUI
import NookDesign
import NookWeb

public struct SpacesSettingsView: View {
    @Environment(TabsController.self) private var tabs
    @Environment(\.tabActions) private var actions

    @State private var showAccentPickerFor: UUID?
    @State private var showIconPickerFor: UUID?
    /// A move that would leave its profile with no space, waiting on keep, delete or cancel.
    @State private var pendingMove: (space: UUID, to: UUID?, profile: String)?

    public init() {}

    private var spaces: [SpaceRecord] { tabs.orderedSpaces.filter { !$0.isAgent } }

    public var body: some View {
        Form {
            Section {
                // The Agent space keeps its look and borrows another space's data, so it has no row.
                ForEach(spaces) { space in
                    row(space)
                }
            } header: {
                Text("Spaces")
            } footer: {
                Text("Each space uses one profile's logins, cookies and history. Moving a space to another profile signs it in as that profile. Set up profiles in the Profiles pane.")
                    .settingsFooter()
            }

            Section {
                Button("New Space…", systemImage: "plus", action: showCreateDialog)
                if actions?.supportsSpaceFiles == true {
                    Button("Import Space…", systemImage: "square.and.arrow.down") { actions?.importSpace() }
                }
            }
        }
        .formStyle(.grouped)
        .alert(
            "Keep the \u{201C}\(pendingMove?.profile ?? "")\u{201D} profile?",
            isPresented: Binding(get: { pendingMove != nil }, set: { if !$0 { pendingMove = nil } })
        ) {
            Button("Move and Keep Profile") {
                if let move = pendingMove { tabs.setProfile(move.space, to: move.to, keepingLeftProfile: true) }
            }
            Button("Move and Delete Profile", role: .destructive) {
                if let move = pendingMove { tabs.setProfile(move.space, to: move.to) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("No other space uses it. Keep it in Profiles with its logins, cookies and history to use it again, or delete them.")
        }
    }

    private func profilePicker(_ space: SpaceRecord) -> some View {
        let current = tabs.profiles.first { $0.spaceIDs.contains(space.id) }
        // A nil selection is "New Profile"; every space is always in some profile.
        return Picker("Profile", selection: Binding<UUID?>(
            get: { current?.id },
            set: { move(space.id, to: $0, from: current) }
        )) {
            ForEach(tabs.profiles) { profile in
                Text(profile.name).tag(UUID?.some(profile.id))
            }
            Divider()
            Text("New Profile").tag(UUID?.none)
        }
        .labelsHidden()
        .fixedSize()
    }

    private func move(_ spaceID: UUID, to storeID: UUID?, from current: ProfileSummary?) {
        guard storeID != current?.id else { return }
        if let left = tabs.profileLeftEmpty(byMoving: spaceID, to: storeID) {
            pendingMove = (spaceID, storeID, left.name)
        } else {
            tabs.setProfile(spaceID, to: storeID)
        }
    }

    @ViewBuilder
    private func row(_ space: SpaceRecord) -> some View {
        HStack(spacing: NookDesign.Spacing.md) {
            Button {
                showAccentPickerFor = space.id
            } label: {
                Circle()
                    .fill(space.accentColor)
                    .frame(width: NookDesign.Size.iconButton, height: NookDesign.Size.iconButton)
            }
            .buttonStyle(.plain)
            .popover(isPresented: Binding(
                get: { showAccentPickerFor == space.id },
                set: { if !$0 { showAccentPickerFor = nil } }
            )) {
                SpaceAccentPicker(selectedHex: Binding(
                    get: { space.accentHex },
                    set: { tabs.updateSpace(space.id, name: nil, icon: nil, accentHex: $0) }
                ))
                .padding(NookDesign.Spacing.lg)
            }

            Button { showIconPickerFor = space.id } label: {
                SpaceIcon(space.icon, name: space.name)
                    .frame(width: NookDesign.Size.spaceTarget, height: NookDesign.Size.spaceTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Change Icon or Emoji…")
            .accessibilityLabel("Space icon for \(space.name)")
            .popover(isPresented: Binding(
                get: { showIconPickerFor == space.id },
                set: { if !$0 { showIconPickerFor = nil } }
            )) {
                SpaceIconPicker(icon: Binding(
                    get: { tabs.space(space.id)?.icon ?? space.icon },
                    set: { tabs.updateSpace(space.id, name: nil, icon: $0, accentHex: nil) }
                ), onSelect: { showIconPickerFor = nil })
            }

            TextField("Space name", text: Binding(
                get: { space.name },
                set: { tabs.updateSpace(space.id, name: $0, icon: nil, accentHex: nil) }
            ))
            .textFieldStyle(.plain)
            .labelsHidden()
            .layoutPriority(1)
            Spacer()
            profilePicker(space)
            if spaces.count > 1 || actions?.supportsSpaceFiles == true {
                Menu {
                    if actions?.supportsSpaceFiles == true {
                        Button("Export Space…", systemImage: "square.and.arrow.up") { actions?.exportSpace(space.id) }
                    }
                    if spaces.count > 1 {
                        Button("Delete Space…", systemImage: "trash", role: .destructive) {
                            showDeleteDialog(space)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    // MARK: - Dialogs

    private func showCreateDialog() {
        actions?.presentSpaceCreation { name, accentHex in
            tabs.createSpace(
                name: name.isEmpty ? "New Space" : name,
                icon: "",
                accentHex: accentHex,
                after: tabs.orderedSpaces.last?.id,
                sharingLoginsWith: tabs.windowRegistry.activeWindow?.spaceID ?? tabs.regularWindows.first?.spaceID
            )
        }
    }

    private func showDeleteDialog(_ space: SpaceRecord) {
        actions?.confirmSpaceDeletion(
            spaceName: space.name,
            tabCount: tabs.tabCount(inSpace: space.id),
            isLastSpace: spaces.count <= 1,
            onDelete: { tabs.deleteSpace(space.id) }
        )
    }
}
