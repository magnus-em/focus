import CloudKit
import Foundation

/// What the iPhone/iPad reports to the Mac's activity log: app opens/closes
/// from Shortcuts automations, and screen-broadcast blocks (title + notes
/// written on the device). Raw CloudKit in its own zone, separate from the
/// SwiftData mirror, because the broadcast extension can't share that store.
/// Screen text never leaves the device; only these fields do.
public struct DeviceActivity: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable { case open, close, block }

    public var id: String
    public var kind: Kind
    public var device: String
    public var app: String
    public var date: Date
    public var end: Date?
    public var category: String?
    public var title: String
    public var bullets: [String]

    public init(id: String = UUID().uuidString, kind: Kind, device: String, app: String, date: Date,
                end: Date? = nil, category: String? = nil, title: String = "", bullets: [String] = []) {
        self.id = id; self.kind = kind; self.device = device; self.app = app; self.date = date
        self.end = end; self.category = category; self.title = title; self.bullets = bullets
    }
}

public enum DeviceActivityCloud {
    static let recordType = "DeviceActivity"
    static let zoneID = CKRecordZone.ID(zoneName: "FocusDeviceActivity", ownerName: CKCurrentUserDefaultName)
    static var database: CKDatabase { CKContainer(identifier: "iCloud.com.magnus.focustracker").privateCloudDatabase }
    nonisolated(unsafe) private static var zoneReady = false

    /// Upserts by `id`, so a block can be re-sent as its notes grow.
    public static func save(_ a: DeviceActivity) async throws {
        if !zoneReady {
            _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
            zoneReady = true
        }
        let r = CKRecord(recordType: recordType, recordID: CKRecord.ID(recordName: a.id, zoneID: zoneID))
        r["kind"] = a.kind.rawValue
        r["device"] = a.device
        r["app"] = a.app
        r["date"] = a.date
        r["end"] = a.end
        r["category"] = a.category
        r["title"] = a.title
        r["bullets"] = a.bullets.isEmpty ? nil : a.bullets
        _ = try await database.modifyRecords(saving: [r], deleting: [], savePolicy: .allKeys)
    }

    /// Everything changed since `token` (nil = all). Returns the new token.
    public static func changes(since token: CKServerChangeToken?) async throws -> ([DeviceActivity], CKServerChangeToken?) {
        var out: [DeviceActivity] = []
        var token = token
        var more = true
        while more {
            let page: (modificationResultsByID: [CKRecord.ID: Result<CKDatabase.RecordZoneChange.Modification, Error>],
                       deletions: [CKDatabase.RecordZoneChange.Deletion], changeToken: CKServerChangeToken, moreComing: Bool)
            do {
                page = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)
            } catch let e as CKError where e.code == .zoneNotFound {
                return ([], token)
            }
            for (_, result) in page.modificationResultsByID {
                guard case .success(let m) = result, let a = decode(m.record) else { continue }
                out.append(a)
            }
            token = page.changeToken
            more = page.moreComing
        }
        return (out, token)
    }

    private static func decode(_ r: CKRecord) -> DeviceActivity? {
        guard let kind = (r["kind"] as? String).flatMap(DeviceActivity.Kind.init),
              let date = r["date"] as? Date else { return nil }
        return DeviceActivity(id: r.recordID.recordName, kind: kind, device: r["device"] as? String ?? "iPhone",
                              app: r["app"] as? String ?? "", date: date, end: r["end"] as? Date,
                              category: r["category"] as? String, title: r["title"] as? String ?? "",
                              bullets: r["bullets"] as? [String] ?? [])
    }
}
