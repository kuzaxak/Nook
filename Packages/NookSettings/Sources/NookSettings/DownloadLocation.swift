// Licensed under GPL-3.0. See LICENSE.
//
//  DownloadLocation.swift
//  NookSettings
//
//  Where a profile's downloads go. Kept on this Mac only: a folder path means nothing on
//  another one.
//

import Foundation

public enum DownloadLocation: Codable, Equatable, Sendable {
    case downloads
    case folder(String)
    case ask
}

public struct ProfileDownloads: Codable, Equatable, Sendable {
    public var location: DownloadLocation
    /// The folder the last file chosen in the save panel went to; the next panel opens there.
    public var lastFolder: String?

    public init(location: DownloadLocation = .downloads, lastFolder: String? = nil) {
        self.location = location
        self.lastFolder = lastFolder
    }

    public mutating func remember(savedFile: URL) {
        lastFolder = savedFile.deletingLastPathComponent().path
    }

    public func destination(downloads: URL, folderExists: (URL) -> Bool) -> DownloadDestination {
        switch location {
        case .downloads:
            return .folder(downloads)
        case .folder(let path):
            let folder = URL(fileURLWithPath: path)
            return .folder(folderExists(folder) ? folder : downloads)
        case .ask:
            let last = lastFolder.map { URL(fileURLWithPath: $0) }.flatMap { folderExists($0) ? $0 : nil }
            return .ask(startingIn: last ?? downloads)
        }
    }
}

public enum DownloadDestination: Equatable, Sendable {
    case folder(URL)
    case ask(startingIn: URL)
}
