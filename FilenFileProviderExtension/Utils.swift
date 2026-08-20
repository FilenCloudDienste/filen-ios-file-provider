import FileProvider
import Foundation

/// The cache's name for the trash. It is not a directory the cache holds a row for: it has its own
/// pair of calls, and an item's `parent` reads as this while it sits there.
let TRASH_CACHE_ID = "trash"

/// Keys the provider stores under an item's `local_data`, which is the drive's per-item scratch
/// space for things the server has no field of its own for.
let LOCAL_DATA_TAGS = "TagData"
let LOCAL_DATA_LAST_USED = "LastUsedDate"

/// A directory has no content, so its content version never moves. Any constant does; this one
/// says what it is in a log.
let DIRECTORY_CONTENT_VERSION = "dir"

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

/// A failure that says nothing permanent about the item, spelled the way the framework wants it.
///
/// "For errors which can not be represented using an existing error code in one of these domains,
/// the extension should construct an NSError with domain NSCocoaErrorDomain and code
/// NSXPCConnectionReplyInvalid. The extension should set the NSUnderlyingErrorKey in the NSError's
/// userInfo to the error which could not be represented." — NSFileProviderReplicatedExtension.h,
/// which also says of every code it does not name: "Any other error [...] will be considered to be
/// transient and will cause the [operation] to be retried." That retry is the whole point of
/// spelling a transient failure this way rather than as an NSFileProviderError.
func transientError(_ reason: String, underlying: (any Error)? = nil) -> any Error {
	var userInfo: [String: Any] = [NSLocalizedDescriptionKey: reason]
	if let underlying { userInfo[NSUnderlyingErrorKey] = underlying as NSError }
	return NSError(
		domain: NSCocoaErrorDomain, code: NSXPCConnectionReplyInvalid, userInfo: userInfo)
}

/// The answer the framework asks for when a `Progress` it was handed gets cancelled: "the extension
/// should call the completion handler with (... NSUserCancelledError) in the NSProgress
/// cancellation handler." — NSFileProviderReplicatedExtension.h
func userCancelledError() -> NSError {
	NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
}

/// Translates a cache error into something the File Provider framework understands.
///
/// Every throwing override funnels through here, so an unmapped error would reach the system as an
/// opaque Swift error with no retry semantics. The switch is deliberately exhaustive rather than
/// falling back to `default` — if a binding regeneration adds a `CacheError` case, this stops
/// compiling and forces a decision instead of silently leaking the raw error.
///
/// An `NSFileProviderError` code is only used where the failure IS what that code means. The
/// tempting catch-all, `.cannotSynchronize`, is documented as permanent — "the system will not
/// retry syncing those items, until either: The operating system has been updated. The FileProvider
/// extension has been updated. The item is modified on disk." (NSFileProviderError.h) — so
/// answering a busy database or a dropped connection with it strands the item until the app ships
/// again. Everything transient goes back as an ordinary Cocoa error instead, which the system
/// retries.
func cacheErrorToError(error: CacheError) -> any Error {
	switch error {
	case .Disabled, .Unauthenticated:
		return NSFileProviderError(.notAuthenticated)
	case .DoesNotExist, .NotADirectory:
		return NSFileProviderError(.noSuchItem)
	case .InvalidName:
		return NSError(domain: NSCocoaErrorDomain, code: NSFileWriteInvalidFileNameError)
	case .Remote:
		return NSFileProviderError(.serverUnreachable)
	case .Unsupported:
		return NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)
	// Not really an error: the answer is to drop what the replica has and enumerate from nothing.
	// The working-set enumerator catches this case before it gets here, so reaching this arm means
	// an anchor was handed to a call that has no re-enumeration to fall back on.
	case .SyncAnchorExpired:
		return NSFileProviderError(.syncAnchorExpired)
	// Content this build cannot read: not a blip, and retrying the same bytes with the same keys
	// produces the same failure. This is what `.cannotSynchronize` describes — "syncing that item
	// is definitively broken" until "the FileProvider extension has been updated [or] the item is
	// modified on disk" (NSFileProviderError.h) — and the provider can lift it early by calling
	// `signalErrorResolved:`.
	case .FailedToDecrypt:
		return NSFileProviderError(.cannotSynchronize)
	// Everything left is a blip, not a verdict: a busy SQLite database (the cache DB is WAL and
	// two processes write it, so SQLITE_BUSY is routine), a failed disk write, a network-ish SDK
	// failure, a row that did not deserialize, a thumbnail that would not decode. All of them
	// succeed on a later attempt, so they must stay retryable.
	case .Sql, .Sdk, .Conversion, .Io, .Image:
		return transientError("the cache could not complete the operation", underlying: error)
	}
}

/// Translates anything thrown on the way to a File Provider completion handler.
///
/// Every replicated-extension entry point answers the system with an error rather than by
/// throwing, and the system only understands `NSCocoaErrorDomain` / `NSFileProviderErrorDomain`
/// errors. Cache errors go through the table above; a cancelled task is the system cancelling the
/// `Progress` it was handed, which the framework expects to come back as `NSUserCancelledError`.
/// Anything else — a lifted Rust panic (`UniffiInternalError.rustPanic`), a lift failure, a stray
/// Swift error — is outside the two permitted domains and must not reach the framework raw:
/// transient is the honest default, because a retry after the underlying blip (or a fix) clears
/// it, while an unrecognised domain's interpretation is undefined.
func providerError(from error: any Error) -> any Error {
	if let cacheError = error as? CacheError { return cacheErrorToError(error: cacheError) }
	if error is CancellationError { return userCancelledError() }
	let nsError = error as NSError
	if nsError.domain == NSCocoaErrorDomain || nsError.domain == NSFileProviderErrorDomain {
		return error
	}
	return transientError("an unmapped error reached the provider boundary", underlying: error)
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
	if parent.isEmpty || parent == TRASH_CACHE_ID { return nil }
	return parent
}

/// Whether an object is sitting in the trash. Nil (an item the cache does not hold) is not.
func objectIsTrashed(_ object: FfiObject?) -> Bool {
	switch object {
	case .file(let file): return file.parent == TRASH_CACHE_ID
	case .dir(let dir): return dir.parent == TRASH_CACHE_ID
	case .root, .none: return false
	}
}
