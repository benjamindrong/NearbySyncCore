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

    public init(persistence: SyncQueuePersistence? = nil) {
        self.persistence = persistence
        let snapshot = persistence?.loadSnapshot() ?? SyncQueueSnapshot()
        pendingChanges = snapshot.pendingChanges
        appliedChangeIDs = Set(snapshot.appliedChangeIDs)
        pendingAcknowledgementIDs = Set(snapshot.pendingAcknowledgementIDs)
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

    public func pendingBatch(limit: Int = 100) -> [SyncChange] {
        Array(pendingChanges.prefix(limit))
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
        appliedChangeIDs.insert(changeID)
        // Applying a remote change never creates a local content change. The
        // only outbound work generated here is metadata saying it was received.
        pendingAcknowledgementIDs.insert(changeID)
        persistPendingChanges()
    }

    public func markAcknowledgementSent(_ changeIDs: [UUID]) {
        pendingAcknowledgementIDs.subtract(changeIDs)
        persistPendingChanges()
    }

    public func pendingCount() -> Int {
        pendingChanges.count
    }

    private func persistPendingChanges() {
        _ = persistence?.saveSnapshot(
            SyncQueueSnapshot(
                pendingChanges: pendingChanges,
                appliedChangeIDs: Array(appliedChangeIDs),
                pendingAcknowledgementIDs: Array(pendingAcknowledgementIDs)
            )
        )
    }
}

public protocol SyncQueuePersistence: Sendable {
    func loadSnapshot() -> SyncQueueSnapshot
    func saveSnapshot(_ snapshot: SyncQueueSnapshot) -> SyncPersistenceResult
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

    public func loadSnapshot() -> SyncQueueSnapshot {
        guard let data = try? Data(contentsOf: fileURL) else { return SyncQueueSnapshot() }
        if let snapshot = try? decoder.decode(SyncQueueSnapshot.self, from: data) {
            return snapshot
        }
        // MYR-71 wrote a bare [SyncChange]. Keep reading that legacy queue so
        // existing installs do not lose unsent local edits on upgrade.
        if let legacyChanges = try? decoder.decode([SyncChange].self, from: data) {
            return SyncQueueSnapshot(pendingChanges: legacyChanges)
        }
        return SyncQueueSnapshot()
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

private extension SyncChange {
    var syncTarget: SyncTarget {
        SyncTarget(entityType: entityType, entityID: entityID)
    }
}

private struct SyncTarget: Hashable {
    let entityType: SyncEntityType
    let entityID: String
}
