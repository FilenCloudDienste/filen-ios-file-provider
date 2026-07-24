import CryptoKit
import Foundation

/// Shared auth bootstrap for the integration tests — the iOS mirror of the Android harness's
/// `TestAuth.kt`.
///
/// The Rust cache only accepts an encrypted auth file: version(0x01) ++ nonce(12) ++ ciphertext ++
/// tag(16), AES-256-GCM, no AAD — after the version byte this is exactly the SDK's `DataCrypter`
/// format (see `filen-mobile-native-cache/src/auth.rs`).
///
/// Unlike the extension — which shares its DEK with the app through a keychain access group — the
/// tests generate their own DEK per run and hand it straight to `FilenMobileCacheState`, so no
/// keychain entitlement, app group, or host app is needed.
///
/// The session itself is a pre-obtained one read from the environment at run time, so there is no
/// live login and no credentials in the repo.
enum TestAuth {
	private static let authFileVersion: UInt8 = 0x01

	struct Credentials {
		let email: String
		/// Raw JSON array literal, e.g. `["key"]` — same shape the Android harness passes through
		/// `BuildConfig.MASTER_KEYS`.
		let masterKeysJson: String
		let apiKey: String
		let privateKey: String
		let authVersion: Int
		let baseFolderUuid: String
	}

	enum TestAuthError: LocalizedError {
		case sealFailed
		case malformedMasterKeys

		var errorDescription: String? {
			switch self {
			case .sealFailed:
				return "AES-GCM seal produced no combined representation"
			case .malformedMasterKeys:
				return
					"MASTER_KEYS is not a JSON array of strings — expected [\"<key>\"] (optionally with the escaped quotes the Android .env uses)"
			}
		}
	}

	/// The environment variables the harness reads, in their documented spelling.
	///
	/// The bare names (`EMAIL`, `MASTER_KEYS`, …) are the ones the Android harness's `.env` already
	/// uses, so the same file drives both platforms.
	static let requiredVariables = [
		"EMAIL",
		"MASTER_KEYS",
		"API_KEY",
		"PRIVATE_KEY",
		"AUTH_VERSION",
		"BASE_FOLDER_UUID",
	]

	/// Reads the session from the environment, or nil if it is not fully configured.
	///
	/// Four spellings are accepted per variable, most specific first: `FILEN_TEST_<NAME>`, then the
	/// bare `<NAME>` the Android `.env` uses, each also with the `TEST_RUNNER_` prefix that
	/// `xcodebuild test` strips when forwarding host variables into the test process.
	static func credentialsFromEnvironment() -> Credentials? {
		func read(_ name: String) -> String? {
			let environment = ProcessInfo.processInfo.environment
			let candidates = [
				"FILEN_TEST_" + name,
				"TEST_RUNNER_FILEN_TEST_" + name,
				name,
				"TEST_RUNNER_" + name,
			]
			for candidate in candidates {
				if let value = environment[candidate], !value.isEmpty { return value }
			}
			return nil
		}

		guard let email = read("EMAIL"),
			let masterKeysJson = read("MASTER_KEYS"),
			let apiKey = read("API_KEY"),
			let privateKey = read("PRIVATE_KEY"),
			let authVersionRaw = read("AUTH_VERSION"),
			let authVersion = Int(authVersionRaw),
			let baseFolderUuid = read("BASE_FOLDER_UUID")
		else { return nil }

		return Credentials(
			email: email,
			masterKeysJson: masterKeysJson,
			apiKey: apiKey,
			privateKey: privateKey,
			authVersion: authVersion,
			baseFolderUuid: baseFolderUuid)
	}

	/// Writes the sealed auth file and returns the raw DEK, which callers pass to
	/// `FilenMobileCacheState`'s constructor.
	static func provision(authFile: URL, credentials: Credentials) throws -> Data {
		// CryptoKit keys come from the system CSPRNG.
		let dek = SymmetricKey(size: .bits256)
		try writeSealed(dek: dek, authFile: authFile, plaintext: sessionJson(credentials))
		return dek.withUnsafeBytes { Data($0) }
	}

	private static func writeSealed(dek: SymmetricKey, authFile: URL, plaintext: String) throws {
		// A fresh random nonce per seal; `combined` is nonce(12) ++ ciphertext ++ tag(16), which is
		// exactly what the Rust side expects after the version byte.
		let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: dek)
		guard let combined = sealed.combined else { throw TestAuthError.sealFailed }
		try (Data([authFileVersion]) + combined).write(to: authFile, options: .atomic)
	}

	/// Parses the master keys, accepting both spellings the value occurs in.
	///
	/// The Android harness stores it as a Java string *literal* — gradle splices the `.env` value
	/// raw into generated Java and `TestAuth.kt` interpolates `BuildConfig.MASTER_KEYS` raw into
	/// JSON — so the same `.env` yields `[\"key\"]` with literal backslashes once the surrounding
	/// quotes come off. Plain `["key"]` is accepted unchanged.
	static func parseMasterKeys(_ raw: String) throws -> [String] {
		func decode(_ candidate: String) -> [String]? {
			guard
				let parsed = try? JSONSerialization.jsonObject(with: Data(candidate.utf8)),
				let keys = parsed as? [String]
			else { return nil }
			return keys
		}

		if let keys = decode(raw) { return keys }

		let unescaped =
			raw
			.replacingOccurrences(of: "\\\"", with: "\"")
			.replacingOccurrences(of: "\\\\", with: "\\")
		if let keys = decode(unescaped) { return keys }

		throw TestAuthError.malformedMasterKeys
	}

	/// Builds the auth JSON through `JSONSerialization` rather than string interpolation, so a value
	/// containing a quote or backslash can't corrupt the document.
	private static func sessionJson(_ credentials: Credentials) throws -> String {
		let masterKeys = try parseMasterKeys(credentials.masterKeysJson)

		let sdkConfig: [String: Any] = [
			"email": credentials.email,
			"password": "redacted",
			"twoFactorCode": "",
			"masterKeys": masterKeys,
			"apiKey": credentials.apiKey,
			"publicKey": "",
			"privateKey": credentials.privateKey,
			"authVersion": credentials.authVersion,
			"baseFolderUUID": credentials.baseFolderUuid,
			"userId": 0,
			"metadataCache": false,
			"tmpPath": "",
			"connectToSocket": false,
		]
		let authFile: [String: Any] = [
			"providerEnabled": true,
			"sdkConfig": sdkConfig,
		]

		let data = try JSONSerialization.data(withJSONObject: authFile)
		return String(decoding: data, as: UTF8.self)
	}
}
