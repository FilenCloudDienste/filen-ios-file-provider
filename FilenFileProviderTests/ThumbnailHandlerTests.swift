import FileProvider
import XCTest

/// `FetchThumbnailHandler` fans each thumbnail result back to the system. Every branch must advance the
/// progress count — a missed increment leaves the framework waiting on a `Progress` that never
/// finishes — and must report a distinguishable outcome.
final class ThumbnailHandlerTests: XCTestCase {
	private final class Recorder: @unchecked Sendable {
		private let lock = NSLock()
		private var results: [(NSFileProviderItemIdentifier, Data?, Error?)] = []
		private(set) var completedCount = 0

		func record(_ id: NSFileProviderItemIdentifier, _ data: Data?, _ error: Error?) {
			lock.lock()
			defer { lock.unlock() }
			results.append((id, data, error))
		}

		func markCompleted() {
			lock.lock()
			defer { lock.unlock() }
			completedCount += 1
		}

		var all: [(NSFileProviderItemIdentifier, Data?, Error?)] {
			lock.lock()
			defer { lock.unlock() }
			return results
		}
	}

	private func makeHandler() -> (FetchThumbnailHandler, Recorder, Progress) {
		let recorder = Recorder()
		let progress = Progress(totalUnitCount: 10)
		let handler = FetchThumbnailHandler(
			perThumbnailCompletionHandler: { id, data, error in recorder.record(id, data, error) },
			completionHandler: { _ in recorder.markCompleted() },
			progress: progress)
		return (handler, recorder, progress)
	}

	func testAMissingThumbnailReportsNoSuchItem() {
		let (handler, recorder, _) = makeHandler()

		handler.process(id: "a", result: .notFound)

		let (id, data, error) = try! XCTUnwrap(recorder.all.first)
		XCTAssertEqual(id, NSFileProviderItemIdentifier("a"))
		XCTAssertNil(data)
		XCTAssertEqual((error as? NSError)?.domain, NSFileProviderErrorDomain)
		XCTAssertEqual((error as? NSError)?.code, NSFileProviderError.noSuchItem.rawValue)
	}

	/// "This item legitimately has no thumbnail" is a success with no data — not an error.
	func testAnItemWithNoThumbnailReportsNeitherDataNorError() {
		let (handler, recorder, _) = makeHandler()

		handler.process(id: "b", result: .noThumbnail)

		let (_, data, error) = try! XCTUnwrap(recorder.all.first)
		XCTAssertNil(data)
		XCTAssertNil(error)
	}

	func testACacheErrorIsMappedNotPassedThroughRaw() {
		let (handler, recorder, _) = makeHandler()

		handler.process(id: "c", result: .err(.Remote("502")))

		let (_, data, error) = try! XCTUnwrap(recorder.all.first)
		XCTAssertNil(data)
		XCTAssertFalse(error is CacheError, "the raw cache error must not reach the system")
		XCTAssertEqual((error as? NSError)?.domain, NSFileProviderErrorDomain)
	}

	/// A promised thumbnail that cannot be read is an error, not "this item has no thumbnail".
	/// Collapsing the two would make the system cache "none" instead of retrying.
	func testAnUnreadableThumbnailPathReportsAnError() throws {
		let (handler, recorder, _) = makeHandler()

		handler.process(id: "d", result: .ok("/nonexistent/thumbnail.jpg"))

		let (_, data, error) = try XCTUnwrap(recorder.all.first)
		XCTAssertNil(data)
		XCTAssertNotNil(
			error, "an unreadable promised file must not be reported as having no thumbnail")
	}

	/// A readable path returns its bytes and no error.
	func testAReadableThumbnailPathReturnsItsData() throws {
		let (handler, recorder, _) = makeHandler()
		let url = FileManager.default.temporaryDirectory
			.appending(component: "thumb-\(UUID().uuidString).bin")
		let expected = Data([0xDE, 0xAD, 0xBE, 0xEF])
		try expected.write(to: url)
		defer { try? FileManager.default.removeItem(at: url) }

		handler.process(id: "e", result: .ok(url.path(percentEncoded: false)))

		let (_, data, error) = try XCTUnwrap(recorder.all.first)
		XCTAssertEqual(data, expected)
		XCTAssertNil(error)
	}

	// MARK: - Progress accounting

	func testEveryOutcomeAdvancesProgressExactlyOnce() {
		let (handler, _, progress) = makeHandler()

		handler.process(id: "a", result: .notFound)
		handler.process(id: "b", result: .noThumbnail)
		handler.process(id: "c", result: .err(.Io("x")))
		handler.process(id: "d", result: .ok("/nonexistent/thumbnail.jpg"))

		XCTAssertEqual(
			progress.completedUnitCount, 4,
			"each result must advance progress or the framework waits forever")
	}

	func testCompleteInvokesTheOverallCompletionHandler() {
		let (handler, recorder, _) = makeHandler()

		handler.complete()

		XCTAssertEqual(recorder.completedCount, 1)
	}
}
