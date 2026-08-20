import XCTest
import os

/// `ProgressNotifier` owns the shared in-flight sets that back `isUploading` / `isDownloading` on
/// every item, so getting membership wrong makes the Files app show a transfer as finished while
/// bytes are still moving (or the reverse).
final class TransferProgressTests: XCTestCase {
	private let uuid = "11111111-1111-1111-1111-111111111111"

	private func makeSet() -> TransfersInFlight {
		TransfersInFlight(initialState: [:])
	}

	private func contains(_ set: TransfersInFlight, _ uuid: String) -> Bool {
		set.withLock { $0[uuid] != nil }
	}

	// MARK: - Membership lifecycle

	func testConstructingANotifierMarksTheTransferInFlight() {
		let set = makeSet()
		let notifier = ProgressNotifier(set: set, id: uuid)

		XCTAssertTrue(contains(set, uuid))
		_ = notifier
	}

	func testReachingTheTotalEndsTheTransfer() {
		let set = makeSet()
		let notifier = ProgressNotifier(set: set, id: uuid)
		notifier.setTotal(size: 100)

		notifier.onProgress(bytesProcessed: 60)
		XCTAssertTrue(contains(set, uuid), "still in flight at 60/100")

		notifier.onProgress(bytesProcessed: 40)
		XCTAssertFalse(contains(set, uuid), "finished at 100/100")
	}

	func testReleasingANotifierAlwaysClearsTheTransfer() {
		let set = makeSet()
		do {
			let notifier = ProgressNotifier(set: set, id: uuid)
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
		let notifier = ProgressNotifier(set: set, id: uuid)

		notifier.onProgress(bytesProcessed: 1)

		XCTAssertTrue(
			contains(set, uuid),
			"a transfer whose total is not known yet must not be reported as complete")
	}

	/// The same trap with a zero-byte callback: 0 >= 0 is true.
	func testAZeroByteProgressBeforeTheTotalDoesNotEndTheTransfer() {
		let set = makeSet()
		let notifier = ProgressNotifier(set: set, id: uuid)

		notifier.onProgress(bytesProcessed: 0)

		XCTAssertTrue(contains(set, uuid))
	}

	// MARK: - Concurrent transfers of the same item

	/// Two notifiers can exist for one uuid at once (an upload and a retry, say). The item must
	/// keep reporting as in-flight until the LAST of them finishes — otherwise the first to
	/// complete blanks the indicator while bytes are still moving.
	func testTheTransferStaysInFlightUntilEveryNotifierFinishes() {
		let set = makeSet()
		let first = ProgressNotifier(set: set, id: uuid)
		let second = ProgressNotifier(set: set, id: uuid)
		first.setTotal(size: 10)
		second.setTotal(size: 1000)

		first.onProgress(bytesProcessed: 10)
		XCTAssertTrue(
			contains(set, uuid), "the second notifier is still transferring")

		second.onProgress(bytesProcessed: 1000)
		XCTAssertFalse(contains(set, uuid), "both finished, so the transfer is over")
	}

	/// Releasing one notifier must not clear a slot another still holds.
	func testReleasingOneOfTwoNotifiersLeavesTheTransferInFlight() {
		let set = makeSet()
		let survivor = ProgressNotifier(set: set, id: uuid)
		do {
			let temporary = ProgressNotifier(set: set, id: uuid)
			temporary.setTotal(size: 10)
		}

		XCTAssertTrue(contains(set, uuid), "the surviving notifier still holds the transfer")
		_ = survivor
	}

	/// A notifier that both completes and is then released must only give up its own hold once,
	/// or the count would go negative and drop somebody else's.
	func testCompletingThenReleasingReleasesOnlyOnce() {
		let set = makeSet()
		let other = ProgressNotifier(set: set, id: uuid)
		do {
			let finished = ProgressNotifier(set: set, id: uuid)
			finished.setTotal(size: 10)
			finished.onProgress(bytesProcessed: 10)
		}

		XCTAssertTrue(
			contains(set, uuid),
			"completing and then deinitialising must not release two holds")
		_ = other
	}
}
