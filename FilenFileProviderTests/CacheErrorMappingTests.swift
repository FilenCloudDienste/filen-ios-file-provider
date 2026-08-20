import FileProvider
import XCTest

/// Every throwing override in the extension funnels its `CacheError` through `cacheErrorToError`,
/// so whatever this returns is what the Files app shows the user and how the system decides
/// whether an operation is retryable.
///
/// A `CacheError` that escapes unmapped reaches the system as an opaque Swift error the File
/// Provider framework cannot interpret — it degrades to a generic failure with no retry
/// semantics. This table pins every case so a future binding regeneration that adds one cannot
/// silently fall through.
final class CacheErrorMappingTests: XCTestCase {
	private func mapped(_ error: CacheError) -> NSError {
		cacheErrorToError(error: error) as NSError
	}

	private func assertFileProviderError(
		_ error: CacheError,
		_ expected: NSFileProviderError.Code,
		file: StaticString = #filePath,
		line: UInt = #line
	) {
		let nsError = mapped(error)
		XCTAssertEqual(
			nsError.domain, NSFileProviderErrorDomain,
			"expected a File Provider error so the system can interpret it", file: file, line: line)
		XCTAssertEqual(nsError.code, expected.rawValue, file: file, line: line)
	}

	private func assertCocoaError(
		_ error: CacheError,
		_ expectedCode: Int,
		file: StaticString = #filePath,
		line: UInt = #line
	) {
		let nsError = mapped(error)
		XCTAssertEqual(nsError.domain, NSCocoaErrorDomain, file: file, line: line)
		XCTAssertEqual(nsError.code, expectedCode, file: file, line: line)
	}

	/// A failure the system must keep retrying: an ordinary Cocoa error carrying the original,
	/// which is what the header prescribes for a failure with no code of its own — and explicitly
	/// NOT `.cannotSynchronize`, which is documented as permanent.
	private func assertRetryable(
		_ error: CacheError,
		file: StaticString = #filePath,
		line: UInt = #line
	) {
		let nsError = mapped(error)
		XCTAssertEqual(nsError.domain, NSCocoaErrorDomain, file: file, line: line)
		XCTAssertEqual(nsError.code, NSXPCConnectionReplyInvalid, file: file, line: line)
		XCTAssertNotNil(
			nsError.userInfo[NSUnderlyingErrorKey],
			"the failure that could not be represented must be carried along", file: file,
			line: line)
	}

	// MARK: - Authentication

	func testAuthenticationFailuresMapToNotAuthenticated() {
		assertFileProviderError(.Unauthenticated("no session"), .notAuthenticated)
		assertFileProviderError(.Disabled("provider off"), .notAuthenticated)
	}

	// MARK: - Missing items

	func testMissingItemsMapToNoSuchItem() {
		assertFileProviderError(.DoesNotExist("gone"), .noSuchItem)
		assertFileProviderError(.NotADirectory("not a dir"), .noSuchItem)
	}

	// MARK: - Naming

	func testInvalidNameMapsToTheCocoaInvalidFileNameError() {
		assertCocoaError(.InvalidName("bad/name"), NSFileWriteInvalidFileNameError)
	}

	// MARK: - Previously unmapped cases

	/// A failure talking to the server is the one class the system can usefully retry, so it must
	/// be distinguishable from a local failure.
	func testRemoteFailuresMapToServerUnreachable() {
		assertFileProviderError(.Remote("502"), .serverUnreachable)
	}

	/// Local cache/SDK/data failures are blips: a busy WAL database with the app writing it too, a
	/// failed disk write, a row that did not deserialize. Every one of them succeeds on a later
	/// attempt, so none may reach the system as `.cannotSynchronize` — which stops sync for the
	/// item "until either: The operating system has been updated. The FileProvider extension has
	/// been updated. The item is modified on disk." (NSFileProviderError.h)
	func testTransientLocalFailuresStayRetryable() {
		assertRetryable(.Sql("database is locked"))
		assertRetryable(.Sdk("connection reset"))
		assertRetryable(.Conversion("bad shape"))
		assertRetryable(.Image("bad jpeg"))
		assertRetryable(.Io("disk full"))

		for error in [
			CacheError.Sql("x"), .Sdk("x"), .Conversion("x"), .Image("x"), .Io("x"),
		] {
			XCTAssertNotEqual(
				mapped(error).domain, NSFileProviderErrorDomain,
				"\(error) must not be answered with a File Provider code that stops sync")
		}
	}

	/// The one local failure that is permanent: the same bytes and the same keys fail the same way
	/// on every retry, which is what `.cannotSynchronize` describes.
	func testUndecryptableContentIsPermanent() {
		assertFileProviderError(.FailedToDecrypt("bad key"), .cannotSynchronize)
	}

	func testUnsupportedMapsToTheCocoaFeatureUnsupportedError() {
		assertCocoaError(.Unsupported("nope"), NSFeatureUnsupportedError)
	}

	/// An anchor the cache cannot place is answered by re-enumerating from nothing, not by an
	/// error the user sees. The working-set enumerator catches this case itself; the mapping is
	/// here so an anchor handed to anything else still says the same thing.
	func testAnExpiredSyncAnchorMapsToSyncAnchorExpired() {
		assertFileProviderError(.SyncAnchorExpired("wrong database"), .syncAnchorExpired)
	}

	// MARK: - Totality

	/// Nothing may reach the system as a raw `CacheError`. If a binding regeneration adds a case,
	/// `cacheErrorToError` must switch on it exhaustively — this catches any that slips through.
	func testNoCacheErrorEscapesUnmapped() {
		let everyCase: [CacheError] = [
			.Sql("x"), .Sdk("x"), .Conversion("x"), .Io("x"), .Remote("x"), .Image("x"),
			.Unauthenticated("x"), .Disabled("x"), .DoesNotExist("x"), .Unsupported("x"),
			.NotADirectory("x"), .FailedToDecrypt("x"), .InvalidName("x"),
			.SyncAnchorExpired("x"),
		]

		for error in everyCase {
			XCTAssertFalse(
				cacheErrorToError(error: error) is CacheError,
				"\(error) escaped cacheErrorToError unmapped")
		}
	}
}
