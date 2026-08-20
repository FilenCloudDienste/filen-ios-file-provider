import Foundation
import os

/// Transfers currently in flight, as a count of live holds per uuid.
///
/// A count rather than a set because the same item can have more than one transfer at a time (an
/// upload and a retry, say); with a set the first to finish would clear the shared slot and blank
/// the progress indicator while the other was still running.
typealias TransfersInFlight = OSAllocatedUnfairLock<[String: Int]>

final class ProgressNotifier: ProgressCallback {
	private let set: TransfersInFlight
	/// The item's whole-life identifier — see `FileProviderItem.isUploading`.
	let id: String
	/// The `Progress` handed to the system for this operation, if there is one. The system shows
	/// it to the user and cancels through it.
	private let progress: Progress?
	private let total: OSAllocatedUnfairLock<UInt64> = OSAllocatedUnfairLock(initialState: 0)
	private let processed: OSAllocatedUnfairLock<UInt64> = OSAllocatedUnfairLock(initialState: 0)
	/// Guards against releasing this notifier's hold twice — `onProgress` completing and `deinit`
	/// both call `release`, and a double decrement would drop a hold belonging to another notifier.
	private let releasedHold: OSAllocatedUnfairLock<Bool> = OSAllocatedUnfairLock(
		initialState: false)

	init(set: TransfersInFlight, id: String, progress: Progress? = nil) {
		self.set = set
		self.id = id
		self.progress = progress
		set.withLock { transfers in transfers[id, default: 0] += 1 }
	}

	func setTotal(size: UInt64) {
		self.total.withLock { $0 = size }
		self.progress?.totalUnitCount = Int64(size)
	}

	/// Gives up this notifier's hold, at most once.
	private func release() {
		let alreadyReleased = self.releasedHold.withLock { released -> Bool in
			if released { return true }
			released = true
			return false
		}
		guard !alreadyReleased else { return }

		self.set.withLock { transfers in
			guard let remaining = transfers[self.id] else { return }
			if remaining <= 1 {
				transfers.removeValue(forKey: self.id)
			} else {
				transfers[self.id] = remaining - 1
			}
		}
	}

	func onProgress(bytesProcessed: UInt64) {
		let processed = self.processed.withLock { processed in
			processed += bytesProcessed
			return processed
		}
		self.progress?.completedUnitCount = Int64(processed)
		let total = self.total.withLock { total in return total }
		// `total` is 0 until `setTotal` lands, and progress can arrive first — an unguarded
		// `processed >= total` would treat the very first callback as completion and stop showing
		// the transfer while it is still running. A transfer whose size is not known yet is never
		// complete; `deinit` still releases the hold, so nothing gets stuck in flight.
		if total > 0 && processed >= total {
			self.release()
		}
	}

	deinit { self.release() }
}
