import XCTest
@testable import NearbySyncCore

final class MYR223QueueOrderingFailureTests: XCTestCase {
    func testSelectedIDReorderingPersistenceFailureRestoresPriorPendingState() async {
        let first = makeChange(entityID: "first", timestamp: 1)
        let second = makeChange(entityID: "second", timestamp: 2)
        let third = makeChange(entityID: "third", timestamp: 3)
        let initial = SyncQueueSnapshot(pendingChanges: [first, second, third])
        let queue = SyncQueue(
            persistence: MYR223ReorderFailingPersistence(initial: initial)
        )

        do {
            try await queue.reorderPendingChanges(withIDsInOrder: [third.id, second.id])
            XCTFail("Expected persistence failure")
        } catch {
            XCTAssertEqual(error as? SyncQueuePendingOrderError, .persistenceFailed)
        }

        let snapshot = await queue.snapshot()
        XCTAssertEqual(snapshot.pendingChanges, initial.pendingChanges)
    }

    private func makeChange(entityID: String, timestamp: TimeInterval) -> SyncChange {
        SyncChange(
            entityType: .collection,
            entityID: entityID,
            operation: .upsert,
            payload: Data(entityID.utf8),
            updatedAt: Date(timeIntervalSince1970: timestamp),
            originDeviceID: "device-a"
        )
    }
}

private final class MYR223ReorderFailingPersistence: SyncQueuePersistence, @unchecked Sendable {
    private let initial: SyncQueueSnapshot

    init(initial: SyncQueueSnapshot) {
        self.initial = initial
    }

    func loadSnapshotResult() -> SyncQueuePersistenceLoadResult {
        SyncQueuePersistenceLoadResult(snapshot: initial, health: .healthy)
    }

    func saveSnapshot(_ snapshot: SyncQueueSnapshot) -> SyncPersistenceResult {
        SyncPersistenceResult(didPersist: false, errorDescription: "Injected failure")
    }
}
