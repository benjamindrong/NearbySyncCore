import Foundation

public actor SyncQueue {
    private var pendingChanges: [SyncChange] = []
    // Applied IDs are persisted so a peer restart cannot replay the same remote
    // change and re-trigger app-level side effects or duplicate conflicts.
    private var appliedChangeIDs: Set<UUID> = []
    // Acknowledgements are queued separately from content changes. They may be
    // sent in an ack-only envelope and removed once transport confirms send.
    private var pendingAcknowledgementIDs: Set<UUID> = []
    private let persistence: SyncQueuePersistence?
    private var health: SyncQueuePersistenceHealth

    public init(persistence: SyncQueuePersistence? = nil) {
        self.persistence = persistence
        let loadResult = persistence?.loadSnapshotResult() ?? SyncQueuePersistenceLoadResult(
            snapshot: SyncQueueSnapshot(),
            health: .healthy
        )
        pendingChanges = loadResult.snapshot.pendingChanges
        appliedChangeIDs = Set(loadResult.snapshot.appliedChangeIDs)
        pendingAcknowledgementIDs = Set(loadResult.snapshot.pendingAcknowledgementIDs)
        health = loadResult.health
    }

    public func enqueue(_ change: SyncChange) {
        // Collapse pending local edits by entity. The queue represents latest
        // document state for a target, not every intermediate typing event.
        if let existingIndex = pendingChanges.firstIndex(where: { $0.syncTarget == change.syncTarget }) {
            pendingChanges[existingIndex] = change
            persistPendingChanges()
            return
        }
        pendingChanges.append(change)
        persistPendingChanges()
    }

    public func enqueue(_ changes: [SyncChange]) {
        for change in changes {
            enqueue(change)
        }
    }

    public func enqueueSuccessor(
        _ change: SyncChange,
        preserving predecessorID: UUID
    ) throws {
        let matchingPredecessorIndices = pendingChanges.indices.filter {
            pendingChanges[$0].id == predecessorID
        }
        guard matchingPredecessorIndices.count == 1,
              let predecessorIndex = matchingPredecessorIndices.first else {
            throw SyncQueueProtectedSuccessorError.predecessorMissingOrDuplicated
        }

        let predecessor = pendingChanges[predecessorIndex]
        guard predecessor.syncTarget == change.syncTarget else {
            throw SyncQueueProtectedSuccessorError.targetMismatch
        }

        let sameTargetIndices = pendingChanges.indices.filter {
            pendingChanges[$0].syncTarget == change.syncTarget
        }
        let successorIndices = sameTargetIndices.filter { $0 != predecessorIndex }
        guard successorIndices.count <= 1,
              successorIndices.allSatisfy({ $0 > predecessorIndex }) else {
            throw SyncQueueProtectedSuccessorError.invalidExistingTargetState
        }

        let previousPendingChanges = pendingChanges
        if let successorIndex = successorIndices.first {
            pendingChanges[successorIndex] = change
        } else {
            pendingChanges.insert(change, at: predecessorIndex + 1)
        }

        let result = persistPendingChanges()
        guard result.didPersist else {
            pendingChanges = previousPendingChanges
            throw SyncQueueProtectedSuccessorError.persistenceFailed
        }
    }

    public func reorderPendingChanges(withIDsInOrder changeIDs: [UUID]) throws {
        guard Set(changeIDs).count == changeIDs.count else {
            throw SyncQueuePendingOrderError.duplicateRequestedChangeID
        }
        guard !changeIDs.isEmpty else { return }

        let selectedIDs = Set(changeIDs)
        let selectedEntries = pendingChanges.enumerated().filter {
            selectedIDs.contains($0.element.id)
        }
        guard selectedEntries.count == changeIDs.count else {
            throw SyncQueuePendingOrderError.missingRequestedChangeID
        }

        let entryByID = Dictionary(uniqueKeysWithValues: selectedEntries.map { ($0.element.id, $0.element) })
        guard entryByID.count == changeIDs.count else {
            throw SyncQueuePendingOrderError.duplicatePendingChangeID
        }
        let orderedSelected = changeIDs.compactMap { entryByID[$0] }
        guard orderedSelected.count == changeIDs.count,
              let earliestSelectedIndex = selectedEntries.map(\.offset).min() else {
            throw SyncQueuePendingOrderError.missingRequestedChangeID
        }

        let insertionIndex = pendingChanges[..<earliestSelectedIndex].filter {
            !selectedIDs.contains($0.id)
        }.count
        var reordered = pendingChanges.filter { !selectedIDs.contains($0.id) }
        reordered.insert(contentsOf: orderedSelected, at: insertionIndex)

        guard reordered != pendingChanges else { return }

        let previousPendingChanges = pendingChanges
        pendingChanges = reordered
        let result = persistPendingChanges()
        guard result.didPersist else {
            pendingChanges = previousPendingChanges
            throw SyncQueuePendingOrderError.persistenceFailed
        }
    }

    public func pendingBatch(
        limit: Int = 100,
        excludingTargets: Set<SyncTarget> = []
    ) -> [SyncChange] {
        guard limit > 0 else { return [] }

        var result: [SyncChange] = []
        var seenTargets: Set<SyncTarget> = []

        for change in pendingChanges {
            let target = change.syncTarget
            guard seenTargets.insert(target).inserted else { continue }
            guard !excludingTargets.contains(target) else { continue }

            result.append(change)
            if result.count == limit {
                break
            }
        }

        return result
    }

    public func pendingChanges(withIDs changeIDs: [UUID]) -> [SyncChange] {
        let ids = Set(changeIDs)
        return pendingChanges.filter { ids.contains($0.id) }
    }

    public func acknowledgementBatch(limit: Int = 100) -> [UUID] {
        Array(pendingAcknowledgementIDs.prefix(limit))
    }

    public func markAcknowledged(_ acknowledgedChangeIDs: [UUID]) {
        let acknowledgedIDs = Set(acknowledgedChangeIDs)
        pendingChanges.removeAll { acknowledgedIDs.contains($0.id) }
        // If a peer acknowledges an acknowledgement-only envelope, drop those
        // ack IDs too; there is no useful retry once both sides have seen them.
        pendingAcknowledgementIDs.subtract(acknowledgedIDs)
        persistPendingChanges()
    }

    public func hasApplied(_ changeID: UUID) -> Bool {
        appliedChangeIDs.contains(changeID)
    }

    public func markApplied(_ changeID: UUID) {
        commitAppliedChangeIDsBestEffort([changeID])
    }

    /// Strict two-phase commit. Persists handled and pending-acknowledgement
    /// state atomically; rolls back both in-memory sets and throws if
    /// persistence fails, so the caller must not acknowledge the change and
    /// redelivery will present it as a candidate again.
    public func commitAppliedChangeIDs(_ changeIDs: [UUID]) throws {
        let previousAppliedChangeIDs = appliedChangeIDs
        let previousPendingAcknowledgementIDs = pendingAcknowledgementIDs
        appliedChangeIDs.formUnion(changeIDs)
        // Applying a remote change never creates a local content change. The
        // only outbound work generated here is metadata saying it was received.
        pendingAcknowledgementIDs.formUnion(changeIDs)
        let result = persistPendingChanges()
        guard result.didPersist else {
            appliedChangeIDs = previousAppliedChangeIDs
            pendingAcknowledgementIDs = previousPendingAcknowledgementIDs
            throw SyncHandledStateCommitError.persistenceFailed
        }
    }

    /// Compatibility best-effort commit for `applyIncomingEnvelope(_:)\` and
    /// other legacy consumers that do not observe a thrown error. Unlike
    /// `commitAppliedChangeIDs(_:)\`, in-memory handled/pending-acknowledgement
    /// state is retained even when persistence fails, matching the previous
    /// `markApplied(_:)\` behavior. Persistence failure is surfaced only
    /// through `persistenceHealth()\`.
    public func commitAppliedChangeIDsBestEffort(_ changeIDs: [UUID]) {
        appliedChangeIDs.formUnion(changeIDs)
        pendingAcknowledgementIDs.formUnion(changeIDs)
        persistPendingChanges()
    }

    public func markAcknowledgementSent(_ changeIDs: [UUID]) {
        pendingAcknowledgementIDs.subtract(changeIDs)
        persistPendingChanges()
    }

    public func pendingCount() -> Int {
        pendingChanges.count
    }

    public func snapshot() -> SyncQueueSnapshot {
        currentSnapshot()
    }

    public func persistenceHealth() -> SyncQueuePersistenceHealth {
        health
    }

    public func replaceSnapshot(_ replacement: SyncQueueSnapshot) throws {
        switch health {
        case .healthy, .fileMissing:
            break
        case .corrupt, .readFailed:
            throw SyncQueueReplacementError.unhealthyPersistence
        }

        guard let persistence else {
            assignSnapshot(replacement)
            health = .healthy
            return
        }

        let result = persistence.saveSnapshot(replacement)
        guard result.didPersist else {
            health = .readFailed(result.errorDescription ?? "Unknown persistence failure")
            throw SyncQueueReplacementError.persistenceFailed
        }

        assignSnapshot(replacement)
        health = .healthy
    }

    @discardableResult
    private func persistPendingChanges() -> SyncPersistenceResult {
        guard let persistence else {
            health = .healthy
            return SyncPersistenceResult(didPersist: true)
        }

        let result = persistence.saveSnapshot(currentSnapshot())
        if result.didPersist {
            health = .healthy
        } else {
            health = .readFailed(result.errorDescription ?? "Unknown persistence failure")
        }
        return result
    }

    private func currentSnapshot() -> SyncQueueSnapshot {
        SyncQueueSnapshot(
            pendingChanges: pendingChanges,
            appliedChangeIDs: Array(appliedChangeIDs),
            pendingAcknowledgementIDs: Array(pendingAcknowledgementIDs)
        )
    }

    private func assignSnapshot(_ snapshot: SyncQueueSnapshot) {
        pendingChanges = snapshot.pendingChanges
        appliedChangeIDs = Set(snapshot.appliedChangeIDs)
        pendingAcknowledgementIDs = Set(snapshot.pendingAcknowledgementIDs)
    }
}

public protocol SyncQueuePersistence: Sendable {
    func loadSnapshotResult() -> SyncQueuePersistenceLoadResult
    func saveSnapshot(_ snapshot: SyncQueueSnapshot) -> SyncPersistenceResult
}

public enum SyncQueuePersistenceHealth: Equatable, Sendable {
    case healthy
    case fileMissing
    case corrupt
    case readFailed(String)
}

public struct SyncQueuePersistenceLoadResult: Equatable, Sendable {
    public let snapshot: SyncQueueSnapshot
    public let health: SyncQueuePersistenceHealth

    public init(snapshot: SyncQueueSnapshot, health: SyncQueuePersistenceHealth) {
        self.snapshot = snapshot
        self.health = health
    }
}

public enum SyncQueueReplacementError: Error, Equatable {
    case persistenceFailed
    case unhealthyPersistence
}

public enum SyncQueuePendingOrderError: Error, Equatable {
    case duplicateRequestedChangeID
    case missingRequestedChangeID
    case duplicatePendingChangeID
    case persistenceFailed
}

public enum SyncQueueProtectedSuccessorError: Error, Equatable {
    case predecessorMissingOrDuplicated
    case targetMismatch
    case invalidExistingTargetState
    case persistenceFailed
}

/// Thrown by the strict `commitAppliedChangeIDs(_:)\` two-phase commit when
/// handled/pending-acknowledgement state cannot be durably persisted.
public enum SyncHandledStateCommitError: Error, Equatable {
    case persistenceFailed
}

public struct SyncQueueSnapshot: Codable, Equatable, Sendable {
    // Snapshot shape is intentionally broader than "pending changes" so restart
    // behavior preserves duplicate detection and pending acknowledgements.
    public var pendingChanges: [SyncChange]
    public var appliedChangeIDs: [UUID]
    public var pendingAcknowledgementIDs: [UUID]

    public init(
        pendingChanges: [SyncChange] = [],
        appliedChangeIDs: [UUID] = [],
        pendingAcknowledgementIDs: [UUID] = []
    ) {
        self.pendingChanges = pendingChanges
        self.appliedChangeIDs = appliedChangeIDs
        self.pendingAcknowledgementIDs = pendingAcknowledgementIDs
    }
}

public final class FileBackedSyncQueuePersistence: SyncQueuePersistence, @unchecked Sendable {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func loadSnapshotResult() -> SyncQueuePersistenceLoadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return SyncQueuePersistenceLoadResult(snapshot: SyncQueueSnapshot(), health: .fileMissing)
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            return SyncQueuePersistenceLoadResult(
                snapshot: SyncQueueSnapshot(),
                health: .readFailed(String(describing: error))
            )
        }

        if let snapshot = try? decoder.decode(SyncQueueSnapshot.self, from: data) {
            return SyncQueuePersistenceLoadResult(snapshot: snapshot, health: .healthy)
        }
        // MYR-71 wrote a bare [SyncChange]. Keep reading that legacy queue so
        // existing installs do not lose unsent local edits on upgrade.
        if let legacyChanges = try? decoder.decode([SyncChange].self, from: data) {
            return SyncQueuePersistenceLoadResult(
                snapshot: SyncQueueSnapshot(pendingChanges: legacyChanges),
                health: .healthy
            )
        }
        return SyncQueuePersistenceLoadResult(snapshot: SyncQueueSnapshot(), health: .corrupt)
    }

    public func saveSnapshot(_ snapshot: SyncQueueSnapshot) -> SyncPersistenceResult {
        do {
            let directoryURL = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(snapshot)
            try data.write(to: fileURL, options: [.atomic])
            return SyncPersistenceResult(didPersist: true)
        } catch {
            return SyncPersistenceResult(didPersist: false, errorDescription: String(describing: error))
        }
    }
}

public struct SyncTarget: Hashable, Sendable {
    public let entityType: SyncEntityType
    public let entityID: String

    public init(entityType: SyncEntityType, entityID: String) {
        self.entityType = entityType
        self.entityID = entityID
    }
}

private extension SyncChange {
    var syncTarget: SyncTarget {
        SyncTarget(entityType: entityType, entityID: entityID)
    }
}
