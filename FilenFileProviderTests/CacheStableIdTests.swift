import XCTest

/// Integration tests for the `stable/` id namespace, driven through the Swift UniFFI bindings
/// against the live backend — the iOS counterpart to the Android harness's instrumented tests.
///
/// These cover the exact cache calls the file provider depends on for identity:
///  - `stable/<id>` addressing files and directories across renames and moves
///  - `queryPathForUuid`, which resolves a stable id back to a name path
///  - `queryItemByUuid`, which recovers an item from a uuid a provider still holds
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

	/// A move and a rename arrive together and are two server calls, so the move can land and the
	/// rename fail. The replicated model asks for no compensation: the change is already on disk,
	/// which is the truth the provider is catching up to, and undoing the move server-side would
	/// push a spurious move back down. The system retries the whole modification instead, and the
	/// move it replays is a no-op.
	func testAMoveSurvivesAFailingRename() async throws {
		let root = try await makeIsolatedDir("stable-reparent")
		let from = try await state.createDir(parentPath: root.id, name: "from", created: nil)
		let to = try await state.createDir(parentPath: root.id, name: "to", created: nil)
		let created = try await state.createEmptyFile(
			parentPath: from.id, name: "movable.txt", mime: "text/plain")
		let stableId = "stable/\(created.file.stableUuid)"

		_ = try await FileProviderExtension.apply(
			.move(to: to.id), state: state, id: stableId, contents: nil, progress: nil)
		// "/" is rejected as a filename, so the rename fails deterministically after the move.
		do {
			_ = try await FileProviderExtension.apply(
				.rename("bad/name"), state: state, id: stableId, contents: nil, progress: nil)
			XCTFail("a rename to an invalid name should not succeed")
		} catch {
			// expected
		}

		let after = try XCTUnwrap(state.queryItem(path: stableId))
		XCTAssertEqual(
			objectToContainerUuid(object: after), to.dir.uuid,
			"the move stands; the rename is what the system retries")
		XCTAssertEqual(name(of: after), "movable.txt", "and the failed rename changed nothing")
	}

	/// The steps a reparent-with-rename dispatches to, run in order, land both changes.
	func testAMoveFollowedByARenameMovesAndRenames() async throws {
		let root = try await makeIsolatedDir("stable-reparent-ok")
		let from = try await state.createDir(parentPath: root.id, name: "from", created: nil)
		let to = try await state.createDir(parentPath: root.id, name: "to", created: nil)
		let created = try await state.createEmptyFile(
			parentPath: from.id, name: "before.txt", mime: "text/plain")
		let stableId = "stable/\(created.file.stableUuid)"

		_ = try await FileProviderExtension.apply(
			.move(to: to.id), state: state, id: stableId, contents: nil, progress: nil)
		let renamed = try await FileProviderExtension.apply(
			.rename("after.txt"), state: state, id: stableId, contents: nil, progress: nil)

		XCTAssertEqual(name(of: renamed), "after.txt")
		let after = try XCTUnwrap(state.queryItem(path: stableId))
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

	/// The working set is NOT a resolvable cache id, and never will be: it is a set the cache
	/// computes (`queryWorkingSet`), not a container it holds a row for. The sentinel is not even
	/// a syntactically valid id, so a lookup throws a conversion error before any query happens.
	///
	/// This is exactly why `enumerator(for:)` has to route `.workingSet` to its own enumerator
	/// rather than through the generic container path — which substitutes a cache-form id only for
	/// `.rootContainer` and `.trashContainer` and would hand this sentinel straight to
	/// `queryItem(path:)`.
	func testTheWorkingSetSentinelIsNotAResolvableCacheId() {
		XCTAssertThrowsError(
			try state.queryItem(path: NSFileProviderItemIdentifier.workingSet.rawValue),
			"the working set is computed, not addressable — it needs its own enumerator"
		) { error in
			XCTAssertTrue(
				error is CacheError,
				"expected the cache to reject the sentinel outright, got \(error)")
		}
	}

	/// ...and because it is not resolvable, an item lookup for it must be refused explicitly. Left
	/// to fall through it reads as a cache miss, and a miss answers `.noSuchItem` — which the
	/// system acts on by deleting the item from disk.
	func testLookingUpTheWorkingSetIsNotAnItemMiss() async {
		do {
			_ = try await FileProviderExtension.resolveItem(
				state: state, identifier: .workingSet, rootUuid: rootUuid)
			XCTFail("the working set is not an item and must not resolve to one")
		} catch {
			let nsError = error as NSError
			XCTAssertFalse(
				nsError.domain == NSFileProviderErrorDomain
					&& nsError.code == NSFileProviderError.noSuchItem.rawValue,
				"noSuchItem would have the system delete the working set from disk")
			XCTAssertEqual(nsError.domain, NSCocoaErrorDomain, "and it must stay retryable")
		}
	}

	/// `queryItemByUuid` recovers an item from a uuid a provider still holds — a superseded one
	/// included. It must return the row carrying the stable identity.
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
