// Licensed under GPL-3.0. See LICENSE.
//
//  mkdir -p /tmp/space-sync-cloudkit-check
//  swiftc -emit-library -emit-module -module-name NookTabsCore Packages/NookTabsCore/Sources/NookTabsCore/*.swift \
//         -emit-module-path /tmp/space-sync-cloudkit-check/NookTabsCore.swiftmodule -o /tmp/space-sync-cloudkit-check/libNookTabsCore.dylib
//  swiftc -parse-as-library -I /tmp/space-sync-cloudkit-check -L /tmp/space-sync-cloudkit-check -lNookTabsCore \
//         -Xlinker -rpath -Xlinker /tmp/space-sync-cloudkit-check \
//         Nook/Managers/SpaceSync/SyncRecord+CloudKit.swift scripts/tests/SpaceSyncCloudKitCheck.swift \
//         -o /tmp/space-sync-cloudkit-check/check && /tmp/space-sync-cloudkit-check/check
//
//  Two Macs' spaces through real CKRecords, made and read by the app's mapping: Mac B fetching
//  Mac A's space and items for the first time, Mac B getting a later change, and a space Off on
//  Mac B, then which database and zone a Mac that joined another account's share uses. Each
//  record goes across whole through NSKeyedArchiver, as CloudKit hands records back, so names,
//  addresses, titles and the Mac's name must come back from the encrypted fields. No CKContainer
//  is made and nothing reaches iCloud.

import CloudKit
import Foundation
import NookTabsCore

private let zone = CKRecordZone.ID(zoneName: "Spaces", ownerName: CKCurrentUserDefaultName)
private var failures = 0

private func check(_ ok: Bool, _ what: String) {
    if !ok {
        failures += 1
        print("FAIL: \(what)")
    }
}

/// The record as another Mac's fetch gets it: the whole record archived and read again.
private func transported(_ record: CKRecord) -> CKRecord {
    let coder = NSKeyedArchiver(requiringSecureCoding: true)
    record.encode(with: coder)
    coder.finishEncoding()
    guard let decoder = try? NSKeyedUnarchiver(forReadingFrom: coder.encodedData) else { fatalError("archive unreadable") }
    decoder.requiresSecureCoding = true
    guard let copy = CKRecord(coder: decoder) else { fatalError("record unreadable") }
    return copy
}

private struct Mac {
    var tree: TabTree
    var state = SpaceSyncState()
    let device: String

    /// Saves what differs from iCloud and returns the records as iCloud holds them.
    mutating func send(now: Date) -> [CKRecord] {
        let pending = state.pendingChanges(in: tree)
        let records = state.outgoing(pending.saves, in: tree, now: now, device: device).values
            .map { $0.record(in: zone, systemFields: state.systemFields[$0.id]) }
        var fields: [UUID: Data] = [:]
        for record in records { fields[UUID(uuidString: record.recordID.recordName)!] = record.archivedSystemFields }
        state.didSend(saved: records.compactMap(SyncRecord.init), systemFields: fields, deleted: [], now: now)
        return records.map(transported)
    }

    mutating func fetch(_ records: [CKRecord], now: Date) {
        for record in records {
            guard let synced = SyncRecord(record) else {
                check(false, "\(record.recordType) \(record.recordID.recordName) reads back as no record")
                continue
            }
            state.fetched(synced, systemFields: record.archivedSystemFields)
        }
        let inbound = state.receive(into: tree, now: now)
        tree.apply(inbound.change)
        state.prune(against: tree, now: now)
    }

    func row(_ id: UUID) -> SpaceSyncCloudSpace? { state.cloudSpaces(in: tree).first { $0.id == id } }
}

@main
struct SpaceSyncCloudKitCheck {
    static func main() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let home = URL(string: "https://example.com/home")!
        let work = UUID(), mail = UUID(), docs = UUID(), spec = UUID()

        var treeA = TabTree.firstLaunch(homeURL: home, now: start)
        treeA.createSpace(id: work, name: "Work", icon: "💼", accentHex: "#336699", after: nil, profileName: "Job", now: start)
        try treeA.createTab(id: mail, url: URL(string: "https://example.com/mail")!, title: "Mail", in: .favorites(spaceID: work), after: nil, now: start)
        try treeA.createFolder(id: docs, title: "Docs", in: .pinned(spaceID: work), after: nil, now: start)
        try treeA.createTab(id: spec, url: URL(string: "https://example.com/spec")!, title: "Spec", in: .folder(itemID: docs), after: nil, now: start)
        var a = Mac(tree: treeA, device: "Mac A")
        a.state.setLevel(.pinned, for: work, now: start)
        let first = a.send(now: start)

        check(first.count == 4, "Mac A sends the space and its 3 items, sent \(first.count)")
        for record in first {
            for key in ["name", "profile", "url", "title", "device"] {
                check(record[key] == nil, "\(record.recordType) holds \(key) unencrypted")
            }
        }
        let spaceRecord = first.first { $0.recordType == "Space" }
        check(spaceRecord?.encryptedValues["name"] as? String == "Work", "the space's name is in its encrypted fields")
        check(spaceRecord?.encryptedValues["device"] as? String == "Mac A", "the space record names Mac A in its encrypted fields")

        // Mac B fetches Mac A's space and items for the first time.
        var b = Mac(tree: TabTree.firstLaunch(homeURL: home, now: start), device: "Mac B")
        b.fetch(first, now: start.addingTimeInterval(1))
        check(b.tree.space(work)?.name == "Work", "Work arrives on Mac B")
        check(b.tree.item(mail)?.parent == .favorites(spaceID: work), "the favorite arrives")
        check(b.tree.item(spec)?.parent == .folder(itemID: docs), "the pinned folder's tab arrives in it")
        check(b.tree.profile(ofSpace: work)?.name == "Job", "Work joins a profile named Job")
        check(b.state.level(of: work) == .pinned, "Work syncs Favorites & Pinned on Mac B")
        check(b.row(work)?.device == "Mac A", "Mac B's list says Mac A changed Work, says \(String(describing: b.row(work)?.device))")
        check(b.row(work)?.itemCount == 3, "Mac B's list counts Work's 3 items")
        check(b.row(work)?.state == .syncing(.pinned), "Mac B's list shows Work syncing")
        check(b.state.inbox.isEmpty, "nothing waits in Mac B's inbox")

        // Mac B, already running, gets a later change.
        let later = start.addingTimeInterval(60)
        try a.tree.updateSpace(work, name: "Work 2", now: later)
        try a.tree.rename(spec, customTitle: "The spec", now: later)
        let second = a.send(now: later)
        check(second.count == 2, "Mac A sends only the renamed space and tab, sent \(second.count)")
        b.fetch(second, now: later.addingTimeInterval(1))
        check(b.tree.space(work)?.name == "Work 2", "the renamed space reaches Mac B")
        check(b.tree.item(spec)?.customTitle == "The spec", "the renamed tab reaches Mac B")
        check(b.row(work)?.changedAt == later, "Mac B's list shows when Work last changed")
        check(b.state.pendingChanges(in: b.tree) == ([], []), "Mac B has nothing to send back")

        // A space with the same id is Off on Mac C: it stays as it is and shows Off here.
        var treeC = TabTree.firstLaunch(homeURL: home, now: start)
        treeC.createSpace(id: work, name: "Mine", icon: "", accentHex: "#000000", after: nil, now: start)
        var c = Mac(tree: treeC, device: "Mac C")
        c.fetch(first + second, now: later.addingTimeInterval(2))
        check(c.tree.space(work)?.name == "Mine", "Mac C keeps its own Work while Off")
        check(c.tree.item(mail) == nil, "Mac C takes in no items of a space Off there")
        check(c.row(work)?.state == .offHere, "Mac C's list shows Work Off on this Mac")
        check(c.row(work)?.name == "Work 2", "Mac C's list names the space as iCloud has it")

        // Mac C joins Mac A's zone from another account: it sends to and fetches from the shared
        // database, in the zone A's account owns, and goes back to its own zone when it leaves.
        let ownerAccount = "_48e607c1179693a062ca0aefa4e62a57"
        check(c.state.databaseScope == .private, "Mac C syncs its own account's database before joining")
        check(c.state.zoneID.ownerName == CKCurrentUserDefaultName, "Mac C syncs its own zone before joining")
        c.state.join(owner: ownerAccount, ownerName: "Vladimir")
        check(c.state.databaseScope == .shared, "a joined Mac syncs through the shared database")
        check(c.state.zoneID == CKRecordZone.ID(zoneName: "Spaces", ownerName: ownerAccount), "a joined Mac syncs the owner's Spaces zone")
        check(c.state.shareRecordID.recordName == CKRecordNameZoneWideShare && c.state.shareRecordID.zoneID == c.state.zoneID,
              "a joined Mac's share is the zone-wide share of the owner's zone")
        c.state.setLevel(.pinned, for: work, now: later.addingTimeInterval(3))
        let joined = c.state.outgoing(c.state.pendingChanges(in: c.tree).saves, in: c.tree, now: later.addingTimeInterval(3), device: c.device)
            .values.map { $0.record(in: c.state.zoneID, systemFields: nil) }
        check(!joined.isEmpty && joined.allSatisfy { $0.recordID.zoneID.ownerName == ownerAccount }, "a joined Mac's saves go into the owner's zone")
        c.state.leaveSharedZone()
        check(c.state.databaseScope == .private && c.state.zoneID.ownerName == CKCurrentUserDefaultName, "leaving goes back to Mac C's own zone")

        if failures == 0 {
            print("PASS: space sync through CKRecords")
        } else {
            print("\(failures) failed")
            exit(1)
        }
    }
}
