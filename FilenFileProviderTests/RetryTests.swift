import XCTest

/// A failed `itemChanged` upload is a lost user edit — nothing re-triggers it. Retrying is what
/// turns a transient network failure back into a successful upload rather than silent data loss.
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
}
