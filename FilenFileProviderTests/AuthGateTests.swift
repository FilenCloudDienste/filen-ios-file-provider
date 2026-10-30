import CryptoKit
import FileProvider
import XCTest

/// While the cache is signed out, the system can repeat a call every few milliseconds. The gate
/// answers those itself for as long as the cache would give the same answer, and no longer.
final class AuthGateTests: XCTestCase {
	private func assertNotAuthenticated(
		_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line
	) {
		XCTAssertThrowsError(try body(), file: file, line: line) { error in
			XCTAssertEqual((error as NSError).domain, NSFileProviderErrorDomain, file: file, line: line)
			XCTAssertEqual(
				(error as NSError).code, NSFileProviderError.notAuthenticated.rawValue, file: file,
				line: line)
		}
	}

	func testAFreshGateLetsCallsThrough() {
		XCTAssertNoThrow(try AuthGate().check())
	}

	func testASignedOutAnswerClosesTheGateForTheWindow() {
		let gate = AuthGate()
		let now = ContinuousClock.now

		gate.observe(CacheError.Disabled("signed out"), now: now)

		assertNotAuthenticated { try gate.check(now: now) }
		assertNotAuthenticated { try gate.check(now: now + .milliseconds(999)) }
		XCTAssertNoThrow(try gate.check(now: now + AuthGate.window))
		// Expired is reopened: the next call goes to the cache again.
		XCTAssertNoThrow(try gate.check(now: now))
	}

	func testAnUnauthenticatedAnswerClosesTheGateToo() {
		let gate = AuthGate()

		gate.observe(CacheError.Unauthenticated("no session"))

		assertNotAuthenticated { try gate.check() }
	}

	/// Only signed-out answers say anything about the session; a blip must not hold calls back.
	func testOtherFailuresLeaveTheGateOpen() {
		let gate = AuthGate()

		gate.observe(CacheError.Remote("offline"))
		gate.observe(CacheError.DoesNotExist("gone"))
		gate.observe(NSFileProviderError(.notAuthenticated))

		XCTAssertNoThrow(try gate.check())
	}

	func testReopeningSendsTheNextCallToTheCache() {
		let gate = AuthGate()
		gate.observe(CacheError.Disabled("signed out"))

		gate.reopen()

		XCTAssertNoThrow(try gate.check())
	}

	/// End to end against a real cache with no session: what it throws is what closes the gate.
	func testASignedOutCacheClosesTheGate() throws {
		let workDir = FileManager.default.temporaryDirectory
			.appending(component: "filen-auth-gate-tests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: workDir) }
		let state = FilenMobileCacheState(
			filesDir: workDir.appending(component: "files").path(percentEncoded: false),
			authFile: workDir.appending(component: "auth.json").path(percentEncoded: false),
			dek: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
		let gate = AuthGate()

		XCTAssertThrowsError(try state.rootUuid()) { error in
			XCTAssertTrue(AuthGate.isSignedOut(error), "\(error)")
			gate.observe(error)
		}

		assertNotAuthenticated { try gate.check() }
	}
}
