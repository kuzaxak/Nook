// Licensed under GPL-3.0. See LICENSE.
//
//  URLShortcut.swift
//  Nook
//
//  Keyword shortcuts for the command bar: `gh owner/repo` opens https://github.com/owner/repo.
//

import Foundation

public struct URLShortcut: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var keyword: String
    /// The address, with `%@` where the text after the keyword goes.
    public var template: String

    public init(id: UUID = UUID(), keyword: String, template: String) {
        self.id = id
        self.keyword = keyword
        self.template = template
    }

    public static let defaults = [URLShortcut(keyword: "gh", template: "https://github.com/%@")]

    /// The address for `text` when it starts with a keyword, a space and an argument.
    public static func expand(_ text: String, in shortcuts: [URLShortcut]) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let space = trimmed.firstIndex(of: " ") else { return nil }
        let keyword = trimmed[..<space].lowercased()
        let argument = trimmed[space...].trimmingCharacters(in: .whitespaces)
        guard !argument.isEmpty, let shortcut = shortcuts.first(where: { $0.keyword.lowercased() == keyword }),
              let encoded = argument.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }
        return URL(string: shortcut.template.replacingOccurrences(of: "%@", with: encoded))
    }
}
