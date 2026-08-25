import FileProvider
import XCTest

/// The dates an item reports are the only ones the Files app has: it shows them in the list and
/// sorts by them. Both live in the encrypted metadata, which is routinely incomplete — plenty of
/// uploads carry no creation date, directories carry no modification date at all, and metadata
/// that will not decrypt carries nothing. Every one of those cases has to fall back to the row
/// timestamp the server keeps outside the metadata, or the item renders dateless.
final class ItemDateTests: XCTestCase {
	private static let uuid = "11111111-1111-1111-1111-111111111111"
	private static let stableUuid = "22222222-2222-2222-2222-222222222222"
	private static let parent = "33333333-3333-3333-3333-333333333333"

	private static let timestamp: Int64 = 1_500_000_000_000
	private static let created: Int64 = 1_600_000_000_000
	private static let modified: Int64 = 1_700_000_000_000

	private static func date(_ millis: Int64) -> Date {
		Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
	}

	private func file(meta: FfiFileMeta?) -> FileProviderItem {
		FileProviderItem(
			itemIdentifier: NSFileProviderItemIdentifier("stable/" + Self.stableUuid),
			object: .file(
				FfiFile(
					uuid: Self.uuid, stableUuid: Self.stableUuid, parent: Self.parent,
					originalParent: nil, meta: meta, size: 0, favoriteRank: 0,
					timestamp: Self.timestamp, localData: nil, pendingUploadAt: nil, changeSeq: 0)))
	}

	private func fileMeta(created: Int64?, modified: Int64) -> FfiFileMeta {
		FfiFileMeta(
			name: "report.pdf", mime: "application/pdf", created: created, modified: modified,
			hash: nil)
	}

	private func dir(meta: FfiDirMeta?) -> FileProviderItem {
		FileProviderItem(
			itemIdentifier: NSFileProviderItemIdentifier("stable/" + Self.uuid),
			object: .dir(
				FfiDir(
					uuid: Self.uuid, parent: Self.parent, originalParent: nil, meta: meta,
					color: nil, favoriteRank: 0, timestamp: Self.timestamp, lastListed: 0,
					localData: nil, changeSeq: 0)))
	}

	// MARK: - The metadata wins whenever it has the date

	func testAFileWithBothDatesReportsItsOwn() {
		let item = file(meta: fileMeta(created: Self.created, modified: Self.modified))

		XCTAssertEqual(item.creationDate, Self.date(Self.created))
		XCTAssertEqual(item.contentModificationDate, Self.date(Self.modified))
	}

	func testADirectoryWithACreationDateReportsItsOwn() {
		let item = dir(meta: FfiDirMeta(name: "Photos", created: Self.created))

		XCTAssertEqual(item.creationDate, Self.date(Self.created))
		XCTAssertEqual(item.contentModificationDate, Self.date(Self.created))
	}

	// MARK: - Fallback to the row timestamp

	/// The common case: the file uploaded without a creation date. Its modification date is
	/// still its own — only the missing half falls back.
	func testAFileWithNoCreationDateFallsBackForThatDateOnly() {
		let item = file(meta: fileMeta(created: nil, modified: Self.modified))

		XCTAssertEqual(item.creationDate, Self.date(Self.timestamp))
		XCTAssertEqual(item.contentModificationDate, Self.date(Self.modified))
	}

	/// Metadata that will not decrypt: the name renders as a placeholder, and neither date
	/// exists. Both have to come from the timestamp.
	func testAFileWithUndecryptableMetadataFallsBackForBothDates() {
		let item = file(meta: nil)

		XCTAssertEqual(item.creationDate, Self.date(Self.timestamp))
		XCTAssertEqual(item.contentModificationDate, Self.date(Self.timestamp))
	}

	func testADirectoryWithNoCreationDateFallsBackForBothDates() {
		let item = dir(meta: FfiDirMeta(name: "Photos", created: nil))

		XCTAssertEqual(item.creationDate, Self.date(Self.timestamp))
		XCTAssertEqual(item.contentModificationDate, Self.date(Self.timestamp))
	}

	func testADirectoryWithUndecryptableMetadataFallsBackForBothDates() {
		let item = dir(meta: nil)

		XCTAssertEqual(item.creationDate, Self.date(Self.timestamp))
		XCTAssertEqual(item.contentModificationDate, Self.date(Self.timestamp))
	}

	/// A zero date is a real date, not a missing one — the fallback must not fire for it, or an
	/// item genuinely dated at the epoch would silently report the row timestamp instead.
	func testAZeroCreationDateIsNotTreatedAsMissing() {
		let item = file(meta: fileMeta(created: 0, modified: 0))

		XCTAssertEqual(item.creationDate, Self.date(0))
		XCTAssertEqual(item.contentModificationDate, Self.date(0))
	}
}
