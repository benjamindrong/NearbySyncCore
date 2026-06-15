import Foundation

public actor SyncQueue {
    private var pendingChanges: [SyncChange] = []
    private var appliedChangeIDs: Set<UUID> = []
    private let persistence: SyncQueuePersistence?

    public init(persistence: SyncQueuePersistence? = nil) {
        self.persistence = persistence
        pendingChanges = persistence?.loadPendingChanges() ?? []
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

    public func markAcknowledged(_ acknowledgedChangeIDs: [UUID]) {
        let acknowledgedIDs = Set(acknowledgedChangeIDs)
        pendingChanges.removeAll { acknowledgedIDs.contains($0.id) }
        persistPendingChanges()
    }

    public func hasApplied(_ changeID: UUID) -> Bool {
        appliedChangeIDs.contains(changeID)
    }

    public func markApplied(_ changeID: UUID) {
        appliedChangeIDs.insert(changeID)
    }

    public func pendingCount() -> Int {
        pendingChanges.count
    }

    private func persistPendingChanges() {
        persistence?.savePendingChanges(pendingChanges)
    }
}

public protocol SyncQueuePersistence: Sendable {
    func loadPendingChanges() -> [SyncChange]
    func savePendingChanges(_ changes: [SyncChange])
}

public final class FileBackedSyncQueuePersistence: SyncQueuePersistence, @unchecked Sendable {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func loadPendingChanges() -> [SyncChange] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? decoder.decode([SyncChange].self, from: data)) ?? []
    }

    public func savePendingChanges(_ changes: [SyncChange]) {
        do {
            let directoryURL = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(changes)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            assertionFailure("Unable to persist sync queue: \(error)")
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
