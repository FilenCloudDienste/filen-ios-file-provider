import FileProvider
import os

/// The three custom actions: "Keep Downloaded", "Don't Keep Downloaded" and "Remove Download".
///
/// The identifiers are repeated in `NSExtensionFileProviderActions` of the macOS Info.plist and of
/// the iOS one (which the mobile app's config plugin generates). All of them must match.
enum PinAction: String {
	case keep = "io.filen.fileprovider.action.keepDownloaded"
	case stopKeeping = "io.filen.fileprovider.action.stopKeepingDownloaded"
	case removeDownload = "io.filen.fileprovider.action.removeDownload"
}

/// userInfo key present on an item the user pinned. The `.inherited` suffix hands it to every
/// descendant's `inheritedUserInfo` and `resolvedUserInfo` (NSFileProviderItem.h, `userInfo`),
/// which is how the action rules see a pin covering an item without the subtree being re-served
/// whenever a pin above it changes. Only ever set, never set to false: the rules test for the key.
let USER_INFO_PINNED = "pinned.inherited"
/// userInfo key present on an item that can be pinned: a live file or directory.
let USER_INFO_PINNABLE = "pinnable"

/// The pinned identifiers, mirrored in memory so rendering an item costs a set lookup rather than a
/// query. The cache's `pinned_items` table is the source of truth and every write lands there
/// first; this is reloaded from it whenever a session starts.
///
/// Process-wide because items are rendered where no extension instance is in reach. Identifiers
/// are `stable/<uuid>`, which no two accounts share.
enum PinnedItems {
	private static let ids = OSAllocatedUnfairLock<Set<String>>(initialState: [])

	static func contains(_ identifier: NSFileProviderItemIdentifier) -> Bool {
		self.ids.withLock { $0.contains(identifier.rawValue) }
	}

	static var all: Set<String> { self.ids.withLock { $0 } }

	static func set(_ identifier: NSFileProviderItemIdentifier, pinned: Bool) {
		self.ids.withLock { ids in
			if pinned {
				ids.insert(identifier.rawValue)
			} else {
				ids.remove(identifier.rawValue)
			}
		}
	}

	static func load(from state: FilenMobileCacheState) throws {
		let loaded = Set(try state.pinnedIds())
		self.ids.withLock { $0 = loaded }
	}
}

/// A materialized item as the eviction plan needs it.
struct MaterializedEntry: Equatable {
	let identifier: String
	let parent: String
	let isFolder: Bool
}

/// The pin and eviction decisions, pure so they are testable without the system.
///
/// Semantics:
/// - A pin on a directory covers its subtree: descendants report the inherited content policy and
///   see the pin through `resolvedUserInfo`.
/// - A covered item cannot be unpinned on its own. Its menu offers neither "Don't Keep Downloaded"
///   nor "Remove Download" (eviction under a keep-downloaded ancestor fails NonEvictable); the pin
///   is undone where it was made, which the badge marks. An item pinned itself keeps its own pin
///   when a pin above it goes.
/// - "Remove Download" clears the selected items' own pins, then evicts every downloaded file in
///   the selection, skipping subtrees pinned below it.
/// - On iOS a pin keeps the item's own replica (no `allowsEvicting`) and its bytes, and those of
///   everything below a pinned directory, in the cache; see `prefetchPinned`.
enum KeepDownloaded {
	/// What the action rules read off an item.
	static func userInfo(pinned: Bool, pinnable: Bool) -> [AnyHashable: Any]? {
		guard pinnable else { return nil }
		var userInfo: [AnyHashable: Any] = [USER_INFO_PINNABLE: true]
		if pinned { userInfo[USER_INFO_PINNED] = true }
		return userInfo
	}

	#if os(macOS)
		/// Keep-downloaded exists on macOS only:
		/// `NSFileProviderContentPolicyDownloadEagerlyAndKeepDownloaded` is
		/// FILEPROVIDER_API_AVAILABILITY_V5_0 (NSFileProviderItem.h). Everything else inherits, so
		/// a directory's pin reaches its whole subtree.
		static func contentPolicy(pinned: Bool) -> NSFileProviderContentPolicy {
			pinned ? .downloadEagerlyAndKeepDownloaded : .inherited
		}
	#endif

	/// The files a "Remove Download" of `targets` evicts: every materialized file that is a target
	/// or sits below one, unless a pinned item lies between them. `pinned` must no longer hold the
	/// targets' own pins.
	static func evictionTargets(
		of targets: Set<String>, materialized: [MaterializedEntry], pinned: Set<String>
	) -> [String] {
		var parents: [String: String] = [:]
		for entry in materialized where entry.isFolder { parents[entry.identifier] = entry.parent }
		// Per folder: whether files below it are evicted. Memoized, so the walk is linear in the
		// materialized set rather than in set times depth.
		var verdicts: [String: Bool] = [:]
		func evicts(below folder: String) -> Bool {
			var chain: [String] = []
			var current = folder
			var verdict = false
			while true {
				if let known = verdicts[current] {
					verdict = known
					break
				}
				chain.append(current)
				if pinned.contains(current) { break }
				if targets.contains(current) {
					verdict = true
					break
				}
				// Off the materialized tree, or a cycle the system should never hand back.
				guard let parent = parents[current], chain.count <= parents.count else { break }
				current = parent
			}
			for folder in chain { verdicts[folder] = verdict }
			return verdict
		}
		return materialized.compactMap { entry in
			guard !entry.isFolder else { return nil }
			if targets.contains(entry.identifier) { return entry.identifier }
			if pinned.contains(entry.identifier) { return nil }
			return evicts(below: entry.parent) ? entry.identifier : nil
		}
	}

	/// Whether an eviction failure is the item's state rather than a fault: an edit not yet
	/// uploaded, a pin, an open file. Those items stay; the rest of the selection still goes.
	static func isExpectedEvictionFailure(_ error: any Error) -> Bool {
		let nsError = error as NSError
		switch nsError.domain {
		case NSFileProviderErrorDomain:
			return [
				NSFileProviderError.Code.unsyncedEdits.rawValue,
				NSFileProviderError.Code.nonEvictable.rawValue,
				NSFileProviderError.Code.nonEvictableChildren.rawValue,
				NSFileProviderError.Code.noSuchItem.rawValue,
			].contains(nsError.code)
		case NSPOSIXErrorDomain:
			return nsError.code == Int(EBUSY) || nsError.code == Int(EMLINK)
		default:
			return false
		}
	}
}
