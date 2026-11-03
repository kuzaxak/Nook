// Licensed under GPL-3.0. See LICENSE.
// swiftc Packages/NookSettings/Sources/NookSettings/DownloadLocation.swift Packages/NookSettings/Checks/DownloadLocationCheck.swift -o /tmp/download-location && /tmp/download-location

import Foundation

@main
struct DownloadLocationCheck {
    static func main() {
        let downloads = URL(fileURLWithPath: "/Users/me/Downloads")
        let work = URL(fileURLWithPath: "/Volumes/Work/Inbox")
        let exists: (URL) -> Bool = { $0 == work || $0 == downloads }
        let gone: (URL) -> Bool = { $0 == downloads }

        precondition(ProfileDownloads().destination(downloads: downloads, folderExists: exists) == .folder(downloads),
                     "a profile saves to Downloads until told otherwise")
        precondition(ProfileDownloads(location: .folder(work.path)).destination(downloads: downloads, folderExists: exists) == .folder(work))
        precondition(ProfileDownloads(location: .folder(work.path)).destination(downloads: downloads, folderExists: gone) == .folder(downloads),
                     "an unplugged drive falls back to Downloads")

        var ask = ProfileDownloads(location: .ask)
        precondition(ask.destination(downloads: downloads, folderExists: exists) == .ask(startingIn: downloads))
        ask.remember(savedFile: work.appendingPathComponent("report.pdf"))
        precondition(ask.lastFolder == work.path)
        precondition(ask.destination(downloads: downloads, folderExists: exists) == .ask(startingIn: work),
                     "asking again opens where the last file went")
        precondition(ask.destination(downloads: downloads, folderExists: gone) == .ask(startingIn: downloads))

        let saved = try! JSONEncoder().encode([ProfileDownloads(location: .folder(work.path)), ask])
        precondition(try! JSONDecoder().decode([ProfileDownloads].self, from: saved) == [ProfileDownloads(location: .folder(work.path)), ask])
        print("DownloadLocationCheck passed")
    }
}
