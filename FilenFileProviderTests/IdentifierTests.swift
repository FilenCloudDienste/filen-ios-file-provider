import FileProvider
import XCTest

/// Pure tests for how items report their identity and their container to the system.
///
/// The framework contract is that an item's identifier is stable for its whole life and its
/// `parentItemIdentifier` names the container it actually lives in. Getting the parent wrong does
/// not crash anything — the Files app just shows the item in the wrong place — so nothing but a
/// test catches it.
///
/// These need no network and no `FileProviderExtension` instance.
final class IdentifierTests: XCTestCase {
	private static let fileStableUuid = "11111111-1111-1111-1111-111111111111"
	private static let fileUuid = "22222222-2222-2222-2222-222222222222"
	private static let parentUuid = "33333333-3333-3333-3333-333333333333"

	private func makeFile(
		parent: String,
		originalParent: String?
	) -> FfiFile {
		FfiFile(
			uuid: Self.fileUuid,
			stableUuid: Self.fileStableUuid,
			parent: parent,
			originalParent: originalParent,
			meta: nil,
			size: 0,
			favoriteRank: 0,
			localData: nil,
			pendingUploadAt: nil,
			changeSeq: 0)
	}

	// MARK: - A1: trashed items must report their original container, not the drive root

	/// Reproduces what `trashItem` hands back to the system: an item built with no explicit parent.
	/// Its parent must resolve to the container it was trashed out of. Reporting `.rootContainer`
	/// would move every trashed item to the drive root in the Files app.
	func testATrashedItemReportsItsOriginalParentNotTheRoot() {
		let trashed = makeFile(parent: "trash", originalParent: Self.parentUuid)
		let item = FileProviderItem(
			itemIdentifier: NSFileProviderItemIdentifier("stable/" + Self.fileStableUuid),
			object: .file(trashed))

		XCTAssertNotEqual(
			item.parentItemIdentifier, .rootContainer,
			"a trashed item nested under a folder must not report the drive root as its parent")
		XCTAssertEqual(
			item.parentItemIdentifier,
			NSFileProviderItemIdentifier("stable/" + Self.parentUuid),
			"a trashed item must report the container it will be restored into")
	}

	/// An explicitly supplied parent always wins — this is the path every other mutation handler
	/// already takes, and it must keep working.
	func testAnExplicitParentIsPreservedVerbatim() {
		let file = makeFile(parent: Self.parentUuid, originalParent: nil)
		let item = FileProviderItem(
			itemIdentifier: NSFileProviderItemIdentifier("stable/" + Self.fileStableUuid),
			object: .file(file),
			parentItemIdentifier: .rootContainer)

		XCTAssertEqual(item.parentItemIdentifier, .rootContainer)
	}

	/// A live (non-trashed) item built without an explicit parent must still report its real
	/// container rather than collapsing to the root.
	func testALiveItemWithoutAnExplicitParentReportsItsContainer() {
		let file = makeFile(parent: Self.parentUuid, originalParent: nil)
		let item = FileProviderItem(
			itemIdentifier: NSFileProviderItemIdentifier("stable/" + Self.fileStableUuid),
			object: .file(file))

		XCTAssertEqual(
			item.parentItemIdentifier,
			NSFileProviderItemIdentifier("stable/" + Self.parentUuid))
	}

	/// `isTrashed` is read off the object, because a stable identifier carries no `trash/` prefix.
	func testTrashStateComesFromTheObjectNotTheIdentifier() {
		let trashed = makeFile(parent: "trash", originalParent: Self.parentUuid)
		let live = makeFile(parent: Self.parentUuid, originalParent: nil)
		let identifier = NSFileProviderItemIdentifier("stable/" + Self.fileStableUuid)

		XCTAssertTrue(FileProviderItem(itemIdentifier: identifier, object: .file(trashed)).isTrashed)
		XCTAssertFalse(FileProviderItem(itemIdentifier: identifier, object: .file(live)).isTrashed)
	}

	// MARK: - A5: pin the legacy path-splitting helper

	/// `getParentItemIdentifier` is a legacy heuristic that needs two or more slashes to split a
	/// real parent out of a path-form identifier. Every identifier the app issues now is
	/// `stable/<uuid>` — exactly one slash — so it always answers `.rootContainer`.
	///
	/// This pins that fact deliberately: the helper is NOT a usable fallback for current
	/// identifiers, and nothing should lean on it as one. It exists only so identifiers persisted
	/// by the system before the migration keep resolving.
	func testGetParentItemIdentifierIsRootContainerForEveryCurrentIdentifier() {
		XCTAssertEqual(
			getParentItemIdentifier(
				itemIdentifier: NSFileProviderItemIdentifier("stable/" + Self.fileStableUuid)),
			.rootContainer,
			"single-slash stable ids cannot be split — the helper is legacy-only")
	}

	func testGetParentItemIdentifierSplitsLegacyPathIdentifiers() {
		XCTAssertEqual(
			getParentItemIdentifier(
				itemIdentifier: NSFileProviderItemIdentifier("root-uuid/Photos/holiday.jpg")),
			NSFileProviderItemIdentifier("root-uuid/Photos"))
	}

	func testGetParentItemIdentifierIsRootContainerWithoutASlash() {
		XCTAssertEqual(
			getParentItemIdentifier(itemIdentifier: NSFileProviderItemIdentifier("root-uuid")),
			.rootContainer)
	}
}
