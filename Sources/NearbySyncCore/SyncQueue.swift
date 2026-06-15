import Foundation

public actor SyncQueue {
    private var pendingChanges: [SyncChange] = []
    private var appliedChangeIDs: Set<UUID> = []
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

    public func acknowledgementBatch(limit: Int = 100) -> [UUID] {
        Array(pendingAcknowledgementIDs.prefix(limit))
    }

    public func markAcknowledged(_ acknowledgedChangeIDs: [UUID]) {
        let acknowledgedIDs = Set(acknowledgedChangeIDs)
        pendingChanges.removeAll { acknowledgedIDs.contains($0.id) }
        pendingAcknowledgementIDs.subtract(acknowledgedIDs)
        persistPendingChanges()
    }

    public func hasApplied(_ changeID: UUID) -> Bool {
        appliedChangeIDs.contains(changeID)
    }

    public func markApplied(_ changeID: UUID) {
        appliedChangeIDs.insert(changeID)
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
