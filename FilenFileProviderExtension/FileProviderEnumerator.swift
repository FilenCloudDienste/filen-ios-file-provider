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

			let response: QueryChildrenResponse?
			do {
				response = try await self.state.updateAndQueryDirChildren(
					path: self.enumeratedItemIdentifier.rawValue, orderBy: nil)
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
			observer.finishEnumerating(upTo: nil)
		}
	}
}
