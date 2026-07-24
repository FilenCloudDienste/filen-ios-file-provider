import XCTest
import os

/// `ProgressNotifier` owns the shared in-flight sets that back `isUploading` / `isDownloading` on
/// every item, so getting membership wrong makes the Files app show a transfer as finished while
/// bytes are still moving (or the reverse).
final class TransferProgressTests: XCTestCase {
	private let uuid = "11111111-1111-1111-1111-111111111111"

	private func makeSet() -> OSAllocatedUnfairLock<Set<String>> {
		OSAllocatedUnfairLock(initialState: Set<String>())
	}

	private func contains(_ set: OSAllocatedUnfairLock<Set<String>>, _ uuid: String) -> Bool {
		set.withLock { $0.contains(uuid) }
	}

	// MARK: - Membership lifecycle

	func testConstructingANotifierMarksTheTransferInFlight() {
		let set = makeSet()
		let notifier = ProgressNotifier(set: set, uuid: uuid)

		XCTAssertTrue(contains(set, uuid))
		_ = notifier
	}

	func testReachingTheTotalEndsTheTransfer() {
		let set = makeSet()
		let notifier = ProgressNotifier(set: set, uuid: uuid)
		notifier.setTotal(size: 100)

		notifier.onProgress(bytesProcessed: 60)
		XCTAssertTrue(contains(set, uuid), "still in flight at 60/100")

		notifier.onProgress(bytesProcessed: 40)
		XCTAssertFalse(contains(set, uuid), "finished at 100/100")
	}

	func testReleasingANotifierAlwaysClearsTheTransfer() {
		let set = makeSet()
		do {
			let notifier = ProgressNotifier(set: set, uuid: uuid)
			notifier.setTotal(size: 100)
			notifier.onProgress(bytesProcessed: 10)
			XCTAssertTrue(contains(set, uuid))
		}
		XCTAssertFalse(contains(set, uuid), "deinit must not leave a transfer stuck in flight")
	}

	// MARK: - Progress arriving before the total is known

	/// `total` starts at 0, so an unguarded `processed >= total` treats the very first progress
	/// callback as completion when `setTotal` has not landed yet — the transfer reads as finished
	/// immediately and the item stops showing as uploading while it is still uploading.
	func testProgressBeforeTheTotalIsKnownDoesNotEndTheTransfer() {
		let set = makeSet()
		let notifier = ProgressNotifier(set: set, uuid: uuid)

		notifier.onProgress(bytesProcessed: 1)

		XCTAssertTrue(
			contains(set, uuid),
			"a transfer whose total is not known yet must not be reported as complete")
	}

	/// The same trap with a zero-byte callback: 0 >= 0 is true.
	func testAZeroByteProgressBeforeTheTotalDoesNotEndTheTransfer() {
		let set = makeSet()
		let notifier = ProgressNotifier(set: set, uuid: uuid)

		notifier.onProgress(bytesProcessed: 0)

		XCTAssertTrue(contains(set, uuid))
	}

	// MARK: - Known limitation

	/// Two notifiers for the SAME uuid share one membership slot, so whichever finishes first
	/// clears it while the other is still transferring.
	///
	/// This pins current behaviour rather than asserting the ideal. Fixing it means refcounting
	/// per uuid, which changes the shared set's type and every reader of it — deliberately out of
	/// scope here. If that fix lands, this test should flip to asserting membership survives until
	/// both finish.
	func testConcurrentNotifiersForOneUuidShareASingleSlot() {
		let set = makeSet()
		let first = ProgressNotifier(set: set, uuid: uuid)
		let second = ProgressNotifier(set: set, uuid: uuid)
		first.setTotal(size: 10)
		second.setTotal(size: 1000)

		first.onProgress(bytesProcessed: 10)

		XCTAssertFalse(
			contains(set, uuid),
			"known limitation: the first notifier to finish clears the shared slot")
		_ = second
	}
}
