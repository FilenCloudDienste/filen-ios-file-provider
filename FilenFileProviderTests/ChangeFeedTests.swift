import FileProvider
import XCTest

/// The replicated provider's incremental half, driven against the live cache: the working set the
/// system syncs down without anyone browsing, and the diff it applies on top of it.
///
/// None of this can be exercised by running the extension — a replicated extension does not run in
/// the simulator — so the enumerator and the cache calls behind it are driven directly here.
final class ChangeFeedTests: XCTestCase {
	private var state: FilenMobileCacheState!
	private var workDir: URL!
	private var rootUuid: String!
	private var createdRootDirId: FfiId?

	override func setUpWithError() throws {
		try super.setUpWithError()

		guard let credentials = TestAuth.credentialsFromEnvironment() else {
			throw XCTSkip(
				"""
				Live change-feed tests need a session in the environment: \
				\(TestAuth.requiredVariables.joined(separator: ", ")).
				""")
		}

		workDir = FileManager.default.temporaryDirectory
			.appending(component: "filen-changefeed-tests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

		let authFile = workDir.appending(component: "auth.json")
		let dek = try TestAuth.provision(authFile: authFile, credentials: credentials)
		state = FilenMobileCacheState(
			filesDir: workDir.path(percentEncoded: false),
			authFile: authFile.path(percentEncoded: false),
			dek: dek)
		rootUuid = try state.rootUuid()
	}

	override func tearDown() async throws {
		if let createdRootDirId {
			_ = try? await state.trashItem(path: createdRootDirId)
		}
		state = nil
		if let workDir { try? FileManager.default.removeItem(at: workDir) }
		try await super.tearDown()
	}

	// MARK: - Observer double

	/// Captures both halves of what an enumerator reports: a full enumeration and a diff.
	private final class Recorder: NSObject, NSFileProviderEnumerationObserver,
		NSFileProviderChangeObserver, @unchecked Sendable
	{
		private let lock = NSLock()
		private var items: [NSFileProviderItem] = []
		private var deleted: [NSFileProviderItemIdentifier] = []
		private var anchor: NSFileProviderSyncAnchor?
		private var error: Error?
		private let done = XCTestExpectation(description: "enumeration finished")

		func didEnumerate(_ updatedItems: [any NSFileProviderItemProtocol]) {
			lock.withLock { items.append(contentsOf: updatedItems) }
		}

		func didUpdate(_ updatedItems: [any NSFileProviderItemProtocol]) {
			lock.withLock { items.append(contentsOf: updatedItems) }
		}

		func didDeleteItems(withIdentifiers deletedItemIdentifiers: [NSFileProviderItemIdentifier]) {
			lock.withLock { deleted.append(contentsOf: deletedItemIdentifiers) }
		}

		func finishEnumerating(upTo nextPage: NSFileProviderPage?) { done.fulfill() }

		func finishEnumeratingChanges(upTo anchor: NSFileProviderSyncAnchor, moreComing: Bool) {
			lock.withLock { self.anchor = anchor }
			done.fulfill()
		}

		func finishEnumeratingWithError(_ error: any Error) {
			lock.withLock { self.error = error }
			done.fulfill()
		}

		var expectation: XCTestExpectation { done }
		var enumerated: [NSFileProviderItem] { lock.withLock { items } }
		var deletedIdentifiers: [NSFileProviderItemIdentifier] { lock.withLock { deleted } }
		var finalAnchor: NSFileProviderSyncAnchor? { lock.withLock { anchor } }
		var failure: Error? { lock.withLock { error } }
	}

	private func makeIsolatedDir(_ prefix: String) async throws -> DirWithPathResponse {
		let dir = try await state.createDir(
			parentPath: rootUuid, name: "\(prefix)-\(UUID().uuidString)", created: nil)
		createdRootDirId = dir.id
		return dir
	}

	private func enumerateWorkingSet() -> Recorder {
		let enumerator = WorkingSetEnumerator(state: state, rootUuid: rootUuid, inFlight: InFlightWork())
		let recorder = Recorder()
		enumerator.enumerateItems(
			for: recorder,
			startingAt: NSFileProviderPage(NSFileProviderPage.initialPageSortedByName as Data))
		wait(for: [recorder.expectation], timeout: 120)
		return recorder
	}

	private func enumerateChanges(from anchor: NSFileProviderSyncAnchor) -> Recorder {
		let enumerator = WorkingSetEnumerator(state: state, rootUuid: rootUuid, inFlight: InFlightWork())
		let recorder = Recorder()
		enumerator.enumerateChanges(for: recorder, from: anchor)
		wait(for: [recorder.expectation], timeout: 120)
		return recorder
	}

	private func currentAnchor() throws -> NSFileProviderSyncAnchor {
		let enumerator = WorkingSetEnumerator(state: state, rootUuid: rootUuid, inFlight: InFlightWork())
		var anchor: NSFileProviderSyncAnchor?
		let read = expectation(description: "anchor read")
		enumerator.currentSyncAnchor { value in
			anchor = value
			read.fulfill()
		}
		wait(for: [read], timeout: 30)
		return try XCTUnwrap(anchor, "the working set must always have an anchor")
	}

	// MARK: - The working set

	/// A favourite is a stake in the item by definition, so it belongs to the set the system keeps
	/// up to date whether or not anyone is browsing its folder.
	func testTheWorkingSetServesAFavouritedItem() async throws {
		let dir = try await makeIsolatedDir("ws")
		let file = try await state.createEmptyFile(
			parentPath: dir.id, name: "favourite.txt", mime: "text/plain")
		_ = try await state.setFavoriteRank(
			item: "stable/\(file.file.stableUuid)", favoriteRank: 1)

		let recorder = enumerateWorkingSet()

		XCTAssertNil(recorder.failure)
		let served = try XCTUnwrap(
			recorder.enumerated.first {
				$0.itemIdentifier.rawValue == "stable/\(file.file.stableUuid)"
			}, "a favourited file must be in the working set")
		XCTAssertEqual(served.filename, "favourite.txt")
		XCTAssertEqual(
			served.parentItemIdentifier, NSFileProviderItemIdentifier("stable/\(dir.dir.uuid)"),
			"the working set reports the item's real container, not the working-set sentinel")
	}

	// MARK: - The diff

	/// The round trip the whole thing exists for: hold an anchor, make a change, be told about it.
	func testANewItemIsServedAsAnUpdateWithAFreshAnchor() async throws {
		let dir = try await makeIsolatedDir("feed-new")
		let anchor = try currentAnchor()

		let file = try await state.createEmptyFile(
			parentPath: dir.id, name: "appeared.txt", mime: "text/plain")

		let recorder = enumerateChanges(from: anchor)

		XCTAssertNil(recorder.failure)
		XCTAssertTrue(
			recorder.enumerated.contains {
				$0.itemIdentifier.rawValue == "stable/\(file.file.stableUuid)"
			}, "an item created after the anchor must be in the diff")
		XCTAssertNotEqual(
			recorder.finalAnchor, anchor, "the anchor must move with the change it served")
	}

	/// A deletion cannot be served as an item — there is nothing left to render — so it arrives as
	/// the identifier to drop, in the same `stable/` namespace everything else uses.
	func testADeletedItemIsServedAsAnIdentifierToDrop() async throws {
		let dir = try await makeIsolatedDir("feed-delete")
		let file = try await state.createEmptyFile(
			parentPath: dir.id, name: "doomed.txt", mime: "text/plain")
		let anchor = try currentAnchor()

		try await state.deleteItem(item: "stable/\(file.file.stableUuid)")

		let recorder = enumerateChanges(from: anchor)

		XCTAssertNil(recorder.failure)
		XCTAssertTrue(
			recorder.deletedIdentifiers.contains(
				NSFileProviderItemIdentifier("stable/\(file.file.stableUuid)")),
			"a deleted file must be served under its stable id: \(recorder.deletedIdentifiers)")
	}

	/// An anchor this database never issued names a history that no longer exists. Honouring it
	/// would silently under-report; the contract is to say so, and the system re-enumerates.
	func testAnAnchorFromAnotherDatabaseExpires() throws {
		let recorder = enumerateChanges(
			from: NSFileProviderSyncAnchor(Data(repeating: 0xAB, count: 24)))

		let error = try XCTUnwrap(recorder.failure, "a foreign anchor must not be honoured") as NSError
		XCTAssertEqual(error.domain, NSFileProviderErrorDomain)
		XCTAssertEqual(error.code, NSFileProviderError.syncAnchorExpired.rawValue)
	}

	// MARK: - Versions

	/// The metadata version is the cache's change sequence, so it must move for a rename — and the
	/// content version must not, or every rename would redownload the file.
	func testARenameMovesTheMetadataVersionAndLeavesTheContentVersion() async throws {
		let dir = try await makeIsolatedDir("version")
		let file = try await state.createEmptyFile(
			parentPath: dir.id, name: "before.txt", mime: "text/plain")
		let identifier = NSFileProviderItemIdentifier("stable/\(file.file.stableUuid)")

		let before = try await FileProviderExtension.resolveItem(
			state: state, identifier: identifier, rootUuid: rootUuid)
		_ = try await state.renameItem(item: identifier.rawValue, newName: "after.txt")
		let after = try await FileProviderExtension.resolveItem(
			state: state, identifier: identifier, rootUuid: rootUuid)

		XCTAssertEqual(after.filename, "after.txt")
		XCTAssertNotEqual(
			before.itemVersion?.metadataVersion, after.itemVersion?.metadataVersion,
			"a rename is a metadata change and must move the change sequence")
		XCTAssertEqual(
			before.itemVersion?.contentVersion, after.itemVersion?.contentVersion,
			"a rename does not touch the bytes")
	}

	// MARK: - Item lookup

	/// An identifier that resolves to nothing is the system's cue to drop the item from disk, and
	/// it only gets there through `noSuchItem`.
	func testAnUnknownIdentifierIsNoSuchItem() async throws {
		do {
			_ = try await FileProviderExtension.resolveItem(
				state: state,
				identifier: NSFileProviderItemIdentifier("stable/\(UUID().uuidString)"),
				rootUuid: rootUuid)
			XCTFail("an identifier naming nothing must not resolve to an item")
		} catch {
			let nsError = error as NSError
			XCTAssertEqual(nsError.domain, NSFileProviderErrorDomain)
			XCTAssertEqual(nsError.code, NSFileProviderError.noSuchItem.rawValue)
		}
	}

	/// A live item resolves out of the cache, with the container it lives in.
	func testAKnownIdentifierResolvesToItsItem() async throws {
		let dir = try await makeIsolatedDir("lookup")
		let file = try await state.createEmptyFile(
			parentPath: dir.id, name: "found.txt", mime: "text/plain")

		let item = try await FileProviderExtension.resolveItem(
			state: state,
			identifier: NSFileProviderItemIdentifier("stable/\(file.file.stableUuid)"),
			rootUuid: rootUuid)

		XCTAssertEqual(item.filename, "found.txt")
		XCTAssertEqual(
			item.parentItemIdentifier, NSFileProviderItemIdentifier("stable/\(dir.dir.uuid)"))
	}

	/// The trash is the one container with no cache row of its own, so the system's view of it is
	/// synthesized rather than looked up — and it must still resolve, or trashing has nowhere to
	/// put anything.
	func testTheTrashContainerResolves() async throws {
		let item = try await FileProviderExtension.resolveItem(
			state: state, identifier: .trashContainer, rootUuid: rootUuid)

		XCTAssertEqual(item.itemIdentifier, .trashContainer)
		XCTAssertFalse(item.filename.isEmpty)
	}

	// MARK: - Working-set tracking

	/// Counts the "something in your working set moved" signals the cache raises.
	private final class SignalCounter: WorkingSetUpdateListener, @unchecked Sendable {
		private let lock = NSLock()
		private var signals = 0

		func workingSetChanged() { lock.withLock { signals += 1 } }
		var count: Int { lock.withLock { signals } }
	}

	/// The bridge, as far as it can be driven without the server endpoint: a file with a stake in
	/// it becomes a tracked lineage, a change to that file made on the drive comes back through
	/// the engine's socket rather than through anybody asking, and the listener is what says so.
	///
	/// Reconciliation is asked for twice on purpose — the second pass has nothing to add or drop
	/// and must still succeed, because every membership-changing call makes the same request.
	func testTrackingCarriesADriveChangeIntoTheWorkingSet() async throws {
		let dir = try await makeIsolatedDir("tracking")
		let file = try await state.createEmptyFile(
			parentPath: dir.id, name: "tracked.txt", mime: "text/plain")
		let identifier = "stable/\(file.file.stableUuid)"
		// A favourite is a stake, and a stake is what puts the file under tracking.
		_ = try await state.setFavoriteRank(item: identifier, favoriteRank: 1)

		let signals = SignalCounter()
		state.setWorkingSetListener(listener: signals)
		try await state.refreshWorkingSetTracking()
		try await state.refreshWorkingSetTracking()

		// A drive change to the tracked file. Nothing here asks the cache about the item: the only
		// path from the change to the signal is the socket, the file sync root, and the bridge.
		//
		// Repeated because the engine's socket connects asynchronously behind the registration,
		// and an event that lands before it is up is never redelivered — healing that gap is the
		// one part still waiting on `v3/file/stable`. Each pass is a real drive change, so the
		// first one after the socket is up is delivered.
		for attempt in 0..<10 where signals.count == 0 {
			_ = try await state.setFavoriteRank(
				item: identifier, favoriteRank: attempt % 2 == 0 ? 0 : 1)
			let deadline = Date().addingTimeInterval(6)
			while signals.count == 0 && Date() < deadline {
				try await Task.sleep(nanoseconds: 250_000_000)
			}
		}
		XCTAssertGreaterThan(
			signals.count, 0,
			"a change to a tracked file has to reach the replica without it having asked")

		// Teardown drops the registrations, not the set: it is rebuilt from the database, so a
		// refresh afterwards is a fresh start rather than an error. Stopped again at the end so
		// the test leaves no tracking — and so no engine — running behind it.
		state.stopWorkingSetTracking()
		try await state.refreshWorkingSetTracking()
		state.stopWorkingSetTracking()
		state.setWorkingSetListener(listener: nil)
	}
}
