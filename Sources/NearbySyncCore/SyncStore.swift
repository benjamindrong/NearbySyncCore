import Foundation

public protocol SyncStore: AnyObject, Sendable {
    func record(for entityType: SyncEntityType, entityID: String) async -> SyncRecord?
    func apply(_ change: SyncChange) async -> Bool
    func allRecords() async -> [SyncRecord]
    func preservedConflictsForLastApply() async -> [SyncTextConflictVersion]
    func markLocalChangesAcknowledged(_ changes: [SyncChange]) async
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

    public func preservedConflictsForLastApply() -> [SyncTextConflictVersion] {
        []
    }

    public func markLocalChangesAcknowledged(_ changes: [SyncChange]) {}
}

public actor LocalFirstTextSyncStore: SyncStore {
    private let localDeviceID: String
    private let conflictStore: SyncTextConflictStore
    private let textApplicationGate: SyncTextApplicationGate
    private var records: [RecordKey: SyncRecord] = [:]
    private var remoteBaselines: [RecordKey: SyncRecord] = [:]
    private var pendingLocalTextBaselines: [RecordKey: PendingTextBaseline] = [:]
    private var lastPreservedConflicts: [SyncTextConflictVersion] = []

    public init(
        localDeviceID: String,
        conflictStore: SyncTextConflictStore,
        textApplicationGate: @escaping SyncTextApplicationGate = { _ in .allowAutomaticApply },
        seedRecords: [SyncRecord] = []
    ) {
        self.localDeviceID = localDeviceID
        self.conflictStore = conflictStore
        self.textApplicationGate = textApplicationGate
        for record in seedRecords {
            records[RecordKey(type: record.entityType, id: record.entityID)] = record
        }
    }

    public func record(for entityType: SyncEntityType, entityID: String) -> SyncRecord? {
        records[RecordKey(type: entityType, id: entityID)]
    }

    public func apply(_ change: SyncChange) -> Bool {
        lastPreservedConflicts = []

        if change.entityType == .conflict {
            return applyIncomingConflictMetadata(change)
        }

        let key = RecordKey(type: change.entityType, id: change.entityID)

        if let existing = records[key], existing.updatedAt > change.updatedAt {
            return false
        }

        var payloadToStore = SyncTextPayload.decodeText(from: change.payload).text
        if change.originDeviceID != localDeviceID,
           let existing = records[key] {
            switch incomingTextResolution(existing: existing, change: change) {
            case .store(let text):
                payloadToStore = text
            case .conflict:
                return false
            }
        }

        let record = SyncRecord(
            entityType: change.entityType,
            entityID: change.entityID,
            payload: Data(payloadToStore.utf8),
            updatedAt: change.updatedAt,
            isDeleted: change.operation == .delete
        )
        records[key] = record
        if change.originDeviceID != localDeviceID {
            remoteBaselines[key] = record
            pendingLocalTextBaselines.removeValue(forKey: key)
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

    public func textPayloadData(entityType: SyncEntityType, entityID: String, text: String) throws -> Data {
        let key = RecordKey(type: entityType, id: entityID)
        let baseline: PendingTextBaseline
        if let pendingBaseline = pendingLocalTextBaselines[key] {
            baseline = pendingBaseline
        } else {
            let baselineText = remoteBaselines[key].flatMap { String(data: $0.payload, encoding: .utf8) }
                ?? records[key].flatMap { String(data: $0.payload, encoding: .utf8) }
            baseline = PendingTextBaseline(text: baselineText)
            pendingLocalTextBaselines[key] = baseline
        }
        return try SyncTextPayload(text: text, baseText: baseline.text).encoded()
    }

    public func preservedConflictsForLastApply() -> [SyncTextConflictVersion] {
        lastPreservedConflicts
    }

    public func markLocalChangesAcknowledged(_ changes: [SyncChange]) {
        for change in changes where change.originDeviceID == localDeviceID && change.entityType != .conflict {
            let key = RecordKey(type: change.entityType, id: change.entityID)
            let payload = SyncTextPayload.decodeText(from: change.payload)
            let record = SyncRecord(
                entityType: change.entityType,
                entityID: change.entityID,
                payload: Data(payload.text.utf8),
                updatedAt: change.updatedAt,
                isDeleted: change.operation == .delete
            )
            // Acknowledgement means at least one peer accepted this text as
            // shared state. The next local edit should diff from this text, but
            // all collapsed offline edits before acknowledgement keep the older
            // base so they cannot merge against a previous keystroke.
            remoteBaselines[key] = record
            pendingLocalTextBaselines.removeValue(forKey: key)
        }
    }

    public func removeConflict(id: UUID) -> [SyncTextConflictVersion] {
        conflictStore.removeConflict(id: id)
    }

    public func removeResolvedConflict(_ conflict: SyncTextConflictVersion) -> [SyncTextConflictVersion] {
        conflictStore.removeResolvedConflict(conflict)
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
        return conflictStore.removeResolvedConflict(conflict)
    }

    private func applyIncomingConflictMetadata(_ change: SyncChange) -> Bool {
        guard let payload = try? SyncTextConflictPayload.decode(from: change.payload) else { return false }
        switch payload.action {
        case .preserved:
            guard let conflict = payload.conflict else { return false }
            _ = conflictStore.preserve(normalizedIncomingConflict(conflict))
            return true
        case .resolved:
            if let conflict = payload.conflict,
               let resolvedText = payload.resolvedText,
               !applyResolvedConflictText(conflict, resolvedText: resolvedText, baseText: payload.baseText) {
                return false
            }
            if let conflict = payload.conflict {
                _ = conflictStore.removeResolvedConflict(conflict)
            } else {
                _ = conflictStore.removeConflict(id: payload.conflictID)
            }
            return true
        }
    }

    private func normalizedIncomingConflict(_ conflict: SyncTextConflictVersion) -> SyncTextConflictVersion {
        let key = RecordKey(type: conflict.entityType, id: conflict.entityID)
        guard let localText = records[key].flatMap({ String(data: $0.payload, encoding: .utf8) }) else {
            return conflict
        }
        return conflict.normalizedForPeerPreservedConflict(currentLocalText: localText)
    }

    private func applyResolvedConflictText(
        _ conflict: SyncTextConflictVersion,
        resolvedText: String,
        baseText: String?
    ) -> Bool {
        let key = RecordKey(type: conflict.entityType, id: conflict.entityID)
        let localText = records[key].flatMap { String(data: $0.payload, encoding: .utf8) } ?? ""

        switch SyncThreeWayTextMergePolicy.merge(base: baseText, local: localText, remote: resolvedText) {
        case .apply(let text), .merged(let text):
            let record = SyncRecord(
                entityType: conflict.entityType,
                entityID: conflict.entityID,
                payload: Data(text.utf8),
                updatedAt: Date(),
                isDeleted: false
            )
            records[key] = record
            remoteBaselines[key] = record
            return true
        case .noOp:
            _ = conflictStore.removeConflict(id: conflict.id)
            return true
        case .conflict:
            let record = SyncRecord(
                entityType: conflict.entityType,
                entityID: conflict.entityID,
                payload: Data(resolvedText.utf8),
                updatedAt: Date(),
                isDeleted: false
            )
            records[key] = record
            remoteBaselines[key] = record
            return true
        }
    }

    private func incomingTextResolution(existing: SyncRecord, change: SyncChange) -> IncomingTextResolution {
        let key = RecordKey(type: change.entityType, id: change.entityID)
        let fieldID = "text"
        let localText = String(data: existing.payload, encoding: .utf8) ?? ""
        let incomingPayload = SyncTextPayload.decodeText(from: change.payload)
        let remoteText = incomingPayload.text
        let baselineText = incomingPayload.baseText
            ?? remoteBaselines[key].flatMap { String(data: $0.payload, encoding: .utf8) }

        let context = SyncTextApplicationContext(
            entityType: change.entityType,
            entityID: change.entityID,
            fieldID: fieldID,
            localText: localText,
            remoteText: remoteText,
            baseText: baselineText,
            remoteUpdatedAt: change.updatedAt
        )

        if conflictStore.hasActiveConflict(entityType: change.entityType, entityID: change.entityID, fieldID: fieldID) {
            return preserveIncomingText(
                change: change,
                fieldID: fieldID,
                localText: localText,
                remoteText: remoteText
            )
        }

        switch SyncThreeWayTextMergePolicy.merge(base: baselineText, local: localText, remote: remoteText) {
        case .apply(let remoteText), .merged(let remoteText):
            if remoteText != localText,
               textApplicationGate(context) == .preserveForReview {
                return preserveIncomingText(
                    change: change,
                    fieldID: fieldID,
                    localText: localText,
                    remoteText: remoteText
                )
            }
            return .store(remoteText)
        case .noOp:
            return .store(localText)
        case .conflict:
            break
        }

        return preserveIncomingText(
            change: change,
            fieldID: fieldID,
            localText: localText,
            remoteText: remoteText
        )
    }

    private func preserveIncomingText(
        change: SyncChange,
        fieldID: String,
        localText: String,
        remoteText: String
    ) -> IncomingTextResolution {
        guard let conflict = SyncTextConflictPolicy.conflictIfTextDiverged(
            entityType: change.entityType,
            entityID: change.entityID,
            fieldID: fieldID,
            remoteOperation: change.operation,
            localText: localText,
            remoteText: remoteText,
            remoteUpdatedAt: change.updatedAt
        ) else { return .store(localText) }

        let conflictsBeforePreserve = conflictStore.activeConflicts()
        let conflicts = conflictStore.preserve(conflict)
        lastPreservedConflicts = [conflict]
        if conflicts == conflictsBeforePreserve,
           conflictStore.queuedConflict(
                entityType: change.entityType,
                entityID: change.entityID,
                fieldID: fieldID
           ) != nil {
            lastPreservedConflicts = []
        }
        return .conflict
    }
}

private enum IncomingTextResolution {
    case store(String)
    case conflict
}

private struct PendingTextBaseline {
    let text: String?
}

private struct RecordKey: Hashable {
    let type: SyncEntityType
    let id: String
}
