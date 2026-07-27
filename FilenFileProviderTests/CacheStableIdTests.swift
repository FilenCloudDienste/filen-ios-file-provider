import XCTest

/// Integration tests for the `stable/` id namespace, driven through the Swift UniFFI bindings
/// against the live backend — the iOS counterpart to the Android harness's instrumented tests.
///
/// These cover the exact cache calls the file provider depends on for identity:
///  - `stable/<id>` addressing files and directories across renames and moves
///  - `queryPathForUuid`, which resolves a stable id back to a name path
///  - `queryItemByUuid`, which `persistentIdentifierForItem(at:)` uses to recover an identifier
///
/// Requirements to run: the session env vars listed in `TestAuth.requiredVariables`. Without them
/// every test skips rather than fails, so an unconfigured checkout stays green.
final class CacheStableIdTests: XCTestCase {
	private var state: FilenMobileCacheState!
	private var workDir: URL!
	private var rootUuid: String!

	/// Created on the server during the test, trashed in tearDown.
	private var createdRootDirId: FfiId?

	override func setUpWithError() throws {
		try super.setUpWithError()

		guard let credentials = TestAuth.credentialsFromEnvironment() else {
			throw XCTSkip(
				"""
				Live cache tests need a pre-obtained session in the environment: \
				\(TestAuth.requiredVariables.joined(separator: ", ")). \
				Export them (or their TEST_RUNNER_-prefixed equivalents) and re-run.
				""")
		}

		workDir = FileManager.default.temporaryDirectory
			.appending(component: "filen-cache-tests-\(UUID().uuidString)")
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
			// Best-effort cleanup; leave for the account's own housekeeping if it fails.
			_ = try? await state.trashItem(path: createdRootDirId)
		}
		state = nil
		if let workDir {
			try? FileManager.default.removeItem(at: workDir)
		}
		try await super.tearDown()
	}

	// MARK: - Helpers

	/// Creates an isolated `<root>/<prefix>-<random>` directory and remembers it for cleanup.
	private func makeIsolatedDir(_ prefix: String) async throws -> DirWithPathResponse {
		let dir = try await state.createDir(
			parentPath: rootUuid, name: "\(prefix)-\(UUID().uuidString)", created: nil)
		createdRootDirId = dir.id
		return dir
	}

	private func stableIdentity(of object: FfiObject) throws -> String {
		switch object {
		case .file(let file): return file.stableUuid
		// Directories carry no stable id on the wire — stable == uuid, by design.
		case .dir(let dir): return dir.uuid
		case .root:
			throw XCTSkip("unexpected root object")
		}
	}

	private func name(of object: FfiObject) -> String? {
		switch object {
		case .file(let file): return file.meta?.name
		case .dir(let dir): return dir.meta?.name
		case .root: return nil
		}
	}

	// MARK: - Tests

	/// A freshly uploaded file mints its own lineage: `stableUuid == uuid`. This is the invariant the
	/// providers rely on to treat the two as interchangeable for brand-new items.
	func testAFreshFileMintsItsOwnLineage() async throws {
		let dir = try await makeIsolatedDir("stable-fresh")
		let created = try await state.createEmptyFile(
			parentPath: dir.id, name: "fresh.txt", mime: "text/plain")

		XCTAssertEqual(
			created.file.stableUuid, created.file.uuid,
			"a first upload should mint a lineage whose stable id IS its uuid")
	}

	/// The `stable/<id>` form must address a file, and the identity must survive a rename — that is
	/// the whole point of the providers persisting it instead of a name path.
	func testStableNamespaceAddressesAFileAcrossRename() async throws {
		let dir = try await makeIsolatedDir("stable-file")
		let created = try await state.createEmptyFile(
			parentPath: dir.id, name: "before.txt", mime: "text/plain")
		let stableId = "stable/\(created.file.stableUuid)"

		// The stable form resolves to the same item as the path form.
		let viaStable = try XCTUnwrap(
			state.queryItem(path: stableId), "stable id should address the new file")
		XCTAssertEqual(try stableIdentity(of: viaStable), created.file.stableUuid)
		XCTAssertEqual(name(of: viaStable), "before.txt")

		// Mutating through the stable namespace works, and the identity is unchanged by the rename.
		let renameResponse = try await state.renameItem(item: stableId, newName: "after.txt")
		let renamed = try XCTUnwrap(
			renameResponse, "rename through the stable namespace should succeed")
		XCTAssertEqual(
			try stableIdentity(of: renamed.object), created.file.stableUuid,
			"a rename must not change the file's whole-life id")

		// ...and the same stable id still addresses it under the new name.
		let afterRename = try XCTUnwrap(state.queryItem(path: stableId))
		XCTAssertEqual(name(of: afterRename), "after.txt")
	}

	/// Directories have no wire-level stable id (stable == uuid), so `stable/<uuid>` must still
	/// address them — this is what both providers now use as the directory document id.
	func testStableNamespaceAddressesADirectoryAcrossRename() async throws {
		let dir = try await makeIsolatedDir("stable-dir")
		let child = try await state.createDir(parentPath: dir.id, name: "before", created: nil)
		let stableId = "stable/\(child.dir.uuid)"

		let viaStable = try XCTUnwrap(
			state.queryItem(path: stableId), "stable id should address a directory by its uuid")
		XCTAssertEqual(try stableIdentity(of: viaStable), child.dir.uuid)

		let renameResponse = try await state.renameItem(item: stableId, newName: "after")
		let renamed = try XCTUnwrap(
			renameResponse, "rename through the stable namespace should succeed for directories")
		XCTAssertEqual(
			try stableIdentity(of: renamed.object), child.dir.uuid,
			"a directory's identity is its uuid and must survive a rename")
		XCTAssertEqual(name(of: try XCTUnwrap(state.queryItem(path: stableId))), "after")
	}

	/// Moving must not change identity either — the providers return the unchanged id from
	/// `moveDocument`/`reparentItem` and would hand the system a dangling id if this regressed.
	func testStableNamespaceSurvivesAMove() async throws {
		let dir = try await makeIsolatedDir("stable-move")
		let source = try await state.createDir(parentPath: dir.id, name: "source", created: nil)
		let destination = try await state.createDir(
			parentPath: dir.id, name: "destination", created: nil)
		let created = try await state.createEmptyFile(
			parentPath: source.id, name: "moved.txt", mime: "text/plain")
		let stableId = "stable/\(created.file.stableUuid)"

		let moved = try await state.moveItem(item: stableId, newParent: destination.id)
		XCTAssertEqual(
			try stableIdentity(of: moved.object), created.file.stableUuid,
			"a move must not change the file's whole-life id")

		let afterMove = try XCTUnwrap(
			state.queryItem(path: stableId), "the stable id must still address the moved file")
		XCTAssertEqual(name(of: afterMove), "moved.txt")
	}

	/// `queryPathForUuid` is what the Android provider's `resolveToPath` calls to turn a stable id
	/// back into a name path for `isChildDocument`. It must accept a stable id, not just a uuid.
	func testQueryPathForUuidResolvesAStableId() async throws {
		let dir = try await makeIsolatedDir("stable-path")
		let created = try await state.createEmptyFile(
			parentPath: dir.id, name: "resolvable.txt", mime: "text/plain")

		let path = try XCTUnwrap(
			state.queryPathForUuid(uuid: created.file.stableUuid),
			"queryPathForUuid must resolve a stable id")
		XCTAssertTrue(
			path.hasSuffix("resolvable.txt"),
			"expected a name path ending in the file name, got \(path)")
	}

	/// A move followed by a failing rename must not leave the item moved.
	///
	/// The two steps are separate server calls with no transaction. Previously the move committed
	/// and then a failing rename threw, telling the system the whole operation failed while the
	/// item had in fact moved — so the Files app showed it in its old folder while the server had
	/// it in the new one, and the divergence persisted until something forced a re-listing.
	func testAFailedRenameDoesNotLeaveTheItemMoved() async throws {
		let root = try await makeIsolatedDir("stable-reparent")
		let from = try await state.createDir(parentPath: root.id, name: "from", created: nil)
		let to = try await state.createDir(parentPath: root.id, name: "to", created: nil)
		let created = try await state.createEmptyFile(
			parentPath: from.id, name: "movable.txt", mime: "text/plain")
		let stableId = NSFileProviderItemIdentifier("stable/\(created.file.stableUuid)")

		// "/" is rejected as a filename, so the rename fails deterministically after the move.
		do {
			_ = try await FileProviderExtension.reparent(
				state: state, itemIdentifier: stableId, newParent: to.id, newName: "bad/name",
				parentItemIdentifier: NSFileProviderItemIdentifier(to.id))
			XCTFail("a rename to an invalid name should not succeed")
		} catch {
			// expected
		}

		let after = try XCTUnwrap(state.queryItem(path: stableId.rawValue))
		XCTAssertEqual(
			objectToContainerUuid(object: after), from.dir.uuid,
			"a failed rename must roll the move back, so the reported failure is truthful")
	}

	/// The successful path still moves and renames in one call.
	func testAReparentWithARenameMovesAndRenames() async throws {
		let root = try await makeIsolatedDir("stable-reparent-ok")
		let from = try await state.createDir(parentPath: root.id, name: "from", created: nil)
		let to = try await state.createDir(parentPath: root.id, name: "to", created: nil)
		let created = try await state.createEmptyFile(
			parentPath: from.id, name: "before.txt", mime: "text/plain")
		let stableId = NSFileProviderItemIdentifier("stable/\(created.file.stableUuid)")

		let item = try await FileProviderExtension.reparent(
			state: state, itemIdentifier: stableId, newParent: to.id, newName: "after.txt",
			parentItemIdentifier: NSFileProviderItemIdentifier(to.id))

		XCTAssertEqual(item.filename, "after.txt")
		let after = try XCTUnwrap(state.queryItem(path: stableId.rawValue))
		XCTAssertEqual(objectToContainerUuid(object: after), to.dir.uuid)
	}

	/// End-to-end counterpart to the unit repro in IdentifierTests: trashing a file nested two
	/// levels deep must leave it reporting the folder it came from, not the drive root.
	///
	/// The unit test builds the FfiFile by hand; this proves the server and cache actually populate
	/// `originalParent` the way that resolution depends on.
	func testTrashingANestedFileKeepsItsOriginalContainer() async throws {
		let dir = try await makeIsolatedDir("stable-trash")
		let inner = try await state.createDir(parentPath: dir.id, name: "inner", created: nil)
		let created = try await state.createEmptyFile(
			parentPath: inner.id, name: "doomed.txt", mime: "text/plain")

		let trashed = try await state.trashItem(path: "stable/\(created.file.stableUuid)")

		// The identity survives the trash round-trip.
		XCTAssertEqual(try stableIdentity(of: trashed.object), created.file.stableUuid)

		let container = FileProviderExtension.containerIdentifier(
			for: trashed.object,
			fallbackFrom: NSFileProviderItemIdentifier("stable/\(created.file.stableUuid)"),
			rootUuid: rootUuid)
		XCTAssertEqual(
			container, NSFileProviderItemIdentifier("stable/\(inner.dir.uuid)"),
			"a trashed file must resolve to the folder it will be restored into")
		XCTAssertNotEqual(container, .rootContainer, "and never to the drive root")
	}

	/// The working set is NOT a resolvable cache id, which is why enumerating it cannot work today.
	///
	/// `enumerator(for:)` builds an enumerator for any container, but `FileProviderEnumerator`'s
	/// init only substitutes a cache-form id for `.rootContainer` and `.trashContainer`
	/// (FileProviderEnumerator.swift:17-21). `.workingSet`'s opaque sentinel therefore goes straight
	/// into `queryItem(path:)` and can only miss — and `enumerateChanges(for:from:)` is not
	/// implemented at all. So `itemChanged`'s failure-path `signalEnumerator(for: .workingSet)`
	/// retriggers an enumeration guaranteed to fail: the retry is a dead end.
	///
	/// This pins the mechanism. Making the working set real (routing it to a materialized-items
	/// query and implementing `enumerateChanges`) is a feature, sized separately — when it lands,
	/// this test should flip to asserting the working set resolves.
	/// It does not merely miss — the sentinel is not even a syntactically valid id, so the lookup
	/// throws a conversion error before any query happens.
	func testTheWorkingSetSentinelIsNotAResolvableCacheId() {
		XCTAssertThrowsError(
			try state.queryItem(path: NSFileProviderItemIdentifier.workingSet.rawValue),
			"known gap: the working set is not addressable, so signalling it cannot drive a retry"
		) { error in
			XCTAssertTrue(
				error is CacheError,
				"expected the cache to reject the sentinel outright, got \(error)")
		}
	}

	/// `queryItemByUuid` is what the iOS extension's `persistentIdentifierForItem(at:)` calls to
	/// recover an identifier from a URL. It must return the row carrying the stable identity.
	func testQueryItemByUuidReturnsTheStableIdentity() async throws {
		let dir = try await makeIsolatedDir("stable-byuuid")
		let created = try await state.createEmptyFile(
			parentPath: dir.id, name: "byuuid.txt", mime: "text/plain")

		let byUuid = try XCTUnwrap(
			state.queryItemByUuid(uuid: created.file.uuid),
			"queryItemByUuid must find the file by its current-version uuid")
		XCTAssertEqual(try stableIdentity(of: byUuid), created.file.stableUuid)

		// The same entry point also accepts the stable id, which is what keeps ids persisted before
		// the app migration resolving.
		let byStable = try XCTUnwrap(
			state.queryItemByUuid(uuid: created.file.stableUuid),
			"queryItemByUuid must also accept the stable id")
		XCTAssertEqual(try stableIdentity(of: byStable), created.file.stableUuid)
	}
}
