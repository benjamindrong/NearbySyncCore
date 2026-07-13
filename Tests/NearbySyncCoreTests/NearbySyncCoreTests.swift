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
        let pendingCountBeforeAck = await engine.pendingChangeCount()
        XCTAssertEqual(pendingCountBeforeAck, 1)

        await engine.acknowledgeChanges(try XCTUnwrap(envelope).changes.map(\.id))

        let pendingCountAfterAck = await engine.pendingChangeCount()
        XCTAssertEqual(pendingCountAfterAck, 0)
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

        let pendingCount = await engine.pendingChangeCount()
        XCTAssertEqual(pendingCount, 1)
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

    func testRemoteAppliedTextChangeIsOnlyAcknowledgedAfterRestart() async {
        let queueURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sync-queue.json")
        let conflictURL = queueURL.deletingLastPathComponent()
            .appendingPathComponent("sync-conflicts.json")
        defer { try? FileManager.default.removeItem(at: queueURL.deletingLastPathComponent()) }
        let store = LocalFirstTextSyncStore(
            localDeviceID: "device-b",
            conflictStore: SyncTextConflictStore(fileURL: conflictURL)
        )
        let firstEngine = SyncEngine(
            deviceID: "device-b",
            store: store,
            queue: SyncQueue(persistence: FileBackedSyncQueuePersistence(fileURL: queueURL))
        )
        let change = SyncChange(
            entityType: .item,
            entityID: "note-1",
            operation: .upsert,
            payload: Data("remote body".utf8),
            updatedAt: Date(timeIntervalSince1970: 100),
            originDeviceID: "device-a"
        )

        _ = await firstEngine.applyIncomingEnvelope(SyncEnvelope(senderDeviceID: "device-a", changes: [change]))
        let restartedEngine = SyncEngine(
            deviceID: "device-b",
            store: store,
            queue: SyncQueue(persistence: FileBackedSyncQueuePersistence(fileURL: queueURL))
        )

        let envelope = await restartedEngine.nextEnvelope()
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

        let pendingCount = await sender.pendingChangeCount()
        XCTAssertEqual(pendingCount, 0)
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
        let pendingCount = await engine.pendingChangeCount()
        XCTAssertEqual(pendingCount, 2)
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

    func testLocalFirstTextStoreAppliesNewRemoteNoteWithoutConflict() async throws {
        let conflictURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sync-conflicts.json")
        defer { try? FileManager.default.removeItem(at: conflictURL.deletingLastPathComponent()) }
        let store = LocalFirstTextSyncStore(
            localDeviceID: "device-b",
            conflictStore: SyncTextConflictStore(fileURL: conflictURL)
        )
        let engine = SyncEngine(deviceID: "device-b", store: store)
        let change = SyncChange(
            entityType: .item,
            entityID: "new-note",
            operation: .upsert,
            payload: try SyncTextPayload(text: "new note text", baseText: nil).encoded(),
            updatedAt: Date(timeIntervalSince1970: 100),
            originDeviceID: "device-a"
        )

        let result = await engine.applyIncomingEnvelope(SyncEnvelope(senderDeviceID: "device-a", changes: [change]))

        let record = await store.record(for: .item, entityID: "new-note")
        let conflicts = await store.activeConflicts(now: Date(timeIntervalSince1970: 101))
        XCTAssertEqual(result.appliedChangeIDs, [change.id])
        XCTAssertEqual(record?.payload, Data("new note text".utf8))
        XCTAssertTrue(conflicts.isEmpty)
    }

    func testLocalFirstTextStorePreservesRemoteTextWhenGateBlocksAutomaticApply() async throws {
        let conflictURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sync-conflicts.json")
        defer { try? FileManager.default.removeItem(at: conflictURL.deletingLastPathComponent()) }
        let conflictStore = SyncTextConflictStore(fileURL: conflictURL)
        let store = LocalFirstTextSyncStore(
            localDeviceID: "device-a",
            conflictStore: conflictStore,
            textApplicationGate: { _ in .preserveForReview },
            seedRecords: [
                SyncRecord(
                    entityType: .item,
                    entityID: "item-1",
                    payload: Data("local typing".utf8),
                    updatedAt: Date(timeIntervalSince1970: 100)
                )
            ]
        )
        let engine = SyncEngine(deviceID: "device-a", store: store)
        let payload = try SyncTextPayload(text: "", baseText: "local typing").encoded()
        let change = SyncChange(
            entityType: .item,
            entityID: "item-1",
            operation: .upsert,
            payload: payload,
            updatedAt: Date(timeIntervalSince1970: 200),
            originDeviceID: "device-b"
        )

        let result = await engine.applyIncomingEnvelope(SyncEnvelope(senderDeviceID: "device-b", changes: [change]))

        let record = await store.record(for: .item, entityID: "item-1")
        let conflicts = await store.activeConflicts(now: Date(timeIntervalSince1970: 201))
        XCTAssertEqual(record?.payload, Data("local typing".utf8))
        XCTAssertEqual(result.ignoredStaleIDs, [change.id])
        XCTAssertEqual(result.preservedConflicts.first?.localText, "local typing")
        XCTAssertEqual(result.preservedConflicts.first?.remoteText, "")
        XCTAssertEqual(conflicts.first?.remoteText, "")
    }

    func testCleanRemoteTextEditAfterAcknowledgedBaseAppliesWithoutConflict() async throws {
        let conflictURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sync-conflicts.json")
        defer { try? FileManager.default.removeItem(at: conflictURL.deletingLastPathComponent()) }
        let senderStore = LocalFirstTextSyncStore(
            localDeviceID: "device-a",
            conflictStore: SyncTextConflictStore(fileURL: conflictURL)
        )
        let receiverStore = LocalFirstTextSyncStore(
            localDeviceID: "device-b",
            conflictStore: SyncTextConflictStore(fileURL: conflictURL)
        )
        let sender = SyncEngine(deviceID: "device-a", store: senderStore)
        let receiver = SyncEngine(deviceID: "device-b", store: receiverStore)

        let createPayload = try await senderStore.textPayloadData(
            entityType: .item,
            entityID: "note-1",
            text: "original"
        )
        let create = await sender.recordLocalChange(
            entityType: .item,
            entityID: "note-1",
            payload: createPayload,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let pendingCreateEnvelope = await sender.nextEnvelope()
        let createEnvelope = try XCTUnwrap(pendingCreateEnvelope)
        _ = await receiver.applyIncomingEnvelope(createEnvelope)
        await sender.acknowledgeChanges([create.id])

        let editPayload = try await senderStore.textPayloadData(
            entityType: .item,
            entityID: "note-1",
            text: "edited"
        )
        let edit = await sender.recordLocalChange(
            entityType: .item,
            entityID: "note-1",
            payload: editPayload,
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        let pendingEditEnvelope = await sender.nextEnvelope()
        let editEnvelope = try XCTUnwrap(pendingEditEnvelope)
        let result = await receiver.applyIncomingEnvelope(editEnvelope)

        let record = await receiverStore.record(for: .item, entityID: "note-1")
        let conflicts = await receiverStore.activeConflicts(now: Date(timeIntervalSince1970: 201))
        XCTAssertEqual(result.appliedChangeIDs, [edit.id])
        XCTAssertEqual(record?.payload, Data("edited".utf8))
        XCTAssertTrue(conflicts.isEmpty)
    }

    func testLocalFirstTextStoreQueuesLaterUpdatesForConflictedFieldOnly() async throws {
        let conflictURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sync-conflicts.json")
        defer { try? FileManager.default.removeItem(at: conflictURL.deletingLastPathComponent()) }
        let conflictStore = SyncTextConflictStore(fileURL: conflictURL)
        let store = LocalFirstTextSyncStore(
            localDeviceID: "device-a",
            conflictStore: conflictStore,
            seedRecords: [
                SyncRecord(
                    entityType: .item,
                    entityID: "item-1",
                    payload: Data("local note".utf8),
                    updatedAt: Date(timeIntervalSince1970: 100)
                )
            ]
        )
        let engine = SyncEngine(deviceID: "device-a", store: store)
        let first = SyncChange(
            entityType: .item,
            entityID: "item-1",
            operation: .upsert,
            payload: try SyncTextPayload(text: "remote note", baseText: nil).encoded(),
            updatedAt: Date(timeIntervalSince1970: 200),
            originDeviceID: "device-b"
        )
        let second = SyncChange(
            entityType: .item,
            entityID: "item-1",
            operation: .upsert,
            payload: try SyncTextPayload(text: "latest remote note", baseText: nil).encoded(),
            updatedAt: Date(timeIntervalSince1970: 250),
            originDeviceID: "device-b"
        )
        let unrelated = SyncChange(
            entityType: .item,
            entityID: "item-2",
            operation: .upsert,
            payload: try SyncTextPayload(text: "new unrelated note", baseText: nil).encoded(),
            updatedAt: Date(timeIntervalSince1970: 260),
            originDeviceID: "device-b"
        )

        _ = await engine.applyIncomingEnvelope(SyncEnvelope(senderDeviceID: "device-b", changes: [first]))
        let result = await engine.applyIncomingEnvelope(SyncEnvelope(senderDeviceID: "device-b", changes: [second, unrelated]))

        let conflictedRecord = await store.record(for: .item, entityID: "item-1")
        let unrelatedRecord = await store.record(for: .item, entityID: "item-2")
        let activeConflicts = await store.activeConflicts(now: Date(timeIntervalSince1970: 270))
        let queuedConflict = conflictStore.queuedConflict(entityType: .item, entityID: "item-1", fieldID: "text")
        XCTAssertEqual(conflictedRecord?.payload, Data("local note".utf8))
        XCTAssertEqual(unrelatedRecord?.payload, Data("new unrelated note".utf8))
        XCTAssertEqual(result.appliedChangeIDs, [unrelated.id])
        XCTAssertEqual(activeConflicts.first?.remoteText, "remote note")
        XCTAssertEqual(queuedConflict?.conflict.remoteText, "latest remote note")

        let conflictsAfterResolution = conflictStore.removeResolvedConflict(try XCTUnwrap(activeConflicts.first))
        XCTAssertTrue(conflictsAfterResolution.isEmpty)
        XCTAssertNil(conflictStore.queuedConflict(entityType: .item, entityID: "item-1", fieldID: "text"))
    }

    func testLocalFirstTextStoreBlocksOutgoingLocalTextWhileConflictIsActive() async throws {
        let conflictURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sync-conflicts.json")
        defer { try? FileManager.default.removeItem(at: conflictURL.deletingLastPathComponent()) }
        let conflictStore = SyncTextConflictStore(fileURL: conflictURL)
        let store = LocalFirstTextSyncStore(
            localDeviceID: "device-a",
            conflictStore: conflictStore,
            seedRecords: [
                SyncRecord(
                    entityType: .item,
                    entityID: "item-1",
                    payload: Data("local note".utf8),
                    updatedAt: Date(timeIntervalSince1970: 100)
                )
            ]
        )
        let engine = SyncEngine(deviceID: "device-a", store: store)
        let expiresAt = Date().addingTimeInterval(1_000)
        let conflict = SyncTextConflictVersion(
            entityType: .item,
            entityID: "item-1",
            fieldID: "text",
            localText: "local note",
            remoteText: "Version to Sync",
            remoteUpdatedAt: Date(timeIntervalSince1970: 200),
            expiresAt: expiresAt
        )
        _ = conflictStore.preserve(conflict)

        _ = await engine.recordLocalChange(
            entityType: .item,
            entityID: "item-1",
            payload: try SyncTextPayload(text: "typed during review", baseText: "local note").encoded(),
            updatedAt: Date(timeIntervalSince1970: 250)
        )

        let record = await store.record(for: .item, entityID: "item-1")
        let envelope = await engine.nextEnvelope()
        let pendingCount = await engine.pendingChangeCount()
        XCTAssertEqual(record?.payload, Data("local note".utf8))
        XCTAssertNil(envelope)
        XCTAssertEqual(pendingCount, 0)
        XCTAssertEqual(conflictStore.activeConflicts(now: Date(timeIntervalSince1970: 251)).first, conflict)
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

        XCTAssertEqual(result.mergedText, "alpha local beta gamma remote")
        XCTAssertEqual(result.patch?.applying(to: "alpha local beta gamma"), "alpha local beta gamma remote")
    }

    func testTextPatchReplacesGrapheme() {
        let patch = SyncTextPatch.from(local: "😀", to: "😃")

        XCTAssertEqual(patch.range, NSRange(location: 0, length: 2))
        XCTAssertEqual(patch.replacement, "😃")
        XCTAssertEqual(patch.applying(to: "😀"), "😃")
    }

    func testTextPatchCapturesInsertion() {
        let patch = SyncTextPatch.from(local: "alpha gamma", to: "alpha beta gamma")

        XCTAssertEqual(patch.replacement, "beta ")
        XCTAssertEqual(patch.applying(to: "alpha gamma"), "alpha beta gamma")
    }

    func testTextPatchCapturesDeletion() {
        let patch = SyncTextPatch.from(local: "alpha beta gamma", to: "alpha gamma")

        XCTAssertEqual(patch.replacement, "")
        XCTAssertEqual(patch.applying(to: "alpha beta gamma"), "alpha gamma")
    }

    func testTextPatchCapturesReplacement() {
        let patch = SyncTextPatch.from(local: "alpha beta gamma", to: "alpha delta gamma")

        XCTAssertEqual(patch.applying(to: "alpha beta gamma"), "alpha delta gamma")
    }

    func testTextPatchCapturesIdenticalStrings() {
        let patch = SyncTextPatch.from(local: "same", to: "same")

        XCTAssertEqual(patch.range, NSRange(location: 4, length: 0))
        XCTAssertEqual(patch.replacement, "")
        XCTAssertEqual(patch.applying(to: "same"), "same")
    }

    func testThreeWayTextMergePatchUsesUTF16Offsets() {
        let result = SyncThreeWayTextMergePolicy.merge(
            base: "a 😀 c",
            local: "a 😀 local c",
            remote: "a 😀 c remote"
        )

        XCTAssertEqual(result.mergedText, "a 😀 local c remote")
        XCTAssertEqual(result.patch?.range, NSRange(location: 12, length: 0))
        XCTAssertEqual(result.patch?.replacement, " remote")
        XCTAssertEqual(result.patch?.applying(to: "a 😀 local c"), "a 😀 local c remote")
    }

    func testTextPatchDeltaCapturesBaseToChangedText() {
        let delta = SyncTextPatch.delta(from: "one two three", to: "one too three")

        XCTAssertEqual(delta.applying(to: "one two three"), "one too three")
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

    // MYR-81: a sender can emit several debounced local edits before the first
    // one is acknowledged, so later edits in the same burst still carry the
    // base from before the burst started. The receiver can safely prefer its
    // own tracked baseline only for same-sender continuations; doing that for
    // a different sender can hide real remote divergence.

    func testRapidLocalTypingFromPeerDoesNotCreateFalseConflict() async throws {
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
                    payload: Data("".utf8),
                    updatedAt: Date(timeIntervalSince1970: 100)
                )
            ]
        )
        let engine = SyncEngine(deviceID: "device-b", store: store)
        let firstKeystrokeBurst = SyncChange(
            entityType: .item,
            entityID: "item-1",
            operation: .upsert,
            payload: try SyncTextPayload(text: "hello", baseText: "").encoded(),
            updatedAt: Date(timeIntervalSince1970: 200),
            originDeviceID: "device-a"
        )
        let secondKeystrokeBurst = SyncChange(
            entityType: .item,
            entityID: "item-1",
            operation: .upsert,
            payload: try SyncTextPayload(text: "hello world", baseText: "").encoded(),
            updatedAt: Date(timeIntervalSince1970: 210),
            originDeviceID: "device-a"
        )

        _ = await engine.applyIncomingEnvelope(SyncEnvelope(senderDeviceID: "device-a", changes: [firstKeystrokeBurst]))
        let result = await engine.applyIncomingEnvelope(
            SyncEnvelope(senderDeviceID: "device-a", changes: [secondKeystrokeBurst])
        )

        let record = await store.record(for: .item, entityID: "item-1")
        let conflicts = await store.activeConflicts(now: Date(timeIntervalSince1970: 211))
        XCTAssertEqual(record?.payload, Data("hello world".utf8))
        XCTAssertEqual(result.appliedChangeIDs, [secondKeystrokeBurst.id])
        XCTAssertTrue(conflicts.isEmpty)
    }

    func testRapidLocalTypoCorrectionFromPeerDoesNotCreateFalseConflict() async throws {
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
                    payload: Data("Hello".utf8),
                    updatedAt: Date(timeIntervalSince1970: 100)
                )
            ]
        )
        let engine = SyncEngine(deviceID: "device-b", store: store)
        // Sender typed a typo and sent it before noticing.
        let typo = SyncChange(
            entityType: .item,
            entityID: "item-1",
            operation: .upsert,
            payload: try SyncTextPayload(text: "Helllo World", baseText: "Hello").encoded(),
            updatedAt: Date(timeIntervalSince1970: 200),
            originDeviceID: "device-a"
        )
        // Sender deletes the extra letter and resends before the typo edit is acknowledged.
        let correction = SyncChange(
            entityType: .item,
            entityID: "item-1",
            operation: .upsert,
            payload: try SyncTextPayload(text: "Hello World", baseText: "Hello").encoded(),
            updatedAt: Date(timeIntervalSince1970: 210),
            originDeviceID: "device-a"
        )

        _ = await engine.applyIncomingEnvelope(SyncEnvelope(senderDeviceID: "device-a", changes: [typo]))
        let result = await engine.applyIncomingEnvelope(SyncEnvelope(senderDeviceID: "device-a", changes: [correction]))

        let record = await store.record(for: .item, entityID: "item-1")
        let conflicts = await store.activeConflicts(now: Date(timeIntervalSince1970: 211))
        XCTAssertEqual(record?.payload, Data("Hello World".utf8))
        XCTAssertEqual(result.appliedChangeIDs, [correction.id])
        XCTAssertTrue(conflicts.isEmpty)
    }

    func testRapidLocalDeletionFromPeerDoesNotCreateFalseConflict() async throws {
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
                    payload: Data("alpha beta gamma delta".utf8),
                    updatedAt: Date(timeIntervalSince1970: 100)
                )
            ]
        )
        let engine = SyncEngine(deviceID: "device-b", store: store)
        let firstDelete = SyncChange(
            entityType: .item,
            entityID: "item-1",
            operation: .upsert,
            payload: try SyncTextPayload(text: "alpha beta gamma", baseText: "alpha beta gamma delta").encoded(),
            updatedAt: Date(timeIntervalSince1970: 200),
            originDeviceID: "device-a"
        )
        let secondDelete = SyncChange(
            entityType: .item,
            entityID: "item-1",
            operation: .upsert,
            payload: try SyncTextPayload(text: "alpha beta", baseText: "alpha beta gamma delta").encoded(),
            updatedAt: Date(timeIntervalSince1970: 210),
            originDeviceID: "device-a"
        )

        _ = await engine.applyIncomingEnvelope(SyncEnvelope(senderDeviceID: "device-a", changes: [firstDelete]))
        let result = await engine.applyIncomingEnvelope(SyncEnvelope(senderDeviceID: "device-a", changes: [secondDelete]))

        let record = await store.record(for: .item, entityID: "item-1")
        let conflicts = await store.activeConflicts(now: Date(timeIntervalSince1970: 211))
        XCTAssertEqual(record?.payload, Data("alpha beta".utf8))
        XCTAssertEqual(result.appliedChangeIDs, [secondDelete.id])
        XCTAssertTrue(conflicts.isEmpty)
    }

    func testRapidDeleteThenAddBackFromPeerDoesNotCreateFalseConflict() async throws {
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
                    payload: Data("alpha beta gamma".utf8),
                    updatedAt: Date(timeIntervalSince1970: 100)
                )
            ]
        )
        let engine = SyncEngine(deviceID: "device-b", store: store)
        let deletion = SyncChange(
            entityType: .item,
            entityID: "item-1",
            operation: .upsert,
            payload: try SyncTextPayload(text: "alpha gamma", baseText: "alpha beta gamma").encoded(),
            updatedAt: Date(timeIntervalSince1970: 200),
            originDeviceID: "device-a"
        )
        let replacement = SyncChange(
            entityType: .item,
            entityID: "item-1",
            operation: .upsert,
            payload: try SyncTextPayload(text: "alpha better gamma", baseText: "alpha beta gamma").encoded(),
            updatedAt: Date(timeIntervalSince1970: 210),
            originDeviceID: "device-a"
        )

        _ = await engine.applyIncomingEnvelope(SyncEnvelope(senderDeviceID: "device-a", changes: [deletion]))
        let result = await engine.applyIncomingEnvelope(SyncEnvelope(senderDeviceID: "device-a", changes: [replacement]))

        let record = await store.record(for: .item, entityID: "item-1")
        let conflicts = await store.activeConflicts(now: Date(timeIntervalSince1970: 211))
        XCTAssertEqual(record?.payload, Data("alpha better gamma".utf8))
        XCTAssertEqual(result.appliedChangeIDs, [replacement.id])
        XCTAssertTrue(conflicts.isEmpty)
    }

    func testRapidSameRangeAutocorrectFromPeerDoesNotCreateFalseConflict() async throws {
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
                    payload: Data("I went tehre".utf8),
                    updatedAt: Date(timeIntervalSince1970: 100)
                )
            ]
        )
        let engine = SyncEngine(deviceID: "device-b", store: store)
        let autocorrect = SyncChange(
            entityType: .item,
            entityID: "item-1",
            operation: .upsert,
            payload: try SyncTextPayload(text: "I went there", baseText: "I went tehre").encoded(),
            updatedAt: Date(timeIntervalSince1970: 200),
            originDeviceID: "device-a"
        )
        let continuation = SyncChange(
            entityType: .item,
            entityID: "item-1",
            operation: .upsert,
            payload: try SyncTextPayload(text: "I went there today", baseText: "I went tehre").encoded(),
            updatedAt: Date(timeIntervalSince1970: 210),
            originDeviceID: "device-a"
        )

        _ = await engine.applyIncomingEnvelope(SyncEnvelope(senderDeviceID: "device-a", changes: [autocorrect]))
        let result = await engine.applyIncomingEnvelope(SyncEnvelope(senderDeviceID: "device-a", changes: [continuation]))

        let record = await store.record(for: .item, entityID: "item-1")
        let conflicts = await store.activeConflicts(now: Date(timeIntervalSince1970: 211))
        XCTAssertEqual(record?.payload, Data("I went there today".utf8))
        XCTAssertEqual(result.appliedChangeIDs, [continuation.id])
        XCTAssertTrue(conflicts.isEmpty)
    }

    func testRapidNewlineHeavyEditsFromPeerDoNotCreateFalseConflict() async throws {
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
                    payload: Data("Notes:".utf8),
                    updatedAt: Date(timeIntervalSince1970: 100)
                )
            ]
        )
        let engine = SyncEngine(deviceID: "device-b", store: store)
        let firstLine = SyncChange(
            entityType: .item,
            entityID: "item-1",
            operation: .upsert,
            payload: try SyncTextPayload(text: "Notes:\nitem1", baseText: "Notes:").encoded(),
            updatedAt: Date(timeIntervalSince1970: 200),
            originDeviceID: "device-a"
        )
        let moreLines = SyncChange(
            entityType: .item,
            entityID: "item-1",
            operation: .upsert,
            payload: try SyncTextPayload(text: "Notes:\nitem1\nitem2\nitem3", baseText: "Notes:").encoded(),
            updatedAt: Date(timeIntervalSince1970: 210),
            originDeviceID: "device-a"
        )

        _ = await engine.applyIncomingEnvelope(SyncEnvelope(senderDeviceID: "device-a", changes: [firstLine]))
        let result = await engine.applyIncomingEnvelope(SyncEnvelope(senderDeviceID: "device-a", changes: [moreLines]))

        let record = await store.record(for: .item, entityID: "item-1")
        let conflicts = await store.activeConflicts(now: Date(timeIntervalSince1970: 211))
        XCTAssertEqual(record?.payload, Data("Notes:\nitem1\nitem2\nitem3".utf8))
        XCTAssertEqual(result.appliedChangeIDs, [moreLines.id])
        XCTAssertTrue(conflicts.isEmpty)
    }

    func testGenuineTwoDeviceDivergenceFromSameBaseStillConflicts() async throws {
        let conflictURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sync-conflicts.json")
        defer { try? FileManager.default.removeItem(at: conflictURL.deletingLastPathComponent()) }
        let store = LocalFirstTextSyncStore(
            localDeviceID: "device-b",
            conflictStore: SyncTextConflictStore(fileURL: conflictURL)
        )
        let engine = SyncEngine(deviceID: "device-b", store: store)
        let originalRemoteChange = SyncChange(
            entityType: .item,
            entityID: "item-1",
            operation: .upsert,
            payload: try SyncTextPayload(text: "Hello", baseText: nil).encoded(),
            updatedAt: Date(timeIntervalSince1970: 100),
            originDeviceID: "device-a"
        )
        _ = await engine.applyIncomingEnvelope(
            SyncEnvelope(senderDeviceID: "device-a", changes: [originalRemoteChange])
        )
        // device-b makes a genuine local edit device-a does not know about yet.
        _ = await engine.recordLocalChange(
            entityType: .item,
            entityID: "item-1",
            payload: Data("Hello there".utf8),
            updatedAt: Date(timeIntervalSince1970: 150)
        )
        // device-a independently edits from the same shared base.
        let divergentRemoteChange = SyncChange(
            entityType: .item,
            entityID: "item-1",
            operation: .upsert,
            payload: try SyncTextPayload(text: "Hello World", baseText: "Hello").encoded(),
            updatedAt: Date(timeIntervalSince1970: 200),
            originDeviceID: "device-a"
        )

        let result = await engine.applyIncomingEnvelope(
            SyncEnvelope(senderDeviceID: "device-a", changes: [divergentRemoteChange])
        )

        let record = await store.record(for: .item, entityID: "item-1")
        let conflicts = await store.activeConflicts(now: Date(timeIntervalSince1970: 201))
        XCTAssertEqual(record?.payload, Data("Hello there".utf8))
        XCTAssertEqual(result.ignoredStaleIDs, [divergentRemoteChange.id])
        XCTAssertEqual(conflicts.first?.localText, "Hello there")
        XCTAssertEqual(conflicts.first?.remoteText, "Hello World")
    }

    func testDifferentRemoteSenderStaleBaseDoesNotOverwriteTrackedText() async throws {
        let conflictURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sync-conflicts.json")
        defer { try? FileManager.default.removeItem(at: conflictURL.deletingLastPathComponent()) }
        let store = LocalFirstTextSyncStore(
            localDeviceID: "device-b",
            conflictStore: SyncTextConflictStore(fileURL: conflictURL)
        )
        let engine = SyncEngine(deviceID: "device-b", store: store)
        let firstSharedText = SyncChange(
            entityType: .item,
            entityID: "item-1",
            operation: .upsert,
            payload: try SyncTextPayload(text: "Hello", baseText: nil).encoded(),
            updatedAt: Date(timeIntervalSince1970: 100),
            originDeviceID: "device-a"
        )
        let deviceCEdit = SyncChange(
            entityType: .item,
            entityID: "item-1",
            operation: .upsert,
            payload: try SyncTextPayload(text: "Hello from C", baseText: "Hello").encoded(),
            updatedAt: Date(timeIntervalSince1970: 200),
            originDeviceID: "device-c"
        )
        let staleDeviceAEdit = SyncChange(
            entityType: .item,
            entityID: "item-1",
            operation: .upsert,
            payload: try SyncTextPayload(text: "Hello from A", baseText: "Hello").encoded(),
            updatedAt: Date(timeIntervalSince1970: 210),
            originDeviceID: "device-a"
        )

        _ = await engine.applyIncomingEnvelope(SyncEnvelope(senderDeviceID: "device-a", changes: [firstSharedText]))
        _ = await engine.applyIncomingEnvelope(SyncEnvelope(senderDeviceID: "device-c", changes: [deviceCEdit]))
        let result = await engine.applyIncomingEnvelope(SyncEnvelope(senderDeviceID: "device-a", changes: [staleDeviceAEdit]))

        let record = await store.record(for: .item, entityID: "item-1")
        let conflicts = await store.activeConflicts(now: Date(timeIntervalSince1970: 211))
        XCTAssertEqual(record?.payload, Data("Hello from C".utf8))
        XCTAssertEqual(result.ignoredStaleIDs, [staleDeviceAEdit.id])
        XCTAssertEqual(conflicts.first?.localText, "Hello from C")
        XCTAssertEqual(conflicts.first?.remoteText, "Hello from A")
    }

    func testActiveConflictPreventsRemoteOrdinaryTextFromOverwritingLocalText() async throws {
        let conflictURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sync-conflicts.json")
        defer { try? FileManager.default.removeItem(at: conflictURL.deletingLastPathComponent()) }
        let conflictStore = SyncTextConflictStore(fileURL: conflictURL)
        let store = LocalFirstTextSyncStore(
            localDeviceID: "device-b",
            conflictStore: conflictStore,
            seedRecords: [
                SyncRecord(
                    entityType: .item,
                    entityID: "item-1",
                    payload: Data("local editor text".utf8),
                    updatedAt: Date(timeIntervalSince1970: 200)
                )
            ]
        )
        let engine = SyncEngine(deviceID: "device-b", store: store)
        let expiresAt = Date().addingTimeInterval(1_000)
        let existingConflict = SyncTextConflictVersion(
            entityType: .item,
            entityID: "item-1",
            fieldID: "text",
            localText: "local editor text",
            remoteText: "remote conflicting text",
            remoteUpdatedAt: Date(timeIntervalSince1970: 190),
            preservedAt: Date(timeIntervalSince1970: 190),
            expiresAt: expiresAt
        )
        _ = conflictStore.preserve(existingConflict)
        let staleRemoteText = SyncChange(
            entityType: .item,
            entityID: "item-1",
            operation: .upsert,
            payload: try SyncTextPayload(text: "stale remote replacement", baseText: "shared text").encoded(),
            updatedAt: Date(timeIntervalSince1970: 210),
            originDeviceID: "device-a"
        )

        let result = await engine.applyIncomingEnvelope(SyncEnvelope(senderDeviceID: "device-a", changes: [staleRemoteText]))

        let record = await store.record(for: .item, entityID: "item-1")
        let conflicts = await store.activeConflicts(now: Date(timeIntervalSince1970: 211))
        XCTAssertEqual(record?.payload, Data("local editor text".utf8))
        XCTAssertEqual(result.ignoredStaleIDs, [staleRemoteText.id])
        XCTAssertEqual(conflicts.first?.localText, "local editor text")
    }

    func testActiveConflictPreservesLocalDeleteThenRetypeAgainstRemoteOrdinaryText() async throws {
        let conflictURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sync-conflicts.json")
        defer { try? FileManager.default.removeItem(at: conflictURL.deletingLastPathComponent()) }
        let conflictStore = SyncTextConflictStore(fileURL: conflictURL)
        let store = LocalFirstTextSyncStore(
            localDeviceID: "device-b",
            conflictStore: conflictStore,
            seedRecords: [
                SyncRecord(
                    entityType: .item,
                    entityID: "item-1",
                    payload: Data("local corrected text after retyping".utf8),
                    updatedAt: Date(timeIntervalSince1970: 220)
                )
            ]
        )
        let engine = SyncEngine(deviceID: "device-b", store: store)
        let expiresAt = Date().addingTimeInterval(1_000)
        let existingConflict = SyncTextConflictVersion(
            entityType: .item,
            entityID: "item-1",
            fieldID: "text",
            localText: "local text before correction",
            remoteText: "remote conflicting text",
            remoteUpdatedAt: Date(timeIntervalSince1970: 190),
            preservedAt: Date(timeIntervalSince1970: 190),
            expiresAt: expiresAt
        )
        _ = conflictStore.preserve(existingConflict)
        let staleRemoteText = SyncChange(
            entityType: .item,
            entityID: "item-1",
            operation: .upsert,
            payload: try SyncTextPayload(text: "remote text while reviewing", baseText: "shared text").encoded(),
            updatedAt: Date(timeIntervalSince1970: 230),
            originDeviceID: "device-a"
        )

        let result = await engine.applyIncomingEnvelope(SyncEnvelope(senderDeviceID: "device-a", changes: [staleRemoteText]))

        let record = await store.record(for: .item, entityID: "item-1")
        let queuedConflict = conflictStore.queuedConflict(entityType: .item, entityID: "item-1", fieldID: "text")
        XCTAssertEqual(record?.payload, Data("local corrected text after retyping".utf8))
        XCTAssertEqual(result.ignoredStaleIDs, [staleRemoteText.id])
        XCTAssertEqual(queuedConflict?.conflict.localText, "local corrected text after retyping")
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
            expiresAt: Date().addingTimeInterval(1_000)
        )
        _ = conflictStore.preserve(conflict)

        _ = await store.restore(conflict)

        let envelope = await engine.nextEnvelope()
        let pendingCount = await engine.pendingChangeCount()
        XCTAssertEqual(pendingCount, 0)
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
            expiresAt: Date().addingTimeInterval(1_000)
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
            operation: .upsert,
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

    func testResolvedConflictWinnerClearsBothPeersWithoutBounceBack() async throws {
        let conflictURLA = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sync-conflicts.json")
        let conflictURLB = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sync-conflicts.json")
        defer {
            try? FileManager.default.removeItem(at: conflictURLA.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: conflictURLB.deletingLastPathComponent())
        }
        let storeA = LocalFirstTextSyncStore(
            localDeviceID: "device-a",
            conflictStore: SyncTextConflictStore(fileURL: conflictURLA),
            seedRecords: [
                SyncRecord(
                    entityType: .item,
                    entityID: "note-1",
                    payload: Data("phone text".utf8),
                    updatedAt: Date(timeIntervalSince1970: 200)
                )
            ]
        )
        let conflictStoreB = SyncTextConflictStore(fileURL: conflictURLB)
        let storeB = LocalFirstTextSyncStore(
            localDeviceID: "device-b",
            conflictStore: conflictStoreB,
            seedRecords: [
                SyncRecord(
                    entityType: .item,
                    entityID: "note-1",
                    payload: Data("mac text".utf8),
                    updatedAt: Date(timeIntervalSince1970: 200)
                )
            ]
        )
        let engineA = SyncEngine(deviceID: "device-a", store: storeA)
        let conflict = SyncTextConflictVersion(
            entityType: .item,
            entityID: "note-1",
            fieldID: "text",
            localText: "mac text",
            remoteText: "phone text",
            remoteUpdatedAt: Date(timeIntervalSince1970: 200),
            expiresAt: Date().addingTimeInterval(1_000)
        )
        _ = conflictStoreB.preserve(conflict)
        _ = await storeB.removeResolvedConflict(conflict)
        let resolvedPayload = try SyncTextConflictPayload(
            action: .resolved,
            conflict: conflict,
            resolvedText: "mac text",
            baseText: "phone text",
            updatedAt: Date(timeIntervalSince1970: 300)
        ).encoded()
        let resolvedChange = SyncChange(
            entityType: .conflict,
            entityID: conflict.id.uuidString,
            operation: .upsert,
            payload: resolvedPayload,
            updatedAt: Date(timeIntervalSince1970: 300),
            originDeviceID: "device-b"
        )

        let firstApply = await engineA.applyIncomingEnvelope(
            SyncEnvelope(senderDeviceID: "device-b", changes: [resolvedChange])
        )
        let replayApply = await engineA.applyIncomingEnvelope(
            SyncEnvelope(senderDeviceID: "device-b", changes: [resolvedChange])
        )

        let recordA = await storeA.record(for: .item, entityID: "note-1")
        let conflictsA = await storeA.activeConflicts(now: Date(timeIntervalSince1970: 301))
        let conflictsB = await storeB.activeConflicts(now: Date(timeIntervalSince1970: 301))
        XCTAssertEqual(firstApply.appliedChangeIDs, [resolvedChange.id])
        XCTAssertEqual(replayApply.ignoredDuplicateIDs, [resolvedChange.id])
        XCTAssertEqual(recordA?.payload, Data("mac text".utf8))
        XCTAssertTrue(conflictsA.isEmpty)
        XCTAssertTrue(conflictsB.isEmpty)
    }

    func testResolvedConflictDoesNotPreserveAgainFromStaleMessage() {
        let conflictURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sync-conflicts.json")
        defer { try? FileManager.default.removeItem(at: conflictURL.deletingLastPathComponent()) }
        let conflictStore = SyncTextConflictStore(fileURL: conflictURL)
        let conflict = SyncTextConflictVersion(
            entityType: .item,
            entityID: "item-1",
            fieldID: "text",
            localText: "current",
            remoteText: "incoming",
            remoteUpdatedAt: Date(timeIntervalSince1970: 200),
            expiresAt: Date().addingTimeInterval(1_000)
        )
        _ = conflictStore.preserve(conflict)

        XCTAssertTrue(conflictStore.removeResolvedConflict(conflict).isEmpty)
        XCTAssertTrue(conflictStore.preserve(conflict).isEmpty)
    }

    func testTextConflictStoreKeepsOneActiveConflictPerEntityField() {
        let conflictURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sync-conflicts.json")
        defer { try? FileManager.default.removeItem(at: conflictURL.deletingLastPathComponent()) }
        let conflictStore = SyncTextConflictStore(fileURL: conflictURL)
        let expiresAt = Date().addingTimeInterval(1_000)
        let firstConflict = SyncTextConflictVersion(
            entityType: .item,
            entityID: "item-1",
            fieldID: "text",
            localText: "Mac local",
            remoteText: "iPhone incoming",
            remoteUpdatedAt: Date(timeIntervalSince1970: 200),
            preservedAt: Date(timeIntervalSince1970: 201),
            expiresAt: expiresAt
        )
        let duplicateConflict = SyncTextConflictVersion(
            entityType: .item,
            entityID: "item-1",
            fieldID: "text",
            localText: "Mac local",
            remoteText: "iPhone incoming again",
            remoteUpdatedAt: Date(timeIntervalSince1970: 250),
            preservedAt: Date(timeIntervalSince1970: 251),
            expiresAt: expiresAt
        )

        _ = conflictStore.preserve(firstConflict)
        let conflicts = conflictStore.preserve(duplicateConflict)
        let queuedConflict = conflictStore.queuedConflict(entityType: .item, entityID: "item-1", fieldID: "text")

        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts.first?.remoteText, "iPhone incoming")
        XCTAssertEqual(queuedConflict?.conflict.remoteText, "iPhone incoming again")
    }

    func testConflictStoreSnapshotRestoresActiveAndQueuedState() throws {
        let conflictURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sync-conflicts.json")
        defer { try? FileManager.default.removeItem(at: conflictURL.deletingLastPathComponent()) }
        let conflictStore = SyncTextConflictStore(fileURL: conflictURL)
        let expiresAt = Date().addingTimeInterval(1_000)
        let firstConflict = SyncTextConflictVersion(
            entityType: .item,
            entityID: "item-1",
            fieldID: "text",
            localText: "Mac local",
            remoteText: "iPhone incoming",
            remoteUpdatedAt: Date(timeIntervalSince1970: 200),
            preservedAt: Date(timeIntervalSince1970: 201),
            expiresAt: expiresAt
        )
        let queuedConflict = SyncTextConflictVersion(
            entityType: .item,
            entityID: "item-1",
            fieldID: "text",
            localText: "Mac local",
            remoteText: "iPhone incoming again",
            remoteUpdatedAt: Date(timeIntervalSince1970: 250),
            preservedAt: Date(timeIntervalSince1970: 251),
            expiresAt: expiresAt
        )
        _ = conflictStore.preserve(firstConflict)
        _ = conflictStore.preserve(queuedConflict)

        let snapshot = try conflictStore.snapshot()

        // Mutate state past the snapshot point.
        _ = conflictStore.removeConflict(id: firstConflict.id)
        let thirdConflict = SyncTextConflictVersion(
            entityType: .item,
            entityID: "item-2",
            fieldID: "text",
            localText: "Mac local 2",
            remoteText: "iPhone incoming 2",
            remoteUpdatedAt: Date(timeIntervalSince1970: 300),
            preservedAt: Date(timeIntervalSince1970: 301),
            expiresAt: expiresAt
        )
        _ = conflictStore.preserve(thirdConflict)

        try conflictStore.restore(snapshot)

        let restoredActive = conflictStore.activeConflicts()
        let restoredQueued = conflictStore.queuedConflict(entityType: .item, entityID: "item-1", fieldID: "text")
        XCTAssertEqual(restoredActive.map(\.id), [firstConflict.id])
        XCTAssertEqual(restoredQueued?.conflict.remoteText, "iPhone incoming again")
    }

    func testConflictStoreSnapshotCapturesMissingFilesAsAbsentAndRestoresByRemoving() throws {
        let conflictURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sync-conflicts.json")
        let directoryURL = conflictURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let resolvedURL = directoryURL.appendingPathComponent("sync-resolved-conflicts.json")
        let queuedURL = directoryURL.appendingPathComponent("sync-queued-conflicts.json")
        let conflictStore = SyncTextConflictStore(fileURL: conflictURL)

        let snapshot = try conflictStore.snapshot()

        XCTAssertEqual(snapshot.conflicts, .absent)
        XCTAssertEqual(snapshot.resolved, .absent)
        XCTAssertEqual(snapshot.queued, .absent)

        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try Data("active".utf8).write(to: conflictURL)
        try Data("resolved".utf8).write(to: resolvedURL)
        try Data("queued".utf8).write(to: queuedURL)

        try conflictStore.restore(snapshot)

        XCTAssertFalse(FileManager.default.fileExists(atPath: conflictURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: resolvedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: queuedURL.path))
    }

    func testConflictStoreSnapshotRestoresPresentFilesWithExactBytes() throws {
        let conflictURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sync-conflicts.json")
        let directoryURL = conflictURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let resolvedURL = directoryURL.appendingPathComponent("sync-resolved-conflicts.json")
        let queuedURL = directoryURL.appendingPathComponent("sync-queued-conflicts.json")
        let conflictStore = SyncTextConflictStore(fileURL: conflictURL)

        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try Data([0, 1, 2]).write(to: conflictURL)
        try Data([3, 4, 5]).write(to: resolvedURL)
        try Data([6, 7, 8]).write(to: queuedURL)

        let snapshot = try conflictStore.snapshot()

        try Data("mutated-active".utf8).write(to: conflictURL)
        try Data("mutated-resolved".utf8).write(to: resolvedURL)
        try Data("mutated-queued".utf8).write(to: queuedURL)
        try conflictStore.restore(snapshot)

        XCTAssertEqual(try Data(contentsOf: conflictURL), Data([0, 1, 2]))
        XCTAssertEqual(try Data(contentsOf: resolvedURL), Data([3, 4, 5]))
        XCTAssertEqual(try Data(contentsOf: queuedURL), Data([6, 7, 8]))
    }

    func testConflictStoreSnapshotThrowsWhenExistingFileCannotBeRead() throws {
        let conflictURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sync-conflicts.json")
        let conflictStore = SyncTextConflictStore(
            fileURL: conflictURL,
            fileIO: SyncTextConflictStore.FileIO(
                fileExists: { _ in true },
                readData: { _ in throw CocoaError(.fileReadNoPermission) },
                createDirectory: { _ in },
                writeData: { _, _ in },
                removeItem: { _ in }
            )
        )

        XCTAssertThrowsError(try conflictStore.snapshot()) { error in
            XCTAssertEqual(
                error as? SyncTextConflictStoreSnapshotError,
                .captureFailed(path: conflictURL.path)
            )
        }
    }

    func testConflictStoreRestoreThrowsWhenPresentFileCannotBeWritten() {
        let conflictURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sync-conflicts.json")
        let conflictStore = SyncTextConflictStore(
            fileURL: conflictURL,
            fileIO: SyncTextConflictStore.FileIO(
                fileExists: { _ in false },
                readData: { _ in Data() },
                createDirectory: { _ in },
                writeData: { _, _ in throw CocoaError(.fileWriteNoPermission) },
                removeItem: { _ in }
            )
        )
        let snapshot = SyncTextConflictStoreSnapshot(
            conflicts: .present(Data("active".utf8)),
            resolved: .absent,
            queued: .absent
        )

        XCTAssertThrowsError(try conflictStore.restore(snapshot)) { error in
            XCTAssertEqual(
                error as? SyncTextConflictStoreSnapshotError,
                .restoreFailed(path: conflictURL.path)
            )
        }
    }

    func testConflictStoreRestoreThrowsWhenAbsentFileCannotBeRemoved() {
        let conflictURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sync-conflicts.json")
        let conflictStore = SyncTextConflictStore(
            fileURL: conflictURL,
            fileIO: SyncTextConflictStore.FileIO(
                fileExists: { _ in true },
                readData: { _ in Data() },
                createDirectory: { _ in },
                writeData: { _, _ in },
                removeItem: { _ in throw CocoaError(.fileWriteNoPermission) }
            )
        )
        let snapshot = SyncTextConflictStoreSnapshot(conflicts: .absent, resolved: .absent, queued: .absent)

        XCTAssertThrowsError(try conflictStore.restore(snapshot)) { error in
            XCTAssertEqual(
                error as? SyncTextConflictStoreSnapshotError,
                .restoreFailed(path: conflictURL.path)
            )
        }
    }

    func testCheckedConflictCommitThrowsWhenActiveConflictWriteFails() {
        let conflictURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sync-conflicts.json")
        let conflictStore = SyncTextConflictStore(
            fileURL: conflictURL,
            fileIO: SyncTextConflictStore.FileIO(
                fileExists: { _ in false },
                readData: { _ in Data() },
                createDirectory: { _ in },
                writeData: { _, _ in throw CocoaError(.fileWriteNoPermission) },
                removeItem: { _ in }
            )
        )
        let conflict = SyncTextConflictVersion(
            entityType: .item,
            entityID: "item-1",
            fieldID: "text",
            localText: "Local",
            remoteText: "Remote",
            remoteUpdatedAt: Date(timeIntervalSince1970: 200),
            expiresAt: Date().addingTimeInterval(1_000)
        )

        XCTAssertThrowsError(try conflictStore.commitChecked(SyncTextConflictCommitEffects(
            preservedConflicts: [conflict]
        )))
    }

    func testCheckedConflictCommitThrowsWhenQueuedConflictWriteFails() {
        let conflictURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sync-conflicts.json")
        let directoryURL = conflictURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let conflictStore = SyncTextConflictStore(fileURL: conflictURL)
        let activeConflict = SyncTextConflictVersion(
            entityType: .item,
            entityID: "item-1",
            fieldID: "text",
            localText: "Local",
            remoteText: "Remote 1",
            remoteUpdatedAt: Date(timeIntervalSince1970: 200),
            expiresAt: Date().addingTimeInterval(1_000)
        )
        _ = conflictStore.preserve(activeConflict)
        let failingStore = SyncTextConflictStore(
            fileURL: conflictURL,
            fileIO: SyncTextConflictStore.FileIO(
                fileExists: { FileManager.default.fileExists(atPath: $0) },
                readData: { try Data(contentsOf: $0) },
                createDirectory: {
                    try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
                },
                writeData: { data, url in
                    if url.lastPathComponent == "sync-queued-conflicts.json" {
                        throw CocoaError(.fileWriteNoPermission)
                    }
                    try data.write(to: url, options: [.atomic])
                },
                removeItem: { try FileManager.default.removeItem(at: $0) }
            )
        )
        let newerConflict = SyncTextConflictVersion(
            entityType: .item,
            entityID: "item-1",
            fieldID: "text",
            localText: "Local",
            remoteText: "Remote 2",
            remoteUpdatedAt: Date(timeIntervalSince1970: 300),
            expiresAt: Date().addingTimeInterval(1_000)
        )

        XCTAssertThrowsError(try failingStore.commitChecked(SyncTextConflictCommitEffects(
            preservedConflicts: [newerConflict]
        )))
        XCTAssertNil(conflictStore.queuedConflict(entityType: .item, entityID: "item-1", fieldID: "text"))
    }

    func testCheckedConflictCommitThrowsWhenResolvedConflictWriteFails() {
        let conflictURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sync-conflicts.json")
        let directoryURL = conflictURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let conflictStore = SyncTextConflictStore(fileURL: conflictURL)
        let conflict = SyncTextConflictVersion(
            entityType: .item,
            entityID: "item-1",
            fieldID: "text",
            localText: "Local",
            remoteText: "Remote",
            remoteUpdatedAt: Date(timeIntervalSince1970: 200),
            expiresAt: Date().addingTimeInterval(1_000)
        )
        _ = conflictStore.preserve(conflict)
        let failingStore = SyncTextConflictStore(
            fileURL: conflictURL,
            fileIO: SyncTextConflictStore.FileIO(
                fileExists: { FileManager.default.fileExists(atPath: $0) },
                readData: { try Data(contentsOf: $0) },
                createDirectory: {
                    try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
                },
                writeData: { data, url in
                    if url.lastPathComponent == "sync-resolved-conflicts.json" {
                        throw CocoaError(.fileWriteNoPermission)
                    }
                    try data.write(to: url, options: [.atomic])
                },
                removeItem: { try FileManager.default.removeItem(at: $0) }
            )
        )

        XCTAssertThrowsError(try failingStore.commitChecked(SyncTextConflictCommitEffects(
            removedResolvedConflicts: [conflict]
        )))
    }

    func testCheckedConflictCommitQueuesSameFieldConflictWithoutDroppingActiveConflict() throws {
        let conflictURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sync-conflicts.json")
        defer { try? FileManager.default.removeItem(at: conflictURL.deletingLastPathComponent()) }
        let conflictStore = SyncTextConflictStore(fileURL: conflictURL)
        let activeConflict = SyncTextConflictVersion(
            entityType: .item,
            entityID: "item-1",
            fieldID: "text",
            localText: "Local",
            remoteText: "Remote 1",
            remoteUpdatedAt: Date(timeIntervalSince1970: 200),
            expiresAt: Date().addingTimeInterval(1_000)
        )
        let newerConflict = SyncTextConflictVersion(
            entityType: .item,
            entityID: "item-1",
            fieldID: "text",
            localText: "Local",
            remoteText: "Remote 2",
            remoteUpdatedAt: Date(timeIntervalSince1970: 300),
            expiresAt: Date().addingTimeInterval(1_000)
        )

        try conflictStore.commitChecked(SyncTextConflictCommitEffects(preservedConflicts: [activeConflict]))
        try conflictStore.commitChecked(SyncTextConflictCommitEffects(preservedConflicts: [newerConflict]))

        XCTAssertEqual(conflictStore.activeConflicts().map(\.id), [activeConflict.id])
        XCTAssertEqual(
            conflictStore.queuedConflict(entityType: .item, entityID: "item-1", fieldID: "text")?.conflict.id,
            newerConflict.id
        )
    }

    func testPreserveExactRemoteConflictTwiceDoesNotQueueDuplicate() {
        let conflictURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sync-conflicts.json")
        defer { try? FileManager.default.removeItem(at: conflictURL.deletingLastPathComponent()) }
        let conflictStore = SyncTextConflictStore(fileURL: conflictURL)
        let activeConflict = SyncTextConflictVersion(
            entityType: .item,
            entityID: "item-1",
            fieldID: "text",
            localText: "Local 1",
            remoteText: "Remote",
            remoteUpdatedAt: Date(timeIntervalSince1970: 200),
            preservedAt: Date(timeIntervalSince1970: 300),
            expiresAt: Date().addingTimeInterval(1_000)
        )
        let redeliveredConflict = SyncTextConflictVersion(
            entityType: .item,
            entityID: "item-1",
            fieldID: "text",
            localText: "Local 2",
            remoteText: "Remote",
            remoteUpdatedAt: Date(timeIntervalSince1970: 200),
            preservedAt: Date(timeIntervalSince1970: 400),
            expiresAt: Date().addingTimeInterval(1_000)
        )

        _ = conflictStore.preserve(activeConflict)
        _ = conflictStore.preserve(redeliveredConflict)

        XCTAssertEqual(conflictStore.activeConflicts().map(\.id), [activeConflict.id])
        XCTAssertNil(conflictStore.queuedConflict(entityType: .item, entityID: "item-1", fieldID: "text"))
    }

    func testCheckedCommitExactRemoteConflictTwiceDoesNotQueueDuplicate() throws {
        let conflictURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sync-conflicts.json")
        defer { try? FileManager.default.removeItem(at: conflictURL.deletingLastPathComponent()) }
        let conflictStore = SyncTextConflictStore(fileURL: conflictURL)
        let activeConflict = SyncTextConflictVersion(
            entityType: .item,
            entityID: "item-1",
            fieldID: "text",
            localText: "Local 1",
            remoteText: "Remote",
            remoteUpdatedAt: Date(timeIntervalSince1970: 200),
            preservedAt: Date(timeIntervalSince1970: 300),
            expiresAt: Date().addingTimeInterval(1_000)
        )
        let redeliveredConflict = SyncTextConflictVersion(
            entityType: .item,
            entityID: "item-1",
            fieldID: "text",
            localText: "Local 2",
            remoteText: "Remote",
            remoteUpdatedAt: Date(timeIntervalSince1970: 200),
            preservedAt: Date(timeIntervalSince1970: 400),
            expiresAt: Date().addingTimeInterval(1_000)
        )

        try conflictStore.commitChecked(SyncTextConflictCommitEffects(preservedConflicts: [activeConflict]))
        try conflictStore.commitChecked(SyncTextConflictCommitEffects(preservedConflicts: [redeliveredConflict]))

        XCTAssertEqual(conflictStore.activeConflicts().map(\.id), [activeConflict.id])
        XCTAssertNil(conflictStore.queuedConflict(entityType: .item, entityID: "item-1", fieldID: "text"))
    }

    func testRemovingResolvedConflictClearsDuplicateEntityFieldConflicts() {
        let conflictURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sync-conflicts.json")
        defer { try? FileManager.default.removeItem(at: conflictURL.deletingLastPathComponent()) }
        let conflictStore = SyncTextConflictStore(fileURL: conflictURL)
        let expiresAt = Date().addingTimeInterval(1_000)
        let firstConflict = SyncTextConflictVersion(
            entityType: .item,
            entityID: "item-1",
            fieldID: "text",
            localText: "Mac local",
            remoteText: "iPhone incoming",
            remoteUpdatedAt: Date(timeIntervalSince1970: 200),
            preservedAt: Date(timeIntervalSince1970: 201),
            expiresAt: expiresAt
        )
        let duplicateConflict = SyncTextConflictVersion(
            entityType: .item,
            entityID: "item-1",
            fieldID: "text",
            localText: "Mac local edited",
            remoteText: "iPhone incoming edited",
            remoteUpdatedAt: Date(timeIntervalSince1970: 250),
            preservedAt: Date(timeIntervalSince1970: 251),
            expiresAt: expiresAt
        )
        _ = conflictStore.replaceConflicts([firstConflict, duplicateConflict])

        XCTAssertTrue(conflictStore.removeResolvedConflict(firstConflict).isEmpty)
        XCTAssertTrue(conflictStore.preserve(duplicateConflict).isEmpty)
    }

    func testResolvedConflictDoesNotPreserveAgainWhenStaleMessageIsReversed() {
        let conflictURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sync-conflicts.json")
        defer { try? FileManager.default.removeItem(at: conflictURL.deletingLastPathComponent()) }
        let conflictStore = SyncTextConflictStore(fileURL: conflictURL)
        let conflict = SyncTextConflictVersion(
            entityType: .item,
            entityID: "item-1",
            fieldID: "text",
            localText: "Mac local",
            remoteText: "iPhone incoming",
            remoteUpdatedAt: Date(timeIntervalSince1970: 200),
            expiresAt: Date(timeIntervalSince1970: 1_000)
        )
        let staleReversedConflict = SyncTextConflictVersion(
            entityType: .item,
            entityID: "item-1",
            fieldID: "text",
            localText: "iPhone incoming",
            remoteText: "Mac local",
            remoteUpdatedAt: Date(timeIntervalSince1970: 250),
            expiresAt: Date(timeIntervalSince1970: 1_000)
        )
        _ = conflictStore.preserve(conflict)

        XCTAssertTrue(conflictStore.removeResolvedConflict(conflict).isEmpty)
        XCTAssertTrue(conflictStore.preserve(staleReversedConflict).isEmpty)
    }

    func testResolvedConflictDoesNotPreserveAgainWhenRichTextDataChanges() {
        let conflictURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sync-conflicts.json")
        defer { try? FileManager.default.removeItem(at: conflictURL.deletingLastPathComponent()) }
        let conflictStore = SyncTextConflictStore(fileURL: conflictURL)
        let conflict = SyncTextConflictVersion(
            entityType: .item,
            entityID: "item-1",
            fieldID: "text",
            localText: "Mac local",
            remoteText: "iPhone incoming",
            remoteData: Data("rich-a".utf8),
            remoteUpdatedAt: Date(timeIntervalSince1970: 200),
            expiresAt: Date(timeIntervalSince1970: 1_000)
        )
        let staleConflict = SyncTextConflictVersion(
            entityType: .item,
            entityID: "item-1",
            fieldID: "text",
            localText: "Mac local",
            remoteText: "iPhone incoming",
            remoteData: Data("rich-b".utf8),
            remoteUpdatedAt: Date(timeIntervalSince1970: 200),
            expiresAt: Date(timeIntervalSince1970: 1_000)
        )
        _ = conflictStore.preserve(conflict)

        XCTAssertTrue(conflictStore.removeResolvedConflict(conflict).isEmpty)
        XCTAssertTrue(conflictStore.preserve(staleConflict).isEmpty)
    }

    func testPeerPreservedConflictPerspectiveShowsCurrentLocalAndPeerVersionToSync() {
        let conflict = SyncTextConflictVersion(
            entityType: .item,
            entityID: "item-1",
            fieldID: "text",
            localText: "iPhone offline edit",
            remoteText: "Mac edit",
            remoteUpdatedAt: Date(timeIntervalSince1970: 200),
            preservedAt: Date(timeIntervalSince1970: 201),
            expiresAt: Date(timeIntervalSince1970: 1_000)
        )

        let perspective = conflict.perspectiveForPeerPreservedConflict(currentLocalText: "Mac edit with more typing")
        let normalized = conflict.normalizedForPeerPreservedConflict(currentLocalText: "Mac edit with more typing")

        XCTAssertEqual(perspective.localText, "Mac edit with more typing")
        XCTAssertEqual(perspective.versionToSyncText, "iPhone offline edit")
        XCTAssertEqual(normalized.localText, "Mac edit with more typing")
        XCTAssertEqual(normalized.remoteText, "iPhone offline edit")
        XCTAssertEqual(normalized.remoteUpdatedAt, conflict.preservedAt)
    }

    func testResolvedConflictPayloadAppliesWinnerWhenPeerDivergedFromBase() async throws {
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
            operation: .upsert,
            payload: payload,
            updatedAt: Date(timeIntervalSince1970: 300),
            originDeviceID: "device-a"
        )

        let result = await engine.applyIncomingEnvelope(SyncEnvelope(senderDeviceID: "device-a", changes: [change]))

        let record = await store.record(for: .item, entityID: "item-1")
        let conflicts = await store.activeConflicts(now: Date(timeIntervalSince1970: 301))
        XCTAssertEqual(record?.payload, Data("current winner".utf8))
        XCTAssertEqual(result.appliedChangeIDs, [change.id])
        XCTAssertTrue(conflicts.isEmpty)
    }

    func testQueuePersistenceFailureIsReported() {
        let result = FileBackedSyncQueuePersistence(fileURL: URL(fileURLWithPath: "/dev/null/queue.json"))
            .saveSnapshot(SyncQueueSnapshot())

        XCTAssertFalse(result.didPersist)
        XCTAssertNotNil(result.errorDescription)
    }

    func testSyncQueueSnapshotRoundTripsAllFields() throws {
        let fileURL = temporaryQueueURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let change = makeQueueChange(entityID: "item-1")
        let appliedID = UUID()
        let acknowledgementID = UUID()
        let snapshot = SyncQueueSnapshot(
            pendingChanges: [change],
            appliedChangeIDs: [appliedID],
            pendingAcknowledgementIDs: [acknowledgementID]
        )

        let saveResult = FileBackedSyncQueuePersistence(fileURL: fileURL).saveSnapshot(snapshot)
        let loadResult = FileBackedSyncQueuePersistence(fileURL: fileURL).loadSnapshotResult()

        XCTAssertTrue(saveResult.didPersist)
        XCTAssertEqual(loadResult.health, .healthy)
        XCTAssertEqual(loadResult.snapshot, snapshot)
    }

    func testMissingQueueFileReportsFileMissing() {
        let loadResult = FileBackedSyncQueuePersistence(fileURL: temporaryQueueURL()).loadSnapshotResult()

        XCTAssertEqual(loadResult.health, .fileMissing)
        XCTAssertEqual(loadResult.snapshot, SyncQueueSnapshot())
    }

    func testLegacyBareChangeArrayMigratesAsHealthySnapshot() throws {
        let fileURL = temporaryQueueURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let legacyChanges = [makeQueueChange(entityID: "item-1")]
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(legacyChanges).write(to: fileURL, options: [.atomic])

        let loadResult = FileBackedSyncQueuePersistence(fileURL: fileURL).loadSnapshotResult()

        XCTAssertEqual(loadResult.health, .healthy)
        XCTAssertEqual(loadResult.snapshot, SyncQueueSnapshot(pendingChanges: legacyChanges))
    }

    func testCorruptQueueFileReportsCorruptHealth() throws {
        let fileURL = temporaryQueueURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(to: fileURL, options: [.atomic])

        let loadResult = FileBackedSyncQueuePersistence(fileURL: fileURL).loadSnapshotResult()

        XCTAssertEqual(loadResult.health, .corrupt)
        XCTAssertEqual(loadResult.snapshot, SyncQueueSnapshot())
    }

    func testReplaceSnapshotPersistsAndReloadsExactly() async throws {
        let fileURL = temporaryQueueURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let replacement = SyncQueueSnapshot(
            pendingChanges: [makeQueueChange(entityID: "item-1")],
            appliedChangeIDs: [UUID()],
            pendingAcknowledgementIDs: [UUID()]
        )
        let queue = SyncQueue(persistence: FileBackedSyncQueuePersistence(fileURL: fileURL))

        try await queue.replaceSnapshot(replacement)

        let reloadedQueue = SyncQueue(persistence: FileBackedSyncQueuePersistence(fileURL: fileURL))
        let queueSnapshot = await queue.snapshot()
        let queueHealth = await queue.persistenceHealth()
        let reloadedSnapshot = await reloadedQueue.snapshot()
        XCTAssertEqual(queueSnapshot, replacement)
        XCTAssertEqual(queueHealth, .healthy)
        XCTAssertEqual(reloadedSnapshot, replacement)
    }

    func testReplaceSnapshotFailureLeavesMemoryAndDiskUnchanged() async throws {
        let initial = SyncQueueSnapshot(
            pendingChanges: [makeQueueChange(entityID: "item-1")],
            appliedChangeIDs: [UUID()],
            pendingAcknowledgementIDs: [UUID()]
        )
        let persistence = FailingSyncQueuePersistence(
            loadResult: SyncQueuePersistenceLoadResult(snapshot: initial, health: .healthy)
        )
        let queue = SyncQueue(persistence: persistence)
        let replacement = SyncQueueSnapshot(pendingChanges: [makeQueueChange(entityID: "item-2")])

        do {
            try await queue.replaceSnapshot(replacement)
            XCTFail("Expected replacement to fail")
        } catch {
            XCTAssertEqual(error as? SyncQueueReplacementError, .persistenceFailed)
        }

        let queueSnapshot = await queue.snapshot()
        XCTAssertEqual(queueSnapshot, initial)
        XCTAssertEqual(persistence.savedSnapshots, [replacement])
    }

    func testReplaceSnapshotRejectsUnhealthyLoadedPersistence() async {
        let queue = SyncQueue(
            persistence: FailingSyncQueuePersistence(
                loadResult: SyncQueuePersistenceLoadResult(snapshot: SyncQueueSnapshot(), health: .corrupt)
            )
        )

        do {
            try await queue.replaceSnapshot(SyncQueueSnapshot(pendingChanges: [makeQueueChange(entityID: "item-1")]))
            XCTFail("Expected unhealthy replacement to fail")
        } catch {
            XCTAssertEqual(error as? SyncQueueReplacementError, .unhealthyPersistence)
        }
    }

    func testOrdinaryPersistenceFailureBecomesObservableHealth() async {
        let queue = SyncQueue(
            persistence: FailingSyncQueuePersistence(
                loadResult: SyncQueuePersistenceLoadResult(snapshot: SyncQueueSnapshot(), health: .healthy)
            )
        )

        await queue.enqueue(makeQueueChange(entityID: "item-1"))

        if case .readFailed = await queue.persistenceHealth() {
            // Expected.
        } else {
            XCTFail("Expected failed enqueue persistence to mark the queue unhealthy")
        }
    }

    func testDistinctTargetPaginationReturnsSecondPageAfterAcknowledgement() async throws {
        let engine = SyncEngine(deviceID: "device-a", store: InMemorySyncStore())
        for index in 0..<101 {
            _ = await engine.recordLocalChange(
                entityType: .item,
                entityID: "item-\(index)",
                payload: Data("payload-\(index)".utf8)
            )
        }

        let firstOptionalEnvelope = await engine.nextEnvelope()
        let firstEnvelope = try XCTUnwrap(firstOptionalEnvelope)
        await engine.acknowledgeChanges(firstEnvelope.changes.map(\.id))
        let secondOptionalEnvelope = await engine.nextEnvelope()
        let secondEnvelope = try XCTUnwrap(secondOptionalEnvelope)

        XCTAssertEqual(firstEnvelope.changes.count, 100)
        XCTAssertEqual(secondEnvelope.changes.count, 1)
    }

    func testSameTargetChangesCoalesceAndDoNotExercisePagination() async throws {
        let engine = SyncEngine(deviceID: "device-a", store: InMemorySyncStore())
        for index in 0..<101 {
            _ = await engine.recordLocalChange(
                entityType: .item,
                entityID: "item-1",
                payload: Data("payload-\(index)".utf8)
            )
        }

        let optionalEnvelope = await engine.nextEnvelope()
        let envelope = try XCTUnwrap(optionalEnvelope)

        XCTAssertEqual(envelope.changes.count, 1)
        XCTAssertEqual(envelope.changes.first?.payload, Data("payload-100".utf8))
    }

    // MARK: - Two-phase legacy receive (prepare / commit)

    func testPrepareIncomingEnvelopeDoesNotMarkCandidateHandled() async throws {
        let queue = SyncQueue()
        let engine = SyncEngine(deviceID: "device-b", store: InMemorySyncStore(), queue: queue)
        let change = SyncChange(
            entityType: .item,
            entityID: "item-1",
            operation: .upsert,
            payload: Data("payload".utf8),
            updatedAt: Date(timeIntervalSince1970: 100),
            originDeviceID: "device-a"
        )
        let envelope = SyncEnvelope(senderDeviceID: "device-a", changes: [change])

        let preparation = await engine.prepareIncomingEnvelope(envelope)

        XCTAssertEqual(preparation.candidateChanges, [change])
        XCTAssertTrue(preparation.alreadyHandledChangeIDs.isEmpty)
        let hasApplied = await queue.hasApplied(change.id)
        XCTAssertFalse(hasApplied)
        let pendingAcknowledgementIDs = await queue.acknowledgementBatch()
        XCTAssertFalse(pendingAcknowledgementIDs.contains(change.id))
    }

    func testStrictCommitPersistsHandledStateAcrossRestart() async throws {
        let fileURL = temporaryQueueURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let change = SyncChange(
            entityType: .item,
            entityID: "item-1",
            operation: .upsert,
            payload: Data("payload".utf8),
            updatedAt: Date(timeIntervalSince1970: 100),
            originDeviceID: "device-a"
        )
        let firstEngine = SyncEngine(
            deviceID: "device-b",
            store: InMemorySyncStore(),
            queue: SyncQueue(persistence: FileBackedSyncQueuePersistence(fileURL: fileURL))
        )
        let firstPreparation = await firstEngine.prepareIncomingEnvelope(
            SyncEnvelope(senderDeviceID: "device-a", changes: [change])
        )
        try await firstEngine.commitHandledIncomingChanges(Set(firstPreparation.candidateChanges.map(\.id)))

        let restartedEngine = SyncEngine(
            deviceID: "device-b",
            store: InMemorySyncStore(),
            queue: SyncQueue(persistence: FileBackedSyncQueuePersistence(fileURL: fileURL))
        )
        let secondPreparation = await restartedEngine.prepareIncomingEnvelope(
            SyncEnvelope(senderDeviceID: "device-a", changes: [change])
        )

        XCTAssertTrue(secondPreparation.candidateChanges.isEmpty)
        XCTAssertEqual(secondPreparation.alreadyHandledChangeIDs, [change.id])
    }

    func testStrictCommitFailureRollsBackAndThrows() async throws {
        let queue = SyncQueue(
            persistence: FailingSyncQueuePersistence(
                loadResult: SyncQueuePersistenceLoadResult(snapshot: SyncQueueSnapshot(), health: .healthy)
            )
        )
        let engine = SyncEngine(deviceID: "device-b", store: InMemorySyncStore(), queue: queue)
        let change = SyncChange(
            entityType: .item,
            entityID: "item-1",
            operation: .upsert,
            payload: Data("payload".utf8),
            updatedAt: Date(timeIntervalSince1970: 100),
            originDeviceID: "device-a"
        )
        let preparation = await engine.prepareIncomingEnvelope(
            SyncEnvelope(senderDeviceID: "device-a", changes: [change])
        )

        do {
            try await engine.commitHandledIncomingChanges(Set(preparation.candidateChanges.map(\.id)))
            XCTFail("Expected strict commit to throw")
        } catch {
            XCTAssertEqual(error as? SyncHandledStateCommitError, .persistenceFailed)
        }

        let hasApplied = await queue.hasApplied(change.id)
        XCTAssertFalse(hasApplied)
        let pendingAcknowledgementIDs = await queue.acknowledgementBatch()
        XCTAssertFalse(pendingAcknowledgementIDs.contains(change.id))

        let redeliveredPreparation = await engine.prepareIncomingEnvelope(
            SyncEnvelope(senderDeviceID: "device-a", changes: [change])
        )
        XCTAssertEqual(redeliveredPreparation.candidateChanges, [change])
    }

    func testCompatibilityWrapperMarksAppliedCandidateTerminal() async throws {
        let queue = SyncQueue()
        let engine = SyncEngine(deviceID: "device-b", store: InMemorySyncStore(), queue: queue)
        let change = SyncChange(
            entityType: .item,
            entityID: "item-1",
            operation: .upsert,
            payload: Data("payload".utf8),
            updatedAt: Date(timeIntervalSince1970: 100),
            originDeviceID: "device-a"
        )

        let result = await engine.applyIncomingEnvelope(SyncEnvelope(senderDeviceID: "device-a", changes: [change]))

        XCTAssertEqual(result.appliedChangeIDs, [change.id])
        let hasApplied = await queue.hasApplied(change.id)
        XCTAssertTrue(hasApplied)
        let pendingAcknowledgementIDs = await queue.acknowledgementBatch()
        XCTAssertTrue(pendingAcknowledgementIDs.contains(change.id))

        let redelivered = await engine.applyIncomingEnvelope(SyncEnvelope(senderDeviceID: "device-a", changes: [change]))
        XCTAssertEqual(redelivered.ignoredDuplicateIDs, [change.id])
    }

    /// Regression test: the compatibility wrapper must treat a store-rejected
    /// stale change as terminal, the same as the pre-two-phase implementation.
    /// Otherwise a deterministically stale change is redelivered forever and
    /// never classifies as a duplicate.
    func testCompatibilityWrapperMarksStaleCandidateTerminal() async throws {
        let queue = SyncQueue()
        let store = InMemorySyncStore(seedRecords: [
            SyncRecord(
                entityType: .item,
                entityID: "item-1",
                payload: Data("newer".utf8),
                updatedAt: Date(timeIntervalSince1970: 200)
            )
        ])
        let engine = SyncEngine(deviceID: "device-b", store: store, queue: queue)
        let staleChange = SyncChange(
            entityType: .item,
            entityID: "item-1",
            operation: .upsert,
            payload: Data("older".utf8),
            updatedAt: Date(timeIntervalSince1970: 100),
            originDeviceID: "device-a"
        )

        let result = await engine.applyIncomingEnvelope(
            SyncEnvelope(senderDeviceID: "device-a", changes: [staleChange])
        )

        XCTAssertEqual(result.ignoredStaleIDs, [staleChange.id])
        XCTAssertTrue(result.appliedChangeIDs.isEmpty)
        let hasApplied = await queue.hasApplied(staleChange.id)
        XCTAssertTrue(
            hasApplied,
            "A deterministically stale change must still be committed as handled so it becomes terminal."
        )
        let pendingAcknowledgementIDs = await queue.acknowledgementBatch()
        XCTAssertTrue(pendingAcknowledgementIDs.contains(staleChange.id))

        let redelivered = await engine.applyIncomingEnvelope(
            SyncEnvelope(senderDeviceID: "device-a", changes: [staleChange])
        )
        XCTAssertEqual(redelivered.ignoredDuplicateIDs, [staleChange.id])
        XCTAssertTrue(
            redelivered.ignoredStaleIDs.isEmpty,
            "Redelivery of a terminal stale change must classify as duplicate, not stale again."
        )
    }

    func testCompatibilityPersistenceFailureRetainsHandledStateAndDegradesHealth() async throws {
        let persistence = FailingSyncQueuePersistence(
            loadResult: SyncQueuePersistenceLoadResult(snapshot: SyncQueueSnapshot(), health: .healthy)
        )
        let queue = SyncQueue(persistence: persistence)
        let engine = SyncEngine(deviceID: "device-b", store: InMemorySyncStore(), queue: queue)
        let change = SyncChange(
            entityType: .item,
            entityID: "item-1",
            operation: .upsert,
            payload: Data("payload".utf8),
            updatedAt: Date(timeIntervalSince1970: 100),
            originDeviceID: "device-a"
        )

        let result = await engine.applyIncomingEnvelope(SyncEnvelope(senderDeviceID: "device-a", changes: [change]))

        XCTAssertEqual(result.appliedChangeIDs, [change.id])
        let hasApplied = await queue.hasApplied(change.id)
        XCTAssertTrue(
            hasApplied,
            "Compatibility commit must retain in-memory handled state even when persistence fails"
        )
        let pendingAcknowledgementIDs = await queue.acknowledgementBatch()
        XCTAssertTrue(pendingAcknowledgementIDs.contains(change.id))
        if case .readFailed = await queue.persistenceHealth() {
            // Expected.
        } else {
            XCTFail("Expected persistence failure to degrade queue health")
        }
    }

    func testPrepareIncomingEnvelopeExcludesDurableDuplicateFromCandidates() async throws {
        let queue = SyncQueue()
        let engine = SyncEngine(deviceID: "device-b", store: InMemorySyncStore(), queue: queue)
        let change = SyncChange(
            entityType: .item,
            entityID: "item-1",
            operation: .upsert,
            payload: Data("payload".utf8),
            updatedAt: Date(timeIntervalSince1970: 100),
            originDeviceID: "device-a"
        )
        let envelope = SyncEnvelope(senderDeviceID: "device-a", changes: [change])
        let firstPreparation = await engine.prepareIncomingEnvelope(envelope)
        try await engine.commitHandledIncomingChanges(Set(firstPreparation.candidateChanges.map(\.id)))

        let secondPreparation = await engine.prepareIncomingEnvelope(envelope)

        XCTAssertEqual(secondPreparation.alreadyHandledChangeIDs, [change.id])
        XCTAssertTrue(secondPreparation.candidateChanges.isEmpty)
    }

    func testPrepareIncomingEnvelopeMixedBehaviorPreservesEachCategory() async throws {
        let queue = SyncQueue()
        let store = InMemorySyncStore(seedRecords: [
            SyncRecord(
                entityType: .item,
                entityID: "stale-item",
                payload: Data("newer".utf8),
                updatedAt: Date(timeIntervalSince1970: 200)
            )
        ])
        let engine = SyncEngine(deviceID: "device-b", store: store, queue: queue)

        let localChange = await engine.recordLocalChange(
            entityType: .collection,
            entityID: "collection-1",
            payload: Data("Inbox".utf8),
            updatedAt: Date(timeIntervalSince1970: 50)
        )

        let duplicateChange = SyncChange(
            entityType: .item,
            entityID: "item-duplicate",
            operation: .upsert,
            payload: Data("payload".utf8),
            updatedAt: Date(timeIntervalSince1970: 100),
            originDeviceID: "device-a"
        )
        let firstDuplicatePreparation = await engine.prepareIncomingEnvelope(
            SyncEnvelope(senderDeviceID: "device-a", changes: [duplicateChange])
        )
        try await engine.commitHandledIncomingChanges(Set(firstDuplicatePreparation.candidateChanges.map(\.id)))

        let newChange = SyncChange(
            entityType: .item,
            entityID: "item-new",
            operation: .upsert,
            payload: Data("new".utf8),
            updatedAt: Date(timeIntervalSince1970: 100),
            originDeviceID: "device-a"
        )
        let staleChange = SyncChange(
            entityType: .item,
            entityID: "stale-item",
            operation: .upsert,
            payload: Data("older".utf8),
            updatedAt: Date(timeIntervalSince1970: 100),
            originDeviceID: "device-a"
        )

        let mixedEnvelope = SyncEnvelope(
            senderDeviceID: "device-a",
            changes: [duplicateChange, newChange, staleChange],
            acknowledgedChangeIDs: [localChange.id]
        )

        let preparation = await engine.prepareIncomingEnvelope(mixedEnvelope)

        XCTAssertEqual(preparation.acknowledgedLocalChanges.map(\.id), [localChange.id])
        XCTAssertEqual(preparation.alreadyHandledChangeIDs, [duplicateChange.id])
        XCTAssertEqual(Set(preparation.candidateChanges.map(\.id)), [newChange.id, staleChange.id])

        var handledChangeIDs: Set<UUID> = []
        var appliedChangeIDs: Set<UUID> = []
        var staleChangeIDs: Set<UUID> = []
        for change in preparation.candidateChanges {
            let didApply = await store.apply(change)
            if didApply {
                appliedChangeIDs.insert(change.id)
            } else {
                staleChangeIDs.insert(change.id)
            }
            handledChangeIDs.insert(change.id)
        }
        try await engine.commitHandledIncomingChanges(handledChangeIDs)

        XCTAssertEqual(appliedChangeIDs, [newChange.id])
        XCTAssertEqual(staleChangeIDs, [staleChange.id])
    }

    private func temporaryQueueURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sync-queue.json")
    }

    private func makeQueueChange(entityID: String) -> SyncChange {
        SyncChange(
            entityType: .item,
            entityID: entityID,
            operation: .upsert,
            payload: Data(entityID.utf8),
            updatedAt: Date(timeIntervalSince1970: 100),
            originDeviceID: "device-a"
        )
    }
}

private final class FailingSyncQueuePersistence: SyncQueuePersistence, @unchecked Sendable {
    private let loadResult: SyncQueuePersistenceLoadResult
    private(set) var savedSnapshots: [SyncQueueSnapshot] = []

    init(loadResult: SyncQueuePersistenceLoadResult) {
        self.loadResult = loadResult
    }

    func loadSnapshotResult() -> SyncQueuePersistenceLoadResult {
        loadResult
    }

    func saveSnapshot(_ snapshot: SyncQueueSnapshot) -> SyncPersistenceResult {
        savedSnapshots.append(snapshot)
        return SyncPersistenceResult(didPersist: false, errorDescription: "Injected failure")
    }
}
