import Foundation

public enum SyncEntityType: String, Codable, CaseIterable, Sendable {
    case item
    case collection
    case marker
    case attachment
}

public enum SyncOperation: String, Codable, Sendable {
    case upsert
    case delete
}

public struct SyncChange: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let entityType: SyncEntityType
    public let entityID: String
    public let operation: SyncOperation
    public let payload: Data
    public let updatedAt: Date
    public let originDeviceID: String

    public init(
        id: UUID = UUID(),
        entityType: SyncEntityType,
        entityID: String,
        operation: SyncOperation,
        payload: Data,
        updatedAt: Date,
        originDeviceID: String
    ) {
        self.id = id
        self.entityType = entityType
        self.entityID = entityID
        self.operation = operation
        self.payload = payload
        self.updatedAt = updatedAt
        self.originDeviceID = originDeviceID
    }
}

public struct SyncEnvelope: Codable, Equatable, Sendable {
    public let senderDeviceID: String
    public let sentAt: Date
    public let changes: [SyncChange]
    public let acknowledgedChangeIDs: [UUID]

    public init(
        senderDeviceID: String,
        sentAt: Date = Date(),
        changes: [SyncChange],
        acknowledgedChangeIDs: [UUID] = []
    ) {
        self.senderDeviceID = senderDeviceID
        self.sentAt = sentAt
        self.changes = changes
        self.acknowledgedChangeIDs = acknowledgedChangeIDs
    }

    private enum CodingKeys: String, CodingKey {
        case senderDeviceID
        case sentAt
        case changes
        case acknowledgedChangeIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        senderDeviceID = try container.decode(String.self, forKey: .senderDeviceID)
        sentAt = try container.decode(Date.self, forKey: .sentAt)
        changes = try container.decode([SyncChange].self, forKey: .changes)
        acknowledgedChangeIDs = try container.decodeIfPresent([UUID].self, forKey: .acknowledgedChangeIDs) ?? []
    }
}

public struct SyncRecord: Equatable, Sendable {
    public let entityType: SyncEntityType
    public let entityID: String
    public var payload: Data
    public var updatedAt: Date
    public var isDeleted: Bool

    public init(
        entityType: SyncEntityType,
        entityID: String,
        payload: Data,
        updatedAt: Date,
        isDeleted: Bool = false
    ) {
        self.entityType = entityType
        self.entityID = entityID
        self.payload = payload
        self.updatedAt = updatedAt
        self.isDeleted = isDeleted
    }
}

public struct SyncApplyResult: Equatable, Sendable {
    public var appliedChangeIDs: [UUID]
    public var ignoredDuplicateIDs: [UUID]
    public var ignoredStaleIDs: [UUID]

    public init(
        appliedChangeIDs: [UUID] = [],
        ignoredDuplicateIDs: [UUID] = [],
        ignoredStaleIDs: [UUID] = []
    ) {
        self.appliedChangeIDs = appliedChangeIDs
        self.ignoredDuplicateIDs = ignoredDuplicateIDs
        self.ignoredStaleIDs = ignoredStaleIDs
    }
}

public struct SyncTextConflictVersion: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let entityType: SyncEntityType
    public let entityID: String
    public let fieldID: String
    public let remoteOperation: SyncOperation
    public let localText: String
    public let remoteText: String
    public let remoteData: Data?
    public let remoteUpdatedAt: Date
    public let preservedAt: Date
    public let expiresAt: Date

    public init(
        id: UUID = UUID(),
        entityType: SyncEntityType,
        entityID: String,
        fieldID: String,
        remoteOperation: SyncOperation = .upsert,
        localText: String,
        remoteText: String,
        remoteData: Data? = nil,
        remoteUpdatedAt: Date,
        preservedAt: Date = Date(),
        expiresAt: Date
    ) {
        self.id = id
        self.entityType = entityType
        self.entityID = entityID
        self.fieldID = fieldID
        self.remoteOperation = remoteOperation
        self.localText = localText
        self.remoteText = remoteText
        self.remoteData = remoteData
        self.remoteUpdatedAt = remoteUpdatedAt
        self.preservedAt = preservedAt
        self.expiresAt = expiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case entityType
        case entityID
        case fieldID
        case remoteOperation
        case localText
        case remoteText
        case remoteData
        case remoteUpdatedAt
        case preservedAt
        case expiresAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        entityType = try container.decode(SyncEntityType.self, forKey: .entityType)
        entityID = try container.decode(String.self, forKey: .entityID)
        fieldID = try container.decode(String.self, forKey: .fieldID)
        remoteOperation = try container.decodeIfPresent(SyncOperation.self, forKey: .remoteOperation) ?? .upsert
        localText = try container.decode(String.self, forKey: .localText)
        remoteText = try container.decode(String.self, forKey: .remoteText)
        remoteData = try container.decodeIfPresent(Data.self, forKey: .remoteData)
        remoteUpdatedAt = try container.decode(Date.self, forKey: .remoteUpdatedAt)
        preservedAt = try container.decode(Date.self, forKey: .preservedAt)
        expiresAt = try container.decode(Date.self, forKey: .expiresAt)
    }
}

public enum SyncTextConflictPolicy {
    public static let retention: TimeInterval = 7 * 24 * 60 * 60

    public static func conflictIfTextDiverged(
        entityType: SyncEntityType,
        entityID: String,
        fieldID: String,
        remoteOperation: SyncOperation = .upsert,
        localText: String,
        remoteText: String,
        remoteData: Data? = nil,
        localData: Data? = nil,
        remoteUpdatedAt: Date,
        preservedAt: Date = Date()
    ) -> SyncTextConflictVersion? {
        guard localText != remoteText || localData != remoteData else { return nil }
        return SyncTextConflictVersion(
            entityType: entityType,
            entityID: entityID,
            fieldID: fieldID,
            remoteOperation: remoteOperation,
            localText: localText,
            remoteText: remoteText,
            remoteData: remoteData,
            remoteUpdatedAt: remoteUpdatedAt,
            preservedAt: preservedAt,
            expiresAt: preservedAt.addingTimeInterval(retention)
        )
    }
}

public final class SyncTextConflictStore: @unchecked Sendable {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func activeConflicts(now: Date = Date()) -> [SyncTextConflictVersion] {
        let active = loadConflicts().filter { $0.expiresAt > now }
        saveConflicts(active)
        return active.sorted {
            if $0.preservedAt == $1.preservedAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.preservedAt > $1.preservedAt
        }
    }

    public func preserve(_ conflict: SyncTextConflictVersion) -> [SyncTextConflictVersion] {
        var conflicts = activeConflicts()
        if let index = conflicts.firstIndex(where: {
            $0.entityType == conflict.entityType
                && $0.entityID == conflict.entityID
                && $0.fieldID == conflict.fieldID
                && $0.remoteUpdatedAt == conflict.remoteUpdatedAt
                && $0.remoteText == conflict.remoteText
                && $0.remoteData == conflict.remoteData
        }) {
            conflicts[index] = conflict
        } else {
            conflicts.append(conflict)
        }
        saveConflicts(conflicts)
        return activeConflicts()
    }

    public func removeConflict(id: UUID) -> [SyncTextConflictVersion] {
        let conflicts = activeConflicts().filter { $0.id != id }
        saveConflicts(conflicts)
        return conflicts
    }

    private func loadConflicts() -> [SyncTextConflictVersion] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? decoder.decode([SyncTextConflictVersion].self, from: data)) ?? []
    }

    private func saveConflicts(_ conflicts: [SyncTextConflictVersion]) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(conflicts)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            assertionFailure("Unable to persist sync text conflicts: \(error)")
        }
    }
}
