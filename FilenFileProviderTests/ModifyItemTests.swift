import FileProvider
import UniformTypeIdentifiers
import XCTest

/// `modifyItem` is handed a set of changed fields and has to turn it into cache calls. Getting the
/// dispatch wrong is silent: a reparent taken for a move puts a trashed file back in the trash, a
/// missed field is a change the user made and never sees again, and a wrong order renames an item
/// in the container it just left.
///
/// `modifySteps` is the whole of that decision and is pure, so it can be pinned without a live
/// extension — which cannot be constructed outside the extension process.
final class ModifyItemTests: XCTestCase {
	private static let rootUuid = "00000000-0000-0000-0000-000000000000"
	private static let stableUuid = "11111111-1111-1111-1111-111111111111"
	private static let folderUuid = "22222222-2222-2222-2222-222222222222"

	private func template(
		name: String = "report.pdf",
		parent: NSFileProviderItemIdentifier = NSFileProviderItemIdentifier(
			"stable/" + ModifyItemTests.folderUuid),
		favoriteRank: Int64 = 0,
		localData: [String: String]? = nil
	) -> FileProviderItem {
		let file = FfiFile(
			uuid: Self.stableUuid, stableUuid: Self.stableUuid, parent: Self.folderUuid,
			originalParent: nil,
			meta: FfiFileMeta(
				name: name, mime: "application/pdf", created: 0, modified: 0, hash: nil),
			size: 0, favoriteRank: favoriteRank, localData: localData, pendingUploadAt: nil,
			changeSeq: 0)
		return FileProviderItem(
			itemIdentifier: NSFileProviderItemIdentifier("stable/" + Self.stableUuid),
			object: .file(file), parentItemIdentifier: parent)
	}

	private func steps(
		_ changedFields: NSFileProviderItemFields,
		item: FileProviderItem? = nil,
		hasContents: Bool = false,
		currentlyTrashed: Bool = false
	) -> [FileProviderExtension.ModifyStep] {
		FileProviderExtension.modifySteps(
			changedFields: changedFields, item: item ?? template(), hasContents: hasContents,
			currentlyTrashed: currentlyTrashed, rootUuid: Self.rootUuid)
	}

	/// What the same call reports back as `stillPendingFields`.
	private func stillPending(
		_ changedFields: NSFileProviderItemFields,
		item: FileProviderItem? = nil,
		hasContents: Bool = false,
		currentlyTrashed: Bool = false
	) -> NSFileProviderItemFields {
		FileProviderExtension.stillPendingFields(
			changedFields: changedFields,
			steps: steps(
				changedFields, item: item, hasContents: hasContents,
				currentlyTrashed: currentlyTrashed))
	}

	// MARK: - One field at a time

	func testARenameDispatchesToTheRename() {
		XCTAssertEqual(steps(.filename, item: template(name: "after.pdf")), [.rename("after.pdf")])
	}

	func testAContentChangeDispatchesToTheUpload() {
		XCTAssertEqual(steps(.contents, hasContents: true), [.contents])
	}

	/// The system can report a content change with nothing to hand over. There is no upload to do,
	/// and reading a nil URL would be a crash — but the change was not applied either, so it stays
	/// pending rather than being claimed as done.
	func testAContentChangeWithoutBytesDispatchesToNothing() {
		XCTAssertEqual(steps(.contents, hasContents: false), [])
		XCTAssertEqual(stillPending(.contents, hasContents: false), .contents)
	}

	func testAReparentDispatchesToTheMove() {
		XCTAssertEqual(
			steps(.parentItemIdentifier), [.move(to: "stable/" + Self.folderUuid)])
	}

	/// The root is a sentinel, not a cache id — the move has to name the drive root's uuid.
	func testAReparentToTheRootMovesToTheRootUuid() {
		XCTAssertEqual(
			steps(.parentItemIdentifier, item: template(parent: .rootContainer)),
			[.move(to: Self.rootUuid)])
	}

	/// Trashing is a reparent into the trash container, never a delete.
	func testAReparentIntoTheTrashDispatchesToTheTrash() {
		XCTAssertEqual(
			steps(.parentItemIdentifier, item: template(parent: .trashContainer)), [.trash])
	}

	/// ...and a reparent OUT of the trash is a restore, not a move: a move would leave the item
	/// trashed at a new parent.
	func testAReparentOutOfTheTrashDispatchesToTheRestore() {
		XCTAssertEqual(
			steps(.parentItemIdentifier, currentlyTrashed: true),
			[.restore(to: "stable/" + Self.folderUuid)])
	}

	func testAFavouriteDispatchesToTheRank() {
		XCTAssertEqual(steps(.favoriteRank, item: template(favoriteRank: 5)), [.favoriteRank(5)])
	}

	/// Unfavouriting arrives as a nil rank, which the drive spells zero.
	func testUnfavouritingDispatchesToRankZero() {
		XCTAssertEqual(steps(.favoriteRank), [.favoriteRank(0)])
	}

	func testTagsAreStoredAsProviderLocalData() {
		let tags = Data([0xDE, 0xAD])
		XCTAssertEqual(
			steps(.tagData, item: template(localData: ["TagData": tags.base64EncodedString()])),
			[.localData(key: "TagData", value: tags.base64EncodedString())])
	}

	/// Clearing the tags must clear the key, not store an empty blob.
	func testClearingTagsStoresNothing() {
		XCTAssertEqual(steps(.tagData), [.localData(key: "TagData", value: nil)])
	}

	/// The drive has no last-used date, so it is kept locally — the system's Recents view reads it
	/// straight back off the item.
	func testTheLastUsedDateIsStoredAsProviderLocalData() {
		XCTAssertEqual(
			steps(.lastUsedDate, item: template(localData: ["LastUsedDate": "1700000000000"])),
			[.localData(key: "LastUsedDate", value: "1700000000000")])
	}

	/// A field the provider does not carry dispatches to nothing at all rather than to a wrong
	/// guess — and comes back as still pending, which is how the system learns the provider does
	/// not support it instead of re-sending it forever over the disk's own copy.
	func testAnUnhandledFieldDispatchesToNothing() {
		XCTAssertEqual(steps(.creationDate), [])
		XCTAssertEqual(stillPending(.creationDate), .creationDate)
		XCTAssertEqual(steps(.extendedAttributes), [])
		XCTAssertEqual(stillPending(.extendedAttributes), .extendedAttributes)
	}

	// MARK: - What the call reports back

	/// A field that dispatched to a step was applied, so it must NOT come back as pending —
	/// reporting the whole set is how the system is told the provider supports none of it.
	func testEveryDispatchedFieldIsReportedAsApplied() {
		let everything: NSFileProviderItemFields = [
			.contents, .filename, .parentItemIdentifier, .favoriteRank, .tagData, .lastUsedDate,
		]
		XCTAssertEqual(stillPending(everything, hasContents: true), [])
	}

	/// A mixed call reports exactly the fields it did not apply.
	func testOnlyTheUnappliedFieldsAreReportedAsPending() {
		XCTAssertEqual(
			stillPending([.filename, .creationDate, .fileSystemFlags]),
			[.creationDate, .fileSystemFlags])
	}

	/// A reparent is applied whichever of the three steps it dispatches to.
	func testAReparentOutOfTheTrashIsNotReportedAsPending() {
		XCTAssertEqual(stillPending(.parentItemIdentifier, currentlyTrashed: true), [])
		XCTAssertEqual(
			stillPending(.parentItemIdentifier, item: template(parent: .trashContainer)), [])
	}

	// MARK: - Creation dispatch

	/// A package (.rtfd, .key, .app) is a directory the system hands over with no contents, but it
	/// conforms to `public.directory` and NOT to `public.folder` — matching on `.folder` alone
	/// creates it as a 0-byte file whose children then have nowhere to go.
	func testAPackageIsCreatedAsADirectory() {
		XCTAssertTrue(FileProviderExtension.createsDirectory(contentType: .package))
		XCTAssertTrue(FileProviderExtension.createsDirectory(contentType: .bundle))
		XCTAssertTrue(FileProviderExtension.createsDirectory(contentType: .rtfd))
		XCTAssertFalse(
			UTType.package.conforms(to: .folder),
			"the premise: a package is not a folder, which is why .folder was the wrong test")
	}

	func testAPlainFolderIsStillCreatedAsADirectory() {
		XCTAssertTrue(FileProviderExtension.createsDirectory(contentType: .folder))
		XCTAssertTrue(FileProviderExtension.createsDirectory(contentType: .directory))
	}

	/// Files, and a template that says nothing at all, are not directories.
	func testAFileIsNotCreatedAsADirectory() {
		XCTAssertFalse(FileProviderExtension.createsDirectory(contentType: .plainText))
		XCTAssertFalse(FileProviderExtension.createsDirectory(contentType: .data))
		XCTAssertFalse(FileProviderExtension.createsDirectory(contentType: nil))
	}

	// MARK: - Order

	/// Content first (it is what the user is waiting on), then the reparent, then the rename — so
	/// a rename that collides collides in the container the item ends up in.
	func testEverythingAtOnceRunsContentThenReparentThenRename() {
		XCTAssertEqual(
			steps(
				[.contents, .filename, .parentItemIdentifier, .favoriteRank],
				item: template(name: "after.pdf", favoriteRank: 3), hasContents: true),
			[
				.contents, .move(to: "stable/" + Self.folderUuid), .rename("after.pdf"),
				.favoriteRank(3),
			])
	}

	func testNoChangedFieldsDispatchesToNothing() {
		XCTAssertEqual(steps([], hasContents: true), [])
	}
}
