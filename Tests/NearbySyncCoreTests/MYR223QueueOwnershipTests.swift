import XCTest
@testable import NearbySyncCore

final class MYR223QueueOwnershipTests: XCTestCase {
    func testCallerSuppliedLocalChangePreservesExactIdentityAndRejectsForeignOrigin() async {
        let store = InMemorySyncStore()
        let engine = SyncEngine(deviceID: "device-a", store: store)
        let supplied = SyncChange(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            entityType: .collection,
            entityID: "folder-1",
            operation: .upsert,
            payload: Data("frozen-folder".utf8),
            updatedAt: Date(timeIntervalSince1970: 123),
            originDeviceID: "device-a"
        )

        let admitted = await engine.recordLocalChange(supplied)
        let snapshot = await engine.queueSnapshot()

        XCTAssertTrue(admitted)
        XCTAssertEqual(snapshot.pendingChanges, [supplied])

        let foreign = SyncChange(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            entityType: .collection,
            entityID: "folder-2",
            operation: .upsert,
            payload: Data("foreign".utf8),
            updatedAt: Date(timeIntervalSince1970: 124),
            originDeviceID: "device-b"
        )
        let foreignAdmitted = await engine.recordLocalChange(foreign)
        let afterForeignSnapshot = await engine.queueSnapshot()

        XCTAssertFalse(foreignAdmitted)
        XCTAssertEqual(afterForeignSnapshot.pendingChanges, [supplied])
    }

    func testCallerSuppliedStaleChangeDoesNotManufactureQueueOwnership() async {
        let store = InMemorySyncStore(seedRecords: [
            SyncRecord(
                entityType: .collection,
                entityID: "folder-1",
                payload: Data("newer".utf8),
                updatedAt: Date(timeIntervalSince1970: 200)
            )
        ])
        let engine = SyncEngine(deviceID: "device-a", store: store)
        let stale = SyncChange(
            entityType: .collection,
            entityID: "folder-1",
            operation: .upsert,
            payload: Data("older".utf8),
            updatedAt: Date(timeIntervalSince1970: 100),
            originDeviceID: "device-a"
        )

        let admitted = await engine.recordLocalChange(stale)
        let snapshot = await engine.queueSnapshot()

        XCTAssertFalse(admitted)
        XCTAssertTrue(snapshot.pendingChanges.isEmpty)
    }

    func testSelectedIDReorderingPersistsRequestedBlockWithoutDisturbingUnselectedOrder() async throws {
        let fileURL = temporaryQueueURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let first = makeChange(type: .collection, entityID: "first", timestamp: 1)
        let second = makeChange(type: .collection, entityID: "second", timestamp: 2)
        let third = makeChange(type: .collection, entityID: "third", timestamp: 3)
        let fourth = makeChange(type: .collection, entityID: "fourth", timestamp: 4)
        let queue = SyncQueue(persistence: FileBackedSyncQueuePersistence(fileURL: fileURL))

        await queue.enqueue([first, second, third, fourth])
        try await queue.reorderPendingChanges(withIDsInOrder: [fourth.id, second.id])

        let expected = [first, fourth, second, third]
        let snapshot = await queue.snapshot()
        XCTAssertEqual(snapshot.pendingChanges, expected)

        let restarted = SyncQueue(persistence: FileBackedSyncQueuePersistence(fileURL: fileURL))
        let restartedSnapshot = await restarted.snapshot()
        XCTAssertEqual(restartedSnapshot.pendingChanges, expected)
    }

    func testSelectedIDReorderingFailsClosedWhenRequestedWitnessIsMissing() async {
        let first = makeChange(type: .collection, entityID: "first", timestamp: 1)
        let second = makeChange(type: .collection, entityID: "second", timestamp: 2)
        let queue = SyncQueue()
        await queue.enqueue([first, second])

        do {
            try await queue.reorderPendingChanges(withIDsInOrder: [first.id, UUID()])
            XCTFail("Expected missing witness to fail")
        } catch {
            XCTAssertEqual(error as? SyncQueuePendingOrderError, .missingRequestedChangeID)
        }

        let snapshot = await queue.snapshot()
        XCTAssertEqual(snapshot.pendingChanges, [first, second])
    }

    func testProtectedSuccessorCoalescesWithoutReplacingPredecessor() async throws {
        let predecessor = makeChange(type: .attachment, entityID: "attachment-1", timestamp: 1)
        let unrelated = makeChange(type: .collection, entityID: "folder-2", timestamp: 2)
        let firstSuccessor = makeChange(type: .attachment, entityID: "attachment-1", timestamp: 3)
        let latestSuccessor = makeChange(type: .attachment, entityID: "attachment-1", timestamp: 4)
        let queue = SyncQueue()

        await queue.enqueue([predecessor, unrelated])
        try await queue.enqueueSuccessor(firstSuccessor, preserving: predecessor.id)
        try await queue.enqueueSuccessor(latestSuccessor, preserving: predecessor.id)

        let snapshot = await queue.snapshot()
        XCTAssertEqual(snapshot.pendingChanges, [predecessor, latestSuccessor, unrelated])

        let pending = await queue.pendingBatch(limit: 100)
        XCTAssertEqual(pending, [predecessor, unrelated])
    }

    func testProtectedPredecessorAcknowledgementPromotesPersistedSuccessor() async throws {
        let queue = SyncQueue()
        let engine = SyncEngine(deviceID: "device-a", store: InMemorySyncStore(), queue: queue)
        let predecessor = makeChange(type: .marker, entityID: "pin-1", timestamp: 1)
        let successor = makeChange(type: .marker, entityID: "pin-1", timestamp: 2)

        let predecessorAdmitted = await engine.recordLocalChange(predecessor)
        let successorAdmitted = try await engine.recordLocalSuccessorChange(
            successor,
            preserving: predecessor.id
        )
        XCTAssertTrue(predecessorAdmitted)
        XCTAssertTrue(successorAdmitted)

        let firstEnvelope = try XCTUnwrap(await engine.nextEnvelope())
        XCTAssertEqual(firstEnvelope.changes, [predecessor])

        _ = await engine.acknowledgeChanges([predecessor.id])

        let secondEnvelope = try XCTUnwrap(await engine.nextEnvelope())
        XCTAssertEqual(secondEnvelope.changes, [successor])
    }

    func testProtectedPairSurvivesRestartWithPredecessorStillFirst() async throws {
        let fileURL = temporaryQueueURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let predecessor = makeChange(type: .collection, entityID: "folder-1", timestamp: 1)
        let successor = makeChange(type: .collection, entityID: "folder-1", timestamp: 2)
        let firstQueue = SyncQueue(persistence: FileBackedSyncQueuePersistence(fileURL: fileURL))

        await firstQueue.enqueue(predecessor)
        try await firstQueue.enqueueSuccessor(successor, preserving: predecessor.id)

        let restarted = SyncQueue(persistence: FileBackedSyncQueuePersistence(fileURL: fileURL))
        let restartedSnapshot = await restarted.snapshot()
        XCTAssertEqual(restartedSnapshot.pendingChanges, [predecessor, successor])

        let beforeAck = await restarted.pendingBatch()
        XCTAssertEqual(beforeAck, [predecessor])

        await restarted.markAcknowledged([predecessor.id])

        let afterAck = await restarted.pendingBatch()
        XCTAssertEqual(afterAck, [successor])
    }

    func testFilteredEarliestPerTargetSelectionScansPastProtectedTarget() async throws {
        let queue = SyncQueue()
        let engine = SyncEngine(deviceID: "device-a", store: InMemorySyncStore(), queue: queue)
        let predecessor = makeChange(type: .item, entityID: "note-1", timestamp: 1)
        let successor = makeChange(type: .item, entityID: "note-1", timestamp: 2)
        let unrelated = makeChange(type: .collection, entityID: "folder-2", timestamp: 3)

        await queue.enqueue(predecessor)
        try await queue.enqueueSuccessor(successor, preserving: predecessor.id)
        await queue.enqueue(unrelated)
        try await queue.commitAppliedChangeIDs([
            UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        ])

        let envelope = try XCTUnwrap(
            await engine.nextEnvelope(
                limit: 1,
                excludingTargets: [SyncTarget(entityType: .item, entityID: "note-1")]
            )
        )

        XCTAssertEqual(envelope.changes, [unrelated])
        XCTAssertEqual(envelope.acknowledgedChangeIDs.count, 1)
    }

    func testStrictSuccessorPersistenceFailureRestoresPriorPendingState() async {
        let predecessor = makeChange(type: .marker, entityID: "pin-1", timestamp: 1)
        let persistence = MYR223FailingQueuePersistence(
            initial: SyncQueueSnapshot(pendingChanges: [predecessor])
        )
        let queue = SyncQueue(persistence: persistence)
        let successor = makeChange(type: .marker, entityID: "pin-1", timestamp: 2)

        do {
            try await queue.enqueueSuccessor(successor, preserving: predecessor.id)
            XCTFail("Expected persistence failure")
        } catch {
            XCTAssertEqual(error as? SyncQueueProtectedSuccessorError, .persistenceFailed)
        }

        let snapshot = await queue.snapshot()
        XCTAssertEqual(snapshot.pendingChanges, [predecessor])
    }

    private func temporaryQueueURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sync-queue.json")
    }

    private func makeChange(
        type: SyncEntityType,
        entityID: String,
        timestamp: TimeInterval
    ) -> SyncChange {
        SyncChange(
            entityType: type,
            entityID: entityID,
            operation: .upsert,
            payload: Data("\(entityID)-\(timestamp)".utf8),
            updatedAt: Date(timeIntervalSince1970: timestamp),
            originDeviceID: "device-a"
        )
    }
}

private final class MYR223FailingQueuePersistence: SyncQueuePersistence, @unchecked Sendable {
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
