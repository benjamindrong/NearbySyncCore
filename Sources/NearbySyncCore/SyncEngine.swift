import Foundation

public final class SyncEngine: @unchecked Sendable {
    public let deviceID: String
    private let store: SyncStore
    private let queue: SyncQueue

    public init(deviceID: String, store: SyncStore, queue: SyncQueue = SyncQueue()) {
        self.deviceID = deviceID
        self.store = store
        self.queue = queue
    }

    public func recordLocalChange(
        entityType: SyncEntityType,
        entityID: String,
        operation: SyncOperation = .upsert,
        payload: Data,
        updatedAt: Date = Date()
    ) async -> SyncChange {
        let change = SyncChange(
            entityType: entityType,
            entityID: entityID,
            operation: operation,
            payload: payload,
            updatedAt: updatedAt,
            originDeviceID: deviceID
        )

        let didApply = await store.apply(change)
        if didApply {
            await queue.enqueue(change)
        }
        return change
    }

    public func nextEnvelope(limit: Int = 100) async -> SyncEnvelope? {
        let changes = await queue.pendingBatch(limit: limit)
        let acknowledgements = await queue.acknowledgementBatch(limit: limit)
        guard !changes.isEmpty || !acknowledgements.isEmpty else { return nil }
        // Envelopes may carry content, acknowledgements, or both. This keeps the
        // public acknowledgedChangeIDs API meaningful without requiring a local
        // content edit just to clear a peer's send queue.
        return SyncEnvelope(
            senderDeviceID: deviceID,
            changes: changes,
            acknowledgedChangeIDs: acknowledgements
        )
    }

    @discardableResult
    public func acknowledgeChanges(_ changeIDs: [UUID]) async -> [SyncChange] {
        let acknowledgedLocalChanges = await queue.pendingChanges(withIDs: changeIDs)
        await store.markLocalChangesAcknowledged(acknowledgedLocalChanges)
        await queue.markAcknowledged(changeIDs)
        return acknowledgedLocalChanges
    }

    public func prepareIncomingEnvelope(_ envelope: SyncEnvelope) async -> LegacyIncomingEnvelopePreparation {
        // Ack metadata is terminal queue state. It is processed before content
        // so a mixed envelope can clear old sends even if new changes are stale.
        let acknowledgedLocalChanges = await acknowledgeChanges(envelope.acknowledgedChangeIDs)

        var alreadyHandledChangeIDs: Set<UUID> = []
        var candidateChanges: [SyncChange] = []

        for change in envelope.changes.sorted(by: syncApplyOrder) {
            if await queue.hasApplied(change.id) {
                alreadyHandledChangeIDs.insert(change.id)
                continue
            }
            candidateChanges.append(change)
        }

        return LegacyIncomingEnvelopePreparation(
            acknowledgedChangeIDs: envelope.acknowledgedChangeIDs,
            acknowledgedLocalChanges: acknowledgedLocalChanges,
            alreadyHandledChangeIDs: alreadyHandledChangeIDs,
            candidateChanges: candidateChanges
        )
    }

    public func commitHandledIncomingChanges(_ changeIDs: Set<UUID>) async throws {
        try await queue.commitAppliedChangeIDs(Array(changeIDs))
    }

    public func applyIncomingEnvelope(_ envelope: SyncEnvelope) async -> SyncApplyResult {
        let preparation = await prepareIncomingEnvelope(envelope)

        var result = SyncApplyResult(
            ignoredDuplicateIDs: Array(preparation.alreadyHandledChangeIDs),
            acknowledgedChangeIDs: preparation.acknowledgedChangeIDs,
            acknowledgedLocalChanges: preparation.acknowledgedLocalChanges
        )

        // Every fully processed candidate is terminal here, whether the store
        // applied it or rejected it as stale: the legacy compatibility API has
        // no way to ask the host to reconsider a stale change, so leaving it
        // unhandled would redeliver it forever instead of converging.
        var handledChangeIDs: Set<UUID> = []
        for change in preparation.candidateChanges {
            // Store application is deliberately one-way. If a host app wants to
            // publish a follow-up edit, it must call recordLocalChange itself.
            let didApply = await store.apply(change)
            let preservedConflicts = await store.preservedConflictsForLastApply()
            result.preservedConflicts.append(contentsOf: preservedConflicts)

            if didApply {
                result.appliedChangeIDs.append(change.id)
            } else {
                result.ignoredStaleIDs.append(change.id)
            }
            handledChangeIDs.insert(change.id)
        }
        // Best-effort commit: this compatibility API has no thrown-error
        // surface, so persistence failure is retained in memory and exposed
        // only through queuePersistenceHealth(), matching prior markApplied
        // behavior rather than rolling back and silently discarding a change
        // this call already reported as applied/stale to the caller.
        await queue.commitAppliedChangeIDsBestEffort(Array(handledChangeIDs))

        return result
    }

    private func syncApplyOrder(_ lhs: SyncChange, _ rhs: SyncChange) -> Bool {
        if lhs.isResolvedConflictMetadata != rhs.isResolvedConflictMetadata {
            return lhs.isResolvedConflictMetadata
        }
        return lhs.updatedAt < rhs.updatedAt
    }

    public func markAcknowledgementSent(_ changeIDs: [UUID]) async {
        await queue.markAcknowledgementSent(changeIDs)
    }

    public func pendingChangeCount() async -> Int {
        await queue.pendingCount()
    }

    public func queueSnapshot() async -> SyncQueueSnapshot {
        await queue.snapshot()
    }

    public func queuePersistenceHealth() async -> SyncQueuePersistenceHealth {
        await queue.persistenceHealth()
    }

    public func replaceQueueSnapshot(_ snapshot: SyncQueueSnapshot) async throws {
        try await queue.replaceSnapshot(snapshot)
    }

    public func records() async -> [SyncRecord] {
        await store.allRecords()
    }

    public func record(for entityType: SyncEntityType, entityID: String) async -> SyncRecord? {
        await store.record(for: entityType, entityID: entityID)
    }
}

private extension SyncChange {
    var isResolvedConflictMetadata: Bool {
        guard entityType == .conflict,
              let payload = try? SyncTextConflictPayload.decode(from: payload) else {
            return false
        }
        return payload.action == .resolved
    }
}
