#if os(macOS)
	import ImageIO
	import UniformTypeIdentifiers
	import XCTest

	/// The macOS cache has no HEIF decoder, so ImageIO makes those thumbnails. It must take only
	/// what the cache refuses, stay inside the cache's source and decode bounds, and never hand
	/// back more than the served size.
	final class ThumbnailFallbackTests: XCTestCase {
		func testHeifFamilyNamesAreTaken() {
			for name in ["IMG_0001.HEIC", "a.heic", "a.heif", "a.hif", "a.avif"] {
				XCTAssertTrue(ThumbnailFallback.handles(name: name, mime: nil), name)
			}
		}

		/// What the cache decodes itself, or nothing can, stays with the cache's answer.
		func testOtherNamesAreLeftAlone() {
			for name in ["a.jpg", "a.png", "a.pdf", "heic", "a.heic.txt", "noextension"] {
				XCTAssertFalse(ThumbnailFallback.handles(name: name, mime: nil), name)
			}
		}

		/// A HEIC some clients stored without its extension is still found by its mime.
		func testTheMimeDecidesWhenTheNameDoesNot() {
			XCTAssertTrue(ThumbnailFallback.handles(name: "photo", mime: "image/heic"))
			XCTAssertTrue(ThumbnailFallback.handles(name: nil, mime: "image/avif"))
			XCTAssertFalse(ThumbnailFallback.handles(name: "photo", mime: "application/octet-stream"))
		}

		func testTheSourceCapIsTheSdks() {
			XCTAssertTrue(ThumbnailFallback.withinSourceCap(1))
			XCTAssertTrue(ThumbnailFallback.withinSourceCap(64 * 1024 * 1024))
			XCTAssertFalse(ThumbnailFallback.withinSourceCap(64 * 1024 * 1024 + 1))
			XCTAssertFalse(ThumbnailFallback.withinSourceCap(0))
		}

		func testTheSubsampleFactorIsTheSmallestThatFitsTheBudget() {
			let budget = ThumbnailFallback.decodeBudgetBytes
			XCTAssertEqual(ThumbnailFallback.subsampleFactor(width: 1000, height: 1000, budget: budget), 1)
			// 12 MP: 48 MB as RGBA, under 12 MiB at half size.
			XCTAssertEqual(ThumbnailFallback.subsampleFactor(width: 4032, height: 3024, budget: budget), 2)
			XCTAssertEqual(ThumbnailFallback.subsampleFactor(width: 2048, height: 1536, budget: budget), 1)
			XCTAssertNil(ThumbnailFallback.subsampleFactor(width: 100_000, height: 100_000, budget: budget))
			XCTAssertNil(ThumbnailFallback.subsampleFactor(width: 0, height: 10, budget: budget))
		}

		private func writeHeic(width: Int, height: Int) throws -> URL {
			let heic = UTType.heic.identifier
			guard (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains(heic) else {
				throw XCTSkip("this Mac's ImageIO cannot encode HEIC")
			}
			let context = try XCTUnwrap(
				CGContext(
					data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
					space: CGColorSpace(name: CGColorSpace.sRGB)!,
					bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
			context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
			context.fill(CGRect(x: 0, y: 0, width: width, height: height))
			let image = try XCTUnwrap(context.makeImage())
			let url = FileManager.default.temporaryDirectory
				.appending(component: "thumbnail-fallback-\(UUID().uuidString).heic")
			addTeardownBlock { try? FileManager.default.removeItem(at: url) }
			let destination = try XCTUnwrap(
				CGImageDestinationCreateWithURL(url as CFURL, heic as CFString, 1, nil))
			CGImageDestinationAddImage(destination, image, nil)
			XCTAssertTrue(CGImageDestinationFinalize(destination))
			return url
		}

		func testAHeicBecomesAJpegNoLargerThanTheServedSize() throws {
			let url = try writeHeic(width: 3000, height: 2000)

			let data = try XCTUnwrap(
				ThumbnailFallback.makeThumbnail(
					at: url, maxPixelSize: 256, budget: ThumbnailFallback.decodeBudgetBytes))

			XCTAssertTrue(data.starts(with: [0xFF, 0xD8]), "expected a JPEG")
			let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
			let properties = try XCTUnwrap(
				CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
			XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 256)
			XCTAssertLessThan(properties[kCGImagePropertyPixelHeight] as? Int ?? .max, 256)
		}

		/// Over the decode budget even at the largest subsample: no thumbnail, as the cache answers.
		func testAnImageOverTheBudgetIsRefused() throws {
			let url = try writeHeic(width: 512, height: 512)

			XCTAssertNil(ThumbnailFallback.makeThumbnail(at: url, maxPixelSize: 256, budget: 1024))
		}

		func testUnreadableBytesAreRefused() throws {
			let url = FileManager.default.temporaryDirectory
				.appending(component: "thumbnail-fallback-\(UUID().uuidString).heic")
			try Data("not an image".utf8).write(to: url)
			addTeardownBlock { try? FileManager.default.removeItem(at: url) }

			XCTAssertNil(
				ThumbnailFallback.makeThumbnail(
					at: url, maxPixelSize: 256, budget: ThumbnailFallback.decodeBudgetBytes))
		}
	}
#endif
