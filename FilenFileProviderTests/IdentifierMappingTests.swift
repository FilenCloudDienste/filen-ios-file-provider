import FileProvider
import XCTest

/// `FileProviderExtension.itemIdentifier` and `.containerIdentifier` are the single place deciding
/// that a file keys off its whole-life `stableUuid` while a directory keys off its `uuid`.
///
/// A copy-paste swapping `stableUuid` for `uuid` here would break identity for every mutation
/// response — the system would see a brand new item after every content edit — and nothing would
/// crash. These pin the invariant.
final class IdentifierMappingTests: XCTestCase {
	private static let fileUuid = "11111111-1111-1111-1111-111111111111"
	private static let fileStableUuid = "22222222-2222-2222-2222-222222222222"
	private static let dirUuid = "33333333-3333-3333-3333-333333333333"
	private static let parentUuid = "44444444-4444-4444-4444-444444444444"
	private static let rootUuid = "55555555-5555-5555-5555-555555555555"

	private func file(parent: String = parentUuid, originalParent: String? = nil) -> FfiObject {
		.file(
			FfiFile(
				uuid: Self.fileUuid, stableUuid: Self.fileStableUuid, parent: parent,
				originalParent: originalParent, meta: nil, size: 0, favoriteRank: 0, localData: nil,
			pendingUploadAt: nil))
	}

	private func dir(parent: String = parentUuid, originalParent: String? = nil) -> FfiObject {
		.dir(
			FfiDir(
				uuid: Self.dirUuid, parent: parent, originalParent: originalParent, meta: nil,
				color: nil, favoriteRank: 0, lastListed: 0, localData: nil))
	}

	private func root() -> FfiObject {
		.root(
			FfiRoot(
				uuid: Self.rootUuid, storageUsed: 0, maxStorage: 0, lastUpdated: 0, lastListed: 0))
	}

	// MARK: - itemIdentifier

	/// A file MUST key off its stable id — `uuid` is re-minted on every content edit and version
	/// restore, so using it would change the item's identity whenever the file is edited.
	func testAFileIsIdentifiedByItsStableUuidNotItsCurrentUuid() {
		let identifier = FileProviderExtension.itemIdentifier(for: file(), fallback: "unused")

		XCTAssertEqual(identifier.rawValue, "stable/" + Self.fileStableUuid)
		XCTAssertNotEqual(identifier.rawValue, "stable/" + Self.fileUuid)
	}

	/// Directories carry no stable id on the wire — stable == uuid, by design.
	func testADirectoryIsIdentifiedByItsUuid() {
		XCTAssertEqual(
			FileProviderExtension.itemIdentifier(for: dir(), fallback: "unused").rawValue,
			"stable/" + Self.dirUuid)
	}

	func testTheRootFallsBackToTheSuppliedIdentifier() {
		XCTAssertEqual(
			FileProviderExtension.itemIdentifier(for: root(), fallback: "root-fallback").rawValue,
			"root-fallback")
	}

	// MARK: - containerIdentifier

	func testAnItemInAFolderReportsThatFolderAsItsContainer() {
		XCTAssertEqual(
			FileProviderExtension.containerIdentifier(
				for: file(), fallbackFrom: NSFileProviderItemIdentifier("stable/x"),
				rootUuid: Self.rootUuid),
			NSFileProviderItemIdentifier("stable/" + Self.parentUuid))
	}

	/// A child of the drive root must report the framework's root sentinel, not the root's own
	/// `stable/` form — the system compares against `.rootContainer` by identity.
	func testAChildOfTheRootReportsTheRootContainerSentinel() {
		XCTAssertEqual(
			FileProviderExtension.containerIdentifier(
				for: file(parent: Self.rootUuid),
				fallbackFrom: NSFileProviderItemIdentifier("stable/x"),
				rootUuid: Self.rootUuid),
			.rootContainer)
	}

	/// A trashed item points at the folder it will be restored into, not at the trash sentinel.
	func testATrashedItemReportsItsOriginalParent() {
		XCTAssertEqual(
			FileProviderExtension.containerIdentifier(
				for: file(parent: "trash", originalParent: Self.parentUuid),
				fallbackFrom: NSFileProviderItemIdentifier("stable/x"),
				rootUuid: Self.rootUuid),
			NSFileProviderItemIdentifier("stable/" + Self.parentUuid))
	}

	func testATrashedDirectoryAlsoReportsItsOriginalParent() {
		XCTAssertEqual(
			FileProviderExtension.containerIdentifier(
				for: dir(parent: "trash", originalParent: Self.parentUuid),
				fallbackFrom: NSFileProviderItemIdentifier("stable/x"),
				rootUuid: Self.rootUuid),
			NSFileProviderItemIdentifier("stable/" + Self.parentUuid))
	}

	/// With no recoverable parent the legacy path-splitting fallback takes over.
	func testAnItemWithNoRecoverableParentFallsBackToThePathSplit() {
		XCTAssertEqual(
			FileProviderExtension.containerIdentifier(
				for: file(parent: "trash", originalParent: nil),
				fallbackFrom: NSFileProviderItemIdentifier("root-uuid/Photos/holiday.jpg"),
				rootUuid: Self.rootUuid),
			NSFileProviderItemIdentifier("root-uuid/Photos"))
	}

	/// An unknown root must not accidentally match an item whose parent is genuinely nil-ish.
	func testAnUnknownRootNeverYieldsTheRootContainer() {
		XCTAssertEqual(
			FileProviderExtension.containerIdentifier(
				for: file(parent: Self.rootUuid),
				fallbackFrom: NSFileProviderItemIdentifier("stable/x"),
				rootUuid: nil),
			NSFileProviderItemIdentifier("stable/" + Self.rootUuid))
	}

	func testTheRootObjectItselfFallsBackToThePathSplit() {
		XCTAssertEqual(
			FileProviderExtension.containerIdentifier(
				for: root(), fallbackFrom: NSFileProviderItemIdentifier("stable/x"),
				rootUuid: Self.rootUuid),
			.rootContainer)
	}
}
