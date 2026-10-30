#if os(macOS)
	import FileProvider
	import Foundation
	import ImageIO
	import UniformTypeIdentifiers
	import os

	/// Thumbnails for the formats the cache cannot decode on macOS, where it is built without a
	/// HEIF decoder and answers "no thumbnail" for HEIC, HEIF and AVIF. ImageIO reads all of them,
	/// so this pulls the bytes through the cache's own download and lets ImageIO make the
	/// thumbnail, downsampled while decoding.
	final class ThumbnailFallback: Sendable {
		private static let logger = Logger(subsystem: PROVIDER, category: "FileProvider")

		/// Extensions the cache leaves to this fallback; only those ImageIO reads are taken.
		static let extensions: Set<String> = ["heic", "heif", "hif", "avif", "avci"]
		/// The SDK's `MAX_THUMBNAIL_SOURCE_BYTES`: never pull more than this for a thumbnail.
		static let maxSourceBytes: Int64 = 64 * 1024 * 1024
		/// The decode budget the cache's own pipeline runs under (`THUMBNAIL_MEM_BUDGET_BYTES`).
		static let decodeBudgetBytes = 12 * 1024 * 1024
		/// The cache's own bounds: four items in flight, one decode at a time.
		private static let itemSlots = AsyncSlots(4)
		private static let decodeSlots = AsyncSlots(1)

		/// The fallback types this ImageIO can read.
		private static let readableTypes: Set<String> = {
			let readable = Set((CGImageSourceCopyTypeIdentifiers() as? [String]) ?? [])
			return Set(extensions.compactMap { UTType(filenameExtension: $0)?.identifier })
				.intersection(readable)
		}()

		private let state: FilenMobileCacheState
		/// The cache's thumbnail directory (`<files>/thumbnails`, filen-mobile-native-cache
		/// io/mod.rs). Thumbnails made here sit beside the cache's own, `<uuid>/<w>x<h>.<ext>`, so
		/// its sweep evicts them by budget, prunes them with their item and wipes them on logout.
		private let thumbnailDir: URL
		/// The cache's download directory (`<files>/cache`, same file), one `<uuid>` directory per
		/// downloaded file: how a copy that was already there is told from one fetched here.
		private let downloadDir: URL
		private let pixels: Int

		init(state: FilenMobileCacheState, filesDir: URL, pixels: Int) {
			self.state = state
			self.thumbnailDir = filesDir.appending(component: "thumbnails")
			self.downloadDir = filesDir.appending(component: "cache")
			self.pixels = pixels
		}

		/// Whether a file is one the cache refuses here and ImageIO reads, by name first and the
		/// stored mime second, as the cache decides.
		static func handles(name: String?, mime: String?) -> Bool {
			if let name, let dot = name.lastIndex(of: ".") {
				let ext = name[name.index(after: dot)...].lowercased()
				if Self.extensions.contains(ext), let type = UTType(filenameExtension: ext) {
					return Self.readableTypes.contains(type.identifier)
				}
			}
			guard let mime, let type = UTType(mimeType: mime) else { return false }
			return Self.readableTypes.contains(type.identifier)
		}

		static func withinSourceCap(_ size: Int64) -> Bool {
			size > 0 && size <= Self.maxSourceBytes
		}

		/// The smallest ImageIO subsample factor whose decode fits `budget` as RGBA, or nil when
		/// even the largest does not.
		static func subsampleFactor(width: Int, height: Int, budget: Int) -> Int? {
			guard width > 0, height > 0 else { return nil }
			for factor in [1, 2, 4, 8] {
				let scaledWidth = Double((width + factor - 1) / factor)
				let scaledHeight = Double((height + factor - 1) / factor)
				if scaledWidth * scaledHeight * 4 <= Double(budget) { return factor }
			}
			return nil
		}

		/// A thumbnail of the image at `url`, at most `maxPixelSize` on its longer side: JPEG, or
		/// PNG when it has alpha. Nil when ImageIO cannot read it or the decode would not fit
		/// `budget`. Only the header is read before that decision.
		static func makeThumbnail(at url: URL, maxPixelSize: Int, budget: Int) -> Data? {
			guard
				let source = CGImageSourceCreateWithURL(
					url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
				let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
					as? [CFString: Any],
				let width = properties[kCGImagePropertyPixelWidth] as? Int,
				let height = properties[kCGImagePropertyPixelHeight] as? Int,
				let factor = Self.subsampleFactor(width: width, height: height, budget: budget)
			else { return nil }
			var options: [CFString: Any] = [
				kCGImageSourceCreateThumbnailFromImageAlways: true,
				kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
				kCGImageSourceShouldCacheImmediately: true,
				kCGImageSourceCreateThumbnailWithTransform: true,
			]
			if factor > 1 { options[kCGImageSourceSubsampleFactor] = factor }
			guard
				let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
			else { return nil }
			// From the file, not the thumbnail: ImageIO hands an opaque image back with alpha.
			return Self.encode(image, opaque: properties[kCGImagePropertyHasAlpha] as? Bool != true)
		}

		private static func encode(_ image: CGImage, opaque: Bool) -> Data? {
			let data = NSMutableData()
			guard
				let destination = CGImageDestinationCreateWithData(
					data, (opaque ? UTType.jpeg : UTType.png).identifier as CFString, 1, nil)
			else { return nil }
			let properties: [CFString: Any] =
				opaque ? [kCGImageDestinationLossyCompressionQuality: 0.8] : [:]
			CGImageDestinationAddImage(destination, image, properties as CFDictionary)
			guard CGImageDestinationFinalize(destination) else { return nil }
			return data as Data
		}

		/// The thumbnail for `id`, or (nil, nil) when it is not one this fallback makes. Errors are
		/// the retryable kind; a settled refusal is (nil, nil), as the cache answers one.
		func thumbnail(for id: String, abort: FfiAbortController) async -> (Data?, (any Error)?) {
			do {
				guard case .file(let file) = try self.state.queryItem(path: id),
					Self.handles(name: file.meta?.name, mime: file.meta?.mime),
					Self.withinSourceCap(file.size)
				else { return (nil, nil) }
				if let stored = self.stored(uuid: file.uuid) { return (stored, nil) }
				let data = try await Self.withSlot(Self.itemSlots) {
					try await self.make(id: id, uuid: file.uuid, abort: abort)
				}
				return (data, nil)
			} catch is CancellationError {
				return (nil, userCancelledError())
			} catch CacheError.Aborted(_) {
				return (nil, userCancelledError())
			} catch {
				Self.logger.error("thumbnail fallback for \(id) failed: \(error)")
				return (nil, providerError(from: error))
			}
		}

		/// Downloads through the cache, decodes, and removes a copy fetched only for this.
		private func make(id: String, uuid: String, abort: FfiAbortController) async throws
			-> Data?
		{
			try Task.checkCancellation()
			let hadCopy = FileManager.default.fileExists(
				atPath: self.downloadDir.appending(component: uuid).path(percentEncoded: false))
			let downloaded = try await self.state.downloadFileIfChangedWithItem(
				id: id, progressCallback: nil, abort: abort.signal())
			let response = Download(
				path: downloaded.path, file: downloaded.file, hadCopy: hadCopy)
			let data: Data?
			do {
				data = try await Self.withSlot(Self.decodeSlots) {
					try Task.checkCancellation()
					return Self.makeThumbnail(
						at: URL(fileURLWithPath: response.path), maxPixelSize: self.pixels,
						budget: Self.decodeBudgetBytes)
				}
			} catch {
				await self.discard(response, id: id)
				throw error
			}
			await self.discard(response, id: id)
			guard let data else {
				Self.logger.info("thumbnail fallback produced nothing for \(id)")
				return nil
			}
			self.store(data, uuid: response.file.uuid)
			return data
		}

		private struct Download {
			let path: String
			let file: FfiFile
			/// Whether the cache held the bytes before this fetched them.
			let hadCopy: Bool
		}

		/// No leftovers: a copy fetched only for the thumbnail goes again. One that was there
		/// already, or that holds an edit not yet uploaded, stays.
		private func discard(_ download: Download, id: String) async {
			guard !download.hadCopy, download.file.pendingUploadAt == nil else { return }
			do {
				try await self.state.clearLocalCache(item: id)
			} catch {
				Self.logger.error("thumbnail fallback could not remove its copy of \(id): \(error)")
			}
		}

		private func storedURL(uuid: String, ext: String) -> URL {
			self.thumbnailDir.appending(component: uuid)
				.appending(component: "\(self.pixels)x\(self.pixels).\(ext)")
		}

		private func stored(uuid: String) -> Data? {
			for ext in ["jpg", "png"] {
				if let data = try? Data(contentsOf: self.storedURL(uuid: uuid, ext: ext)),
					!data.isEmpty
				{
					return data
				}
			}
			return nil
		}

		/// Written beside the cache's own thumbnails through a `.tmp` the sweep skips, and renamed
		/// into place so a reader never sees a torn file. Best-effort: a failure costs a remake.
		private func store(_ data: Data, uuid: String) {
			let ext = data.starts(with: [0xFF, 0xD8]) ? "jpg" : "png"
			let target = self.storedURL(uuid: uuid, ext: ext)
			let directory = target.deletingLastPathComponent()
			let temporary = directory.appending(component: "\(UUID().uuidString).tmp")
			do {
				try FileManager.default.createDirectory(
					at: directory, withIntermediateDirectories: true)
				try data.write(to: temporary)
				guard
					rename(
						temporary.path(percentEncoded: false), target.path(percentEncoded: false))
						== 0
				else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
			} catch {
				try? FileManager.default.removeItem(at: temporary)
				Self.logger.error("thumbnail fallback could not store \(uuid): \(error)")
			}
		}

		private static func withSlot<T>(
			_ slots: AsyncSlots, _ body: () async throws -> T
		) async throws -> T {
			await slots.acquire()
			do {
				let value = try await body()
				await slots.release()
				return value
			} catch {
				await slots.release()
				throw error
			}
		}
	}

	/// A counting semaphore for tasks: a waiter parks as a continuation, not a blocked thread.
	actor AsyncSlots {
		private var free: Int
		private var waiting: [CheckedContinuation<Void, Never>] = []

		init(_ count: Int) {
			self.free = count
		}

		func acquire() async {
			if self.free > 0 {
				self.free -= 1
				return
			}
			await withCheckedContinuation { self.waiting.append($0) }
		}

		func release() {
			if self.waiting.isEmpty {
				self.free += 1
			} else {
				self.waiting.removeFirst().resume()
			}
		}
	}
#endif
