import FileProvider
import XCTest

/// Cache item URLs look like `.../<uuid>/<filename>`, so the uuid is the second-to-last path
/// component. Indexing that position without checking the length traps — and a trap cannot be
/// caught by `do`/`catch`, so a short URL takes down the whole extension process rather than
/// failing one operation.
final class CacheItemURLTests: XCTestCase {
	func testAWellFormedCacheURLYieldsItsUuid() {
		let uuid = "11111111-1111-1111-1111-111111111111"
		let url = URL(fileURLWithPath: "/var/mobile/storage/\(uuid)/report.pdf")

		XCTAssertEqual(uuidFromCacheItemURL(url), uuid)
	}

	func testAUuidIsFoundRegardlessOfHowDeepTheURLIs() {
		let uuid = "22222222-2222-2222-2222-222222222222"
		XCTAssertEqual(
			uuidFromCacheItemURL(URL(fileURLWithPath: "/\(uuid)/a.txt")), uuid,
			"the shallowest well-formed shape must still resolve")
	}

	/// The cases that would trap today.
	func testTooShortAURLReturnsNilInsteadOfTrapping() {
		XCTAssertNil(uuidFromCacheItemURL(URL(fileURLWithPath: "/")))
	}

	func testASingleComponentURLReturnsNil() {
		// "/" plus one component — there is no second-to-last element to read.
		XCTAssertNil(uuidFromCacheItemURL(URL(fileURLWithPath: "/onlyone")))
	}

	func testATrailingSlashDirectoryURLDoesNotTrap() {
		// A directory URL normalises differently; whatever it yields, it must not crash.
		_ = uuidFromCacheItemURL(URL(fileURLWithPath: "/", isDirectory: true))
	}
}
