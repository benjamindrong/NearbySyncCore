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

public struct LegacyIncomingEnvelopePreparation: Equatable, Sendable {
    public let acknowledgedChangeIDs: [UUID]
    public let acknowledgedLocalChanges: [SyncChange]
    public let alreadyHandledChangeIDs: Set<UUID>
    public let candidateChanges: [SyncChange]

    public init(
        acknowledgedChangeIDs: [UUID],
        acknowledgedLocalChanges: [SyncChange],
        alreadyHandledChangeIDs: Set<UUID>,
        candidateChanges: [SyncChange]
    ) {
        self.acknowledgedChangeIDs = acknowledgedChangeIDs
        self.acknowledgedLocalChanges = acknowledgedLocalChanges
        self.alreadyHandledChangeIDs = alreadyHandledChangeIDs
        self.candidateChanges = candidateChanges
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

public struct SyncTextApplicationContext: Equatable, Sendable {
    public let entityType: SyncEntityType
    public let entityID: String
    public let fieldID: String
    public let localText: String
    public let remoteText: String
    public let baseText: String?
    public let remoteUpdatedAt: Date
    public let receivedAt: Date

    public init(
        entityType: SyncEntityType,
        entityID: String,
        fieldID: String,
        localText: String,
        remoteText: String,
        baseText: String?,
        remoteUpdatedAt: Date,
        receivedAt: Date = Date()
    ) {
        self.entityType = entityType
        self.entityID = entityID
        self.fieldID = fieldID
        self.localText = localText
        self.remoteText = remoteText
        self.baseText = baseText
        self.remoteUpdatedAt = remoteUpdatedAt
        self.receivedAt = receivedAt
    }
}

public enum SyncTextApplicationDecision: Equatable, Sendable {
    case allowAutomaticApply
    case preserveForReview
}

public typealias SyncTextApplicationGate = @Sendable (SyncTextApplicationContext) -> SyncTextApplicationDecision

public struct SyncTextTrackedBaseline: Equatable, Sendable {
    public let text: String?
    public let data: Data?
    public let originDeviceID: String?

    public init(text: String?, data: Data? = nil, originDeviceID: String?) {
        self.text = text
        self.data = data
        self.originDeviceID = originDeviceID
    }
}

public struct SyncTextSelectedBaseline: Equatable, Sendable {
    public let text: String?
    public let data: Data?
    public let matchesIncomingBase: Bool

    public init(text: String?, data: Data? = nil, matchesIncomingBase: Bool) {
        self.text = text
        self.data = data
        self.matchesIncomingBase = matchesIncomingBase
    }

    public func localHasDiverged(text localText: String, data localData: Data? = nil) -> Bool {
        localText != text || localData != data
    }
}

public enum SyncTextBaselineSelector {
    public static func select(
        trackedBaseline: SyncTextTrackedBaseline?,
        incomingBaseText: String?,
        incomingBaseData: Data? = nil,
        incomingOriginDeviceID: String
    ) -> SyncTextSelectedBaseline {
        guard let trackedBaseline else {
            return SyncTextSelectedBaseline(
                text: incomingBaseText,
                data: incomingBaseData,
                matchesIncomingBase: incomingBaseText == nil && incomingBaseData == nil
            )
        }

        if trackedBaseline.originDeviceID == incomingOriginDeviceID {
            // Same-peer edit bursts can carry a pre-burst base until they are
            // acknowledged. Prefer the receiver's applied same-peer baseline so
            // local churn arrives as continuation, not a false conflict.
            return SyncTextSelectedBaseline(
                text: trackedBaseline.text,
                data: trackedBaseline.data,
                matchesIncomingBase: true
            )
        }

        return SyncTextSelectedBaseline(
            text: incomingBaseText ?? trackedBaseline.text,
            data: incomingBaseData ?? trackedBaseline.data,
            matchesIncomingBase: incomingBaseText == trackedBaseline.text
                && incomingBaseData == trackedBaseline.data
        )
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

public struct SyncTextConflictResolution: Equatable, Sendable {
    public let resolvedText: String
    public let baseText: String
    public let resolvedData: Data?
    public let usesRemoteData: Bool

    public init(
        resolvedText: String,
        baseText: String,
        resolvedData: Data? = nil,
        usesRemoteData: Bool = false
    ) {
        self.resolvedText = resolvedText
        self.baseText = baseText
        self.resolvedData = resolvedData
        self.usesRemoteData = usesRemoteData
    }
}

public enum SyncTextConflictResolutionChoice: Equatable, Sendable {
    case keepLocal(currentLocalText: String, currentLocalData: Data? = nil)
    case acceptIncoming
    case merged(text: String, data: Data? = nil)
}

public enum SyncTextConflictResolver {
    public static func resolve(
        _ conflict: SyncTextConflictVersion,
        choice: SyncTextConflictResolutionChoice
    ) -> SyncTextConflictResolution {
        switch choice {
        case .keepLocal(let currentLocalText, let currentLocalData):
            return SyncTextConflictResolution(
                resolvedText: currentLocalText,
                baseText: conflict.remoteText,
                resolvedData: currentLocalData,
                usesRemoteData: false
            )

        case .acceptIncoming:
            return SyncTextConflictResolution(
                resolvedText: conflict.remoteText,
                baseText: conflict.localText,
                resolvedData: conflict.remoteData,
                usesRemoteData: true
            )

        case .merged(let text, let data):
            return SyncTextConflictResolution(
                resolvedText: text,
                baseText: conflict.remoteText,
                resolvedData: data,
                usesRemoteData: false
            )
        }
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

    func resolutionKeepingLocal(currentLocalText: String) -> SyncTextConflictResolution {
        SyncTextConflictResolver.resolve(
            self,
            choice: .keepLocal(currentLocalText: currentLocalText)
        )
    }

    func resolutionAcceptingIncoming() -> SyncTextConflictResolution {
        SyncTextConflictResolver.resolve(
            self,
            choice: .acceptIncoming
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
    case noOp
    case apply(text: String, patch: SyncTextPatch)
    case conflict

    public var mergedText: String? {
        switch self {
        case .apply(let text, _):
            text
        case .noOp, .conflict:
            nil
        }
    }

    public var patch: SyncTextPatch? {
        switch self {
        case .apply(_, let patch):
            patch
        case .noOp, .conflict:
            nil
        }
    }
}

public struct SyncTextPatch: Equatable, Sendable {
    public let range: NSRange
    public let replacement: String

    public init(range: NSRange, replacement: String) {
        self.range = range
        self.replacement = replacement
    }

    public func applying(to text: String) -> String? {
        let nsText = text as NSString
        guard NSMaxRange(range) <= nsText.length else { return nil }
        return nsText.replacingCharacters(in: range, with: replacement)
    }

    public static func from(local: String, to target: String) -> SyncTextPatch {
        var localStart = local.startIndex
        var targetStart = target.startIndex

        while localStart < local.endIndex,
              targetStart < target.endIndex,
              local[localStart] == target[targetStart] {
            local.formIndex(after: &localStart)
            target.formIndex(after: &targetStart)
        }

        var localEnd = local.endIndex
        var targetEnd = target.endIndex

        while localEnd > localStart,
              targetEnd > targetStart {
            let previousLocal = local.index(before: localEnd)
            let previousTarget = target.index(before: targetEnd)

            guard local[previousLocal] == target[previousTarget] else {
                break
            }

            localEnd = previousLocal
            targetEnd = previousTarget
        }

        return SyncTextPatch(
            range: NSRange(localStart..<localEnd, in: local),
            replacement: String(target[targetStart..<targetEnd])
        )
    }

    public static func delta(from base: String, to changed: String) -> SyncTextPatch {
        from(local: base, to: changed)
    }
}

public enum SyncThreeWayTextMergePolicy {
    public static func merge(base: String?, local: String, remote: String) -> SyncTextMergeResult {
        guard let base else {
            return local == remote ? .noOp : .conflict
        }
        if local == remote { return .noOp }
        if local == base { return .apply(text: remote, patch: SyncTextPatch.from(local: local, to: remote)) }
        if remote == base { return .noOp }
        guard let mergedText = nonOverlappingMerge(base: base, local: local, remote: remote) else {
            return .conflict
        }
        return .apply(text: mergedText, patch: SyncTextPatch.from(local: local, to: mergedText))
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

public struct SyncTextQueuedConflict: Codable, Equatable, Sendable {
    public let conflict: SyncTextConflictVersion
    public let queuedAt: Date

    public init(conflict: SyncTextConflictVersion, queuedAt: Date = Date()) {
        self.conflict = conflict
        self.queuedAt = queuedAt
    }
}

public struct SyncTextConflictCommitEffects: Sendable, Equatable {
    public let preservedConflicts: [SyncTextConflictVersion]
    public let removedConflictIDs: [UUID]
    public let removedResolvedConflicts: [SyncTextConflictVersion]

    public init(
        preservedConflicts: [SyncTextConflictVersion] = [],
        removedConflictIDs: [UUID] = [],
        removedResolvedConflicts: [SyncTextConflictVersion] = []
    ) {
        self.preservedConflicts = preservedConflicts
        self.removedConflictIDs = removedConflictIDs
        self.removedResolvedConflicts = removedResolvedConflicts
    }
}

public final class SyncTextConflictStore: @unchecked Sendable {
    public struct FileIO: Sendable {
        var fileExists: @Sendable (String) -> Bool
        var readData: @Sendable (URL) throws -> Data
        var createDirectory: @Sendable (URL) throws -> Void
        var writeData: @Sendable (Data, URL) throws -> Void
        var removeItem: @Sendable (URL) throws -> Void

        public init(
            fileExists: @escaping @Sendable (String) -> Bool,
            readData: @escaping @Sendable (URL) throws -> Data,
            createDirectory: @escaping @Sendable (URL) throws -> Void,
            writeData: @escaping @Sendable (Data, URL) throws -> Void,
            removeItem: @escaping @Sendable (URL) throws -> Void
        ) {
            self.fileExists = fileExists
            self.readData = readData
            self.createDirectory = createDirectory
            self.writeData = writeData
            self.removeItem = removeItem
        }

        public static let live = FileIO(
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            readData: { try Data(contentsOf: $0) },
            createDirectory: {
                try FileManager.default.createDirectory(
                    at: $0,
                    withIntermediateDirectories: true
                )
            },
            writeData: { data, url in try data.write(to: url, options: [.atomic]) },
            removeItem: { try FileManager.default.removeItem(at: $0) }
        )
    }

    private let fileURL: URL
    private let fileIO: FileIO
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public convenience init(fileURL: URL) {
        self.init(fileURL: fileURL, fileIO: .live)
    }

    public init(fileURL: URL, fileIO: FileIO) {
        self.fileURL = fileURL
        self.fileIO = fileIO
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
        let conflicts = activeConflicts()
        if conflicts.contains(where: { Self.isExactRemoteMatch($0, conflict) }) {
            return conflicts
        }
        if conflicts.contains(where: { sameLogicalConflict($0, conflict) }) {
            queue(conflict)
            return conflicts
        }

        // A text field can only have one reviewable conflict at a time. Newer
        // updates for that field wait behind the stable review snapshot.
        var updatedConflicts = conflicts
        updatedConflicts.append(conflict)
        _ = saveConflicts(updatedConflicts)
        return activeConflicts()
    }

    public func commitChecked(_ effects: SyncTextConflictCommitEffects) throws {
        for conflict in effects.removedResolvedConflicts {
            try removeResolvedConflictChecked(conflict)
        }
        for conflictID in effects.removedConflictIDs {
            try removeConflictChecked(id: conflictID)
        }
        for conflict in effects.preservedConflicts {
            try preserveChecked(conflict)
        }
    }

    public func hasActiveConflict(entityType: SyncEntityType, entityID: String, fieldID: String, now: Date = Date()) -> Bool {
        activeConflicts(now: now).contains {
            $0.entityType == entityType
                && $0.entityID == entityID
                && $0.fieldID == fieldID
        }
    }

    public func queuedConflict(entityType: SyncEntityType, entityID: String, fieldID: String) -> SyncTextQueuedConflict? {
        loadQueuedConflicts().first {
            $0.conflict.entityType == entityType
                && $0.conflict.entityID == entityID
                && $0.conflict.fieldID == fieldID
        }
    }

    public func queuedConflicts() -> [SyncTextQueuedConflict] {
        loadQueuedConflicts()
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
        removeQueuedConflict(matching: conflict)
        return remainingConflicts
    }

    private func loadConflicts() -> [SyncTextConflictVersion] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? decoder.decode([SyncTextConflictVersion].self, from: data)) ?? []
    }

    private func loadConflictsChecked() throws -> [SyncTextConflictVersion] {
        guard fileIO.fileExists(fileURL.path) else { return [] }
        let data = try fileIO.readData(fileURL)
        return try decoder.decode([SyncTextConflictVersion].self, from: data)
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
            try saveConflictsChecked(conflicts)
            return SyncPersistenceResult(didPersist: true)
        } catch {
            return SyncPersistenceResult(didPersist: false, errorDescription: String(describing: error))
        }
    }

    private func saveConflictsChecked(_ conflicts: [SyncTextConflictVersion]) throws {
        try fileIO.createDirectory(fileURL.deletingLastPathComponent())
        let data = try encoder.encode(conflicts)
        try fileIO.writeData(data, fileURL)
    }

    @discardableResult
    private func preserveChecked(_ conflict: SyncTextConflictVersion) throws -> [SyncTextConflictVersion] {
        guard try !isResolvedChecked(conflict) else {
            return try activeConflictsChecked()
        }
        let conflicts = try activeConflictsChecked()
        if conflicts.contains(where: { Self.isExactRemoteMatch($0, conflict) }) {
            return conflicts
        }
        if conflicts.contains(where: { sameLogicalConflict($0, conflict) }) {
            try queueChecked(conflict)
            return conflicts
        }

        var updatedConflicts = conflicts
        updatedConflicts.append(conflict)
        try saveConflictsChecked(updatedConflicts)
        return try activeConflictsChecked()
    }

    @discardableResult
    private func removeConflictChecked(id: UUID) throws -> [SyncTextConflictVersion] {
        let conflicts = try activeConflictsChecked().filter { $0.id != id }
        try saveConflictsChecked(conflicts)
        return conflicts
    }

    @discardableResult
    private func removeResolvedConflictChecked(_ conflict: SyncTextConflictVersion) throws -> [SyncTextConflictVersion] {
        let conflicts = try activeConflictsChecked()
        let resolvedConflicts = conflicts.filter {
            sameLogicalConflict($0, conflict) || sameRemoteConflict($0, conflict)
        }
        for resolvedConflict in resolvedConflicts {
            try recordResolvedConflictChecked(resolvedConflict)
        }
        if !resolvedConflicts.contains(where: { $0.id == conflict.id }) {
            try recordResolvedConflictChecked(conflict)
        }
        let remainingConflicts = conflicts.filter {
            !sameLogicalConflict($0, conflict) && !sameRemoteConflict($0, conflict)
        }
        try saveConflictsChecked(remainingConflicts)
        try removeQueuedConflictChecked(matching: conflict)
        return remainingConflicts
    }

    private func activeConflictsChecked(now: Date = Date()) throws -> [SyncTextConflictVersion] {
        let active = try loadConflictsChecked().filter { $0.expiresAt > now }
        try saveConflictsChecked(active)
        return active.sorted {
            if $0.preservedAt == $1.preservedAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.preservedAt > $1.preservedAt
        }
    }

    private func isResolved(_ conflict: SyncTextConflictVersion, now: Date = Date()) -> Bool {
        loadResolvedConflicts(now: now).contains {
            sameRemoteConflict($0, conflict)
        }
    }

    private func isResolvedChecked(_ conflict: SyncTextConflictVersion, now: Date = Date()) throws -> Bool {
        try loadResolvedConflictsChecked(now: now).contains {
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

    private func recordResolvedConflictChecked(_ conflict: SyncTextConflictVersion, now: Date = Date()) throws {
        var resolvedConflicts = try loadResolvedConflictsChecked(now: now)
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
        try saveResolvedConflictsChecked(resolvedConflicts)
    }

    private func loadResolvedConflicts(now: Date = Date()) -> [SyncTextResolvedConflict] {
        guard let data = try? Data(contentsOf: resolvedFileURL) else { return [] }
        let resolvedConflicts = ((try? decoder.decode([SyncTextResolvedConflict].self, from: data)) ?? [])
            .filter { $0.expiresAt > now }
        _ = saveResolvedConflicts(resolvedConflicts)
        return resolvedConflicts
    }

    private func loadResolvedConflictsChecked(now: Date = Date()) throws -> [SyncTextResolvedConflict] {
        guard fileIO.fileExists(resolvedFileURL.path) else { return [] }
        let data = try fileIO.readData(resolvedFileURL)
        let resolvedConflicts = try decoder.decode([SyncTextResolvedConflict].self, from: data)
            .filter { $0.expiresAt > now }
        try saveResolvedConflictsChecked(resolvedConflicts)
        return resolvedConflicts
    }

    @discardableResult
    private func saveResolvedConflicts(_ resolvedConflicts: [SyncTextResolvedConflict]) -> SyncPersistenceResult {
        do {
            try saveResolvedConflictsChecked(resolvedConflicts)
            return SyncPersistenceResult(didPersist: true)
        } catch {
            return SyncPersistenceResult(didPersist: false, errorDescription: String(describing: error))
        }
    }

    private func saveResolvedConflictsChecked(_ resolvedConflicts: [SyncTextResolvedConflict]) throws {
        try fileIO.createDirectory(resolvedFileURL.deletingLastPathComponent())
        let data = try encoder.encode(resolvedConflicts)
        try fileIO.writeData(data, resolvedFileURL)
    }

    public static func isExactRemoteMatch(
        _ lhs: SyncTextConflictVersion,
        _ rhs: SyncTextConflictVersion
    ) -> Bool {
        lhs.entityType == rhs.entityType
            && lhs.entityID == rhs.entityID
            && lhs.fieldID == rhs.fieldID
            && lhs.remoteUpdatedAt == rhs.remoteUpdatedAt
            && lhs.remoteText == rhs.remoteText
            && lhs.remoteData == rhs.remoteData
    }

    private func sameRemoteConflict(_ lhs: SyncTextConflictVersion, _ rhs: SyncTextConflictVersion) -> Bool {
        Self.isExactRemoteMatch(lhs, rhs)
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

    private func queue(_ conflict: SyncTextConflictVersion, queuedAt: Date = Date()) {
        var queuedConflicts = loadQueuedConflicts()
        queuedConflicts.removeAll { sameLogicalConflict($0.conflict, conflict) }
        queuedConflicts.append(SyncTextQueuedConflict(conflict: conflict, queuedAt: queuedAt))
        _ = saveQueuedConflicts(queuedConflicts)
    }

    private func queueChecked(_ conflict: SyncTextConflictVersion, queuedAt: Date = Date()) throws {
        var queuedConflicts = try loadQueuedConflictsChecked()
        queuedConflicts.removeAll { sameLogicalConflict($0.conflict, conflict) }
        queuedConflicts.append(SyncTextQueuedConflict(conflict: conflict, queuedAt: queuedAt))
        try saveQueuedConflictsChecked(queuedConflicts)
    }

    private func removeQueuedConflict(matching conflict: SyncTextConflictVersion) {
        let queuedConflicts = loadQueuedConflicts().filter {
            !sameLogicalConflict($0.conflict, conflict)
        }
        _ = saveQueuedConflicts(queuedConflicts)
    }

    private func removeQueuedConflictChecked(matching conflict: SyncTextConflictVersion) throws {
        let queuedConflicts = try loadQueuedConflictsChecked().filter {
            !sameLogicalConflict($0.conflict, conflict)
        }
        try saveQueuedConflictsChecked(queuedConflicts)
    }

    private func loadQueuedConflicts() -> [SyncTextQueuedConflict] {
        guard let data = try? Data(contentsOf: queuedFileURL) else { return [] }
        return (try? decoder.decode([SyncTextQueuedConflict].self, from: data)) ?? []
    }

    private func loadQueuedConflictsChecked() throws -> [SyncTextQueuedConflict] {
        guard fileIO.fileExists(queuedFileURL.path) else { return [] }
        let data = try fileIO.readData(queuedFileURL)
        return try decoder.decode([SyncTextQueuedConflict].self, from: data)
    }

    @discardableResult
    private func saveQueuedConflicts(_ queuedConflicts: [SyncTextQueuedConflict]) -> SyncPersistenceResult {
        do {
            try saveQueuedConflictsChecked(queuedConflicts)
            return SyncPersistenceResult(didPersist: true)
        } catch {
            return SyncPersistenceResult(didPersist: false, errorDescription: String(describing: error))
        }
    }

    private func saveQueuedConflictsChecked(_ queuedConflicts: [SyncTextQueuedConflict]) throws {
        try fileIO.createDirectory(queuedFileURL.deletingLastPathComponent())
        let data = try encoder.encode(queuedConflicts)
        try fileIO.writeData(data, queuedFileURL)
    }

    private var resolvedFileURL: URL {
        fileURL.deletingLastPathComponent()
            .appendingPathComponent("sync-resolved-conflicts.json")
    }

    private var queuedFileURL: URL {
        fileURL.deletingLastPathComponent()
            .appendingPathComponent("sync-queued-conflicts.json")
    }

    /// Captures the exact on-disk bytes backing active, resolved, and queued
    /// conflict state. Intended for callers that must speculatively apply an
    /// incoming change (which may write conflict metadata as a side effect)
    /// and roll back that write if a separate, later persistence step fails.
    public func snapshot() throws -> SyncTextConflictStoreSnapshot {
        SyncTextConflictStoreSnapshot(
            conflicts: try snapshotState(for: fileURL),
            resolved: try snapshotState(for: resolvedFileURL),
            queued: try snapshotState(for: queuedFileURL)
        )
    }

    /// Restores exactly the on-disk bytes captured by `snapshot()`, including
    /// removing a file that did not exist at snapshot time.
    public func restore(_ snapshot: SyncTextConflictStoreSnapshot) throws {
        try restore(snapshot.conflicts, to: fileURL)
        try restore(snapshot.resolved, to: resolvedFileURL)
        try restore(snapshot.queued, to: queuedFileURL)
    }

    private func snapshotState(for url: URL) throws -> SyncFileSnapshotState {
        guard fileIO.fileExists(url.path) else {
            return .absent
        }
        do {
            return .present(try fileIO.readData(url))
        } catch {
            throw SyncTextConflictStoreSnapshotError.captureFailed(path: url.path)
        }
    }

    private func restore(_ state: SyncFileSnapshotState, to url: URL) throws {
        do {
            switch state {
            case .absent:
                if fileIO.fileExists(url.path) {
                    try fileIO.removeItem(url)
                }
            case .present(let data):
                try fileIO.createDirectory(url.deletingLastPathComponent())
                try fileIO.writeData(data, url)
            }
        } catch {
            throw SyncTextConflictStoreSnapshotError.restoreFailed(path: url.path)
        }
    }
}

public enum SyncFileSnapshotState: Sendable, Equatable {
    case absent
    case present(Data)
}

public enum SyncTextConflictStoreSnapshotError: Error, Equatable {
    case captureFailed(path: String)
    case restoreFailed(path: String)
}

public struct SyncTextConflictStoreSnapshot: Sendable, Equatable {
    public let conflicts: SyncFileSnapshotState
    public let resolved: SyncFileSnapshotState
    public let queued: SyncFileSnapshotState
}
