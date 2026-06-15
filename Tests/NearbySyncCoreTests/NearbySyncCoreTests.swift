import XCTest
@testable import NearbySyncCore

final class NearbySyncCoreTests: XCTestCase {
    func testLocalChangeIsQueuedAndStored() async {
        let store = InMemorySyncStore()
        let engine = SyncEngine(deviceID: "device-a", store: store)
        let payload = Data("hello".utf8)

        let change = await engine.recordLocalChange(
            entityType: .item,
            entityID: "item-1",
            payload: payload,
            updatedAt: Date(timeIntervalSince1970: 100)
        )

        let records = await engine.records()
        let envelope = await engine.nextEnvelope()

        XCTAssertEqual(change.entityID, "item-1")
        XCTAssertEqual(records.first?.payload, payload)
        XCTAssertEqual(envelope?.changes, [change])
    }

    func testAcknowledgedEnvelopeClearsQueue() async {
        let store = InMemorySyncStore()
        let engine = SyncEngine(deviceID: "device-a", store: store)

        _ = await engine.recordLocalChange(
            entityType: .collection,
            entityID: "collection-1",
            payload: Data("Inbox".utf8)
        )

        let envelope = await engine.nextEnvelope()
        XCTAssertEqual(await engine.pendingChangeCount(), 1)

        await engine.acknowledgeChanges(XCTUnwrap(envelope).changes.map(\.id))

        XCTAssertEqual(await engine.pendingChangeCount(), 0)
    }

    func testSentEnvelopeStaysQueuedUntilAck() async {
        let store = InMemorySyncStore()
        let engine = SyncEngine(deviceID: "device-a", store: store)

        _ = await engine.recordLocalChange(
            entityType: .collection,
            entityID: "collection-1",
            payload: Data("Inbox".utf8)
        )

        _ = await engine.nextEnvelope()

        XCTAssertEqual(await engine.pendingChangeCount(), 1)
    }

    func testDuplicateIncomingChangeIsNotAppliedTwice() async {
        let store = InMemorySyncStore()
        let engine = SyncEngine(deviceID: "device-b", store: store)
        let change = SyncChange(
            entityType: .marker,
            entityID: "pin-1",
            operation: .upsert,
            payload: Data("Marker".utf8),
            updatedAt: Date(timeIntervalSince1970: 200),
            originDeviceID: "device-a"
        )
        let envelope = SyncEnvelope(senderDeviceID: "device-a", changes: [change])

        let firstResult = await engine.applyIncomingEnvelope(envelope)
        let secondResult = await engine.applyIncomingEnvelope(envelope)

        XCTAssertEqual(firstResult.appliedChangeIDs, [change.id])
        XCTAssertEqual(secondResult.ignoredDuplicateIDs, [change.id])
    }

    func testNewestUpdatedAtWinsConflict() async {
        let store = InMemorySyncStore()
        let engine = SyncEngine(deviceID: "device-b", store: store)
        let newerChange = SyncChange(
            entityType: .item,
            entityID: "item-1",
            operation: .upsert,
            payload: Data("newer".utf8),
            updatedAt: Date(timeIntervalSince1970: 300),
            originDeviceID: "device-a"
        )
        let olderChange = SyncChange(
            entityType: .item,
            entityID: "item-1",
            operation: .upsert,
            payload: Data("older".utf8),
            updatedAt: Date(timeIntervalSince1970: 250),
            originDeviceID: "device-c"
        )

        _ = await engine.applyIncomingEnvelope(SyncEnvelope(senderDeviceID: "device-a", changes: [newerChange]))
        let staleResult = await engine.applyIncomingEnvelope(SyncEnvelope(senderDeviceID: "device-c", changes: [olderChange]))

        let record = await store.record(for: .item, entityID: "item-1")
        XCTAssertEqual(record?.payload, Data("newer".utf8))
        XCTAssertEqual(staleResult.ignoredStaleIDs, [olderChange.id])
    }

    func testQueuedChangesRemainAvailableForCatchUpBeforeSendAck() async {
        let store = InMemorySyncStore()
        let engine = SyncEngine(deviceID: "device-a", store: store)

        _ = await engine.recordLocalChange(entityType: .item, entityID: "item-1", payload: Data("one".utf8))
        _ = await engine.recordLocalChange(entityType: .collection, entityID: "collection-1", payload: Data("two".utf8))

        let reconnectEnvelope = await engine.nextEnvelope()

        XCTAssertEqual(reconnectEnvelope?.changes.count, 2)
        XCTAssertEqual(await engine.pendingChangeCount(), 2)
    }

    func testLocalFirstTextStorePreservesRemoteTextConflict() async {
        let conflictURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sync-conflicts.json")
        defer { try? FileManager.default.removeItem(at: conflictURL.deletingLastPathComponent()) }
        let conflictStore = SyncTextConflictStore(fileURL: conflictURL)
        let store = LocalFirstTextSyncStore(
            localDeviceID: "device-a",
            conflictStore: conflictStore
        )
        let engine = SyncEngine(deviceID: "device-a", store: store)
        let originalRemoteChange = SyncChange(
            entityType: .item,
            entityID: "item-1",
            operation: .upsert,
            payload: Data("original".utf8),
            updatedAt: Date(timeIntervalSince1970: 100),
            originDeviceID: "device-b"
        )
        _ = await engine.applyIncomingEnvelope(
            SyncEnvelope(senderDeviceID: "device-b", changes: [originalRemoteChange])
        )
        _ = await engine.recordLocalChange(
            entityType: .item,
            entityID: "item-1",
            payload: Data("local".utf8),
            updatedAt: Date(timeIntervalSince1970: 150)
        )
        let change = SyncChange(
            entityType: .item,
            entityID: "item-1",
            operation: .upsert,
            payload: Data("remote".utf8),
            updatedAt: Date(timeIntervalSince1970: 200),
            originDeviceID: "device-b"
        )

        let result = await engine.applyIncomingEnvelope(SyncEnvelope(senderDeviceID: "device-b", changes: [change]))

        let record = await store.record(for: .item, entityID: "item-1")
        let conflicts = await store.activeConflicts(now: Date(timeIntervalSince1970: 201))
        XCTAssertEqual(record?.payload, Data("local".utf8))
        XCTAssertEqual(result.ignoredStaleIDs, [change.id])
        XCTAssertEqual(conflicts.first?.localText, "local")
        XCTAssertEqual(conflicts.first?.remoteText, "remote")
    }

    func testLocalFirstTextStoreAppliesRemoteTextWhenLocalMatchesRemoteBaseline() async {
        let conflictURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sync-conflicts.json")
        defer { try? FileManager.default.removeItem(at: conflictURL.deletingLastPathComponent()) }
        let conflictStore = SyncTextConflictStore(fileURL: conflictURL)
        let store = LocalFirstTextSyncStore(
            localDeviceID: "device-a",
            conflictStore: conflictStore
        )
        let engine = SyncEngine(deviceID: "device-a", store: store)
        let originalRemoteChange = SyncChange(
            entityType: .item,
            entityID: "item-1",
            operation: .upsert,
            payload: Data("original".utf8),
            updatedAt: Date(timeIntervalSince1970: 100),
            originDeviceID: "device-b"
        )
        let newerRemoteChange = SyncChange(
            entityType: .item,
            entityID: "item-1",
            operation: .upsert,
            payload: Data("remote".utf8),
            updatedAt: Date(timeIntervalSince1970: 200),
            originDeviceID: "device-b"
        )

        _ = await engine.applyIncomingEnvelope(
            SyncEnvelope(senderDeviceID: "device-b", changes: [originalRemoteChange])
        )
        let result = await engine.applyIncomingEnvelope(
            SyncEnvelope(senderDeviceID: "device-b", changes: [newerRemoteChange])
        )

        let record = await store.record(for: .item, entityID: "item-1")
        let conflicts = await store.activeConflicts(now: Date(timeIntervalSince1970: 201))
        XCTAssertEqual(record?.payload, Data("remote".utf8))
        XCTAssertEqual(result.appliedChangeIDs, [newerRemoteChange.id])
        XCTAssertTrue(conflicts.isEmpty)
    }
}
