import FileProvider
import Foundation
import os

final class FetchThumbnailHandler: ThumbnailCallback {
	private static let logger = Logger(subsystem: PROVIDER, category: "FileProvider")
	private let perThumbnailCompletionHandler:
		@Sendable (NSFileProviderItemIdentifier, Data?, Error?) -> Void
	private let completionHandler: @Sendable (Error?) -> Void
	private let progress: Progress
	#if os(macOS)
		private let fallback: ThumbnailFallback?
		/// Fallback items still running, so the batch completes after the last of them rather
		/// than when the cache is done with its own share.
		private struct Batch {
			var cacheDone = false
			var cancelled = false
			var running: [UUID: (task: Task<Void, Never>, abort: FfiAbortController)] = [:]
		}
		private let batch = OSAllocatedUnfairLock<Batch>(initialState: Batch())
	#endif

	#if os(macOS)
		init(
			perThumbnailCompletionHandler: @Sendable @escaping (
				NSFileProviderItemIdentifier, Data?, Error?
			) -> Void, completionHandler: @Sendable @escaping (Error?) -> Void, progress: Progress,
			fallback: ThumbnailFallback? = nil
		) {
			self.perThumbnailCompletionHandler = perThumbnailCompletionHandler
			self.completionHandler = completionHandler
			self.progress = progress
			self.fallback = fallback
		}
	#else
		init(
			perThumbnailCompletionHandler: @Sendable @escaping (
				NSFileProviderItemIdentifier, Data?, Error?
			) -> Void, completionHandler: @Sendable @escaping (Error?) -> Void, progress: Progress
		) {
			self.perThumbnailCompletionHandler = perThumbnailCompletionHandler
			self.completionHandler = completionHandler
			self.progress = progress
		}
	#endif

	func process(id: String, result: ThumbnailResult) {
		self.progress.completedUnitCount += 1

		switch result {
		case .ok(let path):
			// The cache promised a thumbnail at this path, so failing to read it is a real error.
			// Reporting (nil, nil) would be indistinguishable from `.noThumbnail` — i.e. from the
			// item legitimately having no thumbnail — so the system would cache "none" instead of
			// retrying.
			do {
				let data = try Data(contentsOf: URL(fileURLWithPath: path))
				self.perThumbnailCompletionHandler(NSFileProviderItemIdentifier(id), data, nil)
			} catch {
				Self.logger.error("Thumbnail for \(id) unreadable at \(path): \(error)")
				self.perThumbnailCompletionHandler(NSFileProviderItemIdentifier(id), nil, error)
			}
		case .notFound:
			self.perThumbnailCompletionHandler(
				NSFileProviderItemIdentifier(id), nil, NSFileProviderError(.noSuchItem))
		case .noThumbnail:
			#if os(macOS)
				if let fallback = self.fallback, self.startFallback(id: id, fallback: fallback) {
					return
				}
			#endif
			self.perThumbnailCompletionHandler(NSFileProviderItemIdentifier(id), nil, nil)
		case .err(let error):
			Self.logger.error("Error fetching thumbnail for \(id): \(error)")
			self.perThumbnailCompletionHandler(
				NSFileProviderItemIdentifier(id), nil, cacheErrorToError(error: error))
		}
	}

	#if os(macOS)
		func complete() {
			let finished = self.batch.withLock { batch -> Bool in
				batch.cacheDone = true
				return batch.running.isEmpty
			}
			if finished { self.completionHandler(nil) }
		}

		/// Stops every fallback item still running. The call itself is answered by whoever
		/// cancelled it, so nothing more is reported.
		func cancelFallbacks() {
			let running = self.batch.withLock { batch in
				batch.cancelled = true
				let running = batch.running
				batch.running = [:]
				return running
			}
			for work in running.values {
				work.abort.abort()
				work.task.cancel()
			}
		}

		/// Hands a "no thumbnail" item to the fallback; false when the batch is already cancelled.
		/// The fallback decides itself whether the item is one it makes, off this callback, which
		/// runs on the cache's own thread and must not call back into it.
		private func startFallback(id: String, fallback: ThumbnailFallback) -> Bool {
			let token = UUID()
			let abort = FfiAbortController()
			let perThumbnail = self.perThumbnailCompletionHandler
			let completion = self.completionHandler
			let batch = self.batch
			return batch.withLock { state -> Bool in
				guard !state.cancelled else { return false }
				let task = Task {
					let (data, error) = await fallback.thumbnail(for: id, abort: abort)
					let (deliver, finished) = batch.withLock { state -> (Bool, Bool) in
						guard state.running.removeValue(forKey: token) != nil else {
							return (false, false)
						}
						return (true, state.cacheDone && state.running.isEmpty)
					}
					guard deliver else { return }
					perThumbnail(NSFileProviderItemIdentifier(id), data, error)
					if finished { completion(nil) }
				}
				state.running[token] = (task, abort)
				return true
			}
		}
	#else
		func complete() { self.completionHandler(nil) }
	#endif
}
