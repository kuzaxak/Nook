// Licensed under GPL-3.0. See LICENSE.
//
//  NookCommands.swift
//  Nook
//
//  Menu bar commands for the Nook browser application
//

import AppKit
import SwiftUI
import WebKit
import NookWeb

struct NookCommands: Commands {
    let browserManager: BrowserManager
    let windowRegistry: WindowRegistry
    let shortcutManager: KeyboardShortcutManager
    let tabOrganizerManager: TabOrganizerManager
    @Environment(\.openSettings) private var openSettings
    @Environment(\.nookSettings) var nookSettings

    init(browserManager: BrowserManager, windowRegistry: WindowRegistry, shortcutManager: KeyboardShortcutManager, tabOrganizerManager: TabOrganizerManager) {
        self.browserManager = browserManager
        self.windowRegistry = windowRegistry
        self.shortcutManager = shortcutManager
        self.tabOrganizerManager = tabOrganizerManager
    }

    // MARK: - Dynamic Keyboard Shortcuts

    /// View extension to apply dynamic keyboard shortcut if enabled
    private func dynamicShortcut(_ action: ShortcutAction) -> some ViewModifier {
        DynamicShortcutModifier(
            keyEquivalent: shortcutManager.keyEquivalent(for: action),
            modifiers: shortcutManager.eventModifiers(for: action)
        )
    }

    private func spaceShortcut(_ index: Int) -> DynamicShortcutModifier {
        guard let action = ShortcutAction.goToSpaceActions[safe: index] else {
            return DynamicShortcutModifier(keyEquivalent: nil, modifiers: [])
        }
        return DynamicShortcutModifier(keyEquivalent: shortcutManager.keyEquivalent(for: action), modifiers: shortcutManager.eventModifiers(for: action))
    }

    var body: some Commands {
        Group {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .windowList) {}
            // SwiftUI's own Close (⌘W, which closes the key window) and Close All live in this group.
            CommandGroup(replacing: .saveItem) {
                Button("Close Tab") {
                    shortcutManager.closeTab(isRepeat: CloseShortcut.isHeldKey(NSApp.currentEvent))
                }
                .modifier(dynamicShortcut(.closeTab))

                Button("Close Window") {
                    shortcutManager.closeWindow()
                }
                .modifier(dynamicShortcut(.closeWindow))
            }
        }

        // The Settings scene supplies the standard Settings… item at ⌘,
        CommandGroup(after: .appSettings) {
            Button("Import from another Browser") {
                browserManager.dialogManager.showDialog(
                    BrowserImportDialog(
                        onCancel: {
                            browserManager.dialogManager.closeDialog()
                        }
                    )
                )
            }
        }

        // Replace the standard Quit menu item to route through showQuitDialog(),
        // which respects the "warn before quitting" setting
        CommandGroup(replacing: .appTermination) {
            Button("Quit Nook") {
                browserManager.showQuitDialog()
            }
            .keyboardShortcut("q", modifiers: .command)
        }

        // App Menu Section (under Nook)
        CommandGroup(after: .appInfo) {
            Divider()
            Button("Make Nook Default Browser") {
                browserManager.setAsDefaultBrowser()
            }

            Button("Check for Updates...") {
                browserManager.appDelegate?.updaterController.checkForUpdates(nil)
            }
        }
        

        // Edit Section
        CommandGroup(replacing: .undoRedo) {
            Button("Undo Close Tab") {
                if let window = windowRegistry.activeWindow { browserManager.tabs.reopenLastClosed(in: window) }
            }
            .modifier(dynamicShortcut(.undoCloseTab))

            Button("Reopen Closed Tab") {
                if let window = windowRegistry.activeWindow { browserManager.tabs.reopenLastClosed(in: window) }
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
        }

        // File Section
        CommandGroup(after: .newItem) {
            Button("New Tab") {
                windowRegistry.activeWindow?.commandPalette?.open()
            }
            .modifier(dynamicShortcut(.newTab))
            Button("New Window") {
                browserManager.createNewWindow()
            }
            .modifier(dynamicShortcut(.newWindow))
            
            Button("New Incognito Window") {
                browserManager.createIncognitoWindow()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            
            Divider()
            Button("Open Command Bar") {
                let currentURL = browserManager.frontPage?.url.absoluteString ?? ""
                windowRegistry.activeWindow?.commandPalette?.open(prefill: currentURL, navigateCurrentTab: true)
            }
            .modifier(dynamicShortcut(.focusAddressBar))
            .disabled(browserManager.frontPage == nil)

            Button("Copy Current URL") {
                browserManager.perform(.copyURL)
            }
            .modifier(dynamicShortcut(.copyCurrentURL))
            .disabled(browserManager.frontPage == nil)

            let selectedItem = windowRegistry.activeWindow?.selectedItemID
            Button(selectedItem.map(browserManager.tabs.isBookmark) == true ? "Remove Bookmark" : "Bookmark Tab") {
                if let selectedItem { browserManager.tabs.toggleBookmark(selectedItem, in: windowRegistry.activeWindow) }
            }
            .modifier(dynamicShortcut(.toggleBookmark))
            .disabled(selectedItem == nil)

            Divider()
            Button("Import Space…") {
                browserManager.importSpace()
            }

            Divider()
            Button("Print…") {
                browserManager.perform(.print)
            }
            .modifier(dynamicShortcut(.printPage))
            .disabled(browserManager.frontPage == nil)
        }

        // Sidebar commands
        CommandGroup(after: .sidebar) {
            Button("Toggle Sidebar") {
                browserManager.toggleSidebar()
            }
            .modifier(dynamicShortcut(.toggleSidebar))

            Button("Toggle AI Assistant") {
                browserManager.toggleAISidebar()
            }
            .modifier(dynamicShortcut(.toggleAIAssistant))
            .disabled(!nookSettings.showAIAssistant)

            Button("Toggle Picture in Picture") {
                browserManager.perform(.pictureInPicture)
            }
            .modifier(dynamicShortcut(.togglePictureInPicture))
            .disabled(
                browserManager.frontPage == nil
                    || !(browserManager.frontPage.map { $0.hasVideoContent || $0.hasPiPActive } ?? false)
            )

            if tabOrganizerManager.isAvailable {
                Divider()

                Button("Organize Tabs") {
                    if let spaceID = windowRegistry.activeWindow?.spaceID {
                        Task {
                            await tabOrganizerManager.organizeTabs(in: spaceID, using: browserManager.tabs)
                        }
                    }
                }
                .modifier(dynamicShortcut(.organizeTabs))
                .disabled(
                    tabOrganizerManager.isOrganizing
                        || windowRegistry.activeWindow?.spaceID == nil
                )
            }
        }

        // View commands
        CommandGroup(after: .windowSize) {

            Button("Find in Page") {
                browserManager.perform(.find)
            }
            .modifier(dynamicShortcut(.findInPage))
            .disabled(browserManager.frontPage == nil)

            Button("Reload Page") {
                browserManager.perform(.reload)
            }
            .modifier(dynamicShortcut(.refresh))
            .disabled(browserManager.frontPage == nil)

            Button("Reload with Standard Fingerprinting Protection") {
                browserManager.perform(.reloadWithStandardProtection)
            }
            .disabled(browserManager.frontPage?.usesEnhancedFingerprintingProtection != true)

            Button(browserManager.frontPage?.isTranslated == true ? "Show Original" : "Translate Page") {
                browserManager.perform(.translate)
            }
            .disabled(browserManager.frontPage?.canTranslate != true)

            Divider()

            Button("Zoom In") {
                browserManager.perform(.zoomIn)
            }
            .modifier(dynamicShortcut(.zoomIn))
            .disabled(browserManager.frontPage == nil)

            Button("Zoom Out") {
                browserManager.perform(.zoomOut)
            }
            .modifier(dynamicShortcut(.zoomOut))
            .disabled(browserManager.frontPage == nil)

            Button("Actual Size") {
                browserManager.perform(.actualSize)
            }
            .modifier(dynamicShortcut(.actualSize))
            .disabled(browserManager.frontPage == nil)

            Divider()

            Button("Hard Reload (Ignore Cache)") {
                browserManager.perform(.hardReload)
            }
            .modifier(dynamicShortcut(.hardReload))
            .disabled(browserManager.frontPage == nil)

            Divider()

            Button("Web Inspector") {
                browserManager.perform(.webInspector)
            }
            .modifier(dynamicShortcut(.openDevTools))
            .disabled(browserManager.frontPage == nil)

            Button("Developer Mode for This Site") {
                browserManager.perform(.developerMode)
            }
            .modifier(dynamicShortcut(.toggleDeveloperMode))
            .disabled(browserManager.frontPage?.url.host == nil)

            if nookSettings.developerModeEnabled {
                Button("Developer Panel") {
                    browserManager.toggleDevPanel(.console)
                }
                .modifier(dynamicShortcut(.openDevPanel))

                Button("Network Panel") {
                    browserManager.toggleDevPanel(.network)
                }
                .modifier(dynamicShortcut(.openNetworkPanel))

                Button("Performance Panel") {
                    browserManager.toggleDevPanel(.perf)
                }
                .modifier(dynamicShortcut(.openPerformancePanel))

                Button("Pick Element") {
                    browserManager.perform(.pickElement)
                }
                .modifier(dynamicShortcut(.pickElement))
                .disabled(browserManager.frontPage == nil)
            }

            Button("Copy Screenshot") {
                browserManager.perform(.copyScreenshot)
            }
            .modifier(dynamicShortcut(.copyScreenshot))
            .disabled(browserManager.frontPage == nil)

            Button("Capture in Portrait Mode") {
                shortcutManager.perform(.capturePortrait)
            }
            .modifier(dynamicShortcut(.capturePortrait))
            .disabled(browserManager.frontPage == nil)

            Divider()

            Button(browserManager.frontPage?.isAudioMuted == true ? "Unmute Audio" : "Mute Audio") {
                browserManager.perform(.mute)
            }
            .modifier(dynamicShortcut(.muteUnmuteAudio))
            .disabled(
                browserManager.frontPage == nil
                    || browserManager.frontPage?.hasAudioContent != true)
        }

        Group {
            CommandMenu("Spaces") {
                Button("Next Space") {
                    if let window = windowRegistry.activeWindow { browserManager.tabs.selectNextSpace(in: window) }
                }
                .modifier(dynamicShortcut(.nextSpace))

                Button("Previous Space") {
                    if let window = windowRegistry.activeWindow { browserManager.tabs.selectPreviousSpace(in: window) }
                }
                .modifier(dynamicShortcut(.previousSpace))

                if let window = windowRegistry.activeWindow {
                    let spaces = browserManager.tabs.userSpaces(for: window)
                    if !spaces.isEmpty { Divider() }
                    ForEach(Array(spaces.enumerated()), id: \.element.id) { index, space in
                        Button(space.name) {
                            browserManager.tabs.selectSpace(at: index, in: window)
                        }
                        .modifier(spaceShortcut(index))
                    }
                }
            }

            CommandMenu("Privacy") {
                Menu("Clear Cookies") {
                    Button("Clear Cookies for Current Site") {
                        browserManager.perform(.clearSiteCookies)
                    }
                    .disabled(browserManager.frontPage?.url.host == nil)

                    Button("Clear Expired Cookies") {
                        browserManager.clearExpiredCookies()
                    }

                    Divider()

                    Button("Clear All Cookies") {
                        browserManager.clearAllCookies()
                    }

                    Divider()

                    Button("Clear Third-Party Cookies") {
                        browserManager.clearThirdPartyCookies()
                    }

                    Button("Clear High-Risk Cookies") {
                        browserManager.clearHighRiskCookies()
                    }
                }

                Menu("Clear Cache") {
                    Button("Clear Cache for Current Site") {
                        browserManager.perform(.clearSiteCache)
                    }
                    .disabled(browserManager.frontPage?.url.host == nil)

                    Button("Clear Stale Cache") {
                        browserManager.clearStaleCache()
                    }

                    Button("Clear Disk Cache") {
                        browserManager.clearDiskCache()
                    }

                    Button("Clear Memory Cache") {
                        browserManager.clearMemoryCache()
                    }

                    Divider()

                    Button("Clear All Cache") {
                        browserManager.clearAllCache()
                    }

                    Divider()

                    Button("Clear Personal Data Cache") {
                        browserManager.clearPersonalDataCache()
                    }

                    Button("Clear Favicon Cache") {
                        browserManager.clearFaviconCache()
                    }
                }

                Divider()

                Button("Privacy Cleanup") {
                    browserManager.performPrivacyCleanup()
                }

                Button("Clear Browsing History") {
                    browserManager.historyManager.clearHistory()
                }

                Button("Clear All Website Data") {
                    Task {
                        // Tabs use one store per profile; Peek and the base config have used the default.
                        let tabs = browserManager.tabs
                        let dataStores: [WKWebsiteDataStore] = tabs.profiles.compactMap { tabs.profile(forStore: $0.id)?.dataStore }
                            + [WKWebsiteDataStore.default()]
                        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
                        for dataStore in dataStores {
                            await dataStore.removeData(ofTypes: dataTypes, modifiedSince: Date.distantPast)
                        }
                        await tabs.translationCaches.eraseAll()
                    }
                }
            }

            CommandMenu("Extensions") {
                Button("Toggle Extension Library") {
                    browserManager.toggleExtensionLibrary()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])

                Divider()

                Button("Install Extension...") {
                    browserManager.showExtensionInstallDialog()
                }
                .modifier(dynamicShortcut(.installExtension))

                Button("Manage Extensions...") {
                    SettingsNavigation.shared.currentSettingsTab = .extensions
                    openSettings()
                }

                Divider()

                Button("Chrome Web Store") {
                    browserManager.frontPage?.load(URL(string: "https://chromewebstore.google.com")!)
                }

                #if DEBUG
                Divider()
                Button("Open Popup Console") {
                    browserManager.extensionManager?.showPopupConsole()
                }
                #endif
            }

            CommandMenu("Appearance") {
                Button("Space Settings...") {
                    browserManager.showSpaceSettings()
                }
                .modifier(dynamicShortcut(.customizeSpaceGradient))
                .disabled(windowRegistry.activeWindow?.spaceID == nil)

                Button("Boost This Site...") {
                    browserManager.perform(.boost)
                }
                .disabled(browserManager.frontPage == nil)
            }
        }
    }
}

// MARK: - Dynamic Shortcut Modifier

/// View modifier that conditionally applies a keyboard shortcut based on user preferences
struct DynamicShortcutModifier: ViewModifier {
    let keyEquivalent: KeyEquivalent?
    let modifiers: EventModifiers

    func body(content: Content) -> some View {
        if let keyEquivalent = keyEquivalent {
            content.keyboardShortcut(keyEquivalent, modifiers: modifiers)
        } else {
            content
        }
    }
}

extension KeyboardShortcutManager {
    func keyEquivalent(for action: ShortcutAction) -> KeyEquivalent? {
        guard let shortcut = self.shortcut(for: action),
              shortcut.isEnabled else { return nil }
        switch shortcut.keyCombination.key.lowercased() {
        case "return", "enter": return .return
        case "escape", "esc": return .escape
        case "delete", "backspace": return .delete
        case "tab": return .tab
        case "space": return .space
        case "up", "uparrow": return .upArrow
        case "down", "downarrow": return .downArrow
        case "left", "leftarrow": return .leftArrow
        case "right", "rightarrow": return .rightArrow
        case "home": return .home
        case "end": return .end
        case "pageup": return .pageUp
        case "pagedown": return .pageDown
        case "clear": return .clear
        default:
            if shortcut.keyCombination.key.count == 1,
               let char = shortcut.keyCombination.key.first {
                return KeyEquivalent(char)
            }
            return nil
        }
    }

    func eventModifiers(for action: ShortcutAction) -> EventModifiers {
        guard let shortcut = self.shortcut(for: action),
              shortcut.isEnabled else { return [] }
        var modifiers: EventModifiers = []
        if shortcut.keyCombination.modifiers.contains(.command) { modifiers.insert(.command) }
        if shortcut.keyCombination.modifiers.contains(.shift) { modifiers.insert(.shift) }
        if shortcut.keyCombination.modifiers.contains(.option) { modifiers.insert(.option) }
        if shortcut.keyCombination.modifiers.contains(.control) { modifiers.insert(.control) }
        return modifiers
    }

    /// The person's shortcut for `action`, for a menu item to show; nil when it is off.
    func swiftUIShortcut(for action: ShortcutAction) -> SwiftUI.KeyboardShortcut? {
        keyEquivalent(for: action).map { SwiftUI.KeyboardShortcut($0, modifiers: eventModifiers(for: action)) }
    }
}
