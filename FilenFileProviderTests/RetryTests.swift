import XCTest

/// A failed content upload out of `modifyItem` is a lost user edit unless something retries it.
/// Retrying is what turns a transient network failure back into a successful upload rather than
/// silent data loss; a failure past the retries falls back to the cache's pending-upload marker.
final class RetryTests: XCTestCase {
	private struct Boom: Error, Equatable {
		let attempt: Int
	}

	func testASuccessfulOperationRunsOnce() async {
		var calls = 0
		let failure = await FileProviderExtension.retrying(attempts: 3) { calls += 1 }

		XCTAssertNil(failure)
		XCTAssertEqual(calls, 1, "a success must not be retried")
	}

	/// The case that matters: a blip on the first attempt still ends in a persisted edit.
	func testATransientFailureIsRecovered() async {
		var calls = 0
		let failure = await FileProviderExtension.retrying(attempts: 3) {
			calls += 1
			if calls == 1 { throw Boom(attempt: calls) }
		}

		XCTAssertNil(failure, "the second attempt succeeded, so the edit is not lost")
		XCTAssertEqual(calls, 2)
	}

	func testTheLastErrorIsReturnedWhenEveryAttemptFails() async {
		var calls = 0
		let failure = await FileProviderExtension.retrying(attempts: 3) {
			calls += 1
			throw Boom(attempt: calls)
		}

		XCTAssertEqual(calls, 3, "it must stop at the configured attempt count")
		XCTAssertEqual(failure as? Boom, Boom(attempt: 3), "the final failure is reported")
	}

	/// Backoff runs between attempts, never after the last one — a trailing sleep would just delay
	/// reporting a failure that is already final.
	func testBackoffRunsBetweenAttemptsOnly() async {
		var retries: [Int] = []
		_ = await FileProviderExtension.retrying(
			attempts: 3,
			operation: { throw Boom(attempt: 0) },
			onRetry: { attempt in retries.append(attempt) })

		XCTAssertEqual(retries, [1, 2], "two gaps between three attempts")
	}

	func testBackoffIsNotRunWhenTheFirstAttemptSucceeds() async {
		var retries = 0
		_ = await FileProviderExtension.retrying(
			attempts: 3, operation: {}, onRetry: { _ in retries += 1 })

		XCTAssertEqual(retries, 0)
	}

	/// A nonsensical attempt count must still run the operation once rather than zero times.
	func testAZeroAttemptCountStillRunsOnce() async {
		var calls = 0
		_ = await FileProviderExtension.retrying(attempts: 0) { calls += 1 }

		XCTAssertEqual(calls, 1)
	}

	// MARK: - Cancellation

	/// A cancelled operation is not a failure to recover from: the call it belongs to has already
	/// been answered with NSUserCancelledError, so retrying would re-upload the file for nobody.
	func testACancelledOperationIsNotRetried() async {
		var calls = 0
		let failure = await FileProviderExtension.retrying(attempts: 3) {
			calls += 1
			throw CancellationError()
		}

		XCTAssertEqual(calls, 1, "cancellation must not be retried")
		XCTAssertTrue(failure is CancellationError)
	}

	/// The same cancellation in its other spelling: uniffi cannot cancel a Rust future, so a
	/// cancelled upload comes back as `CacheError.Aborted` rather than as a `CancellationError`.
	/// Retrying it would send the file again for a call the cancellation handler already answered
	/// — and the retry would abort at once anyway, since the signal stays tripped.
	func testAnAbortedOperationIsNotRetried() async {
		var calls = 0
		let failure = await FileProviderExtension.retrying(attempts: 3) {
			calls += 1
			throw CacheError.Aborted("the call was aborted")
		}

		XCTAssertEqual(calls, 1, "an abort is the cancel, not a failure to recover from")
		guard case .Aborted? = failure as? CacheError else {
			return XCTFail("the abort must be reported as itself: \(String(describing: failure))")
		}
	}

	/// ...and a loop running in a cancelled task stops instead of grinding through its attempts.
	/// The backoff swallows cancellation (`try? await Task.sleep`), so without the check at the top
	/// of the loop a cancelled retry would run every remaining attempt back to back.
	func testACancelledTaskStopsRetrying() async {
		let calls = Counter()
		let task = Task {
			await FileProviderExtension.retrying(
				attempts: 3,
				operation: {
					calls.bump()
					throw Boom(attempt: 0)
				})
		}
		task.cancel()
		_ = await task.value

		XCTAssertLessThanOrEqual(
			calls.value, 1, "a cancelled loop must not keep attempting the operation")
	}

	private final class Counter: @unchecked Sendable {
		private let lock = NSLock()
		private var count = 0

		func bump() { lock.withLock { count += 1 } }
		var value: Int { lock.withLock { count } }
	}
}
