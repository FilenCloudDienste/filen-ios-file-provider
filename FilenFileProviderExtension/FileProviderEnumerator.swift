import FileProvider
import os

/// The working set: the items this device has a stake in, and the only container this provider
/// tracks incrementally.
///
/// Everything else re-enumerates on presentation (`FileProviderEnumerator` hands back a nil sync
/// anchor), which is what the system does with a container it cannot diff. The working set has to
/// be different: it is how a provider tells the system about changes to items whose parent nobody
/// is looking at, and the system will not ask for a full enumeration of it on its own.
class WorkingSetEnumerator: NSObject, NSFileProviderEnumerator {
	private static let logger = Logger(subsystem: PROVIDER, category: "FileProvider")
	private let state: FilenMobileCacheState
	private let rootUuid: String
	/// The extension's registry, so the change enumeration this object starts is work the extension
	/// can drop: `invalidate()` must be able to stop the observer from being called afterwards.
	private let inFlight: InFlightWork
	/// The anchor read TOGETHER WITH (and before) the last full enumeration's rows, serialized
	/// behind a lock because the system may call `enumerateItems` and `currentSyncAnchor` from
	/// different queues. See `currentSyncAnchor` for why a live read must not stand in for it.
	private let anchorLock = NSLock()
	private var enumerationAnchor: NSFileProviderSyncAnchor?

	init(state: FilenMobileCacheState, rootUuid: String, inFlight: InFlightWork) {
		self.state = state
		self.rootUuid = rootUuid
		self.inFlight = inFlight
		super.init()
	}

	func invalidate() {
		// noop — the stashed anchor dies with this instance, and a fresh enumerator's first
		// full enumeration re-establishes it.
	}

	private func stashAnchor(_ anchor: NSFileProviderSyncAnchor) {
		self.anchorLock.lock()
		defer { self.anchorLock.unlock() }
		self.enumerationAnchor = anchor
	}

	private func stashedAnchor() -> NSFileProviderSyncAnchor? {
		self.anchorLock.lock()
		defer { self.anchorLock.unlock() }
		return self.enumerationAnchor
	}

	private func clearStashedAnchor() {
		self.anchorLock.lock()
		defer { self.anchorLock.unlock() }
		self.enumerationAnchor = nil
	}

	/// The item as the working set should present it: with the container it actually lives in,
	/// never the working-set sentinel.
	private func item(for object: FfiObject) -> FileProviderItem? {
		// A root is not part of any replica's world — the feed and the working set both exclude
		// them, and one arriving here would only be noise.
		if case .root(_) = object { return nil }
		let identifier = FileProviderExtension.itemIdentifier(for: object, fallback: self.rootUuid)
		return FileProviderItem(
			itemIdentifier: identifier, object: object,
			parentItemIdentifier: FileProviderExtension.containerIdentifier(
				for: object, fallbackFrom: identifier, rootUuid: self.rootUuid))
	}

	func enumerateItems(
		for observer: any NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage
	) {
		// Served whole: the working set is bounded by what this device has a stake in, not by the
		// size of the drive. The rows come PAIRED with their anchor (read anchor-first on one
		// connection) and the anchor is stashed for `currentSyncAnchor` — see there for why.
		do {
			let workingSet = try self.state.queryWorkingSetWithAnchor()
			self.stashAnchor(NSFileProviderSyncAnchor(workingSet.anchor))
			observer.didEnumerate(workingSet.items.compactMap(self.item(for:)))
			observer.finishEnumerating(upTo: nil)
		} catch {
			observer.finishEnumeratingWithError(providerError(from: error))
		}
	}

	func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
		// The anchor PAIRED with the last full enumeration, never a live counter read after it:
		// the system calls this after `enumerateItems` to establish its diff baseline, and a live
		// read would sit ABOVE any write that landed since the enumeration's snapshot — the
		// strictly-above diff would then skip that write for good. Serving the (possibly older)
		// paired anchor only risks duplicate delivery, which the replica absorbs. The live read
		// remains the fallback for a fresh enumerator the system asks before any enumeration.
		if let stashed = self.stashedAnchor() {
			completionHandler(stashed)
			return
		}
		do {
			completionHandler(NSFileProviderSyncAnchor(try self.state.currentSyncAnchor()))
		} catch {
			// A nil anchor asks the system to enumerate from scratch instead, which is the honest
			// answer when the cache cannot say where it stands.
			Self.logger.error("could not read the sync anchor: \(error)")
			completionHandler(nil)
		}
	}

	/// The diff, served on the extension's registry so `invalidate()` can drop it: an observer
	/// belonging to a discarded instance must not be called afterwards. The refresh below takes no
	/// abort signal — only the three byte-moving calls do — so cancelling only abandons it: it
	/// finishes against the server, and the answer it would have given is dropped by the guard.
	/// That is one metadata round trip, not a transfer, which is why it is not worth stopping.
	func enumerateChanges(
		for observer: any NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor
	) {
		let answer = CallOnce()
		self.inFlight.run(
			Progress(),
			onCancel: { answer.fire { observer.finishEnumeratingWithError(userCancelledError()) } }
		) {
			// Best effort, and deliberately unchecked: the anchor is a purely local watermark, so
			// a refresh that fails (offline, server down) must still serve the diff the cache
			// already holds rather than failing the whole enumeration.
			do {
				try await self.state.updateRecents()
			} catch {
				Self.logger.error("working-set refresh failed, serving the local diff: \(error)")
			}

			do {
				let changes = try self.state.enumerateChanges(anchor: anchor.rawValue)
				let updated = changes.updated.compactMap(self.item(for:))
				let deleted = changes.deletedIds.map { NSFileProviderItemIdentifier($0) }
				// The diff delivered everything up to its anchor, so that anchor is paired with
				// served state exactly like a full enumeration's — keep the stash current with it.
				self.stashAnchor(NSFileProviderSyncAnchor(changes.anchor))
				// One block, so a cancellation cannot land between the updates and the finish.
				answer.fire {
					observer.didUpdate(updated)
					observer.didDeleteItems(withIdentifiers: deleted)
					observer.finishEnumeratingChanges(
						upTo: NSFileProviderSyncAnchor(changes.anchor), moreComing: changes.more)
				}

				// Nothing more to do here for working-set tracking: `enumerateChanges` above
				// already spawns exactly this reconcile off the caller's path — that is what makes
				// it the backstop refresh point. Awaiting a second, identical one only kept the
				// system waiting on the cache's own bookkeeping.
			} catch CacheError.SyncAnchorExpired(_) {
				// The one failure that is not an error: the system drops what it has and asks
				// again from nothing. The stashed anchor belongs to the dead incarnation —
				// clear it, or the re-enumeration's currentSyncAnchor would hand the stale
				// bytes back and buy a second expired round trip.
				self.clearStashedAnchor()
				answer.fire {
					observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
				}
			} catch {
				answer.fire { observer.finishEnumeratingWithError(providerError(from: error)) }
			}
		}
	}
}

class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {
	private let enumeratedItemIdentifier: NSFileProviderItemIdentifier
	// The identifier the SYSTEM enumerated (.rootContainer/.trashContainer
	// stay as-is): children must report this as their parent, not the
	// cache-form substitute used for queries.
	private let reportedContainerIdentifier: NSFileProviderItemIdentifier
	// Only the cache is needed, not the whole extension — holding the state directly is what lets
	// an enumerator be built in a test without constructing a FileProviderExtension.
	private let state: FilenMobileCacheState

	init(
		enumeratedItemIdentifier: NSFileProviderItemIdentifier, state: FilenMobileCacheState,
		rootUuid: String
	) {
		self.reportedContainerIdentifier = enumeratedItemIdentifier
		self.enumeratedItemIdentifier =
			if enumeratedItemIdentifier == NSFileProviderItemIdentifier.rootContainer {
				NSFileProviderItemIdentifier(rootUuid)
			} else if enumeratedItemIdentifier == NSFileProviderItemIdentifier.trashContainer {
				NSFileProviderItemIdentifier(TRASH_CACHE_ID)
			} else { enumeratedItemIdentifier }
		self.state = state
		super.init()
	}

	func invalidate() {
		// noop
		// with paged approach in api v4 we could probably make use of this
	}

	/// No incremental tracking per directory: the drive has no per-container change history to
	/// build a diff from, and a domain-global diff served from every open directory enumerator
	/// costs the same work over and over. A nil anchor tells the system to re-enumerate the
	/// container when it is presented, which is what it did before any of this existed.
	func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
		completionHandler(nil)
	}

	/// Only reachable if the system asks for changes despite the nil anchor above. Expiring is the
	/// documented way to say "start over", and it costs a re-enumeration, not an error the user
	/// sees.
	func enumerateChanges(
		for observer: any NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor
	) {
		observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
	}

	/// The trash is not a cached directory — `queryItem` can never resolve it, so it has its own
	/// pair of cache calls. Routing it through the generic child-listing path below would always
	/// miss and surface as "no such item" in the Files app's Recently Deleted view.
	private func enumerateTrash(for observer: any NSFileProviderEnumerationObserver) async {
		do {
			try await self.state.updateTrash()
			let response = try self.state.queryTrash(orderBy: nil)
			let items = response.objects.map {
				FileProviderItem(parentItemIdentifier: .trashContainer, object: $0)
			}
			observer.didEnumerate(items)
			observer.finishEnumerating(upTo: nil)
		} catch {
			// `providerError` folds CacheError, cancellation, and anything else (a lifted Rust
			// panic included) into the two domains the framework understands.
			observer.finishEnumeratingWithError(providerError(from: error))
		}
	}

	// How many children to hand the system per enumeration page.
	private static let pageSize: UInt32 = 250

	// The system's initial pages (sortedByName/Date) map to offset 0 — a fresh enumeration that
	// refreshes from the server; our own cursors carry a little-endian UInt32 offset into the
	// (locally cached, name-sorted) child listing.
	private static func pageOffset(_ page: NSFileProviderPage) -> UInt32 {
		// The initial-page constants are plain `Data` sentinels, not encoded offsets.
		let data = page.rawValue
		if data == NSFileProviderPage.initialPageSortedByName as Data
			|| data == NSFileProviderPage.initialPageSortedByDate as Data
		{
			return 0
		}
		guard data.count == 4 else { return 0 }
		return data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
	}

	private static func encodePageOffset(_ offset: UInt32) -> NSFileProviderPage {
		NSFileProviderPage(rawValue: withUnsafeBytes(of: offset.littleEndian) { Data($0) })
	}

	func enumerateItems(
		for observer: any NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage
	) {
		Task {
			if self.reportedContainerIdentifier == NSFileProviderItemIdentifier.trashContainer {
				await self.enumerateTrash(for: observer)
				return
			}

			do {
				// A pure local miss is not authoritative: this cache may simply never have
				// listed the container (a fresh domain, a wiped cache, a parent learned from
				// the working set). Ask the server once, exactly as `resolveItem` does, and let
				// only ITS not-found stand as the deletion `.noSuchItem` claims.
				var queried: FfiObject?
				do {
					queried = try self.state.queryItem(
						path: self.enumeratedItemIdentifier.rawValue)
				} catch CacheError.DoesNotExist(_) {
					// An identity-form id with no cached row THROWS DoesNotExist (it never
					// returns nil) — the normal state of a fresh cache. That is a MISS, not an
					// authoritative answer: without this catch the server fallback below was
					// dead code, and every cold container answered .noSuchItem, which the
					// system obeys by deleting the folder from disk.
					queried = nil
				}
				if queried == nil {
					queried = try await self.state.updateAndQueryItem(
						id: self.enumeratedItemIdentifier.rawValue)
				}
				guard let object = queried
				else {
					observer.finishEnumeratingWithError(NSFileProviderError(.noSuchItem))
					return
				}
				switch object {
				case FfiObject.file(_):
					// files are not enumerated, only directories
					// we don't support subscribing to file updates.
					observer.finishEnumerating(upTo: nil)
					return
				case FfiObject.dir(let ffiDir):
					if ffiDir.parent == "trash" {
						// we do not support enumerating trash items
						observer.finishEnumerating(upTo: nil)
						return
					}
				default: break
				}
			} catch {
				// Report what actually went wrong, via the mapping that keeps every failure —
				// CacheError or otherwise — inside the two domains the framework understands.
				// Before the generic arm existed, a non-CacheError throw (a lifted Rust panic)
				// escaped the Task silently and the observer was never answered: the system's
				// enumeration hung until its own timeout, with the panic message discarded.
				observer.finishEnumeratingWithError(providerError(from: error))
				return
			}

			// Paginate: hand the system one page of children at a time via an offset cursor.
			// Refresh from the server only on the first page (offset 0) — Filen's dir listing has
			// no server-side cursor, so we re-list once and page the rest from cache.
			let offset = Self.pageOffset(page)
			let response: QueryChildrenResponse?
			do {
				response = try await self.state.updateAndQueryDirChildrenPage(
					path: self.enumeratedItemIdentifier.rawValue, orderBy: nil,
					offset: offset, limit: Self.pageSize, refresh: offset == 0)
			} catch {
				// Same rule as above: the observer must always be answered, whatever was thrown.
				observer.finishEnumeratingWithError(providerError(from: error))
				return
			}
			guard let response = response else {
				observer.finishEnumeratingWithError(NSFileProviderError(.noSuchItem))
				return
			}

			let items = response.objects.map {
				FileProviderItem(
					parentItemIdentifier: self.reportedContainerIdentifier, object: $0)
			}

			observer.didEnumerate(items)
			// A full page means more may follow — advance the cursor; a short page ends it.
			if response.objects.count == Int(Self.pageSize) {
				observer.finishEnumerating(upTo: Self.encodePageOffset(offset + Self.pageSize))
			} else {
				observer.finishEnumerating(upTo: nil)
			}
		}
	}
}
