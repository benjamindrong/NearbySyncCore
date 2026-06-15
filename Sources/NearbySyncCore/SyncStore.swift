import Foundation

public protocol SyncStore: AnyObject, Sendable {
    func record(for entityType: SyncEntityType, entityID: String) async -> SyncRecord?
    func apply(_ change: SyncChange) async -> Bool
    func allRecords() async -> [SyncRecord]
}

public actor InMemorySyncStore: SyncStore {
    private var records: [RecordKey: SyncRecord] = [:]

    public init(seedRecords: [SyncRecord] = []) {
        for record in seedRecords {
            records[RecordKey(type: record.entityType, id: record.entityID)] = record
        }
    }

    public func record(for entityType: SyncEntityType, entityID: String) -> SyncRecord? {
        records[RecordKey(type: entityType, id: entityID)]
    }

    public func apply(_ change: SyncChange) -> Bool {
        let key = RecordKey(type: change.entityType, id: change.entityID)

        if let existing = records[key], existing.updatedAt > change.updatedAt {
            return false
        }

        records[key] = SyncRecord(
            entityType: change.entityType,
            entityID: change.entityID,
            payload: change.payload,
            updatedAt: change.updatedAt,
            isDeleted: change.operation == .delete
        )
        return true
    }

    public func allRecords() -> [SyncRecord] {
        records.values.sorted {
            if $0.entityType.rawValue == $1.entityType.rawValue {
                return $0.entityID < $1.entityID
            }
            return $0.entityType.rawValue < $1.entityType.rawValue
        }
    }
}

public actor LocalFirstTextSyncStore: SyncStore {
    private let localDeviceID: String
    private let conflictStore: SyncTextConflictStore
    private var records: [RecordKey: SyncRecord] = [:]
    private var remoteBaselines: [RecordKey: SyncRecord] = [:]

    public init(
        localDeviceID: String,
        conflictStore: SyncTextConflictStore,
        seedRecords: [SyncRecord] = []
    ) {
        self.localDeviceID = localDeviceID
        self.conflictStore = conflictStore
        for record in seedRecords {
            records[RecordKey(type: record.entityType, id: record.entityID)] = record
        }
    }

    public func record(for entityType: SyncEntityType, entityID: String) -> SyncRecord? {
        records[RecordKey(type: entityType, id: entityID)]
    }

    public func apply(_ change: SyncChange) -> Bool {
        let key = RecordKey(type: change.entityType, id: change.entityID)

        if let existing = records[key], existing.updatedAt > change.updatedAt {
            return false
        }

        if change.originDeviceID != localDeviceID,
           let existing = records[key],
           preserveConflictIfNeeded(existing: existing, change: change) {
            return false
        }

        let record = SyncRecord(
            entityType: change.entityType,
            entityID: change.entityID,
            payload: change.payload,
            updatedAt: change.updatedAt,
            isDeleted: change.operation == .delete
        )
        records[key] = record
        if change.originDeviceID != localDeviceID {
            remoteBaselines[key] = record
        }
        return true
    }

    public func allRecords() -> [SyncRecord] {
        records.values.sorted {
            if $0.entityType.rawValue == $1.entityType.rawValue {
                return $0.entityID < $1.entityID
            }
            return $0.entityType.rawValue < $1.entityType.rawValue
        }
    }

    public func activeConflicts(now: Date = Date()) -> [SyncTextConflictVersion] {
        conflictStore.activeConflicts(now: now)
    }

    public func removeConflict(id: UUID) -> [SyncTextConflictVersion] {
        conflictStore.removeConflict(id: id)
    }

    public func restore(_ conflict: SyncTextConflictVersion) -> [SyncTextConflictVersion] {
        let key = RecordKey(type: conflict.entityType, id: conflict.entityID)
        records[key] = SyncRecord(
            entityType: conflict.entityType,
            entityID: conflict.entityID,
            payload: Data(conflict.remoteText.utf8),
            updatedAt: Date(),
            isDeleted: false
        )
        remoteBaselines[key] = SyncRecord(
            entityType: conflict.entityType,
            entityID: conflict.entityID,
            payload: Data(conflict.remoteText.utf8),
            updatedAt: conflict.remoteUpdatedAt,
            isDeleted: false
        )
        return conflictStore.removeConflict(id: conflict.id)
    }

    private func preserveConflictIfNeeded(existing: SyncRecord, change: SyncChange) -> Bool {
        let key = RecordKey(type: change.entityType, id: change.entityID)
        if let remoteBaseline = remoteBaselines[key],
           existing.payload == remoteBaseline.payload,
           existing.isDeleted == remoteBaseline.isDeleted {
            return false
        }

        let localText = String(data: existing.payload, encoding: .utf8) ?? ""
        let remoteText = String(data: change.payload, encoding: .utf8) ?? ""

        guard let conflict = SyncTextConflictPolicy.conflictIfTextDiverged(
            entityType: change.entityType,
            entityID: change.entityID,
            fieldID: "text",
            remoteOperation: change.operation,
            localText: localText,
            remoteText: remoteText,
            remoteUpdatedAt: change.updatedAt
        ) else { return false }

        _ = conflictStore.preserve(conflict)
        return true
    }
}

private struct RecordKey: Hashable {
    let type: SyncEntityType
    let id: String
}
