import FileProvider
import XCTest

/// `itemVersion` is the staleness signal the File Provider framework works from. Its content half
/// decides whether the system redownloads a file and whether a cached thumbnail is still good; its
/// metadata half is what comes back as the `baseVersion` of the next change. If content moves when
/// nothing changed, every item re-downloads; if it stands still across an edit, the system serves
/// stale bytes forever. Neither failure crashes anything, so only a test catches them.
final class ItemVersionTests: XCTestCase {
	private static let uuid = "11111111-1111-1111-1111-111111111111"
	private static let editedUuid = "44444444-4444-4444-4444-444444444444"
	private static let stableUuid = "22222222-2222-2222-2222-222222222222"
	private static let parent = "33333333-3333-3333-3333-333333333333"

	private func makeFile(
		uuid: String = ItemVersionTests.uuid,
		name: String = "report.pdf",
		size: Int64 = 1024,
		changeSeq: Int64 = 7
	) -> FileProviderItem {
		let file = FfiFile(
			uuid: uuid,
			stableUuid: Self.stableUuid,
			parent: Self.parent,
			originalParent: nil,
			meta: FfiFileMeta(
				name: name, mime: "application/pdf", created: 1_600_000_000,
				modified: 1_700_000_000, hash: nil),
			size: size,
			favoriteRank: 0,
			localData: nil,
			pendingUploadAt: nil,
			changeSeq: changeSeq)
		return FileProviderItem(
			itemIdentifier: NSFileProviderItemIdentifier("stable/" + Self.stableUuid),
			object: .file(file))
	}

	private func makeDir(name: String = "Photos", changeSeq: Int64 = 3) -> FileProviderItem {
		let dir = FfiDir(
			uuid: Self.uuid,
			parent: Self.parent,
			originalParent: nil,
			meta: FfiDirMeta(name: name, created: 1_600_000_000),
			color: nil,
			favoriteRank: 0,
			lastListed: 0,
			localData: nil,
			changeSeq: changeSeq)
		return FileProviderItem(
			itemIdentifier: NSFileProviderItemIdentifier("stable/" + Self.uuid), object: .dir(dir))
	}

	// MARK: - Determinism

	func testTheSameFileTwiceProducesTheSameVersion() {
		XCTAssertEqual(makeFile().itemVersion.contentVersion, makeFile().itemVersion.contentVersion)
		XCTAssertEqual(
			makeFile().itemVersion.metadataVersion, makeFile().itemVersion.metadataVersion)
	}

	func testTheSameDirectoryTwiceProducesTheSameVersion() {
		XCTAssertEqual(makeDir().itemVersion.contentVersion, makeDir().itemVersion.contentVersion)
		XCTAssertEqual(makeDir().itemVersion.metadataVersion, makeDir().itemVersion.metadataVersion)
	}

	// MARK: - Content

	/// The server re-mints a file's uuid on every content edit, which is exactly the event the
	/// content version exists to signal.
	func testEditingContentChangesTheContentVersion() {
		XCTAssertNotEqual(
			makeFile().itemVersion.contentVersion,
			makeFile(uuid: Self.editedUuid).itemVersion.contentVersion)
	}

	/// ...and metadata alone must NOT move it, or every rename would redownload the file and throw
	/// away its thumbnail.
	func testRenamingAFileLeavesTheContentVersionAlone() {
		XCTAssertEqual(
			makeFile().itemVersion.contentVersion,
			makeFile(name: "other.pdf", changeSeq: 9).itemVersion.contentVersion)
	}

	/// A directory has no content to version.
	func testDirectoriesShareOneConstantContentVersion() {
		XCTAssertEqual(
			makeDir().itemVersion.contentVersion,
			makeDir(name: "Videos", changeSeq: 50).itemVersion.contentVersion)
	}

	// MARK: - Metadata

	func testTheMetadataVersionIsTheChangeSequenceLittleEndian() {
		XCTAssertEqual(
			makeFile(changeSeq: 258).itemVersion.metadataVersion,
			Data([2, 1, 0, 0, 0, 0, 0, 0]),
			"the metadata version is the cache's change_seq, little-endian")
	}

	func testAMetadataChangeMovesTheMetadataVersion() {
		XCTAssertNotEqual(
			makeFile().itemVersion.metadataVersion,
			makeFile(name: "other.pdf", changeSeq: 8).itemVersion.metadataVersion)
		XCTAssertNotEqual(
			makeDir().itemVersion.metadataVersion,
			makeDir(name: "Videos", changeSeq: 4).itemVersion.metadataVersion)
	}

	/// The change sequence deliberately stands still for purely local state, so an item whose
	/// only movement was local must look unchanged to the system.
	func testAStandingChangeSequenceMeansAnUnchangedItem() {
		XCTAssertEqual(
			makeFile().itemVersion.metadataVersion,
			makeFile(size: 2048).itemVersion.metadataVersion,
			"the version tracks the sequence, not the fields — the substrate decides what bumps it")
	}

	// MARK: - Files and directories must not collide

	func testAFileAndADirectorySharingAUuidHaveDifferentContentVersions() {
		XCTAssertNotEqual(
			makeFile(uuid: Self.uuid).itemVersion.contentVersion,
			makeDir().itemVersion.contentVersion)
	}
}
