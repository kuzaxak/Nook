// Licensed under GPL-3.0. See LICENSE.
//
//  General.swift
//  Nook
//
//  Created by Maciek Bagiński on 07/12/2025.
//

import SwiftUI
import NookDesign
import NookSettings
import NookWeb

public struct SettingsGeneralTab: View {
    @Environment(TabsController.self) private var tabs
    @Environment(NookSettingsService.self) var nookSettings
    @State private var showingAddSite = false
    @State private var showingAddEngine = false
    @State private var kagiSessionLink = ""
    @State private var newShortcutKeyword = ""
    @State private var newShortcutTemplate = ""

    public init() {}

    /// The provider list, shared by both platforms' spellings of the row.
    @ViewBuilder
    private func searchEnginePicker(_ settings: NookSettingsService) -> some View {
        @Bindable var settings = settings
        Picker("Default search engine", selection: $settings.searchEngineId) {
            ForEach(SearchProvider.allCases) { provider in
                Text(provider.displayName).tag(provider.rawValue)
            }
            ForEach(nookSettings.customSearchEngines) { engine in
                Text(engine.name).tag(engine.id.uuidString)
            }
        }
    }

    public var body: some View {
        @Bindable var settings = nookSettings
        Form {
            #if os(macOS)
            // Quitting and Sparkle updates are both macOS-only concepts.
            Section {
                Toggle("Warn before quitting Nook", isOn: $settings.askBeforeQuit)
                Toggle("Automatically update Nook", isOn: .constant(true))
                    .disabled(true)
            }

            Section {
                Toggle("Keep videos playing in the sidebar", isOn: $settings.autoPictureInPicture)
            } footer: {
                Text("Leaving a tab with a playing video moves it into a small window above the sidebar media controls.")
            }
            #endif

            Section {
                Toggle("Open new tabs ungrouped", isOn: $settings.newTabsAtTopLevel)
                Toggle("Nest link tabs under the page that opened them", isOn: $settings.nestLinkTabsUnderOpener)
                Picker("Archive tabs not seen for", selection: $settings.archiveTabsAfterHours) {
                    ForEach(NookSettingsService.archiveTabsAfterHoursChoices, id: \.self) { hours in
                        Text(hours < 24 ? "\(hours) hours" : hours == 24 ? "1 day" : "\(hours / 24) days").tag(hours)
                    }
                }
            } header: {
                Text("Tabs")
            } footer: {
                Text("Ungrouped tabs land below the selected tab's folder instead of inside it. Tabs opened from a pinned tab, a favorite or a folder always land in Tabs. Archived tabs can be reopened with Reopen Closed Tab; pinned tabs, favorites and tabs in folders are never archived.")
            }

            Section {
                Picker("Tab Management", selection: Binding(
                    get: { nookSettings.tabManagementMode },
                    set: { nookSettings.tabManagementMode = $0 }
                )) {
                    ForEach(TabManagementMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                Picker("On Startup", selection: Binding(
                    get: { nookSettings.startupLoadMode },
                    set: { nookSettings.startupLoadMode = $0 }
                )) {
                    ForEach(StartupLoadMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                Button("Unload All Inactive Tabs") {
                    tabs.unloadAllHidden()
                }
            } header: {
                Text("Performance")
            } footer: {
                VStack(alignment: .leading, spacing: NookDesign.Spacing.xs) {
                    Label(
                        nookSettings.tabManagementMode.description,
                        systemImage: nookSettings.tabManagementMode.icon
                    )
                    Label(nookSettings.startupLoadMode.description, systemImage: "power")
                }
            }

            Section {
                #if os(macOS)
                LabeledContent("Default search engine") {
                    HStack(spacing: NookDesign.Spacing.md) {
                        searchEnginePicker(settings)
                            .labelsHidden()

                        Button {
                            showingAddEngine = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                #else
                // A picker inside a LabeledContent's trailing slot gets squeezed
                // to "G...gle" at phone width. The Form's own picker row does not,
                // so the add button takes a row of its own.
                searchEnginePicker(settings)
                Button("Add Search Engine…") { showingAddEngine = true }
                #endif

                if nookSettings.searchEngineId == SearchProvider.kagi.rawValue
                    || tabs.orderedSpaces.contains(where: { $0.searchEngineId == SearchProvider.kagi.rawValue }) {
                    if nookSettings.kagiSessionToken != nil {
                        LabeledContent("Kagi Session Link") {
                            HStack(spacing: NookDesign.Spacing.md) {
                                Text("Saved in the Keychain")
                                    .foregroundStyle(.secondary)
                                Button("Remove") { nookSettings.setKagiSession(nil) }
                            }
                        }
                    } else {
                        LabeledContent("Kagi Session Link") {
                            HStack(spacing: NookDesign.Spacing.md) {
                                SecureField("https://kagi.com/search?token=…", text: $kagiSessionLink)
                                Button("Save") {
                                    nookSettings.setKagiSession(kagiSessionLink)
                                    kagiSessionLink = ""
                                }
                                .disabled(KagiSession.token(fromPasted: kagiSessionLink) == nil)
                            }
                        }
                        Link("Find your Session Link in Kagi's account settings",
                             destination: URL(string: "https://kagi.com/settings/user_details")!)
                            .font(NookDesign.Font.caption)
                    }
                }

                if let selected = nookSettings.customSearchEngines.first(where: { $0.id.uuidString == nookSettings.searchEngineId }) {
                    LabeledContent {
                        Button("Remove") {
                            nookSettings.customSearchEngines.removeAll { $0.id == selected.id }
                            nookSettings.searchEngineId = SearchProvider.google.rawValue
                        }
                        .foregroundStyle(.red)
                        .buttonStyle(.plain)
                    } label: {
                        Text(selected.name)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Search")
            }

            Section {
                ForEach(nookSettings.siteSearchEntries) { entry in
                    LabeledContent {
                        HStack(spacing: NookDesign.Spacing.md) {
                            Text(entry.domain)
                                .foregroundStyle(.secondary)
                            Button {
                                nookSettings.siteSearchEntries.removeAll { $0.id == entry.id }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    } label: {
                        Label {
                            Text(entry.name)
                        } icon: {
                            Circle()
                                .fill(entry.color)
                                .frame(
                                    width: NookDesign.Size.statusDot,
                                    height: NookDesign.Size.statusDot
                                )
                        }
                    }
                }

                Button {
                    showingAddSite = true
                } label: {
                    Label("Add Site", systemImage: "plus")
                }

                Button("Reset to Defaults") {
                    nookSettings.siteSearchEntries = SiteSearchEntry.defaultSites
                }
            } header: {
                Text("Site Search")
            } footer: {
                Text("Type a prefix in the command palette and press Tab to search a site directly.")
            }

            Section {
                ForEach(nookSettings.urlShortcuts) { shortcut in
                    LabeledContent(shortcut.keyword) {
                        HStack(spacing: NookDesign.Spacing.md) {
                            Text(shortcut.template)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button {
                                nookSettings.urlShortcuts.removeAll { $0.id == shortcut.id }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                HStack(spacing: NookDesign.Spacing.md) {
                    TextField("Keyword", text: $newShortcutKeyword)
                        .frame(maxWidth: 90)
                    TextField("https://github.com/%@", text: $newShortcutTemplate)
                    Button("Add") {
                        nookSettings.urlShortcuts.append(URLShortcut(
                            keyword: newShortcutKeyword.trimmingCharacters(in: .whitespaces),
                            template: newShortcutTemplate.trimmingCharacters(in: .whitespaces)))
                        newShortcutKeyword = ""
                        newShortcutTemplate = ""
                    }
                    .disabled(newShortcutKeyword.trimmingCharacters(in: .whitespaces).isEmpty
                              || newShortcutKeyword.contains(" ") || !newShortcutTemplate.contains("%@"))
                }
            } header: {
                Text("URL Shortcuts")
            } footer: {
                Text("Type a keyword, a space and the rest in the command palette, such as \"gh owner/repo\". %@ in the address stands for the rest.")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingAddSite) {
            SiteSearchEntryEditor(entry: nil) { newEntry in
                nookSettings.siteSearchEntries.append(newEntry)
            }
        }
        .sheet(isPresented: $showingAddEngine) {
            CustomSearchEngineEditor { newEngine in
                nookSettings.customSearchEngines.append(newEngine)
            }
        }
    }
}

// MARK: - Custom Search Engine Editor

struct CustomSearchEngineEditor: View {
    let onSave: (CustomSearchEngine) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var urlTemplate: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: NookDesign.Spacing.xl) {
            Text("Add Custom Search Engine")
                .font(NookDesign.Font.heading)

            Form {
                Section {
                    TextField("Name (e.g. Startpage)", text: $name)
                    TextField("URL Template (use %@ for query)", text: $urlTemplate)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                Button("Save") {
                    let engine = CustomSearchEngine(
                        name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                        urlTemplate: urlTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    onSave(engine)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty || urlTemplate.isEmpty)
            }
        }
        .padding(NookDesign.Spacing.xxl)
        .frame(width: NookDesign.Size.sheetSmallWidth)
    }
}
