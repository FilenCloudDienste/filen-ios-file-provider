import FileProvider
import XCTest

/// `versionIdentifier` is the only staleness signal the File Provider framework has. If it fails to
/// change when content or metadata changes, the system serves stale data forever; if it changes
/// when nothing did, every item re-downloads. Neither failure crashes anything, so only a test
/// catches them.
final class ItemVersionTests: XCTestCase {
	private static let uuid = "11111111-1111-1111-1111-111111111111"
	private static let stableUuid = "22222222-2222-2222-2222-222222222222"
	private static let parent = "33333333-3333-3333-3333-333333333333"

	private func makeFile(
		name: String = "report.pdf",
		mime: String = "application/pdf",
		size: Int64 = 1024,
		favoriteRank: Int64 = 0,
		modified: Int64 = 1_700_000_000,
		hash: Data? = nil,
		localData: [String: String]? = nil
	) -> FileProviderItem {
		let file = FfiFile(
			uuid: Self.uuid,
			stableUuid: Self.stableUuid,
			parent: Self.parent,
			originalParent: nil,
			meta: FfiFileMeta(
				name: name, mime: mime, created: 1_600_000_000, modified: modified, hash: hash),
			size: size,
			favoriteRank: favoriteRank,
			localData: localData,
			pendingUploadAt: nil)
		return FileProviderItem(
			itemIdentifier: NSFileProviderItemIdentifier("stable/" + Self.stableUuid),
			object: .file(file))
	}

	private func makeDir(
		name: String = "Photos",
		color: String? = nil,
		favoriteRank: Int64 = 0
	) -> FileProviderItem {
		let dir = FfiDir(
			uuid: Self.uuid,
			parent: Self.parent,
			originalParent: nil,
			meta: FfiDirMeta(name: name, created: 1_600_000_000),
			color: color,
			favoriteRank: favoriteRank,
			lastListed: 0,
			localData: nil)
		return FileProviderItem(
			itemIdentifier: NSFileProviderItemIdentifier("stable/" + Self.uuid),
			object: .dir(dir))
	}

	// MARK: - Determinism

	func testTheSameFileTwiceProducesTheSameVersion() {
		XCTAssertEqual(makeFile().versionIdentifier, makeFile().versionIdentifier)
	}

	func testTheSameDirectoryTwiceProducesTheSameVersion() {
		XCTAssertEqual(makeDir().versionIdentifier, makeDir().versionIdentifier)
	}

	func testAVersionIsAlwaysProduced() {
		XCTAssertNotNil(makeFile().versionIdentifier)
		XCTAssertNotNil(makeDir().versionIdentifier)
	}

	// MARK: - Every field that a user can change must move the version

	func testRenamingAFileChangesTheVersion() {
		XCTAssertNotEqual(makeFile().versionIdentifier, makeFile(name: "other.pdf").versionIdentifier)
	}

	func testEditingContentChangesTheVersion() {
		XCTAssertNotEqual(makeFile().versionIdentifier, makeFile(size: 2048).versionIdentifier)
		XCTAssertNotEqual(
			makeFile().versionIdentifier, makeFile(modified: 1_700_000_001).versionIdentifier)
	}

	func testAContentHashChangeChangesTheVersion() {
		XCTAssertNotEqual(
			makeFile(hash: Data([1, 2, 3])).versionIdentifier,
			makeFile(hash: Data([4, 5, 6])).versionIdentifier)
	}

	func testFavouritingAFileChangesTheVersion() {
		XCTAssertNotEqual(makeFile().versionIdentifier, makeFile(favoriteRank: 5).versionIdentifier)
	}

	func testRenamingADirectoryChangesTheVersion() {
		XCTAssertNotEqual(makeDir().versionIdentifier, makeDir(name: "Videos").versionIdentifier)
	}

	func testRecolouringADirectoryChangesTheVersion() {
		XCTAssertNotEqual(makeDir().versionIdentifier, makeDir(color: "#ff0000").versionIdentifier)
	}

	func testFavouritingADirectoryChangesTheVersion() {
		XCTAssertNotEqual(makeDir().versionIdentifier, makeDir(favoriteRank: 5).versionIdentifier)
	}

	// MARK: - Purely local state must NOT move the version

	/// `localData` is provider-side bookkeeping, not content. Including it would make every item
	/// look stale to the system after a purely local change.
	func testLocalDataDoesNotChangeTheVersion() {
		XCTAssertEqual(
			makeFile().versionIdentifier,
			makeFile(localData: ["TagData": "abc"]).versionIdentifier)
	}

	// MARK: - Files and directories must not collide

	func testAFileAndADirectorySharingAUuidHaveDifferentVersions() {
		let file = FfiFile(
			uuid: Self.uuid, stableUuid: Self.uuid, parent: Self.parent, originalParent: nil,
			meta: FfiFileMeta(name: "Photos", mime: "", created: 1_600_000_000, modified: 0, hash: nil),
			size: 0, favoriteRank: 0, localData: nil,
			pendingUploadAt: nil)
		let fileItem = FileProviderItem(
			itemIdentifier: NSFileProviderItemIdentifier("stable/" + Self.uuid), object: .file(file))

		XCTAssertNotEqual(fileItem.versionIdentifier, makeDir().versionIdentifier)
	}
}
