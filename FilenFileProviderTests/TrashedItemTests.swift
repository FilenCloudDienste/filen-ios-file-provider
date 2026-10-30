import FileProvider
import XCTest

/// A trashed item the system learns about remotely is created straight into the replica's trash.
/// The system locks an item that lacks `allowsWriting`, and creating a locked item there fails
/// with EPERM on every retry, which shows the whole location as paused. These pin the capabilities
/// that keep it creatable, and the anchor revision that re-serves items already on disk.
final class TrashedItemTests: XCTestCase {
	private static let uuid = "11111111-1111-1111-1111-111111111111"
	private static let stableUuid = "22222222-2222-2222-2222-222222222222"
	private static let originalParent = "33333333-3333-3333-3333-333333333333"

	private func file(trashed: Bool) -> FileProviderItem {
		FileProviderItem(
			itemIdentifier: NSFileProviderItemIdentifier("stable/" + Self.stableUuid),
			object: .file(
				FfiFile(
					uuid: Self.uuid, stableUuid: Self.stableUuid,
					parent: trashed ? TRASH_CACHE_ID : Self.originalParent,
					originalParent: trashed ? Self.originalParent : nil, meta: nil, size: 0,
					favoriteRank: 0, timestamp: 1, localData: nil, pendingUploadAt: nil,
					changeSeq: 1)))
	}

	private func dir(trashed: Bool) -> FileProviderItem {
		FileProviderItem(
			itemIdentifier: NSFileProviderItemIdentifier("stable/" + Self.uuid),
			object: .dir(
				FfiDir(
					uuid: Self.uuid, parent: trashed ? TRASH_CACHE_ID : Self.originalParent,
					originalParent: trashed ? Self.originalParent : nil, meta: nil, color: nil,
					favoriteRank: 0, timestamp: 1, lastListed: 0, localData: nil, changeSeq: 1)))
	}

	// MARK: - Capabilities

	func testATrashedFileIsWritableSoTheReplicaIsNotLocked() {
		XCTAssertTrue(file(trashed: true).capabilities.contains(.allowsWriting))
	}

	func testATrashedDirectoryIsWritableSoTheReplicaIsNotLocked() {
		XCTAssertTrue(dir(trashed: true).capabilities.contains(.allowsAddingSubItems))
	}

	/// Restoring and deleting for good are the two things the trash is for.
	func testATrashedItemCanBeRestoredAndDeleted() {
		for item in [file(trashed: true), dir(trashed: true)] {
			XCTAssertTrue(item.capabilities.contains(.allowsTrashing))
			XCTAssertTrue(item.capabilities.contains(.allowsDeleting))
		}
	}

	/// Opening, renaming or moving a trashed item stays off: the drive keeps trashed items out of
	/// reach until they are restored.
	func testATrashedItemCannotBeOpenedRenamedOrMoved() {
		for item in [file(trashed: true), dir(trashed: true)] {
			XCTAssertFalse(item.capabilities.contains(.allowsReading))
			XCTAssertFalse(item.capabilities.contains(.allowsRenaming))
			XCTAssertFalse(item.capabilities.contains(.allowsReparenting))
		}
	}

	func testALiveItemKeepsItsFullCapabilities() {
		XCTAssertEqual(
			file(trashed: false).capabilities,
			[
				.allowsReading, .allowsWriting, .allowsRenaming, .allowsTrashing,
				.allowsReparenting, .allowsDeleting,
			])
		XCTAssertEqual(
			dir(trashed: false).capabilities,
			[
				.allowsContentEnumerating, .allowsAddingSubItems, .allowsRenaming,
				.allowsTrashing, .allowsReparenting, .allowsDeleting,
			])
	}

	// MARK: - Parent and trash flag

	/// iOS reads `isTrashed` and keeps the original parent for the restore; macOS has no
	/// `isTrashed`, so the trash itself is the parent there.
	func testATrashedItemReportsTheParentThePlatformExpects() {
		let item = file(trashed: true)
		#if os(macOS)
			XCTAssertEqual(item.parentItemIdentifier, .trashContainer)
		#else
			XCTAssertTrue(item.isTrashed)
			XCTAssertEqual(
				item.parentItemIdentifier,
				NSFileProviderItemIdentifier("stable/" + Self.originalParent))
		#endif
	}

	// MARK: - Working-set anchor

	func testTheCacheAnchorRoundTripsThroughTheSystemAnchor() {
		let cacheAnchor = Data((0..<24).map { UInt8($0) })

		XCTAssertEqual(
			WorkingSetEnumerator.cacheAnchor(
				from: WorkingSetEnumerator.systemAnchor(cacheAnchor: cacheAnchor)),
			cacheAnchor)
	}

	/// An anchor issued before the revision existed is the cache's bare anchor. It has to expire,
	/// or items already on disk never see a rendering change.
	func testAnAnchorFromAnotherRevisionExpires() {
		var stale = Data([ITEM_RENDERING_REVISION &+ 1])
		stale.append(Data(repeating: 0, count: 24))

		XCTAssertNil(WorkingSetEnumerator.cacheAnchor(from: NSFileProviderSyncAnchor(stale)))
		XCTAssertNil(WorkingSetEnumerator.cacheAnchor(from: NSFileProviderSyncAnchor(Data())))
	}
}
