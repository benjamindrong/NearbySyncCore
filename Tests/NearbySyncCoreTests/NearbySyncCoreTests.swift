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

    func testAcknowledgedEnvelopeClearsQueue() async throws {
        let store = InMemorySyncStore()
        let engine = SyncEngine(deviceID: "device-a", store: store)

        _ = await engine.recordLocalChange(
            entityType: .collection,
            entityID: "collection-1",
            payload: Data("Inbox".utf8)
        )

        let envelope = await engine.nextEnvelope()
        XCTAssertEqual(await engine.pendingChangeCount(), 1)

        await engine.acknowledgeChanges(try XCTUnwrap(envelope).changes.map(\.id))

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

    func testDuplicateIncomingChangeIsRememberedAcrossRestart() async {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sync-queue.json")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let change = SyncChange(
            entityType: .marker,
            entityID: "pin-1",
            operation: .upsert,
            payload: Data("Marker".utf8),
            updatedAt: Date(timeIntervalSince1970: 200),
            originDeviceID: "device-a"
        )
        let firstEngine = SyncEngine(
            deviceID: "device-b",
            store: InMemorySyncStore(),
            queue: SyncQueue(persistence: FileBackedSyncQueuePersistence(fileURL: fileURL))
        )

        _ = await firstEngine.applyIncomingEnvelope(SyncEnvelope(senderDeviceID: "device-a", changes: [change]))

        let restartedEngine = SyncEngine(
            deviceID: "device-b",
            store: InMemorySyncStore(),
            queue: SyncQueue(persistence: FileBackedSyncQueuePersistence(fileURL: fileURL))
        )
        let replayResult = await restartedEngine.applyIncomingEnvelope(
            SyncEnvelope(senderDeviceID: "device-a", changes: [change])
        )

        XCTAssertEqual(replayResult.ignoredDuplicateIDs, [change.id])
    }

    func testIncomingChangeIsNotRequeuedAsLocalChange() async {
        let store = InMemorySyncStore()
        let engine = SyncEngine(deviceID: "device-b", store: store)
        let change = SyncChange(
            entityType: .item,
            entityID: "item-1",
            operation: .upsert,
            payload: Data("remote".utf8),
            updatedAt: Date(timeIntervalSince1970: 200),
            originDeviceID: "device-a"
        )

        _ = await engine.applyIncomingEnvelope(SyncEnvelope(senderDeviceID: "device-a", changes: [change]))

        let envelope = await engine.nextEnvelope()
        XCTAssertEqual(envelope?.changes, [])
        XCTAssertEqual(envelope?.acknowledgedChangeIDs, [change.id])
    }

    func testAcknowledgementEnvelopeClearsSenderQueue() async throws {
        let sender = SyncEngine(deviceID: "device-a", store: InMemorySyncStore())
        let receiver = SyncEngine(deviceID: "device-b", store: InMemorySyncStore())
        let change = await sender.recordLocalChange(
            entityType: .item,
            entityID: "item-1",
            payload: Data("one".utf8),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let outbound = await sender.nextEnvelope()
        _ = await receiver.applyIncomingEnvelope(try XCTUnwrap(outbound))
        let acknowledgement = await receiver.nextEnvelope()

        let result = await sender.applyIncomingEnvelope(try XCTUnwrap(acknowledgement))

        XCTAssertEqual(await sender.pendingChangeCount(), 0)
        XCTAssertEqual(acknowledgement?.acknowledgedChangeIDs, [change.id])
        XCTAssertEqual(result.acknowledgedLocalChanges, [change])
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

    func testThreeWayTextMergeConflictsSameSpotOfflineEdits() {
        let result = SyncThreeWayTextMergePolicy.merge(
            base: "Need milk",
            local: "Need oat milk",
            remote: "Need whole milk"
        )

        XCTAssertEqual(result, .conflict)
    }

    func testThreeWayTextMergeConflictsSameInsertionPointOfflineEdits() {
        let result = SyncThreeWayTextMergePolicy.merge(
            base: "alpha gamma",
            local: "alpha local gamma",
            remote: "alpha remote gamma"
        )

        XCTAssertEqual(result, .conflict)
    }

    func testThreeWayTextMergeCombinesNonOverlappingEdits() {
        let result = SyncThreeWayTextMergePolicy.merge(
            base: "alpha beta gamma",
            local: "alpha local beta gamma",
            remote: "alpha beta gamma remote"
        )

        XCTAssertEqual(result, .merged("alpha local beta gamma remote"))
    }

    func testThreeWayTextMergeConflictsMissingBase() {
        let result = SyncThreeWayTextMergePolicy.merge(
            base: nil,
            local: "local text",
            remote: "remote text"
        )

        XCTAssertEqual(result, .conflict)
    }

    func testLocalFirstTextPayloadKeepsOriginalBaseAcrossCollapsedOfflineEdits() async throws {
        let conflictURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sync-conflicts.json")
        defer { try? FileManager.default.removeItem(at: conflictURL.deletingLastPathComponent()) }
        let store = LocalFirstTextSyncStore(
            localDeviceID: "device-a",
            conflictStore: SyncTextConflictStore(fileURL: conflictURL),
            seedRecords: [
                SyncRecord(
                    entityType: .item,
                    entityID: "item-1",
                    payload: Data("shared".utf8),
                    updatedAt: Date(timeIntervalSince1970: 100)
                )
            ]
        )
        let engine = SyncEngine(deviceID: "device-a", store: store)

        let firstPayload = try await store.textPayloadData(entityType: .item, entityID: "item-1", text: "shared local")
        _ = await engine.recordLocalChange(entityType: .item, entityID: "item-1", payload: firstPayload)
        let secondPayload = try await store.textPayloadData(entityType: .item, entityID: "item-1", text: "shared local final")

        let decodedPayload = SyncTextPayload.decodeText(from: secondPayload)
        XCTAssertEqual(decodedPayload.baseText, "shared")
        XCTAssertEqual(decodedPayload.text, "shared local final")
    }

    func testAcknowledgementAdvancesOutgoingTextBase() async throws {
        let conflictURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sync-conflicts.json")
        defer { try? FileManager.default.removeItem(at: conflictURL.deletingLastPathComponent()) }
        let store = LocalFirstTextSyncStore(
            localDeviceID: "device-a",
            conflictStore: SyncTextConflictStore(fileURL: conflictURL),
            seedRecords: [
                SyncRecord(
                    entityType: .item,
                    entityID: "item-1",
                    payload: Data("shared".utf8),
                    updatedAt: Date(timeIntervalSince1970: 100)
                )
            ]
        )
        let engine = SyncEngine(deviceID: "device-a", store: store)
        let firstPayload = try await store.textPayloadData(entityType: .item, entityID: "item-1", text: "first synced")
        let change = await engine.recordLocalChange(entityType: .item, entityID: "item-1", payload: firstPayload)

        await engine.acknowledgeChanges([change.id])
        let secondPayload = try await store.textPayloadData(entityType: .item, entityID: "item-1", text: "second synced")

        let decodedPayload = SyncTextPayload.decodeText(from: secondPayload)
        XCTAssertEqual(decodedPayload.baseText, "first synced")
        XCTAssertEqual(decodedPayload.text, "second synced")
    }

    func testLocalFirstConflictResolutionActionsDoNotQueueChanges() async {
        let conflictURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sync-conflicts.json")
        defer { try? FileManager.default.removeItem(at: conflictURL.deletingLastPathComponent()) }
        let conflictStore = SyncTextConflictStore(fileURL: conflictURL)
        let store = LocalFirstTextSyncStore(localDeviceID: "device-a", conflictStore: conflictStore)
        let engine = SyncEngine(deviceID: "device-a", store: store)
        let conflict = SyncTextConflictVersion(
            entityType: .item,
            entityID: "item-1",
            fieldID: "text",
            localText: "local",
            remoteText: "remote",
            remoteUpdatedAt: Date(timeIntervalSince1970: 200),
            expiresAt: Date(timeIntervalSince1970: 1_000)
        )
        _ = conflictStore.preserve(conflict)

        _ = await store.restore(conflict)

        let envelope = await engine.nextEnvelope()
        XCTAssertEqual(await engine.pendingChangeCount(), 0)
        XCTAssertNil(envelope)
    }

    func testResolvedConflictPayloadAppliesWinnerWhenPeerStillMatchesBase() async throws {
        let conflictURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sync-conflicts.json")
        defer { try? FileManager.default.removeItem(at: conflictURL.deletingLastPathComponent()) }
        let store = LocalFirstTextSyncStore(
            localDeviceID: "device-b",
            conflictStore: SyncTextConflictStore(fileURL: conflictURL),
            seedRecords: [
                SyncRecord(
                    entityType: .item,
                    entityID: "item-1",
                    payload: Data("incoming".utf8),
                    updatedAt: Date(timeIntervalSince1970: 200)
                )
            ]
        )
        let engine = SyncEngine(deviceID: "device-b", store: store)
        let conflict = SyncTextConflictVersion(
            entityType: .item,
            entityID: "item-1",
            fieldID: "text",
            localText: "current winner",
            remoteText: "incoming",
            remoteUpdatedAt: Date(timeIntervalSince1970: 200),
            expiresAt: Date(timeIntervalSince1970: 1_000)
        )
        let payload = try SyncTextConflictPayload(
            action: .resolved,
            conflict: conflict,
            resolvedText: "current winner",
            baseText: "incoming",
            updatedAt: Date(timeIntervalSince1970: 300)
        ).encoded()
        let change = SyncChange(
            entityType: .conflict,
            entityID: conflict.id.uuidString,
            payload: payload,
            updatedAt: Date(timeIntervalSince1970: 300),
            originDeviceID: "device-a"
        )

        let result = await engine.applyIncomingEnvelope(SyncEnvelope(senderDeviceID: "device-a", changes: [change]))

        let record = await store.record(for: .item, entityID: "item-1")
        let conflicts = await store.activeConflicts(now: Date(timeIntervalSince1970: 301))
        XCTAssertEqual(result.appliedChangeIDs, [change.id])
        XCTAssertEqual(record?.payload, Data("current winner".utf8))
        XCTAssertTrue(conflicts.isEmpty)
    }

    func testResolvedConflictPayloadPreservesConflictWhenPeerDivergedFromBase() async throws {
        let conflictURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sync-conflicts.json")
        defer { try? FileManager.default.removeItem(at: conflictURL.deletingLastPathComponent()) }
        let store = LocalFirstTextSyncStore(
            localDeviceID: "device-b",
            conflictStore: SyncTextConflictStore(fileURL: conflictURL),
            seedRecords: [
                SyncRecord(
                    entityType: .item,
                    entityID: "item-1",
                    payload: Data("new local typing".utf8),
                    updatedAt: Date(timeIntervalSince1970: 350)
                )
            ]
        )
        let engine = SyncEngine(deviceID: "device-b", store: store)
        let conflict = SyncTextConflictVersion(
            entityType: .item,
            entityID: "item-1",
            fieldID: "text",
            localText: "current winner",
            remoteText: "incoming",
            remoteUpdatedAt: Date(timeIntervalSince1970: 200),
            expiresAt: Date(timeIntervalSince1970: 1_000)
        )
        let payload = try SyncTextConflictPayload(
            action: .resolved,
            conflict: conflict,
            resolvedText: "current winner",
            baseText: "incoming",
            updatedAt: Date(timeIntervalSince1970: 300)
        ).encoded()
        let change = SyncChange(
            entityType: .conflict,
            entityID: conflict.id.uuidString,
            payload: payload,
            updatedAt: Date(timeIntervalSince1970: 300),
            originDeviceID: "device-a"
        )

        let result = await engine.applyIncomingEnvelope(SyncEnvelope(senderDeviceID: "device-a", changes: [change]))

        let record = await store.record(for: .item, entityID: "item-1")
        let conflicts = await store.activeConflicts(now: Date(timeIntervalSince1970: 301))
        XCTAssertEqual(record?.payload, Data("new local typing".utf8))
        XCTAssertEqual(result.ignoredStaleIDs, [change.id])
        XCTAssertEqual(conflicts.first?.localText, "new local typing")
        XCTAssertEqual(conflicts.first?.remoteText, "current winner")
    }

    func testQueuePersistenceFailureIsReported() {
        let result = FileBackedSyncQueuePersistence(fileURL: URL(fileURLWithPath: "/dev/null/queue.json"))
            .saveSnapshot(SyncQueueSnapshot())

        XCTAssertFalse(result.didPersist)
        XCTAssertNotNil(result.errorDescription)
    }
}
