import FileProvider
import XCTest

/// Every throwing override in the extension funnels its `CacheError` through `cacheErrorToError`,
/// so whatever this returns is what the Files app shows the user and how the system decides
/// whether an operation is retryable.
///
/// A `CacheError` that escapes unmapped reaches the system as an opaque Swift error the File
/// Provider framework cannot interpret — it degrades to a generic failure with no retry
/// semantics. This table pins all 13 cases so a future binding regeneration that adds a case
/// cannot silently fall through.
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

	/// Local cache/SDK/data failures are not retryable by the system but must still arrive as a
	/// File Provider error rather than an opaque one.
	func testLocalFailuresMapToCannotSynchronize() {
		assertFileProviderError(.Sql("db locked"), .cannotSynchronize)
		assertFileProviderError(.Sdk("sdk blew up"), .cannotSynchronize)
		assertFileProviderError(.Conversion("bad shape"), .cannotSynchronize)
		assertFileProviderError(.FailedToDecrypt("bad key"), .cannotSynchronize)
		assertFileProviderError(.Image("bad jpeg"), .cannotSynchronize)
		assertFileProviderError(.Io("disk full"), .cannotSynchronize)
	}

	func testUnsupportedMapsToTheCocoaFeatureUnsupportedError() {
		assertCocoaError(.Unsupported("nope"), NSFeatureUnsupportedError)
	}

	// MARK: - Totality

	/// Nothing may reach the system as a raw `CacheError`. If a binding regeneration adds a case,
	/// `cacheErrorToError` must switch on it exhaustively — this catches any that slips through.
	func testNoCacheErrorEscapesUnmapped() {
		let everyCase: [CacheError] = [
			.Sql("x"), .Sdk("x"), .Conversion("x"), .Io("x"), .Remote("x"), .Image("x"),
			.Unauthenticated("x"), .Disabled("x"), .DoesNotExist("x"), .Unsupported("x"),
			.NotADirectory("x"), .FailedToDecrypt("x"), .InvalidName("x"),
		]

		for error in everyCase {
			XCTAssertFalse(
				cacheErrorToError(error: error) is CacheError,
				"\(error) escaped cacheErrorToError unmapped")
		}
	}
}
