// Licensed under GPL-3.0. See LICENSE.
//
//  Spaces.swift
//  Nook
//
//  Spaces: name, look, the profile each one uses and how much of it syncs through iCloud.
//  Profiles have their own pane.
//

import NookTabsCore
import SwiftUI
import NookDesign
import NookWeb
#if os(macOS)
import AppKit
#endif

public struct SpacesSettingsView: View {
    @Environment(TabsController.self) private var tabs
    @Environment(\.tabActions) private var actions

    @State private var showAccentPickerFor: UUID?
    @State private var showIconPickerFor: UUID?
    /// A move that would leave its profile with no space, waiting on keep, delete or cancel.
    @State private var pendingMove: (space: UUID, to: UUID?, profile: String)?
    /// A space in iCloud waiting on Remove or Cancel.
    @State private var pendingRemoval: SpaceSyncCloudSpace?
    @State private var joining = false
    @State private var joinLink = ""
    @State private var confirmingStopSharing = false
    @State private var confirmingLeave = false
    @State private var confirmingOldCopyRemoval = false

    public init() {}

    private var spaces: [SpaceRecord] { tabs.orderedSpaces.filter { !$0.isAgent } }

    /// Sync controls when levels can be set; nil on iOS, in an unsigned build and while the tabs
    /// are read-only.
    private var sync: (any SpaceSyncControls)? {
        guard let sync = actions?.spaceSync, sync.status.availability.takesLevels else { return nil }
        return sync
    }

    public var body: some View {
        Form {
            Section {
                // The Agent space keeps its look and borrows another space's data, so it has no row.
                ForEach(spaces) { space in
                    row(space)
                }
                HStack {
                    Button("New Space…", systemImage: "plus", action: showCreateDialog)
                    if actions?.supportsSpaceFiles == true {
                        Button("Import Space…", systemImage: "square.and.arrow.down") { actions?.importSpace() }
                    }
                    Spacer()
                }
            } header: {
                Text("Spaces")
            } footer: {
                Text("Each space uses one profile's logins, cookies and history. Moving a space to another profile signs it in as that profile. Set up profiles in the Profiles pane.")
                    .settingsFooter()
            }

            if let status = actions?.spaceSync?.status {
                syncSection(status)
            }
            if let sync, sync.status.availability == .available {
                cloudSection(sync)
            }
        }
        .formStyle(.grouped)
        .alert(
            "Remove \u{201C}\(pendingRemoval?.name ?? "")\u{201D} from iCloud?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })
        ) {
            Button("Remove from iCloud", role: .destructive) {
                if let space = pendingRemoval { sync?.removeFromICloud(space.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its \(pendingRemoval?.itemCount ?? 0) favorites, pinned tabs, folders and tabs are deleted from iCloud, and every Mac that syncs it deletes it. On this Mac it stays, turned Off.")
        }
        .alert("Join Shared Sync", isPresented: $joining) {
            TextField("https://www.icloud.com/share/\u{2026}", text: $joinLink)
            Button("Join") { sync?.joinSharedSync(link: joinLink) }
                .disabled(SpaceSyncShareLink.parse(joinLink) == nil)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Paste the link someone on another iCloud account shared with you. This Mac then syncs their spaces, and the spaces it syncs now move in with them.")
        }
        .alert("Stop sharing these spaces?", isPresented: $confirmingStopSharing) {
            Button("Stop Sharing", role: .destructive) { sync?.stopSharing() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The people you shared with stop syncing them. Their Macs keep every space, turned Off.")
        }
        .alert("Remove the old copy from this iCloud account?", isPresented: $confirmingOldCopyRemoval) {
            Button("Remove Old Copy", role: .destructive) { sync?.removeOldCopies() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Self.oldCopyWarning(actions?.spaceSync?.status.oldCopies))
        }
        .alert("Leave the shared sync?", isPresented: $confirmingLeave) {
            Button("Leave", role: .destructive) { sync?.leaveSharedSync() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This Mac stops syncing the shared spaces and goes back to this iCloud account. Every space stays here, turned Off.")
        }
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
            if let sync {
                SpaceSyncMenu(space: space, sync: sync)
            }
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

    // MARK: - iCloud Sync

    private func syncSection(_ status: SpaceSyncStatus) -> some View {
        Section {
            HStack {
                Text(status.availability == .available ? Self.describe(status.mode) : Self.describe(status.availability))
                Spacer()
                if status.isSyncing {
                    ProgressView().controlSize(.small)
                }
                if status.availability != .needsSignedBuild {
                    Button("Sync Now") { actions?.spaceSync?.syncNow() }
                        .disabled(status.availability != .available)
                }
            }
            if status.availability != .needsSignedBuild {
                Text("Spaces sync between Macs signed in to the same iCloud account (System Settings \u{2192} your name).")
                    .font(NookDesign.Font.caption)
                    .foregroundStyle(.secondary)
            }
            if status.availability == .available {
                LabeledContent("Account ID") {
                    Text(status.accountID ?? "Checking\u{2026}")
                        .font(NookDesign.Font.mono)
                        .textSelection(.enabled)
                }
                .help("The end of this Mac's iCloud account identifier. Macs that sync with each other show the same one.")
                LabeledContent("Last synced") {
                    if let date = status.lastSync {
                        Text(date, format: .relative(presentation: .named))
                    } else {
                        Text("Not yet")
                    }
                }
                if let sync {
                    sharingRows(status, sync)
                }
            }
            if let error = status.lastError, status.availability != .needsSignedBuild {
                LabeledContent("Last error") {
                    Text(error).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }
            }
            #if os(macOS)
            if let sync, status.availability != .needsSignedBuild {
                HStack {
                    Spacer()
                    Button("Copy Sync Report") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(sync.syncReport(), forType: .string)
                    }
                    .help("Copies what the last sync did with each record, by id, without names, addresses or titles")
                }
            }
            #endif
        } header: {
            Text("iCloud Sync")
        } footer: {
            Text(status.availability == .needsSignedBuild
                 ? "This copy of Nook is not signed for iCloud, so its spaces stay on this Mac."
                 : "Pick what each space syncs to your other Macs with the cloud beside it. Favorites & Pinned sends its favorites, pinned tabs and folders; Everything also sends its open tabs. Logins, cookies, history, site data, Boosts, private windows and the Agent space never sync. Off stops this Mac syncing a space and leaves it in iCloud; deleting a space deletes it from iCloud. To sync with a Mac on another iCloud account, share with it: it joins these spaces and its own synced spaces move in, and leaving turns them Off there without deleting any.")
                .settingsFooter()
        }
    }

    /// Who this account shares with, and sharing, joining or leaving another account's sync.
    @ViewBuilder
    private func sharingRows(_ status: SpaceSyncStatus, _ sync: any SpaceSyncControls) -> some View {
        ForEach(status.participants, id: \.self) { person in
            LabeledContent(person.name) {
                Text(Self.describe(person.status)).foregroundStyle(.secondary)
            }
        }
        HStack {
            switch status.mode {
            case .own:
                Button("Share with Another iCloud Account\u{2026}") { sync.shareWithAnotherAccount() }
                Button("Join Shared Sync\u{2026}") {
                    joinLink = ""
                    joining = true
                }
            case .sharing:
                Button("Share with Another iCloud Account\u{2026}") { sync.shareWithAnotherAccount() }
                Button("Stop Sharing\u{2026}", role: .destructive) { confirmingStopSharing = true }
            case .joined:
                Button("Leave Shared Sync\u{2026}", role: .destructive) { confirmingLeave = true }
            }
            Spacer()
        }
        if let old = status.oldCopies {
            LabeledContent("Old copy in this iCloud account") {
                Text(old.spaces == 1 ? "1 space" : "\(old.spaces) spaces").foregroundStyle(.secondary)
            }
            HStack {
                Button("Remove Old Copy from This iCloud Account\u{2026}", role: .destructive) { confirmingOldCopyRemoval = true }
                Spacer()
            }
        }
    }

    /// Names the Macs that synced the old copy, since one running a version of Nook from before
    /// shared sync deletes the spaces when their records go.
    private static func oldCopyWarning(_ old: SpaceSyncLeftBehind?) -> String {
        let spaces = old?.spaces == 1 ? "The space stays" : "The \(old?.spaces ?? 0) spaces stay"
        let macs = old.map { $0.devices.isEmpty ? "" : " It was synced there by \($0.devices.formatted(.list(type: .and)))." } ?? ""
        return "\(spaces) in the shared sync and on this Mac; only the copy in this iCloud account's own sync is deleted.\(macs) Those Macs keep them if they run this version of Nook or later; an earlier version deletes them."
    }

    private static func describe(_ mode: SpaceSyncMode) -> String {
        switch mode {
        case .own: return "Syncing with this iCloud account"
        case .sharing(0): return "Shared, no one invited yet"
        case .sharing(let people): return people == 1 ? "Shared with 1 person" : "Shared with \(people) people"
        case .joined(let owner): return owner.map { "Joined \($0)\u{2019}s sync" } ?? "Joined another iCloud account\u{2019}s sync"
        }
    }

    private static func describe(_ status: SpaceSyncParticipant.Status) -> String {
        switch status {
        case .pending: return "Invited"
        case .accepted: return "Joined"
        case .removed: return "Removed"
        case .unknown: return "Unknown"
        }
    }

    // MARK: - In iCloud

    private func cloudSection(_ sync: any SpaceSyncControls) -> some View {
        Section {
            if sync.cloudSpaces.isEmpty {
                Text("No spaces in iCloud yet")
                    .foregroundStyle(.secondary)
            }
            ForEach(sync.cloudSpaces) { space in
                cloudRow(space, sync)
            }
        } header: {
            Text("In iCloud")
        } footer: {
            Text(sync.cloudDevices.isEmpty
                 ? "Every space this iCloud account holds, from any Mac."
                 : "Changes in this iCloud account come from: \(sync.cloudDevices.formatted(.list(type: .and))).")
                .settingsFooter()
        }
    }

    private func cloudRow(_ space: SpaceSyncCloudSpace, _ sync: any SpaceSyncControls) -> some View {
        HStack(spacing: NookDesign.Spacing.md) {
            VStack(alignment: .leading, spacing: NookDesign.Spacing.xs) {
                Text(space.name.isEmpty ? "Untitled Space" : space.name)
                Text(Self.details(space))
                    .font(NookDesign.Font.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(Self.describe(space.state))
                .foregroundStyle(.secondary)
                .help(Self.describe(space.state))
            Menu {
                if space.canSyncHere {
                    ForEach([SpaceSyncLevel.pinned, .everything], id: \.self) { level in
                        Button("Sync \(level.title) Here") { sync.setLevel(level, for: space.id) }
                            .disabled(space.state == .syncing(level))
                    }
                }
                Button("Stop Syncing Here") { sync.setLevel(.off, for: space.id) }
                    .disabled(space.state == .offHere)
                Divider()
                Button("Remove from iCloud\u{2026}", role: .destructive) { pendingRemoval = space }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Actions for \(space.name) in iCloud")
        }
    }

    /// Profile, item count and the last change, with the Mac that made it.
    private static func details(_ space: SpaceSyncCloudSpace) -> String {
        var parts: [String] = []
        if !space.profile.isEmpty { parts.append(space.profile) }
        parts.append(space.itemCount == 1 ? "1 item" : "\(space.itemCount) items")
        let when = space.changedAt.formatted(.relative(presentation: .named))
        parts.append(space.device.map { "changed \(when) on \($0)" } ?? "changed \(when)")
        return parts.joined(separator: " \u{00B7} ")
    }

    private static func describe(_ state: SpaceSyncCloudSpace.State) -> String {
        switch state {
        case .syncing(let level): return "Syncing \(level.title)"
        case .offHere: return "Off on this Mac"
        case .arriving: return "Arriving"
        case .moved: return "Moved to a shared sync"
        case .error(let reason): return reason
        }
    }

    private static func describe(_ availability: SpaceSyncAvailability) -> String {
        switch availability {
        case .needsSignedBuild: return "Sync needs a signed build"
        case .readOnlyTabs: return "Sync is paused: Nook could not read its tabs"
        case .checking: return "Checking iCloud…"
        case .noAccount: return "Sign in to iCloud in System Settings to sync spaces"
        case .restricted: return "iCloud is restricted on this Mac"
        case .unavailable: return "iCloud is not available right now"
        case .available: return "Syncing with iCloud"
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
