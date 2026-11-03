// Licensed under GPL-3.0. See LICENSE.
//
//  CommandPaletteView.swift
//  Nook
//
//  Created by Maciek Bagiński on 28/07/2025.
//

import AppKit
import SwiftUI
import Garnish
import NookDesign
import NookSettings
import NookWeb
import NookUI

struct CommandPaletteView: View {
    @EnvironmentObject var browserManager: BrowserManager
    @Environment(BrowserWindowState.self) private var windowState
    @Environment(CommandPalette.self) private var commandPalette
    @EnvironmentObject var gradientColorManager: GradientColorManager
    @State private var searchManager = SearchManager()
    @Environment(\.nookSettings) var nookSettings

    @FocusState private var isSearchFocused: Bool
    @State private var text: String = ""
    @State private var selectedSuggestionIndex: Int = -1
    @State private var hoveredSuggestionIndex: Int? = nil
    @State private var activeSiteSearch: SiteSearchEntry? = nil
    /// Held Command shows the highlighted row's full address; Return then opens it in the background.
    @State private var commandHeld = false
    /// Set by a deletion, so backspacing out of a completion does not bring it straight back.
    @State private var completionSuppressed: Bool = false

    private var siteSearchMatch: SiteSearchEntry? {
        guard activeSiteSearch == nil else { return nil }
        return SiteSearchEntry.match(for: text, in: nookSettings.siteSearchEntries)
    }

    /// True while an input method is composing, i.e. the field editor holds marked text.
    ///
    /// SwiftUI delivers `onKeyPress` ahead of the text input context, so without this the
    /// palette eats the keys a CJK input method needs: Return commits a candidate rather
    /// than submitting, and the arrow keys pick candidates rather than moving through
    /// suggestions. Handlers return `.ignored` while this is true so the IME gets them.
    private var isComposing: Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() ?? false
    }

    /// The Return row first, then what the search found. Index -1 means the Return row.
    private var visibleSuggestions: [SearchManager.SearchSuggestion] {
        var found = searchManager.suggestions
        if activeSiteSearch != nil {
            found = found.filter {
                if case .search = $0.type { return true }
                return false
            }
        }
        guard let primary = primarySuggestion else { return found }
        let rest = found.filter { row in
            switch row.type {
            case .tab, .history: return true
            case .url, .search: return row.text.caseInsensitiveCompare(primary.text) != .orderedSame
            }
        }
        return [primary] + rest.prefix(4)
    }

    /// What Return does with what was typed: the completed address, the address, or a search.
    private var primarySuggestion: SearchManager.SearchSuggestion? {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return nil }
        if let completion { return SearchManager.SearchSuggestion(text: completion, type: .url) }
        return SearchManager.SearchSuggestion(text: typed, type: activeSiteSearch == nil && isLikelyURL(typed) ? .url : .search)
    }

    /// The row Return acts on: the highlighted one, else the Return row.
    private var targetSuggestion: SearchManager.SearchSuggestion? {
        if selectedSuggestionIndex >= 0, selectedSuggestionIndex < visibleSuggestions.count {
            return visibleSuggestions[selectedSuggestionIndex]
        }
        return primarySuggestion
    }

    private var wordStops: Set<Character> {
        let stops = Set(nookSettings.paletteWordStops)
        return stops.isEmpty ? PaletteText.defaultStops : stops
    }

    let commandPaletteWidth: CGFloat = 765
    let commandPaletteHorizontalPadding: CGFloat = 10
    
    /// Active window width
    private var currentWindowWidth: CGFloat {
        return NSApplication.shared.keyWindow?.frame.width ?? 0
    }
    
    /// Check if the command palette fits in the window
    private var isWindowTooNarrow: Bool {
        let requiredWidth = commandPaletteWidth + (commandPaletteHorizontalPadding * 2)
        return currentWindowWidth <= requiredWidth
    }
    
    /// Caclulate the correct command palette width
    private var effectiveCommandPaletteWidth: CGFloat {
        if isWindowTooNarrow {
            return max(200, currentWindowWidth - (commandPaletteHorizontalPadding * 2))
        } else {
            return commandPaletteWidth
        }
    }

    var body: some View {
        let isVisible = commandPalette.isVisible
        let textFieldColor: Color = text.isEmpty ? .secondary : .primary

        return ZStack {
            Color.clear
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .backgroundDraggable(onClick: {
                    commandPalette.close()
                })

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    VStack {
                        VStack(alignment: .center,spacing: 6) {
                            HStack(spacing: 15) {
                                Image(systemName: leadingIconName)
                                .id(leadingIconName)
                                .transition(.blur(intensity: 2, scale: 0.6).animation(NookDesign.Motion.standard))
                                .font(NookDesign.Font.bodyRegular)
                                .foregroundStyle(Color.primary)
                                .frame(width: 15)

                                if let site = activeSiteSearch {
                                    Text(site.name)
                                        .font(NookDesign.Font.label)
                                        .foregroundStyle(Garnish.contrastingShade(of: site.color, targetRatio: 4.5, blendStyle: .strong) ?? .white)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(site.color)
                                        .clipShape(Capsule())
                                        .transition(
                                            .blur(intensity: 8, scale: 0.6)
                                            .animation(NookDesign.Motion.spring)
                                        )
                                }

                                ZStack(alignment: .trailing) {
                                    TextField(
                                        activeSiteSearch != nil
                                            ? "Search \(activeSiteSearch!.name)..."
                                            : "Search or enter URL...",
                                        text: $text
                                    )
                                    .textFieldStyle(.plain)
                                    .font(NookDesign.Font.heading)
                                    .foregroundColor(textFieldColor)
                                    .tint(gradientColorManager.accentColor)
                                    .overlay(alignment: .leading) {
                                        if let suffix = ghostSuffix {
                                            (Text(text).foregroundColor(.clear) + Text(suffix).foregroundColor(.secondary))
                                                .font(NookDesign.Font.heading)
                                                .lineLimit(1)
                                                .allowsHitTesting(false)
                                        }
                                    }
                                    .focused($isSearchFocused)
                                    .onKeyPress(phases: .down) { press in handleKey(press) }
                                    .onChange(of: text) { oldValue, newValue in
                                        completionSuppressed = newValue.count < oldValue.count
                                        searchManager.searchSuggestions(for: newValue)
                                        selectedSuggestionIndex = -1
                                    }

                                    if activeSiteSearch == nil, let match = siteSearchMatch {
                                        HStack(spacing: 6) {
                                            Text("Search \(match.name)")
                                                .font(NookDesign.Font.body)
                                                .foregroundStyle(Color.secondary)

                                            Text("Tab")
                                                .font(NookDesign.Font.caption)
                                                .foregroundStyle(Color.secondary)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(
                                                    NookDesign.Radius.shape(NookDesign.Radius.xs)
                                                        .fill(NookDesign.Surface.fill)
                                                )
                                                .overlay(
                                                    NookDesign.Radius.shape(NookDesign.Radius.xs)
                                                        .stroke(NookDesign.Surface.hairline, lineWidth: 0.5)
                                                )
                                        }
                                        .allowsHitTesting(false)
                                        .transition(
                                            .blur(intensity: 4, scale: 0.92)
                                            .animation(NookDesign.Motion.standard)
                                        )
                                    }
                                }
                            }
                            .animation(NookDesign.Motion.spring, value: activeSiteSearch != nil)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 8)

                            if !visibleSuggestions.isEmpty {
                                Capsule()
                                    .fill(NookDesign.Surface.hairline)
                                    .frame(height: 0.5)
                                    .frame(maxWidth: .infinity)
                            }

                            if !visibleSuggestions.isEmpty {
                                CommandPaletteSuggestionsListView(
                                    suggestions: visibleSuggestions,
                                    selectedIndex: max(selectedSuggestionIndex, 0),
                                    revealsFullURL: commandHeld,
                                    hoveredIndex: $hoveredSuggestionIndex,
                                    onSelect: { suggestion in
                                        selectSuggestion(suggestion)
                                    }
                                )
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity)
                        .frame(width: effectiveCommandPaletteWidth)
                        .nookFloatingSurface(in: NookDesign.Radius.shape(NookDesign.Radius.xxl))
                        .animation(
                            NookDesign.Motion.quick,
                            value: searchManager.suggestions.count
                        )
                        Spacer()
                    }
                    .frame(
                        width: effectiveCommandPaletteWidth,
                        height: 328
                    )

                    Spacer()
                }
                Spacer()
            }

        }
        .allowsHitTesting(isVisible)
        .opacity(isVisible ? 1.0 : 0.0)
        .onModifierKeysChanged(mask: .command) { _, keys in commandHeld = keys.contains(.command) }
        .onChange(of: commandPalette.isVisible) { _, newVisible in
            if newVisible {
                searchManager.setTabs(browserManager.tabs, window: windowState)
                searchManager.setHistoryManager(browserManager.historyManager)
                searchManager.updateSpaceContext()

                text = commandPalette.prefilledText

                DispatchQueue.main.async {
                    isSearchFocused = true
                    DispatchQueue.main.async {
                        NSApplication.shared.sendAction(
                            #selector(NSText.selectAll(_:)),
                            to: nil,
                            from: nil
                        )
                    }
                }
            } else {
                isSearchFocused = false
                searchManager.clearSuggestions()
                text = ""
                activeSiteSearch = nil
                selectedSuggestionIndex = -1
            }
        }
        .onChange(of: windowState.spaceID) { _, _ in
            if commandPalette.isVisible {
                searchManager.updateSpaceContext()
                searchManager.clearSuggestions()
            }
        }
        .onChange(of: searchManager.suggestions.count) { _, _ in
            let count = visibleSuggestions.count
            if count == 0 {
                selectedSuggestionIndex = -1
            } else if selectedSuggestionIndex >= count {
                selectedSuggestionIndex = count - 1
            }
        }
        .animation(NookDesign.Motion.quick, value: selectedSuggestionIndex)
        .onChange(of: commandPalette.prefilledText) { _, newValue in
            if isVisible {
                text = newValue
                DispatchQueue.main.async {
                    isSearchFocused = true
                }
            }
        }
    }

    // MARK: - Suggestions List Subview
    private struct CommandPaletteSuggestionsListView: View {
        let suggestions: [SearchManager.SearchSuggestion]
        let selectedIndex: Int
        let revealsFullURL: Bool
        @Binding var hoveredIndex: Int?
        let onSelect: (SearchManager.SearchSuggestion) -> Void

        var body: some View {
            LazyVStack(spacing: 5) {
                ForEach(suggestions.indices, id: \.self) { index in
                    let suggestion = suggestions[index]
                    let isHovered = hoveredIndex == index
                    // Rows keep the text roles on a neutral fill, so the chosen row reads on any accent.
                    row(for: suggestion, showsFullURL: revealsFullURL && selectedIndex == index)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            selectedIndex == index
                                ? NookDesign.Surface.fillPressed
                                : isHovered
                                    ? NookDesign.Surface.fill
                                    : .clear
                        )
                        .clipShape(
                            NookDesign.Radius.shape(NookDesign.Radius.sm)
                        )
                        .font(NookDesign.Font.label)
                        .foregroundStyle(.primary)
                        .contentShape(NookDesign.Radius.shape(NookDesign.Radius.sm))
                        .onHoverTracking { hovering in
                            withAnimation(NookDesign.Motion.quick) {
                                if hovering {
                                    hoveredIndex = index
                                } else {
                                    hoveredIndex = nil
                                }
                            }
                        }
                        .onTapGesture { onSelect(suggestion) }
                }
            }
        }

        @ViewBuilder
        private func row(
            for suggestion: SearchManager.SearchSuggestion,
            showsFullURL: Bool
        ) -> some View {
            switch suggestion.type {
            case .tab(let tab):
                TabSuggestionItem(tab: tab, showsFullURL: showsFullURL)
            case .history(let entry):
                HistorySuggestionItem(entry: entry, showsFullURL: showsFullURL)
            case .url:
                GenericSuggestionItem(
                    icon: Image(systemName: "link"),
                    text: suggestion.text,
                    isSelected: false
                )
            case .search:
                GenericSuggestionItem(
                    icon: Image(systemName: "magnifyingglass"),
                    text: suggestion.text,
                    isSelected: false
                )
            }
        }
    }

    private func handleReturn() {
        if let site = activeSiteSearch {
            let query: String
            if selectedSuggestionIndex >= 0 && selectedSuggestionIndex < visibleSuggestions.count {
                query = visibleSuggestions[selectedSuggestionIndex].text
            } else {
                query = text
            }
            guard !query.isEmpty else { return }
            let navigateURL: String
            if let url = site.searchURL(for: query) {
                navigateURL = url.absoluteString
            } else {
                // Fallback: search on the site's domain directly
                navigateURL = "https://\(site.domain)/search?q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)"
            }
            if let url = URL(string: navigateURL) {
                open(url)
            }
            text = ""
            activeSiteSearch = nil
            selectedSuggestionIndex = -1
            commandPalette.close()
            return
        }

        if selectedSuggestionIndex >= 0
            && selectedSuggestionIndex < visibleSuggestions.count
        {
            let suggestion = visibleSuggestions[selectedSuggestionIndex]
            selectSuggestion(suggestion)
        } else if let primary = primarySuggestion {
            selectSuggestion(primary)
        }
    }

    private func selectSuggestion(_ suggestion: SearchManager.SearchSuggestion)
    {
        switch suggestion.type {
        case .tab(let match):
            browserManager.tabs.select(match.itemID, in: windowState)
        case .history(let historyEntry):
            browserManager.historyManager.recordPick(prefix: text, url: historyEntry.url)
            open(historyEntry.url)
        case .url, .search:
            // A page another window holds is not navigated from here; the text opens a new tab.
            if commandPalette.shouldNavigateCurrentTab, let session = browserManager.tabs.controllableSession(in: windowState) {
                session.typedVisitPending = true
                session.navigate(to: suggestion.text)
            } else {
                // Normalize the URL/search query first, then create the tab with
                // the correct URL so the webview loads it directly without a race.
                let template = browserManager.nookSettings?.resolvedSearchEngineTemplate ?? SearchProvider.google.queryTemplate
                let resolved = normalizeURL(suggestion.text, queryTemplate: template)
                if let url = URL(string: resolved) {
                    let id = browserManager.tabs.open(url: url, in: windowState, placement: .newTab)
                    id.flatMap(browserManager.tabs.session(for:))?.typedVisitPending = true
                }
            }
        }

        text = ""
        activeSiteSearch = nil
        selectedSuggestionIndex = -1
        commandPalette.close()
    }

    /// Loads `url` in the selected page when the palette was opened to navigate it, else in a new tab.
    private func open(_ url: URL) {
        let navigateCurrent = commandPalette.shouldNavigateCurrentTab && windowState.selectedItemID != nil
        let id = browserManager.tabs.open(url: url, in: windowState, placement: navigateCurrent ? .replaceCurrent : .newTab)
        id.flatMap(browserManager.tabs.session(for:))?.typedVisitPending = true
    }

    // MARK: - Keys

    /// Every key the field sees, ahead of the text view. While an input method composes, all go
    /// to it. Keys left `.ignored` get the text view's own behaviour.
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        if isComposing { return .ignored }
        let modifiers = press.modifiers
        if press.key == .delete || press.characters == "\u{7F}" {
            if modifiers.contains(.shift), removeSelectedHistoryRow() { return .handled }
            if modifiers.contains(.option) {
                deleteWordBack()
                return .handled
            }
            if activeSiteSearch != nil && text.isEmpty {
                withAnimation(NookDesign.Motion.standard) { activeSiteSearch = nil }
                return .handled
            }
            return .ignored
        }
        switch press.key {
        case .return:
            if modifiers.contains(.command) || commandHeld { openTargetInBackground() }
            else if modifiers.contains(.shift) { openTargetInSplit() }
            else { handleReturn() }
            return .handled
        case .tab:
            return handleTab()
        case .upArrow:
            navigateSuggestions(direction: -1)
            return .handled
        case .downArrow:
            navigateSuggestions(direction: 1)
            return .handled
        case .rightArrow:
            if modifiers.contains(.option) { return acceptGhostWord() ? .handled : .ignored }
            return modifiers.isEmpty && caretIsAtEnd && acceptGhost() ? .handled : .ignored
        case .leftArrow where modifiers.contains(.option):
            moveCaretBackOneWord()
            return .handled
        case .escape:
            if activeSiteSearch != nil {
                withAnimation(NookDesign.Motion.standard) { activeSiteSearch = nil }
            } else {
                commandPalette.close()
            }
            return .handled
        default:
            break
        }
        if modifiers == .control, let letter = Self.letter(of: press) {
            switch letter {
            case "w": deleteWordBack()
            case "u": clearTypedText()
            case "n": navigateSuggestions(direction: 1)
            case "p": navigateSuggestions(direction: -1)
            case "e": return caretIsAtEnd && acceptGhost() ? .handled : .ignored
            default: return .ignored
            }
            return .handled
        }
        if modifiers == .option, let letter = Self.letter(of: press) {
            switch letter {
            case "f", "ƒ": return acceptGhostWord() ? .handled : .ignored
            case "b", "∫":
                moveCaretBackOneWord()
                return .handled
            default: return .ignored
            }
        }
        return .ignored
    }

    /// The letter of a Control or Option chord, which arrives as a control character or as the
    /// layout's Option character.
    private static func letter(of press: KeyPress) -> Character? {
        guard let scalar = press.characters.unicodeScalars.first ?? press.key.character.unicodeScalars.first else { return nil }
        if scalar.value >= 1, scalar.value <= 26, let letter = UnicodeScalar(scalar.value + 96) { return Character(letter) }
        return Character(scalar).lowercased().first
    }

    /// Tab: a site keyword becomes its chip; a highlighted row puts its host and first path
    /// segment in the field to refine; else the ghost is accepted or the list is entered.
    private func handleTab() -> KeyPress.Result {
        if selectedSuggestionIndex < 0, let match = siteSearchMatch {
            withAnimation(NookDesign.Motion.spring) { activeSiteSearch = match }
            text = ""
            return .handled
        }
        if selectedSuggestionIndex >= 0, selectedSuggestionIndex < visibleSuggestions.count {
            let row = visibleSuggestions[selectedSuggestionIndex]
            switch row.type {
            case .tab(let match): text = PaletteText.refineText(for: match.url)
            case .history(let entry): text = PaletteText.refineText(for: entry.url)
            case .url: text = URL(string: row.text).flatMap { $0.host == nil ? nil : PaletteText.refineText(for: $0) } ?? row.text
            case .search: text = row.text
            }
            selectedSuggestionIndex = -1
            return .handled
        }
        if acceptGhost() { return .handled }
        if visibleSuggestions.count > 1 {
            navigateSuggestions(direction: 1)
            return .handled
        }
        return .ignored
    }

    /// Makes the whole ghost the field's text. False when none is showing.
    private func acceptGhost() -> Bool {
        guard ghostSuffix != nil, let completion else { return false }
        text = completion
        return true
    }

    /// Adds the ghost's next word to the field, which runs the search again.
    private func acceptGhostWord() -> Bool {
        guard let ghost = ghostSuffix else { return false }
        text += PaletteText.nextWord(of: ghost, stops: wordStops)
        return true
    }

    /// Ctrl+U: back to the typed text when a row is highlighted, else an empty field.
    private func clearTypedText() {
        if selectedSuggestionIndex >= 0 {
            selectedSuggestionIndex = -1
        } else {
            text = ""
        }
    }

    private var fieldEditor: NSTextView? { NSApp.keyWindow?.firstResponder as? NSTextView }

    /// UTF-16 range from the start of the word before the caret to the caret.
    private func wordBeforeCaret(in editor: NSTextView) -> NSRange {
        let caret = editor.selectedRange().location
        let prefix = (editor.string as NSString).substring(to: min(caret, (editor.string as NSString).length))
        let start = PaletteText.wordStart(before: prefix.count, in: prefix, stops: wordStops)
        let startOffset = String(prefix.prefix(start)).utf16.count
        return NSRange(location: startOffset, length: (prefix as NSString).length - startOffset)
    }

    /// Ctrl+W and ⌥⌫: deletes the selection, else the word before the caret, URL-aware.
    private func deleteWordBack() {
        guard let editor = fieldEditor else {
            text = PaletteText.deletingLastWord(text, stops: wordStops)
            return
        }
        let selection = editor.selectedRange()
        editor.insertText("", replacementRange: selection.length > 0 ? selection : wordBeforeCaret(in: editor))
    }

    /// ⌥← and Alt+B: the caret moves to the start of the word before it.
    private func moveCaretBackOneWord() {
        guard let editor = fieldEditor else { return }
        editor.setSelectedRange(NSRange(location: wordBeforeCaret(in: editor).location, length: 0))
    }

    // MARK: - Opening Rows

    /// Cmd+Return: the row opens in a background tab and the bar stays open with its query, so
    /// several can be opened in a row. An open tab is switched to, as with Return.
    private func openTargetInBackground() {
        guard let row = targetSuggestion else { return }
        guard let url = url(for: row) else {
            selectSuggestion(row)
            return
        }
        if case .history = row.type { browserManager.historyManager.recordPick(prefix: text, url: url) }
        browserManager.tabs.open(url: url, in: windowState, placement: .background)
    }

    /// Shift+Return: the row opens in split view beside the current tab.
    private func openTargetInSplit() {
        guard let row = targetSuggestion else { return }
        let itemID: UUID?
        if case .tab(let match) = row.type {
            itemID = match.itemID
        } else if let url = url(for: row) {
            if case .history = row.type { browserManager.historyManager.recordPick(prefix: text, url: url) }
            itemID = browserManager.tabs.open(url: url, in: windowState, placement: .background)
        } else {
            itemID = nil
        }
        guard let itemID else { return }
        browserManager.enterSplit(with: itemID, placeOnRight: true, in: windowState)
        commandPalette.close()
    }

    /// The page a row stands for; nil for an open tab, which is switched to instead.
    private func url(for row: SearchManager.SearchSuggestion) -> URL? {
        switch row.type {
        case .tab: return nil
        case .history(let entry): return entry.url
        case .url, .search:
            if activeSiteSearch != nil, case .search = row.type { return activeSiteSearch?.searchURL(for: row.text) }
            let template = browserManager.nookSettings?.resolvedSearchEngineTemplate ?? SearchProvider.google.queryTemplate
            return URL(string: normalizeURL(row.text, queryTemplate: template))
        }
    }

    private var caretIsAtEnd: Bool {
        guard let editor = fieldEditor else { return true }
        return editor.selectedRange().location >= (editor.string as NSString).length
    }

    /// Moves the highlight only; the field keeps what was typed.
    private func navigateSuggestions(direction: Int) {
        let maxIndex = visibleSuggestions.count - 1
        // Row 0 is the Return row, which index -1 already stands for.
        if direction > 0 {
            guard maxIndex >= 1 else { return }
            selectedSuggestionIndex = min(max(selectedSuggestionIndex, 0) + 1, maxIndex)
        } else {
            selectedSuggestionIndex = selectedSuggestionIndex <= 1 ? -1 : selectedSuggestionIndex - 1
        }
    }

    /// Globe once Return would navigate, which includes the case where only the ghost makes it a URL.
    private var leadingIconName: String {
        guard activeSiteSearch == nil else { return "magnifyingglass" }
        return isLikelyURL(text) || completion != nil ? "globe" : "magnifyingglass"
    }

    /// What the typed text completes to: the best page whose address starts with it, a host
    /// worth autofilling first. Off after a deletion, so backspacing does not bring it back.
    private var completion: String? {
        guard activeSiteSearch == nil, !completionSuppressed else { return nil }
        let pages = searchManager.suggestions.compactMap { row -> String? in
            switch row.type {
            case .history(let entry): return entry.url.absoluteString
            case .tab(let match): return match.url.absoluteString
            case .url, .search: return nil
            }
        }
        return PaletteText.completion(for: text, candidates: (searchManager.autofillHost.map { [$0] } ?? []) + pages)
    }

    /// The grey text after the caret. Hidden while a row is highlighted.
    private var ghostSuffix: String? {
        guard selectedSuggestionIndex == -1, let completion else { return nil }
        return String(completion.dropFirst(text.count))
    }

    /// Shift-Delete on a history row forgets that page and puts the typed text back.
    private func removeSelectedHistoryRow() -> Bool {
        guard selectedSuggestionIndex >= 0, selectedSuggestionIndex < visibleSuggestions.count,
              case .history(let entry) = visibleSuggestions[selectedSuggestionIndex].type else { return false }
        browserManager.historyManager.forget(entry.url)
        selectedSuggestionIndex = -1
        searchManager.searchSuggestions(for: text)
        return true
    }
}
