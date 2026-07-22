import FileProvider

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
				NSFileProviderItemIdentifier("trash")
			} else { enumeratedItemIdentifier }
		self.state = state
		super.init()
	}

	func invalidate() {
		// noop
		// with paged approach in api v4 we could probably make use of this
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
		} catch let error as CacheError {
			observer.finishEnumeratingWithError(cacheErrorToError(error: error))
		} catch {
			observer.finishEnumeratingWithError(error)
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
				guard
					let object = try self.state.queryItem(
						path: self.enumeratedItemIdentifier.rawValue)
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
			} catch let error as CacheError {
				// Report what actually went wrong. `cacheErrorToError` maps every case to something
				// the framework understands, but not always to an NSFileProviderError — an invalid
				// name or an unsupported operation is a Cocoa error, and coercing those to
				// `.noSuchItem` would tell the user the item is missing when it is not.
				observer.finishEnumeratingWithError(cacheErrorToError(error: error))
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
			} catch let error as CacheError {
				observer.finishEnumeratingWithError(cacheErrorToError(error: error))
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
