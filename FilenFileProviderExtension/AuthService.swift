#if os(macOS)
	import CryptoKit
	import FileProvider
	import Foundation
	import os

	/// How the desktop app hands this extension its session. The same declaration lives on the app
	/// side; the two must stay identical.
	@objc(FilenFileProviderAuthService) protocol FilenFileProviderAuthService {
		func setAuth(_ authFile: Data, reply: @escaping (NSError?) -> Void)
		func clearAuth(reply: @escaping (NSError?) -> Void)
	}

	let AUTH_SERVICE_NAME = NSFileProviderServiceName("io.filen.FileProviderAuth")

	extension FileProviderExtension: NSFileProviderServicing {
		/// Offered on the root only: the session belongs to the domain, not to any item in it.
		func supportedServiceSources(
			for itemIdentifier: NSFileProviderItemIdentifier,
			completionHandler: @escaping ([any NSFileProviderServiceSource]?, (any Error)?) -> Void
		) -> Progress {
			completionHandler(itemIdentifier == .rootContainer ? [self.authService] : [], nil)
			return Progress()
		}
	}

	/// `AuthFile` as the cache parses it (filen-mobile-native-cache `auth.rs`). Decoding it is the
	/// schema check, and the file is written from the decoded value, so it holds exactly what was
	/// checked and nothing else.
	private struct AuthFilePayload: Codable {
		struct SdkConfig: Codable {
			let email: String
			let password: String
			let twoFactorCode: String
			let masterKeys: [String]
			let apiKey: String
			let publicKey: String
			let privateKey: String
			let authVersion: UInt8
			let baseFolderUUID: String
			let userId: PermissiveU64
			let metadataCache: Bool
			let tmpPath: String
			let connectToSocket: Bool
		}

		/// The cache accepts a user id as a number or as a numeric string.
		struct PermissiveU64: Codable {
			let value: UInt64

			init(from decoder: any Decoder) throws {
				let container = try decoder.singleValueContainer()
				if let number = try? container.decode(UInt64.self) {
					self.value = number
				} else if let parsed = UInt64(try container.decode(String.self)) {
					self.value = parsed
				} else {
					throw DecodingError.dataCorruptedError(
						in: container, debugDescription: "not an unsigned integer")
				}
			}

			func encode(to encoder: any Encoder) throws {
				var container = encoder.singleValueContainer()
				try container.encode(self.value)
			}
		}

		let providerEnabled: Bool
		let sdkConfig: SdkConfig?
		let maxThumbnailFilesBudget: UInt64?
		let maxCacheFilesBudget: UInt64?
		let thumbnailMemBudget: UInt64?
		let thumbnailMaxSourceBytes: UInt64?
		let thumbnailDecodeConcurrency: UInt32?
		let thumbnailItemConcurrency: UInt32?

		/// What the types alone do not say: an enabled provider needs a session, and the auth
		/// version is one the SDK knows.
		var isValid: Bool {
			guard let sdkConfig else { return !self.providerEnabled }
			return (1...3).contains(sdkConfig.authVersion)
		}
	}

	/// Replies are `NSError`s in this domain. They never carry anything from the payload.
	let AUTH_SERVICE_ERROR_DOMAIN = "io.filen.FileProviderAuth"

	enum AuthServiceErrorCode: Int {
		case payloadTooLarge = 1
		case invalidPayload = 2
		case keyUnavailable = 3
		case writeFailed = 4
	}

	private func authServiceError(_ code: AuthServiceErrorCode, _ reason: String) -> NSError {
		NSError(
			domain: AUTH_SERVICE_ERROR_DOMAIN, code: code.rawValue,
			userInfo: [NSLocalizedDescriptionKey: reason])
	}

	/// The `io.filen.FileProviderAuth` service: an anonymous listener whose connections export
	/// `FilenFileProviderAuthService`.
	///
	/// The session is sealed into the auth.json the cache already reads, in its existing format
	/// (`0x01 ‖ nonce ‖ AES-GCM ciphertext ‖ tag`) under the DEK this extension provisioned, so the
	/// Rust side needs nothing new. Restricted, so only a process that can manage the domain can
	/// reach it.
	final class AuthServiceSource: NSObject, NSFileProviderServiceSource, NSXPCListenerDelegate,
		FilenFileProviderAuthService, @unchecked Sendable
	{
		private static let logger = Logger(subsystem: PROVIDER, category: "AuthService")
		/// The largest payload accepted. A real one is a few KiB.
		private static let maxPayloadBytes = 1 << 20
		private static let authFileVersion: UInt8 = 0x01
		/// The cache re-reads auth.json at most once a second while unauthenticated. The nudge has
		/// to land after that window, or the call it triggers gets the old answer and the system
		/// throttles on it again.
		private static let nudgeDelay: DispatchTimeInterval = .milliseconds(1500)
		/// Both calls, from every connection and instance, run here one at a time: they write the
		/// same file.
		private static let queue = DispatchQueue(label: "io.filen.FileProviderAuth")

		let serviceName = AUTH_SERVICE_NAME
		var isRestricted: Bool { true }

		private let state: FilenMobileCacheState
		private let manager: NSFileProviderManager?
		private let authFile: URL?
		/// The key the running cache state was built with, so a sealed file is one it can open.
		private let dek: Data
		private let authGate: AuthGate
		private let listenerLock = NSLock()
		private var listener: NSXPCListener?

		init(
			state: FilenMobileCacheState, manager: NSFileProviderManager?, authFile: URL?, dek: Data,
			authGate: AuthGate
		) {
			self.state = state
			self.manager = manager
			self.authFile = authFile
			self.dek = dek
			self.authGate = authGate
			super.init()
		}

		func makeListenerEndpoint() throws -> NSXPCListenerEndpoint {
			self.listenerLock.lock()
			defer { self.listenerLock.unlock() }
			if let listener = self.listener { return listener.endpoint }
			let listener = NSXPCListener.anonymous()
			listener.delegate = self
			listener.resume()
			self.listener = listener
			return listener.endpoint
		}

		func listener(
			_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection
		) -> Bool {
			newConnection.exportedInterface = NSXPCInterface(with: FilenFileProviderAuthService.self)
			newConnection.exportedObject = self
			newConnection.resume()
			return true
		}

		func setAuth(_ authFile: Data, reply: @escaping (NSError?) -> Void) {
			Self.queue.async {
				let error = self.writeAuth(authFile)
				if let error {
					Self.logger.error("setAuth rejected: \(error.localizedDescription, privacy: .public)")
				} else {
					Self.logger.notice("setAuth stored a new session")
					self.nudge()
				}
				reply(error)
			}
		}

		/// Deleting auth.json is the cache's trusted disable: it stops serving, and wipes its
		/// on-disk state once the disable holds. The live socket is stopped first, so it does not
		/// keep applying events until the next re-read notices.
		func clearAuth(reply: @escaping (NSError?) -> Void) {
			Self.queue.async {
				self.state.stopLiveUpdates()
				guard let authFile = self.authFile else {
					Self.logger.error("clearAuth has no auth.json location")
					reply(nil)
					return
				}
				do {
					try FileManager.default.removeItem(at: authFile)
				} catch let error as CocoaError where error.code == .fileNoSuchFile {
					// Already disabled.
				} catch {
					Self.logger.error("clearAuth failed to remove auth.json: \(error)")
					reply(authServiceError(.writeFailed, "auth.json could not be removed"))
					return
				}
				Self.logger.notice("clearAuth removed the session")
				reply(nil)
			}
		}

		private func writeAuth(_ payload: Data) -> NSError? {
			guard payload.count <= Self.maxPayloadBytes else {
				return authServiceError(.payloadTooLarge, "auth payload exceeds 1 MiB")
			}
			let plaintext: Data
			do {
				let decoded = try JSONDecoder().decode(AuthFilePayload.self, from: payload)
				guard decoded.isValid else {
					return authServiceError(.invalidPayload, "auth payload is not a valid AuthFile")
				}
				plaintext = try JSONEncoder().encode(decoded)
			} catch {
				// The decoding error can quote the payload, so it is not passed on.
				return authServiceError(.invalidPayload, "auth payload is not a valid AuthFile")
			}
			guard self.dek.count == 32, let authFile = self.authFile else {
				return authServiceError(.keyUnavailable, "the auth key is unavailable")
			}
			do {
				guard
					let combined = try AES.GCM.seal(plaintext, using: SymmetricKey(data: self.dek))
						.combined
				else {
					return authServiceError(.writeFailed, "auth.json could not be sealed")
				}
				var sealed = Data(capacity: 1 + combined.count)
				sealed.append(Self.authFileVersion)
				sealed.append(combined)
				try FileManager.default.createDirectory(
					at: authFile.deletingLastPathComponent(), withIntermediateDirectories: true)
				// Atomic: the cache must never read a half-written file, which it would take for an
				// unreadable one.
				try sealed.write(to: authFile, options: .atomic)
			} catch {
				Self.logger.error("setAuth failed to write auth.json: \(error)")
				return authServiceError(.writeFailed, "auth.json could not be written")
			}
			return nil
		}

		/// Asks the system to come back now rather than after its own backoff: lifts the
		/// not-authenticated throttling and has it ask for the working set, whose first call makes
		/// the cache re-read auth.json. The gate opens first, or that call could still be answered
		/// from a signed-out verdict taken before the session landed.
		private func nudge() {
			guard let manager = self.manager else { return }
			let authGate = self.authGate
			Self.queue.asyncAfter(deadline: .now() + Self.nudgeDelay) {
				authGate.reopen()
				manager.signalErrorResolved(NSFileProviderError(.notAuthenticated)) { error in
					if let error { Self.logger.error("signalErrorResolved failed: \(error)") }
				}
				manager.signalEnumerator(for: .workingSet) { error in
					if let error { Self.logger.error("signalling the working set failed: \(error)") }
				}
			}
		}
	}
#endif
