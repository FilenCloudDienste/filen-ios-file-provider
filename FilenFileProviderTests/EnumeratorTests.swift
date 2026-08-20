import FileProvider
import XCTest

/// Enumeration tests driven against the live cache.
///
/// The container substitution is the subtle part: the system enumerates `.rootContainer` and
/// `.trashContainer` sentinels, which are not cache ids, so the enumerator swaps in a cache-form id
/// for its own queries while children must still report the SENTINEL as their parent. Commit
/// d8ffbd5 fixed exactly this confusion once already — reporting the raw root uuid instead of
/// `.rootContainer` detaches every top-level item from the root in the Files app.
final class EnumeratorTests: XCTestCase {
	private var state: FilenMobileCacheState!
	private var workDir: URL!
	private var rootUuid: String!
	private var createdRootDirId: FfiId?

	override func setUpWithError() throws {
		try super.setUpWithError()

		guard let credentials = TestAuth.credentialsFromEnvironment() else {
			throw XCTSkip(
				"""
				Live enumerator tests need a session in the environment: \
				\(TestAuth.requiredVariables.joined(separator: ", ")).
				""")
		}

		workDir = FileManager.default.temporaryDirectory
			.appending(component: "filen-enumerator-tests-\(UUID().uuidString)")
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

	/// Captures what the enumerator reports back to the system.
	private final class Observer: NSObject, NSFileProviderEnumerationObserver, @unchecked Sendable {
		private let lock = NSLock()
		private var items: [NSFileProviderItem] = []
		private var finished = false
		private var error: Error?
		private let done = XCTestExpectation(description: "enumeration finished")

		func didEnumerate(_ updatedItems: [any NSFileProviderItemProtocol]) {
			lock.lock()
			defer { lock.unlock() }
			items.append(contentsOf: updatedItems)
		}

		func finishEnumerating(upTo nextPage: NSFileProviderPage?) {
			lock.lock()
			finished = true
			lock.unlock()
			done.fulfill()
		}

		func finishEnumeratingWithError(_ error: any Error) {
			lock.lock()
			self.error = error
			lock.unlock()
			done.fulfill()
		}

		var expectation: XCTestExpectation { done }

		var enumerated: [NSFileProviderItem] {
			lock.lock()
			defer { lock.unlock() }
			return items
		}

		var failure: Error? {
			lock.lock()
			defer { lock.unlock() }
			return error
		}

		var didFinish: Bool {
			lock.lock()
			defer { lock.unlock() }
			return finished
		}
	}

	private func enumerate(
		_ container: NSFileProviderItemIdentifier,
		page: NSFileProviderPage = NSFileProviderPage(NSFileProviderPage.initialPageSortedByName as Data)
	) throws -> Observer {
		let enumerator = FileProviderEnumerator(
			enumeratedItemIdentifier: container, state: state, rootUuid: rootUuid)
		let observer = Observer()
		enumerator.enumerateItems(for: observer, startingAt: page)
		wait(for: [observer.expectation], timeout: 120)
		return observer
	}

	// MARK: - C2: container substitution

	/// Children of the root must report `.rootContainer`, NOT the raw root uuid. This is the
	/// regression d8ffbd5 fixed.
	func testRootChildrenReportTheRootContainerSentinelAsTheirParent() async throws {
		let dir = try await state.createDir(
			parentPath: rootUuid, name: "enum-\(UUID().uuidString)", created: nil)
		createdRootDirId = dir.id

		let observer = try enumerate(.rootContainer)

		XCTAssertNil(observer.failure, "enumerating the root should not error")
		XCTAssertFalse(observer.enumerated.isEmpty, "the root should contain the directory we made")
		for item in observer.enumerated {
			XCTAssertEqual(
				item.parentItemIdentifier, .rootContainer,
				"a root child must report the sentinel, not the raw root uuid")
			XCTAssertNotEqual(item.parentItemIdentifier.rawValue, rootUuid)
		}
	}

	/// The directory we created must actually come back, addressed by its stable id.
	func testEnumeratingTheRootYieldsTheCreatedDirectory() async throws {
		let name = "enum-\(UUID().uuidString)"
		let dir = try await state.createDir(parentPath: rootUuid, name: name, created: nil)
		createdRootDirId = dir.id

		let observer = try enumerate(.rootContainer)

		let match = observer.enumerated.first { $0.filename == name }
		let found = try XCTUnwrap(match, "the new directory should be enumerated under the root")
		XCTAssertEqual(found.itemIdentifier.rawValue, "stable/" + dir.dir.uuid)
	}

	/// Children of a normal directory report that directory, in stable form.
	func testChildrenOfADirectoryReportThatDirectoryAsTheirParent() async throws {
		let parent = try await state.createDir(
			parentPath: rootUuid, name: "enum-\(UUID().uuidString)", created: nil)
		createdRootDirId = parent.id
		_ = try await state.createEmptyFile(
			parentPath: parent.id, name: "child.txt", mime: "text/plain")

		let container = NSFileProviderItemIdentifier("stable/" + parent.dir.uuid)
		let observer = try enumerate(container)

		XCTAssertNil(observer.failure)
		XCTAssertFalse(observer.enumerated.isEmpty)
		for item in observer.enumerated {
			XCTAssertEqual(item.parentItemIdentifier, container)
		}
	}

	/// The trash is not a cached directory — it is reachable only through the dedicated
	/// `queryTrash` / `updateTrash` API, so the enumerator must route `.trashContainer` there
	/// rather than through the generic `queryItem` / `updateAndQueryDirChildren` path.
	func testTheTrashContainerEnumerates() throws {
		let observer = try enumerate(.trashContainer)

		XCTAssertNil(
			observer.failure, "the trash container must enumerate, even when it holds nothing")
		XCTAssertTrue(observer.didFinish)
	}

	/// A trashed item must actually show up in the trash listing, reporting the trash sentinel as
	/// its parent so the Files app files it under Recently Deleted rather than the drive root.
	func testATrashedItemAppearsInTheTrashContainer() async throws {
		let name = "enum-\(UUID().uuidString)"
		let dir = try await state.createDir(parentPath: rootUuid, name: name, created: nil)
		createdRootDirId = dir.id
		_ = try await state.trashItem(path: dir.id)
		// Already trashed; tearDown must not try again.
		createdRootDirId = nil

		let observer = try enumerate(.trashContainer)

		XCTAssertNil(observer.failure)
		let match = observer.enumerated.first { $0.filename == name }
		let found = try XCTUnwrap(match, "the trashed directory should appear in the trash")
		XCTAssertEqual(
			found.parentItemIdentifier, .trashContainer,
			"a trashed item must report the trash sentinel as its parent")
	}

	/// Enumerating a file is a no-op that finishes cleanly rather than erroring — only directories
	/// are enumerable, and the system may still ask.
	func testEnumeratingAFileFinishesWithoutError() async throws {
		let dir = try await state.createDir(
			parentPath: rootUuid, name: "enum-\(UUID().uuidString)", created: nil)
		createdRootDirId = dir.id
		let file = try await state.createEmptyFile(
			parentPath: dir.id, name: "leaf.txt", mime: "text/plain")

		let observer = try enumerate(
			NSFileProviderItemIdentifier("stable/" + file.file.stableUuid))

		XCTAssertNil(observer.failure)
		XCTAssertTrue(observer.enumerated.isEmpty, "a file has no children to enumerate")
	}

	/// An identifier that resolves to nothing must report noSuchItem, not finish empty — finishing
	/// empty would tell the system the container exists and is empty.
	func testAnUnknownContainerReportsNoSuchItem() throws {
		let observer = try enumerate(
			NSFileProviderItemIdentifier("stable/" + UUID().uuidString))

		let error = try XCTUnwrap(observer.failure) as NSError
		XCTAssertEqual(error.domain, NSFileProviderErrorDomain)
		XCTAssertEqual(error.code, NSFileProviderError.noSuchItem.rawValue)
	}

	// MARK: - C3: paging contract

	/// Both of the system's initial pages start the enumeration from the beginning, so a
	/// directory smaller than one page comes back whole either way. This pins that the sort the
	/// system asks for never costs items.
	func testEveryChildIsDeliveredInASingleBatchRegardlessOfPage() async throws {
		let parent = try await state.createDir(
			parentPath: rootUuid, name: "enum-\(UUID().uuidString)", created: nil)
		createdRootDirId = parent.id

		let childCount = 5
		for index in 0..<childCount {
			_ = try await state.createEmptyFile(
				parentPath: parent.id, name: "child-\(index).txt", mime: "text/plain")
		}

		let container = NSFileProviderItemIdentifier("stable/" + parent.dir.uuid)

		let byName = try enumerate(
			container,
			page: NSFileProviderPage(NSFileProviderPage.initialPageSortedByName as Data))
		XCTAssertEqual(byName.enumerated.count, childCount)

		// A different starting page must yield the same full set while paging is unimplemented.
		let byDate = try enumerate(
			container,
			page: NSFileProviderPage(NSFileProviderPage.initialPageSortedByDate as Data))
		XCTAssertEqual(
			byDate.enumerated.count, childCount,
			"both initial pages start from the beginning and return everything")
	}

	// MARK: - C4: no incremental tracking per directory

	/// A directory enumerator answers with no sync anchor on purpose: the drive has no
	/// per-container change history to diff against, and the system re-enumerates the container
	/// when it is presented instead. Handing out an anchor we cannot honour would be worse than
	/// none — the system would trust a diff that silently misses items moved out of the folder.
	func testADirectoryHasNoSyncAnchor() throws {
		let enumerator = FileProviderEnumerator(
			enumeratedItemIdentifier: .rootContainer, state: state, rootUuid: rootUuid)

		var anchor: NSFileProviderSyncAnchor? = NSFileProviderSyncAnchor(Data())
		let read = expectation(description: "anchor read")
		enumerator.currentSyncAnchor { value in
			anchor = value
			read.fulfill()
		}
		wait(for: [read], timeout: 30)

		XCTAssertNil(anchor, "a directory enumerator must not claim an anchor it cannot honour")
	}
}
