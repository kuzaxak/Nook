// Licensed under GPL-3.0. See LICENSE.
//
//  SettingsUtils.swift
//  Nook
//
//  Created by Maciek Bagiński on 03/08/2025.
//
import Foundation
import SwiftUI

enum SettingsTabs: String, Hashable, CaseIterable {
    case general
    case appearance
    case ai
    case privacy
    case adBlocker
    case tweaks
    case airTrafficControl
    case spaces
    case profiles
    case shortcuts
    case extensions
    case developer

    var name: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .ai: return "AI"
        case .privacy: return "Privacy"
        case .adBlocker: return "Ad Blocker"
        case .tweaks: return "Tweaks"
        case .airTrafficControl: return "Air Traffic Control"
        case .spaces: return "Spaces"
        case .profiles: return "Profiles"
        case .shortcuts: return "Shortcuts"
        case .extensions: return "Extensions"
        case .developer: return "Developer"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .ai: return "sparkles"
        case .privacy: return "lock.shield"
        case .adBlocker: return "shield.lefthalf.filled"
        case .tweaks: return "wand.and.stars"
        case .airTrafficControl: return "arrow.triangle.branch"
        case .spaces: return "square.on.square"
        case .profiles: return "person.crop.circle"
        case .shortcuts: return "keyboard"
        case .extensions: return "puzzlepiece.extension"
        case .developer: return "hammer"
        }
    }

    /// Extra search terms, so a pane is findable by what it holds rather than only its name.
    var searchKeywords: [String] {
        switch self {
        case .general: return ["startup", "search engine", "tabs", "quit", "update", "archive", "ungrouped", "new tabs", "nest", "link tabs", "url shortcuts", "kagi", "session link", "site search"]
        case .appearance: return ["theme", "dark", "light", "sidebar"]
        case .ai: return ["gemini", "openrouter", "openai", "anthropic", "claude", "ollama", "mcp", "translation", "translate"]
        case .privacy: return ["cookies", "cache", "tracking", "website data", "history", "half-life", "pawl", "vault", "passwords", "passkeys", "autofill"]
        case .adBlocker: return ["ads", "filters", "blocking", "allowlist", "whitelist"]
        case .tweaks: return ["youtube", "shorts", "thumbnails", "sponsorblock", "facebook", "instagram", "reels", "download", "social media"]
        case .airTrafficControl: return ["routing", "rules", "domains"]
        case .spaces: return ["accent", "colour", "color", "rename", "icon"]
        case .profiles: return ["profile", "logins", "cookies", "search engine", "downloads", "download location", "website data"]
        case .shortcuts: return ["keyboard", "keys", "hotkeys"]
        case .extensions: return ["web extensions", "chrome", "add-ons"]
        case .developer: return ["devtools", "inspector", "console", "network", "mcp", "browser control"]
        }
    }

    func matches(_ query: String) -> Bool {
        let term = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !term.isEmpty else { return true }
        return name.lowercased().contains(term)
            || searchKeywords.contains { $0.contains(term) }
    }

    var iconColor: Color {
        switch self {
        case .general: return .gray
        case .appearance: return .pink
        case .ai: return .purple
        case .privacy: return .blue
        case .adBlocker: return .green
        case .tweaks: return .orange
        case .airTrafficControl: return .mint
        case .spaces: return .cyan
        case .profiles: return .blue
        case .shortcuts: return .indigo
        case .extensions: return .teal
        case .developer: return .gray
        }
    }

    /// Sidebar groups, separated by visual spacing. A titled group gets a section header.
    static var sidebarGroups: [(title: String?, tabs: [SettingsTabs])] {
        [
            (nil, [.general, .appearance]),
            (nil, [.ai]),
            (nil, [.privacy, .adBlocker, .airTrafficControl]),
            (nil, [.spaces, .profiles, .shortcuts, .extensions, .developer]),
            (nil, [.tweaks]),
        ]
    }
}
