// Licensed under GPL-3.0. See LICENSE.
//
//  SyncRecord+CloudKit.swift
//  Nook
//
//  NookTabsCore's sync records as CKRecords: names, addresses, titles and looks in encrypted
//  fields, each field group's modification time beside them as "<group>At".
//  scripts/cloudkit/schema.ckdb declares the same fields.
//

import CloudKit
import NookTabsCore

extension SyncRecord {
    static func timeKey(_ group: String) -> String { group + "At" }

    init?(_ record: CKRecord) {
        guard let type = RecordType(rawValue: record.recordType), let id = UUID(uuidString: record.recordID.recordName) else { return nil }
        var fields: [String: SyncValue] = [:]
        for key in type.keys {
            let value = type.encryptedKeys.contains(key) ? record.encryptedValues[key] : record[key]
            if let text = value as? String {
                fields[key] = .string(text)
            } else if let data = value as? Data {
                fields[key] = .bytes(data)
            } else if let number = value as? NSNumber {
                fields[key] = .int(number.int64Value)
            }
        }
        var times: [String: Int64] = [:]
        for group in type.groups.keys {
            if let time = record[Self.timeKey(group)] as? NSNumber { times[group] = time.int64Value }
        }
        self.init(type: type, id: id, fields: fields, times: times)
    }

    /// The record to save: the last server version's system fields, so CloudKit can tell a
    /// stale save, with every field set or cleared.
    func record(in zoneID: CKRecordZone.ID, systemFields: Data?) -> CKRecord {
        let record = systemFields.flatMap(CKRecord.init(archivedSystemFields:))
            ?? CKRecord(recordType: type.rawValue, recordID: CKRecord.ID(recordName: id.uuidString, zoneID: zoneID))
        for key in type.keys {
            let value: CKRecordValue?
            switch fields[key] {
            case .string(let text)?: value = text as NSString
            case .bytes(let data)?: value = data as NSData
            case .int(let number)?: value = NSNumber(value: number)
            case nil: value = nil
            }
            if type.encryptedKeys.contains(key) {
                record.encryptedValues[key] = value
            } else {
                record[key] = value
            }
        }
        for group in type.groups.keys {
            record[Self.timeKey(group)] = times[group].map { NSNumber(value: $0) }
        }
        return record
    }
}

extension SpaceSyncState {
    /// The zone this Mac syncs: this account's own, or the other account's it joined.
    var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: SpaceSyncAvailability.zoneName, ownerName: zoneOwner ?? CKCurrentUserDefaultName)
    }

    var databaseScope: CKDatabase.Scope { database == .shared ? .shared : .private }

    /// The zone-wide share of `zoneID`, which CloudKit always names `CKRecordNameZoneWideShare`.
    var shareRecordID: CKRecord.ID { CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID) }

    /// Takes in what a fetch returned for this Mac's zone. A shared database holds a zone for
    /// every share the account joined, so records of any other zone are left out. Returns the
    /// zone's share when it came or went.
    mutating func fetched(_ records: [CKRecord], deletions: [(id: CKRecord.ID, type: CKRecord.RecordType)]) -> (share: CKShare?, shareDeleted: Bool) {
        let zone = zoneID
        var share: CKShare?
        for record in records where record.recordID.zoneID == zone {
            if let zoneShare = record as? CKShare {
                share = zoneShare
            } else if let synced = SyncRecord(record) {
                fetched(synced, systemFields: record.archivedSystemFields)
            }
        }
        var shareDeleted = false
        for deletion in deletions where deletion.id.zoneID == zone {
            if deletion.type == CKRecord.SystemType.share {
                shareDeleted = true
            } else if let id = UUID(uuidString: deletion.id.recordName) {
                fetchedDeletion(id)
            }
        }
        return (share, shareDeleted)
    }
}

extension CKRecord {
    var archivedSystemFields: Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    convenience init?(archivedSystemFields data: Data) {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        self.init(coder: coder)
    }
}
