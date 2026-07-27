import FileProvider
import Foundation
import os

final class FetchThumbnailHandler: ThumbnailCallback {
	private static let logger = Logger(subsystem: PROVIDER, category: "FileProvider")
	private let perThumbnailCompletionHandler:
		@Sendable (NSFileProviderItemIdentifier, Data?, Error?) -> Void
	private let completionHandler: @Sendable (Error?) -> Void
	private let progress: Progress

	init(
		perThumbnailCompletionHandler: @Sendable @escaping (
			NSFileProviderItemIdentifier, Data?, Error?
		) -> Void, completionHandler: @Sendable @escaping (Error?) -> Void, progress: Progress
	) {
		self.perThumbnailCompletionHandler = perThumbnailCompletionHandler
		self.completionHandler = completionHandler
		self.progress = progress
	}

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
			self.perThumbnailCompletionHandler(NSFileProviderItemIdentifier(id), nil, nil)
		case .err(let error):
			Self.logger.error("Error fetching thumbnail for \(id): \(error)")
			self.perThumbnailCompletionHandler(
				NSFileProviderItemIdentifier(id), nil, cacheErrorToError(error: error))
		}
	}

	func complete() { self.completionHandler(nil) }
}
