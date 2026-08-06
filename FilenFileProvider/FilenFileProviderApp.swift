import CryptoKit
import FileProvider
import Foundation
import Security
import SwiftUI

/// Development harness for the replicated extension. Enabling does the four things the app side owes
/// the extension, in the order the extension needs them:
///
/// 1. provision the auth.json DEK in the shared keychain access group (the extension reads it there,
///    see `FileProviderExtension.readAuthDek`),
/// 2. seal an auth.json with that DEK — the Rust cache only accepts the encrypted form,
/// 3. register an `NSFileProviderDomain`: a replicated extension has no implicit default domain, so
///    without this the system never instantiates it,
/// 4. read the domain's root container through a file coordinator, which is what actually makes the
///    system launch the extension and run its enumerator.
///
/// Credentials come from Info.plist (`$(VAR)`s fed by secrets.xcconfig) and are never logged.

/// The team-prefixed access group, the ":no-auth" service suffix and the account-stored-as-Data are
/// expo-secure-store's exact item shape — the extension queries for it verbatim, so the harness has
/// to write it verbatim.
private let authDekAccessGroup = "7YTW5D2K7P.io.filen.sharedkeys"
private let authDekService = "io.filen.fileprovider:no-auth"
private let authDekAccount = "fileProviderAuthKey"
/// version(0x01) ++ AES-256-GCM combined — see `filen-mobile-native-cache/src/auth.rs`.
private let authFileVersion: UInt8 = 0x01

private let providerDomain = NSFileProviderDomain(
	identifier: NSFileProviderDomainIdentifier("io.filen.drive"), displayName: "Filen")

private func harnessLog(_ message: String) { print("[harness] \(message)") }

private enum HarnessError: LocalizedError {
	case noAppGroup
	case sealFailed
	case keychain(OSStatus)

	var errorDescription: String? {
		switch self {
		case .noAppGroup: return "no container for app group group.io.filen.app"
		case .sealFailed: return "AES-GCM seal produced no combined representation"
		case .keychain(let status): return "keychain error (status \(status))"
		}
	}
}

// MARK: - DEK

private func readAuthDek() -> SymmetricKey? {
	let query: [String: Any] = [
		kSecClass as String: kSecClassGenericPassword,
		kSecAttrService as String: authDekService,
		kSecAttrAccount as String: Data(authDekAccount.utf8),
		kSecAttrAccessGroup as String: authDekAccessGroup,
		kSecReturnData as String: true,
		kSecMatchLimit as String: kSecMatchLimitOne,
	]
	var item: CFTypeRef?
	let status = SecItemCopyMatching(query as CFDictionary, &item)
	guard status == errSecSuccess,
		let stored = item as? Data,
		let base64 = String(data: stored, encoding: .utf8),
		let raw = Data(base64Encoded: base64)
	else {
		if status != errSecItemNotFound { harnessLog("DEK read failed: status \(status)") }
		return nil
	}
	return SymmetricKey(data: raw)
}

/// The shared DEK, minted on first enable. Idempotent: an existing item wins, including when the
/// extension provisioned it first (it does the same thing for the same reason), so both sides always
/// end up on one key.
private func loadOrCreateAuthDek() throws -> SymmetricKey {
	if let existing = readAuthDek() {
		harnessLog("DEK: reusing the existing keychain item")
		return existing
	}

	let dek = SymmetricKey(size: .bits256)
	let account = Data(authDekAccount.utf8)
	let addQuery: [String: Any] = [
		kSecClass as String: kSecClassGenericPassword,
		kSecAttrService as String: authDekService,
		kSecAttrGeneric as String: account,
		kSecAttrAccount as String: account,
		kSecAttrAccessGroup as String: authDekAccessGroup,
		kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
		kSecValueData as String: Data(
			dek.withUnsafeBytes { Data($0) }.base64EncodedString().utf8),
	]
	let status = SecItemAdd(addQuery as CFDictionary, nil)

	if status == errSecDuplicateItem, let existing = readAuthDek() {
		harnessLog("DEK: lost the provisioning race, using the stored item")
		return existing
	}
	guard status == errSecSuccess else { throw HarnessError.keychain(status) }
	harnessLog("DEK: provisioned a new keychain item")
	return dek
}

// MARK: - auth.json

private var authFileURL: URL? {
	FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.io.filen.app")?
		.appending(component: "auth.json")
}

/// Seals the auth JSON under the shared DEK and writes it where the extension looks.
private func writeAuthFile(_ json: String, dek: SymmetricKey) throws {
	guard let fileURL = authFileURL else { throw HarnessError.noAppGroup }
	// `combined` is nonce(12) ++ ciphertext ++ tag(16), which is exactly what the Rust side expects
	// after the version byte.
	let sealed = try AES.GCM.seal(Data(json.utf8), using: dek)
	guard let combined = sealed.combined else { throw HarnessError.sealFailed }
	try (Data([authFileVersion]) + combined).write(to: fileURL, options: .atomic)
}

private func sessionJson() -> String {
	"""
	{
		"providerEnabled": true,
		"sdkConfig": {
			"email": "\(Bundle.main.infoDictionary!["EMAIL"] as! String)",
			"password": "redacted",
			"masterKeys": \(Bundle.main.infoDictionary!["MASTER_KEYS"] as! String),
			"connectToSocket": true,
			"metadataCache": true,
			"twoFactorCode": "redacted",
			"publicKey": "",
			"privateKey": "\(Bundle.main.infoDictionary!["PRIVATE_KEY"] as! String)",
			"apiKey": "\(Bundle.main.infoDictionary!["API_KEY"] as! String)",
			"authVersion": \(Bundle.main.infoDictionary!["AUTH_VERSION"] as! String),
			"baseFolderUUID": "\(Bundle.main.infoDictionary!["BASE_FOLDER_UUID"] as! String)",
			"userId": 0,
			"tmpPath": ""
		}
	}
	"""
}

private let disabledJson = """
	{
		"providerEnabled": false,
		"sdkConfig": null
	}
	"""

// MARK: - Domain

private func addDomain() async {
	do {
		// Adding a domain that already exists is a no-op, so this is safe to repeat.
		try await NSFileProviderManager.add(providerDomain)
		harnessLog("domain registered: \(providerDomain.identifier.rawValue)")
	} catch { harnessLog("domain registration failed: \(error)") }
}

private func removeDomain() async {
	do {
		try await NSFileProviderManager.remove(providerDomain)
		harnessLog("domain removed: \(providerDomain.identifier.rawValue)")
	} catch { harnessLog("domain removal failed: \(error)") }
}

// MARK: - Probe

/// Lists the domain's root container. The coordinated read is the load-bearing part: it is what
/// makes the system materialise the container, launch the extension and run its enumerator — an
/// uncoordinated read would just report whatever happens to be on disk already.
private func probeRootContainer() async {
	guard let manager = NSFileProviderManager(for: providerDomain) else {
		harnessLog("probe: no manager for the domain — not registered?")
		return
	}
	do {
		let root = try await manager.getUserVisibleURL(for: .rootContainer)
		harnessLog("probe: root container at \(root.path(percentEncoded: false))")

		let scoped = root.startAccessingSecurityScopedResource()
		defer { if scoped { root.stopAccessingSecurityScopedResource() } }

		var coordinationError: NSError?
		var listing: Result<[URL], Error> = .success([])
		NSFileCoordinator().coordinate(readingItemAt: root, options: [], error: &coordinationError) {
			url in
			listing = Result {
				try FileManager.default.contentsOfDirectory(
					at: url, includingPropertiesForKeys: nil)
			}
		}
		if let coordinationError { throw coordinationError }

		let children = try listing.get()
		harnessLog("probe: root lists \(children.count) child(ren)")
		for child in children { harnessLog("probe: child \(child.lastPathComponent)") }
	} catch { harnessLog("probe failed: \(error)") }
}

// MARK: - UI

struct TestView: View {
	@State private var isEnabled = false

	var body: some View {
		VStack(spacing: 16) {
			Toggle("Switch state", isOn: $isEnabled).onChange(of: isEnabled) { newValue in
				if newValue { enable() } else { disable() }
			}
			Button("Probe root container") { Task.detached { await probeRootContainer() } }
		}.padding()
			.onAppear {
				harnessLog(
					"auth file path: \(authFileURL?.path(percentEncoded: false) ?? "")")
				// So the flow can be driven from a script (`simctl launch … -harness-enable`)
				// without tapping the toggle. Flipping the state runs the same onChange path;
				// the toggle is already off in the disable case, so that one calls straight
				// through.
				if ProcessInfo.processInfo.arguments.contains("-harness-enable") { isEnabled = true }
				if ProcessInfo.processInfo.arguments.contains("-harness-disable") { disable() }
			}
	}

	private func enable() {
		do {
			try writeAuthFile(sessionJson(), dek: loadOrCreateAuthDek())
			harnessLog("auth file sealed")
		} catch {
			harnessLog("enable failed, not registering the domain: \(error)")
			return
		}
		Task.detached {
			await addDomain()
			await probeRootContainer()
		}
	}

	private func disable() {
		Task.detached {
			await removeDomain()
			do {
				try writeAuthFile(disabledJson, dek: loadOrCreateAuthDek())
				harnessLog("auth file cleared")
			} catch { harnessLog("clearing the auth file failed: \(error)") }
		}
	}
}

struct ContentView: View { var body: some View { TestView() } }

@main struct FilenFileProviderApp: App { var body: some Scene { WindowGroup { ContentView() } } }
