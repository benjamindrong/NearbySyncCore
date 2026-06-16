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

        _ = await store.apply(change)
        await queue.enqueue(change)
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

    public func applyIncomingEnvelope(_ envelope: SyncEnvelope) async -> SyncApplyResult {
        // Ack metadata is terminal queue state. It is processed before content
        // so a mixed envelope can clear old sends even if new changes are stale.
        let acknowledgedLocalChanges = await acknowledgeChanges(envelope.acknowledgedChangeIDs)

        var result = SyncApplyResult(
            acknowledgedChangeIDs: envelope.acknowledgedChangeIDs,
            acknowledgedLocalChanges: acknowledgedLocalChanges
        )

        for change in envelope.changes {
            if await queue.hasApplied(change.id) {
                result.ignoredDuplicateIDs.append(change.id)
                continue
            }

            await queue.markApplied(change.id)
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
        }

        return result
    }

    public func markAcknowledgementSent(_ changeIDs: [UUID]) async {
        await queue.markAcknowledgementSent(changeIDs)
    }

    public func pendingChangeCount() async -> Int {
        await queue.pendingCount()
    }

    public func records() async -> [SyncRecord] {
        await store.allRecords()
    }

    public func record(for entityType: SyncEntityType, entityID: String) async -> SyncRecord? {
        await store.record(for: entityType, entityID: entityID)
    }
}
