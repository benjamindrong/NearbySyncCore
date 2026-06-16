import Foundation

public enum SyncEntityType: String, Codable, CaseIterable, Sendable {
    case item
    case collection
    case marker
    case attachment
    case conflict
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

public struct SyncTextPayload: Codable, Equatable, Sendable {
    public let text: String
    public let baseText: String?

    public init(text: String, baseText: String? = nil) {
        self.text = text
        self.baseText = baseText
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func decodeText(from data: Data) -> SyncTextPayload {
        if let payload = try? JSONDecoder().decode(SyncTextPayload.self, from: data) {
            return payload
        }
        return SyncTextPayload(text: String(data: data, encoding: .utf8) ?? "", baseText: nil)
    }
}

public struct SyncApplyResult: Equatable, Sendable {
    public var appliedChangeIDs: [UUID]
    public var ignoredDuplicateIDs: [UUID]
    public var ignoredStaleIDs: [UUID]
    public var acknowledgedChangeIDs: [UUID]
    public var acknowledgedLocalChanges: [SyncChange]
    public var preservedConflicts: [SyncTextConflictVersion]

    public init(
        appliedChangeIDs: [UUID] = [],
        ignoredDuplicateIDs: [UUID] = [],
        ignoredStaleIDs: [UUID] = [],
        acknowledgedChangeIDs: [UUID] = [],
        acknowledgedLocalChanges: [SyncChange] = [],
        preservedConflicts: [SyncTextConflictVersion] = []
    ) {
        self.appliedChangeIDs = appliedChangeIDs
        self.ignoredDuplicateIDs = ignoredDuplicateIDs
        self.ignoredStaleIDs = ignoredStaleIDs
        self.acknowledgedChangeIDs = acknowledgedChangeIDs
        self.acknowledgedLocalChanges = acknowledgedLocalChanges
        self.preservedConflicts = preservedConflicts
    }
}

public enum SyncTextConflictAction: String, Codable, Sendable {
    case preserved
    case resolved
}

public struct SyncTextConflictPayload: Codable, Equatable, Sendable {
    public let action: SyncTextConflictAction
    public let conflict: SyncTextConflictVersion?
    public let conflictID: UUID
    public let resolvedText: String?
    public let baseText: String?
    public let updatedAt: Date

    public init(
        action: SyncTextConflictAction,
        conflict: SyncTextConflictVersion,
        resolvedText: String? = nil,
        baseText: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.action = action
        self.conflict = conflict
        conflictID = conflict.id
        self.resolvedText = resolvedText
        self.baseText = baseText
        self.updatedAt = updatedAt
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func decode(from data: Data) throws -> SyncTextConflictPayload {
        try JSONDecoder().decode(SyncTextConflictPayload.self, from: data)
    }
}

public struct SyncPersistenceResult: Equatable, Sendable {
    public let didPersist: Bool
    public let errorDescription: String?

    public init(didPersist: Bool, errorDescription: String? = nil) {
        self.didPersist = didPersist
        self.errorDescription = errorDescription
    }

    public static let skipped = SyncPersistenceResult(didPersist: true)
}

public struct SyncTextConflictVersion: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let entityType: SyncEntityType
    public let entityID: String
    public let fieldID: String
    public let contextID: String?
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
        contextID: String? = nil,
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
        self.contextID = contextID
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
        case contextID
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
        contextID = try container.decodeIfPresent(String.self, forKey: .contextID)
        remoteOperation = try container.decodeIfPresent(SyncOperation.self, forKey: .remoteOperation) ?? .upsert
        localText = try container.decode(String.self, forKey: .localText)
        remoteText = try container.decode(String.self, forKey: .remoteText)
        remoteData = try container.decodeIfPresent(Data.self, forKey: .remoteData)
        remoteUpdatedAt = try container.decode(Date.self, forKey: .remoteUpdatedAt)
        preservedAt = try container.decode(Date.self, forKey: .preservedAt)
        expiresAt = try container.decode(Date.self, forKey: .expiresAt)
    }
}

public struct SyncTextConflictPerspective: Equatable, Sendable {
    public let localText: String
    public let versionToSyncText: String

    public init(localText: String, versionToSyncText: String) {
        self.localText = localText
        self.versionToSyncText = versionToSyncText
    }
}

public extension SyncTextConflictVersion {
    func perspectiveForPeerPreservedConflict(currentLocalText: String) -> SyncTextConflictPerspective {
        if localText == remoteText {
            return SyncTextConflictPerspective(
                localText: currentLocalText,
                versionToSyncText: remoteText
            )
        }

        return SyncTextConflictPerspective(
            localText: currentLocalText,
            versionToSyncText: localText
        )
    }

    func normalizedForPeerPreservedConflict(
        currentLocalText: String,
        remoteUpdatedAt: Date? = nil
    ) -> SyncTextConflictVersion {
        let perspective = perspectiveForPeerPreservedConflict(currentLocalText: currentLocalText)
        return SyncTextConflictVersion(
            id: id,
            entityType: entityType,
            entityID: entityID,
            fieldID: fieldID,
            contextID: contextID,
            remoteOperation: remoteOperation,
            localText: perspective.localText,
            remoteText: perspective.versionToSyncText,
            remoteData: nil,
            remoteUpdatedAt: remoteUpdatedAt ?? preservedAt,
            preservedAt: preservedAt,
            expiresAt: expiresAt
        )
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

public enum SyncTextMergeResult: Equatable, Sendable {
    case apply(remoteText: String)
    case noOp
    case merged(String)
    case conflict

    public var mergedText: String? {
        switch self {
        case .apply(let remoteText), .merged(let remoteText):
            remoteText
        case .noOp, .conflict:
            nil
        }
    }
}

public enum SyncThreeWayTextMergePolicy {
    public static func merge(base: String?, local: String, remote: String) -> SyncTextMergeResult {
        guard let base else {
            return local == remote ? .noOp : .conflict
        }
        if local == remote { return .noOp }
        if local == base { return .apply(remoteText: remote) }
        if remote == base { return .noOp }
        return nonOverlappingMerge(base: base, local: local, remote: remote).map(SyncTextMergeResult.merged) ?? .conflict
    }

    private static func nonOverlappingMerge(base: String, local: String, remote: String) -> String? {
        let baseCharacters = Array(base)
        let localChange = changedRange(base: baseCharacters, changed: Array(local))
        let remoteChange = changedRange(base: baseCharacters, changed: Array(remote))
        guard localChange.lowerBound != remoteChange.lowerBound else { return nil }
        guard !localChange.overlaps(remoteChange) else { return nil }

        if remoteChange.upperBound <= localChange.lowerBound {
            let beforeRemote = String(baseCharacters[..<remoteChange.lowerBound])
            let middle = String(baseCharacters[remoteChange.upperBound..<localChange.lowerBound])
            let afterLocal = String(baseCharacters[localChange.upperBound...])
            return beforeRemote + remoteChange.replacement + middle + localChange.replacement + afterLocal
        }

        let beforeLocal = String(baseCharacters[..<localChange.lowerBound])
        let middle = String(baseCharacters[localChange.upperBound..<remoteChange.lowerBound])
        let afterRemote = String(baseCharacters[remoteChange.upperBound...])
        return beforeLocal + localChange.replacement + middle + remoteChange.replacement + afterRemote
    }

    private static func changedRange(base: [Character], changed: [Character]) -> TextChangeRange {
        var prefix = 0
        while prefix < base.count,
              prefix < changed.count,
              base[prefix] == changed[prefix] {
            prefix += 1
        }

        var suffixBase = base.count
        var suffixChanged = changed.count
        while suffixBase > prefix,
              suffixChanged > prefix,
              base[suffixBase - 1] == changed[suffixChanged - 1] {
            suffixBase -= 1
            suffixChanged -= 1
        }

        return TextChangeRange(
            lowerBound: prefix,
            upperBound: suffixBase,
            replacement: String(changed[prefix..<suffixChanged])
        )
    }
}

private struct TextChangeRange {
    let lowerBound: Int
    let upperBound: Int
    let replacement: String

    func overlaps(_ other: TextChangeRange) -> Bool {
        lowerBound < other.upperBound && other.lowerBound < upperBound
    }
}

private struct SyncTextResolvedConflict: Codable, Equatable {
    let entityType: SyncEntityType
    let entityID: String
    let fieldID: String
    let localText: String?
    let remoteText: String
    let remoteData: Data?
    let remoteUpdatedAt: Date
    let resolvedAt: Date
    let expiresAt: Date

    private enum CodingKeys: String, CodingKey {
        case entityType
        case entityID
        case fieldID
        case localText
        case remoteText
        case remoteData
        case remoteUpdatedAt
        case resolvedAt
        case expiresAt
    }

    init(
        entityType: SyncEntityType,
        entityID: String,
        fieldID: String,
        localText: String?,
        remoteText: String,
        remoteData: Data?,
        remoteUpdatedAt: Date,
        resolvedAt: Date,
        expiresAt: Date
    ) {
        self.entityType = entityType
        self.entityID = entityID
        self.fieldID = fieldID
        self.localText = localText
        self.remoteText = remoteText
        self.remoteData = remoteData
        self.remoteUpdatedAt = remoteUpdatedAt
        self.resolvedAt = resolvedAt
        self.expiresAt = expiresAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entityType = try container.decode(SyncEntityType.self, forKey: .entityType)
        entityID = try container.decode(String.self, forKey: .entityID)
        fieldID = try container.decode(String.self, forKey: .fieldID)
        localText = try container.decodeIfPresent(String.self, forKey: .localText)
        remoteText = try container.decode(String.self, forKey: .remoteText)
        remoteData = try container.decodeIfPresent(Data.self, forKey: .remoteData)
        remoteUpdatedAt = try container.decode(Date.self, forKey: .remoteUpdatedAt)
        resolvedAt = try container.decode(Date.self, forKey: .resolvedAt)
        expiresAt = try container.decode(Date.self, forKey: .expiresAt)
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
        _ = saveConflicts(active)
        return active.sorted {
            if $0.preservedAt == $1.preservedAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.preservedAt > $1.preservedAt
        }
    }

    public func preserve(_ conflict: SyncTextConflictVersion) -> [SyncTextConflictVersion] {
        guard !isResolved(conflict) else {
            return activeConflicts()
        }
        // A text field can only have one reviewable conflict at a time. Newer
        // preserved metadata replaces stale rows for the same entity field.
        var conflicts = activeConflicts().filter { !sameLogicalConflict($0, conflict) }
        conflicts.append(conflict)
        _ = saveConflicts(conflicts)
        return activeConflicts()
    }

    public func removeConflict(id: UUID) -> [SyncTextConflictVersion] {
        let conflicts = activeConflicts().filter { $0.id != id }
        _ = saveConflicts(conflicts)
        return conflicts
    }

    public func removeResolvedConflict(_ conflict: SyncTextConflictVersion) -> [SyncTextConflictVersion] {
        let conflicts = activeConflicts()
        // Resolving a conflict is terminal for the whole entity field, not just
        // the tapped row. This clears duplicate preserved rows from stale sync.
        let resolvedConflicts = conflicts.filter {
            sameLogicalConflict($0, conflict) || sameRemoteConflict($0, conflict)
        }
        for resolvedConflict in resolvedConflicts {
            recordResolvedConflict(resolvedConflict)
        }
        if !resolvedConflicts.contains(where: { $0.id == conflict.id }) {
            recordResolvedConflict(conflict)
        }
        let remainingConflicts = conflicts.filter {
            !sameLogicalConflict($0, conflict) && !sameRemoteConflict($0, conflict)
        }
        _ = saveConflicts(remainingConflicts)
        return remainingConflicts
    }

    private func loadConflicts() -> [SyncTextConflictVersion] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? decoder.decode([SyncTextConflictVersion].self, from: data)) ?? []
    }

    @discardableResult
    public func replaceConflicts(_ conflicts: [SyncTextConflictVersion]) -> SyncPersistenceResult {
        saveConflicts(conflicts)
    }

    @discardableResult
    public func saveConflictsForTesting(_ conflicts: [SyncTextConflictVersion]) -> SyncPersistenceResult {
        replaceConflicts(conflicts)
    }

    @discardableResult
    private func saveConflicts(_ conflicts: [SyncTextConflictVersion]) -> SyncPersistenceResult {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(conflicts)
            try data.write(to: fileURL, options: [.atomic])
            return SyncPersistenceResult(didPersist: true)
        } catch {
            return SyncPersistenceResult(didPersist: false, errorDescription: String(describing: error))
        }
    }

    private func isResolved(_ conflict: SyncTextConflictVersion, now: Date = Date()) -> Bool {
        loadResolvedConflicts(now: now).contains {
            sameRemoteConflict($0, conflict)
        }
    }

    private func recordResolvedConflict(_ conflict: SyncTextConflictVersion, now: Date = Date()) {
        var resolvedConflicts = loadResolvedConflicts(now: now)
        let resolvedConflict = SyncTextResolvedConflict(
            entityType: conflict.entityType,
            entityID: conflict.entityID,
            fieldID: conflict.fieldID,
            localText: conflict.localText,
            remoteText: conflict.remoteText,
            remoteData: conflict.remoteData,
            remoteUpdatedAt: conflict.remoteUpdatedAt,
            resolvedAt: now,
            expiresAt: now.addingTimeInterval(SyncTextConflictPolicy.retention)
        )
        if let index = resolvedConflicts.firstIndex(where: { sameRemoteConflict($0, conflict) }) {
            resolvedConflicts[index] = resolvedConflict
        } else {
            resolvedConflicts.append(resolvedConflict)
        }
        _ = saveResolvedConflicts(resolvedConflicts)
    }

    private func loadResolvedConflicts(now: Date = Date()) -> [SyncTextResolvedConflict] {
        guard let data = try? Data(contentsOf: resolvedFileURL) else { return [] }
        let resolvedConflicts = ((try? decoder.decode([SyncTextResolvedConflict].self, from: data)) ?? [])
            .filter { $0.expiresAt > now }
        _ = saveResolvedConflicts(resolvedConflicts)
        return resolvedConflicts
    }

    @discardableResult
    private func saveResolvedConflicts(_ resolvedConflicts: [SyncTextResolvedConflict]) -> SyncPersistenceResult {
        do {
            try FileManager.default.createDirectory(
                at: resolvedFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(resolvedConflicts)
            try data.write(to: resolvedFileURL, options: [.atomic])
            return SyncPersistenceResult(didPersist: true)
        } catch {
            return SyncPersistenceResult(didPersist: false, errorDescription: String(describing: error))
        }
    }

    private func sameRemoteConflict(_ lhs: SyncTextConflictVersion, _ rhs: SyncTextConflictVersion) -> Bool {
        lhs.entityType == rhs.entityType
            && lhs.entityID == rhs.entityID
            && lhs.fieldID == rhs.fieldID
            && lhs.remoteUpdatedAt == rhs.remoteUpdatedAt
            && lhs.remoteText == rhs.remoteText
            && lhs.remoteData == rhs.remoteData
    }

    private func sameLogicalConflict(_ lhs: SyncTextConflictVersion, _ rhs: SyncTextConflictVersion) -> Bool {
        lhs.entityType == rhs.entityType
            && lhs.entityID == rhs.entityID
            && lhs.fieldID == rhs.fieldID
    }

    private func sameRemoteConflict(_ lhs: SyncTextResolvedConflict, _ rhs: SyncTextConflictVersion) -> Bool {
        guard lhs.entityType == rhs.entityType,
              lhs.entityID == rhs.entityID,
              lhs.fieldID == rhs.fieldID else {
            return false
        }
        let sameOrientation = lhs.remoteUpdatedAt == rhs.remoteUpdatedAt
            && lhs.remoteText == rhs.remoteText
        let reversedOrientation = lhs.localText == rhs.remoteText
            && lhs.remoteText == rhs.localText
        return sameOrientation || reversedOrientation
    }

    private var resolvedFileURL: URL {
        fileURL.deletingLastPathComponent()
            .appendingPathComponent("sync-resolved-conflicts.json")
    }
}
