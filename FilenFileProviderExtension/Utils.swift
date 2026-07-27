import FileProvider
import Foundation

func getParentItemIdentifier(itemIdentifier: NSFileProviderItemIdentifier)
	-> NSFileProviderItemIdentifier
{
	// very ghetto
	if let lastSlash = itemIdentifier.rawValue.lastIndex(of: "/") {
		if itemIdentifier.rawValue.count(where: { $0 == "/" }) >= 2 {
			return NSFileProviderItemIdentifier(
				String(itemIdentifier.rawValue.prefix(upTo: lastSlash)))

		} else {
			return .rootContainer
		}
	} else {
		return .rootContainer
	}
}

/// Translates a cache error into something the File Provider framework understands.
///
/// Every throwing override funnels through here, so an unmapped error would reach the system as an
/// opaque Swift error with no retry semantics. The switch is deliberately exhaustive rather than
/// falling back to `default` — if a binding regeneration adds a `CacheError` case, this stops
/// compiling and forces a decision instead of silently leaking the raw error.
func cacheErrorToError(error: CacheError) -> any Error {
	switch error {
	case .Disabled, .Unauthenticated:
		return NSFileProviderError(.notAuthenticated)
	case .DoesNotExist, .NotADirectory:
		return NSFileProviderError(.noSuchItem)
	case .InvalidName:
		return NSError(domain: NSCocoaErrorDomain, code: NSFileWriteInvalidFileNameError)
	// The one class the system can usefully retry.
	case .Remote:
		return NSFileProviderError(.serverUnreachable)
	case .Unsupported:
		return NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)
	// Local cache, SDK, data-shape and decode failures: not retryable, but the system still needs
	// a File Provider error rather than an opaque one.
	case .Sql, .Sdk, .Conversion, .Io, .Image, .FailedToDecrypt:
		return NSFileProviderError(.cannotSynchronize)
	}
}

/// The uuid out of a cache item URL, which is shaped `.../<uuid>/<filename>`.
///
/// Nil when the URL is too short to have that shape. Reading the index directly would TRAP on a
/// short URL, and a trap cannot be intercepted by `do`/`catch` — it takes the whole extension
/// process down instead of failing the one operation.
func uuidFromCacheItemURL(_ url: URL) -> String? {
	// At least root + uuid + filename: `pathComponents` includes the leading "/", so a shorter URL
	// has no uuid position and would otherwise hand back "/" as if it were one.
	let components = url.pathComponents
	guard components.count >= 3 else { return nil }
	return components[components.count - 2]
}

func objectToUuid(object: FfiObject) -> String {
	switch object {
	case .file(let file): return file.uuid
	case .dir(let dir): return dir.uuid
	case .root(let root): return root.uuid
	}
}

/// The uuid of the container an object lives in — its ORIGINAL parent while trashed, so a trashed
/// item still reports the folder it will be restored into rather than the trash sentinel.
///
/// Nil for the root (which has no container) and for an item whose parent is unknown.
func objectToContainerUuid(object: FfiObject) -> String? {
	let parent: String
	let originalParent: String?
	switch object {
	case .file(let file):
		parent = file.parent
		originalParent = file.originalParent
	case .dir(let dir):
		parent = dir.parent
		originalParent = dir.originalParent
	case .root: return nil
	}

	if let originalParent, !originalParent.isEmpty { return originalParent }
	// A trashed item with no recorded original parent has no container to point at.
	if parent.isEmpty || parent == "trash" { return nil }
	return parent
}
