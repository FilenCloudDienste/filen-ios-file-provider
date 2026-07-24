import FileProvider
import XCTest

/// `itemChanged` is how a local edit becomes an upload. If it gives up without either uploading or
/// asking to be retried, the user's edit is silently lost — no error, no crash, no upload.
///
/// The distinction that matters: "the cache does not know this uuid" is terminal, but "the lookup
/// failed" says nothing about whether the item exists, so it must be retried.
final class ItemChangedTests: XCTestCase {
	private let uuid = "11111111-1111-1111-1111-111111111111"

	private struct LookupFailure: Error {}

	func testAResolvedPathIsUploaded() {
		let resolution = FileProviderExtension.resolveItemChanged(uuid: uuid) { _ in
			"root/Documents/report.pdf"
		}

		XCTAssertEqual(resolution, .upload("root/Documents/report.pdf"))
	}

	func testAnItemTheCacheDoesNotKnowIsTerminal() {
		let resolution = FileProviderExtension.resolveItemChanged(uuid: uuid) { _ in nil }

		XCTAssertEqual(
			resolution, .unknownItem,
			"a genuinely unknown uuid has nothing to upload and nothing to retry")
	}

	/// A thrown lookup must NOT be treated as "item missing" — that would drop the edit.
	func testAFailedLookupAsksForARetryInsteadOfDroppingTheEdit() {
		let resolution = FileProviderExtension.resolveItemChanged(uuid: uuid) { _ in
			throw LookupFailure()
		}

		XCTAssertEqual(
			resolution, .needsRetry,
			"a failed lookup says nothing about whether the item exists — it must be retried")
		XCTAssertNotEqual(
			resolution, .unknownItem,
			"treating a lookup failure as a missing item silently loses the user's edit")
	}

	func testTheUuidIsPassedThroughToTheLookup() {
		var seen: String?
		_ = FileProviderExtension.resolveItemChanged(uuid: uuid) { uuid in
			seen = uuid
			return nil
		}

		XCTAssertEqual(seen, uuid)
	}
}
