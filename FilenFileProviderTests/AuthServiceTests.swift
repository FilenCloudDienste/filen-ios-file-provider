#if os(macOS)
	import CryptoKit
	import FileProvider
	import XCTest

	/// The XPC auth service is the only way a session reaches the macOS extension, and the only
	/// validation in front of the file the cache trusts. What it writes must be exactly the sealed
	/// format the cache opens, and anything else must be refused without touching the file.
	final class AuthServiceTests: XCTestCase {
		private var workDir: URL!
		private var authFile: URL!
		private var dek: Data!
		private var state: FilenMobileCacheState!

		override func setUpWithError() throws {
			workDir = FileManager.default.temporaryDirectory
				.appending(component: "filen-auth-service-tests-\(UUID().uuidString)")
			try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
			authFile = workDir.appending(component: "auth.json")
			dek = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
			// No auth.json yet: the state starts unauthenticated, as a fresh extension does.
			state = FilenMobileCacheState(
				filesDir: workDir.appending(component: "files").path(percentEncoded: false),
				authFile: authFile.path(percentEncoded: false),
				dek: dek)
		}

		override func tearDownWithError() throws {
			state = nil
			if let workDir { try? FileManager.default.removeItem(at: workDir) }
		}

		private func service(dek: Data? = nil) -> AuthServiceSource {
			AuthServiceSource(state: state, manager: nil, authFile: authFile, dek: dek ?? self.dek)
		}

		private func setAuth(_ payload: Data, on service: AuthServiceSource? = nil) async -> NSError? {
			let service = service ?? self.service()
			return await withCheckedContinuation { continuation in
				service.setAuth(payload) { continuation.resume(returning: $0) }
			}
		}

		private func clearAuth(on service: AuthServiceSource) async -> NSError? {
			await withCheckedContinuation { continuation in
				service.clearAuth { continuation.resume(returning: $0) }
			}
		}

		private func sdkConfig(userId: Any = 1, authVersion: Int = 2) -> [String: Any] {
			[
				"email": "test@example.com", "password": "redacted", "twoFactorCode": "",
				"masterKeys": ["key"], "apiKey": "api", "publicKey": "", "privateKey": "private",
				"authVersion": authVersion, "baseFolderUUID": "00000000-0000-0000-0000-000000000000",
				"userId": userId, "metadataCache": false, "tmpPath": "", "connectToSocket": false,
			]
		}

		private func json(_ object: [String: Any]) throws -> Data {
			try JSONSerialization.data(withJSONObject: object)
		}

		/// Opens auth.json the way the cache does: version byte, then AES-GCM combined.
		private func openAuthFile() throws -> [String: Any] {
			let sealed = try Data(contentsOf: authFile)
			XCTAssertEqual(sealed.first, 0x01)
			let box = try AES.GCM.SealedBox(combined: sealed.dropFirst())
			let plaintext = try AES.GCM.open(box, using: SymmetricKey(data: dek))
			return try XCTUnwrap(JSONSerialization.jsonObject(with: plaintext) as? [String: Any])
		}

		private func assertRejected(
			_ error: NSError?, _ code: AuthServiceErrorCode, file: StaticString = #filePath,
			line: UInt = #line
		) {
			XCTAssertEqual(error?.domain, AUTH_SERVICE_ERROR_DOMAIN, file: file, line: line)
			XCTAssertEqual(error?.code, code.rawValue, file: file, line: line)
			XCTAssertFalse(
				FileManager.default.fileExists(atPath: authFile.path(percentEncoded: false)),
				"a rejected payload must not touch auth.json", file: file, line: line)
		}

		func testAValidSessionIsSealedInTheCacheFormat() async throws {
			let error = await setAuth(
				try json(["providerEnabled": true, "sdkConfig": sdkConfig(), "unknownKey": 1]))
			XCTAssertNil(error)

			let written = try openAuthFile()
			XCTAssertEqual(written["providerEnabled"] as? Bool, true)
			let config = try XCTUnwrap(written["sdkConfig"] as? [String: Any])
			XCTAssertEqual(config["email"] as? String, "test@example.com")
			XCTAssertEqual(config["baseFolderUUID"] as? String, "00000000-0000-0000-0000-000000000000")
			XCTAssertNil(written["unknownKey"], "only the checked fields are written")
		}

		/// The cache takes a user id as a number or a numeric string; the file always gets a number.
		func testAStringUserIdIsAcceptedAndWrittenAsANumber() async throws {
			let error = await setAuth(
				try json(["providerEnabled": true, "sdkConfig": sdkConfig(userId: "42")]))
			XCTAssertNil(error)
			let config = try XCTUnwrap(try openAuthFile()["sdkConfig"] as? [String: Any])
			XCTAssertEqual(config["userId"] as? Int, 42)
		}

		func testAnOversizedPayloadIsRejected() async {
			let error = await setAuth(Data(count: (1 << 20) + 1))
			assertRejected(error, .payloadTooLarge)
		}

		func testMalformedPayloadsAreRejected() async throws {
			var missingField = sdkConfig()
			missingField["apiKey"] = nil
			let payloads: [Data] = [
				Data("not json".utf8),
				try json(["providerEnabled": "yes", "sdkConfig": sdkConfig()]),
				try json(["providerEnabled": true, "sdkConfig": missingField]),
				try json(["providerEnabled": true]),
				try json(["providerEnabled": true, "sdkConfig": sdkConfig(authVersion: 7)]),
				try json(["providerEnabled": true, "sdkConfig": sdkConfig(userId: -1)]),
			]
			for payload in payloads {
				let error = await setAuth(payload)
				assertRejected(error, .invalidPayload)
			}
		}

		/// A key the running state cannot have been built with seals nothing.
		func testAMissingKeyIsRejected() async throws {
			let error = await setAuth(
				try json(["providerEnabled": true, "sdkConfig": sdkConfig()]),
				on: service(dek: Data()))
			assertRejected(error, .keyUnavailable)
		}

		func testClearingRemovesTheSessionAndIsIdempotent() async throws {
			let service = self.service()
			let set = await setAuth(try json(["providerEnabled": false]), on: service)
			XCTAssertNil(set)
			XCTAssertEqual(try openAuthFile()["providerEnabled"] as? Bool, false)

			let cleared = await clearAuth(on: service)
			XCTAssertNil(cleared)
			XCTAssertFalse(FileManager.default.fileExists(atPath: authFile.path(percentEncoded: false)))
			let clearedAgain = await clearAuth(on: service)
			XCTAssertNil(clearedAgain)
		}

		/// End to end: a state that started without a session is authenticated by `setAuth` alone,
		/// within the cache's one-second unauthenticated re-read.
		func testASessionPushedOverTheServiceAuthenticatesTheRunningState() async throws {
			guard let credentials = TestAuth.credentialsFromEnvironment() else {
				throw XCTSkip(
					"""
					The live auth service test needs a session in the environment: \
					\(TestAuth.requiredVariables.joined(separator: ", ")).
					""")
			}
			XCTAssertThrowsError(try state.rootUuid(), "no session yet")

			let error = await setAuth(Data(try TestAuth.sessionJson(credentials).utf8))
			XCTAssertNil(error)

			try await Task.sleep(for: .milliseconds(1100))
			XCTAssertEqual(try state.rootUuid(), credentials.baseFolderUuid)
		}
	}
#endif
