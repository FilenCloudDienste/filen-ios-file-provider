import FileProvider
import XCTest

/// "Keep Downloaded", "Don't Keep Downloaded" and "Remove Download": what an item renders for its
/// pin, which menu entries the Info.plist rules show for it, and which files a removal evicts.
/// The rules are evaluated here exactly as written in both Info.plists, against items rendered by
/// `FileProviderItem`, with `inheritedUserInfo` / `resolvedUserInfo` built the way
/// NSFileProviderItem.h describes them.
final class KeepDownloadedTests: XCTestCase {
	private static let parent = "33333333-3333-3333-3333-333333333333"

	override func tearDown() {
		for id in PinnedItems.all {
			PinnedItems.set(NSFileProviderItemIdentifier(id), pinned: false)
		}
		super.tearDown()
	}

	private func file(_ uuid: String, trashed: Bool = false) -> FileProviderItem {
		FileProviderItem(
			itemIdentifier: NSFileProviderItemIdentifier("stable/" + uuid),
			object: .file(
				FfiFile(
					uuid: uuid, stableUuid: uuid, parent: trashed ? TRASH_CACHE_ID : Self.parent,
					originalParent: trashed ? Self.parent : nil, meta: nil, size: 1,
					favoriteRank: 0, timestamp: 1, localData: nil, pendingUploadAt: nil,
					changeSeq: 5)))
	}

	private func dir(_ uuid: String, trashed: Bool = false) -> FileProviderItem {
		FileProviderItem(
			itemIdentifier: NSFileProviderItemIdentifier("stable/" + uuid),
			object: .dir(
				FfiDir(
					uuid: uuid, parent: trashed ? TRASH_CACHE_ID : Self.parent,
					originalParent: trashed ? Self.parent : nil, meta: nil, color: nil,
					favoriteRank: 0, timestamp: 1, lastListed: 0, localData: nil, changeSeq: 5)))
	}

	private func root() -> FileProviderItem {
		FileProviderItem(
			itemIdentifier: .rootContainer,
			object: .root(
				FfiRoot(
					uuid: Self.parent, storageUsed: 0, maxStorage: 0, lastUpdated: 0,
					lastListed: 0)))
	}

	private func pin(_ item: FileProviderItem) {
		PinnedItems.set(item.itemIdentifier, pinned: true)
	}

	// MARK: - Rendering

	func testAnUnpinnedItemIsPinnableAndInheritsItsPolicy() {
		let item = file("a1")
		XCTAssertFalse(item.isPinned)
		XCTAssertEqual(item.userInfo?[USER_INFO_PINNABLE] as? Bool, true)
		XCTAssertNil(item.userInfo?[USER_INFO_PINNED])
		#if os(macOS)
			XCTAssertEqual(item.contentPolicy, .inherited)
			XCTAssertNil(item.decorations)
		#endif
	}

	func testAPinnedItemCarriesTheInheritedKeyAndKeepsItsContent() {
		for item in [file("a2"), dir("a3")] {
			pin(item)
			XCTAssertTrue(item.isPinned)
			XCTAssertEqual(item.userInfo?[USER_INFO_PINNED] as? Bool, true)
			#if os(macOS)
				XCTAssertEqual(item.contentPolicy, .downloadEagerlyAndKeepDownloaded)
				XCTAssertEqual(item.decorations?.count, 1)
			#endif
		}
	}

	/// The system keeps an item's metadata while its version stands still, so a pin that did not
	/// move it would never reach the replica.
	func testPinningMovesTheMetadataVersionButNotTheContentVersion() {
		let before = file("a4").itemVersion
		pin(file("a4"))
		let after = file("a4").itemVersion
		XCTAssertNotEqual(before.metadataVersion, after.metadataVersion)
		XCTAssertEqual(before.contentVersion, after.contentVersion)
	}

	#if os(iOS)
		/// iOS has no keep-downloaded content policy; an item it may not evict is the equivalent.
		func testOnIOSOnlyAPinnedItemIsKeptFromEviction() {
			let item = file("a7")
			XCTAssertTrue(item.capabilities.contains(.allowsEvicting))
			pin(item)
			XCTAssertFalse(item.capabilities.contains(.allowsEvicting))
			XCTAssertFalse(root().capabilities.contains(.allowsEvicting))
		}
	#endif

	func testTheTrashAndTheRootHaveNothingToPin() {
		XCTAssertNil(file("a5", trashed: true).userInfo)
		XCTAssertNil(dir("a6", trashed: true).userInfo)
		XCTAssertNil(root().userInfo)
		XCTAssertFalse(root().isPinned)
	}

	// MARK: - Activation rules

	private struct Rules {
		let keep: NSPredicate
		let stopKeeping: NSPredicate
		let removeDownload: NSPredicate
	}

	private static let repoRoot = URL(fileURLWithPath: #filePath)
		.deletingLastPathComponent().deletingLastPathComponent()

	private func rules(_ plist: String) throws -> Rules {
		let data = try Data(contentsOf: Self.repoRoot.appending(path: plist))
		let info = try XCTUnwrap(
			PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
		let actions = try XCTUnwrap(
			(info["NSExtension"] as? [String: Any])?["NSExtensionFileProviderActions"]
				as? [[String: String]])
		var byId: [String: NSPredicate] = [:]
		for action in actions {
			let id = try XCTUnwrap(action["NSExtensionFileProviderActionIdentifier"])
			let rule = try XCTUnwrap(action["NSExtensionFileProviderActionActivationRule"])
			byId[id] = NSPredicate(format: rule)
		}
		return Rules(
			keep: try XCTUnwrap(byId[PinAction.keep.rawValue]),
			stopKeeping: try XCTUnwrap(byId[PinAction.stopKeeping.rawValue]),
			removeDownload: try XCTUnwrap(byId[PinAction.removeDownload.rawValue]))
	}

	/// What a predicate sees for an item: its userInfo, the `.inherited` keys of its ancestors
	/// (nearest wins), and the two merged.
	private func context(
		_ item: FileProviderItem, ancestors: [FileProviderItem] = [], downloaded: Bool = true
	) -> [String: Any] {
		var inherited: [AnyHashable: Any] = [:]
		for ancestor in ancestors.reversed() {
			for (key, value) in ancestor.userInfo ?? [:]
			where (key as? String)?.hasSuffix(".inherited") == true {
				inherited[key] = value
			}
		}
		var resolved = inherited
		for (key, value) in item.userInfo ?? [:]
		where (key as? String)?.hasSuffix(".inherited") == true {
			resolved[key] = value
		}
		var context: [String: Any] = [
			"inheritedUserInfo": inherited, "resolvedUserInfo": resolved,
			"isDownloaded": downloaded,
		]
		if let userInfo = item.userInfo { context["userInfo"] = userInfo }
		return context
	}

	private func shown(_ rule: NSPredicate, _ items: [[String: Any]]) -> Bool {
		rule.evaluate(with: ["fileproviderItems": items])
	}

	private func eachPlist(_ body: (Rules) throws -> Void) throws {
		try body(try rules("FilenFileProviderMac/Info.plist"))
		try body(try rules("FilenFileProviderExtension/Info.plist"))
	}

	func testAPlainDownloadedItemOffersKeepAndRemove() throws {
		try eachPlist { rules in
			let item = context(file("b1"))
			XCTAssertTrue(shown(rules.keep, [item]))
			XCTAssertFalse(shown(rules.stopKeeping, [item]))
			XCTAssertTrue(shown(rules.removeDownload, [item]))
			XCTAssertFalse(shown(rules.removeDownload, [context(file("b1"), downloaded: false)]))
		}
	}

	/// An item pinned itself offers to undo it, and to remove the download (which undoes it too).
	func testAPinnedItemOffersStopAndRemove() throws {
		let pinned = dir("b2")
		pin(pinned)
		try eachPlist { rules in
			let item = context(pinned)
			XCTAssertFalse(shown(rules.keep, [item]))
			XCTAssertTrue(shown(rules.stopKeeping, [item]))
			XCTAssertTrue(shown(rules.removeDownload, [item]))
		}
	}

	/// An item covered by a pinned ancestor is kept already and cannot be unpinned or evicted on
	/// its own, so it offers none of the three.
	func testACoveredItemOffersNothing() throws {
		let ancestor = dir("b3")
		pin(ancestor)
		try eachPlist { rules in
			let item = context(file("b4"), ancestors: [dir("b5"), ancestor])
			XCTAssertFalse(shown(rules.keep, [item]))
			XCTAssertFalse(shown(rules.stopKeeping, [item]))
			XCTAssertFalse(shown(rules.removeDownload, [item]))
		}
	}

	/// An item pinned itself below a pinned ancestor can still drop its own pin.
	func testAnItemPinnedBelowAPinOffersStop() throws {
		let ancestor = dir("b6")
		let pinned = file("b7")
		pin(ancestor)
		pin(pinned)
		try eachPlist { rules in
			XCTAssertTrue(shown(rules.stopKeeping, [context(pinned, ancestors: [ancestor])]))
		}
	}

	func testTheTrashAndTheRootOfferNoPin() throws {
		try eachPlist { rules in
			for item in [context(file("b8", trashed: true)), context(root())] {
				XCTAssertFalse(shown(rules.keep, [item]))
				XCTAssertFalse(shown(rules.stopKeeping, [item]))
			}
			XCTAssertTrue(shown(rules.removeDownload, [context(root())]))
		}
	}

	/// A selection shows an entry when any item in it would act on it.
	func testAMixedSelectionShowsEveryEntryThatApplies() throws {
		let pinned = file("b9")
		pin(pinned)
		try eachPlist { rules in
			let selection = [context(file("b10")), context(pinned)]
			XCTAssertTrue(shown(rules.keep, selection))
			XCTAssertTrue(shown(rules.stopKeeping, selection))
			XCTAssertTrue(shown(rules.removeDownload, selection))
		}
	}

	func testBothPlatformsShareTheRules() throws {
		let mac = try rules("FilenFileProviderMac/Info.plist")
		let ios = try rules("FilenFileProviderExtension/Info.plist")
		XCTAssertEqual(mac.keep.predicateFormat, ios.keep.predicateFormat)
		XCTAssertEqual(mac.stopKeeping.predicateFormat, ios.stopKeeping.predicateFormat)
		XCTAssertEqual(mac.removeDownload.predicateFormat, ios.removeDownload.predicateFormat)
	}

	// MARK: - Eviction plan

	private func entry(_ id: String, in parent: String, folder: Bool = false) -> MaterializedEntry {
		MaterializedEntry(identifier: id, parent: parent, isFolder: folder)
	}

	private let tree: [MaterializedEntry] = [
		MaterializedEntry(identifier: "d", parent: "root", isFolder: true),
		MaterializedEntry(identifier: "d/f1", parent: "d", isFolder: false),
		MaterializedEntry(identifier: "d/s", parent: "d", isFolder: true),
		MaterializedEntry(identifier: "d/s/f2", parent: "d/s", isFolder: false),
		MaterializedEntry(identifier: "d/p", parent: "d", isFolder: true),
		MaterializedEntry(identifier: "d/p/f3", parent: "d/p", isFolder: false),
		MaterializedEntry(identifier: "d/f4", parent: "d", isFolder: false),
		MaterializedEntry(identifier: "other", parent: "root", isFolder: false),
	]

	func testRemovingADirectoryEvictsItsFilesButSkipsPinnedSubtrees() {
		XCTAssertEqual(
			KeepDownloaded.evictionTargets(of: ["d"], materialized: tree, pinned: ["d/p", "d/f4"]),
			["d/f1", "d/s/f2"])
	}

	func testRemovingAFileEvictsExactlyIt() {
		XCTAssertEqual(
			KeepDownloaded.evictionTargets(of: ["d/f1"], materialized: tree, pinned: []), ["d/f1"])
	}

	func testRemovingTheRootEvictsEverythingUnpinned() {
		XCTAssertEqual(
			KeepDownloaded.evictionTargets(of: ["root"], materialized: tree, pinned: ["d/s"]),
			["d/f1", "d/p/f3", "d/f4", "other"])
	}

	func testFilesOffTheMaterializedTreeAreLeftAlone() {
		let orphan = [entry("x/f", in: "x")]
		XCTAssertEqual(
			KeepDownloaded.evictionTargets(of: ["d"], materialized: tree + orphan, pinned: []),
			["d/f1", "d/s/f2", "d/p/f3", "d/f4"])
	}

	func testAParentCycleEndsTheWalk() {
		let cycle = [
			entry("a", in: "b", folder: true), entry("b", in: "a", folder: true), entry("f", in: "a"),
		]
		XCTAssertEqual(
			KeepDownloaded.evictionTargets(of: ["d"], materialized: cycle, pinned: []), [])
	}

	func testAnItemsOwnStateIsNotAnEvictionFault() {
		XCTAssertTrue(KeepDownloaded.isExpectedEvictionFailure(NSFileProviderError(.unsyncedEdits)))
		XCTAssertTrue(KeepDownloaded.isExpectedEvictionFailure(NSFileProviderError(.nonEvictable)))
		XCTAssertTrue(
			KeepDownloaded.isExpectedEvictionFailure(
				NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY))))
		XCTAssertFalse(
			KeepDownloaded.isExpectedEvictionFailure(
				NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError)))
	}
}
