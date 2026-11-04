// Licensed under GPL-3.0. See LICENSE.
//
//  BrowserManager+SpaceFiles.swift
//  Nook
//
//  Export Space and Import Space: the save and open panels, the question of which profile an
//  imported space joins, and what came in. The file format lives in NookTabsCore's SpaceFile.
//

import AppKit
import NookTabsCore
import NookWeb
import OSLog
import UniformTypeIdentifiers

extension UTType {
    static let nookSpace = UTType(exportedAs: SpaceFile.typeIdentifier, conformingTo: .json)
}

extension BrowserManager {
    private static let spaceFileLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Nook", category: "SpaceFile")

    static func isSpaceFile(_ url: URL) -> Bool {
        url.isFileURL && url.pathExtension.lowercased() == SpaceFile.fileExtension
    }

    /// Saves the space's look, favorites, pinned tabs and open tabs to a file the person names.
    func exportSpace(_ spaceID: UUID) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        guard let file = tabs.spaceFile(spaceID, appVersion: version) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.nookSpace]
        panel.canCreateDirectories = true
        let name = file.space.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        panel.nameFieldStringValue = "\(name.isEmpty ? "Space" : name).\(SpaceFile.fileExtension)"
        panel.message = "Saves the space's favorites, pinned tabs and open tabs. Logins, cookies and history stay in Nook."
        runPanel(panel) { [weak self] url in
            do {
                try file.encoded().write(to: url, options: .atomic)
            } catch {
                Self.spaceFileLog.error("Space export failed: \(String(describing: error), privacy: .public)")
                self?.showSpaceFileAlert("\u{201C}\(file.space.name)\u{201D} could not be exported", error.localizedDescription, style: .warning)
            }
        }
    }

    /// Asks for a `.nookspace` file and imports it.
    func importSpace() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.nookSpace]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Import"
        runPanel(panel) { [weak self] url in self?.importSpaceFile(at: url) }
    }

    /// Reads a space file, asks which profile its space joins, and adds it as a new last space.
    /// A file Nook refuses imports nothing.
    func importSpaceFile(at url: URL) {
        let file: SpaceFile
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            file = try SpaceFile.decode(handle.read(upToCount: SpaceFile.maxBytes + 1) ?? Data())
        } catch {
            Self.spaceFileLog.info("Space import refused: \(String(describing: error), privacy: .public)")
            showSpaceFileAlert("\u{201C}\(url.lastPathComponent)\u{201D} could not be imported",
                               Self.refusal(error) + " Nothing was imported.", style: .warning)
            return
        }
        askProfile(for: file) { [weak self] storeID in
            guard let self else { return }
            guard let report = tabs.importSpace(file, intoProfile: storeID) else {
                showSpaceFileAlert("\u{201C}\(file.space.name)\u{201D} could not be imported", "Nothing was imported.", style: .warning)
                return
            }
            showSpaceFileAlert("Imported \u{201C}\(report.name)\u{201D}", Self.summary(report), style: .informational)
        }
    }

    // MARK: - Dialogs

    /// The profile of the frontmost regular window's space; private windows and the Agent space have none.
    private var currentProfileID: UUID? {
        let active = windowRegistry?.activeWindow.flatMap { $0.isIncognito ? nil : $0 } ?? tabs.regularWindows.first
        guard let spaceID = active?.spaceID else { return nil }
        return tabs.profiles.first { $0.spaceIDs.contains(spaceID) }?.id
    }

    private func askProfile(for file: SpaceFile, then handle: @escaping (UUID) -> Void) {
        let profiles = tabs.profiles
        guard !profiles.isEmpty else { return }
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26), pullsDown: false)
        // addItem(withTitle:) drops an earlier item with the same title, and two profiles can share a name.
        for profile in profiles {
            popup.menu?.addItem(NSMenuItem(title: profile.name, action: nil, keyEquivalent: ""))
        }
        popup.selectItem(at: profiles.firstIndex { $0.id == currentProfileID } ?? 0)
        let alert = NSAlert()
        alert.messageText = "Import \u{201C}\(file.space.name)\u{201D}"
        alert.informativeText = "It becomes a new space in the profile you choose and uses that profile's logins, cookies and history."
        alert.accessoryView = popup
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")
        runAlert(alert) { response in
            guard response == .alertFirstButtonReturn, profiles.indices.contains(popup.indexOfSelectedItem) else { return }
            handle(profiles[popup.indexOfSelectedItem].id)
        }
    }

    private func showSpaceFileAlert(_ title: String, _ message: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.addButton(withTitle: "OK")
        runAlert(alert) { _ in }
    }

    /// A sheet on the front window, or a window of its own when none is open.
    private func runAlert(_ alert: NSAlert, then handle: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }

    /// `handle` runs after the panel's sheet has gone, so it can show a sheet of its own.
    private func runPanel(_ panel: NSSavePanel, then handle: @escaping (URL) -> Void) {
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            DispatchQueue.main.async { handle(url) }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }

    // MARK: - Text

    private static func refusal(_ error: Error) -> String {
        switch error as? SpaceFileError {
        case .tooLarge: return "The file is larger than \(SpaceFile.maxBytes / 1024 / 1024) MB."
        case .unreadable: return "The file is damaged or is not a Nook space."
        case .wrongFormat: return "The file is not a Nook space."
        case .newerVersion: return "The file comes from a newer version of Nook. Update Nook, then import it again."
        case .tooManyItems: return "The space has more than \(SpaceFile.maxItems.formatted()) tabs and folders."
        case .tooDeep: return "The space's folders are nested deeper than Nook allows."
        case nil: return error.localizedDescription
        }
    }

    private static func summary(_ report: SpaceImportReport) -> String {
        var text = "\(count(report.tabs, "tab")), \(count(report.folders, "folder")) and \(count(report.favorites, "favorite")) came in. "
            + "The space is last in the space list; its tabs load when you open them."
        var skipped: [String] = []
        if report.duplicateFavorites > 0 { skipped.append("\(count(report.duplicateFavorites, "favorite")) the profile already has") }
        if report.unsafeLinks > 0 {
            skipped.append("\(count(report.unsafeLinks, "link")) that \(report.unsafeLinks == 1 ? "is" : "are") not a web address")
        }
        if !skipped.isEmpty { text += "\n\nLeft out: " + skipped.joined(separator: " and ") + "." }
        return text
    }

    private static func count(_ number: Int, _ noun: String) -> String {
        number == 1 ? "1 \(noun)" : "\(number) \(noun)s"
    }
}
