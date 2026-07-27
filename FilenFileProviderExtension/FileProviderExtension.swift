import FileProvider
import Foundation
import Security
import UniformTypeIdentifiers
import os

let PROVIDER = "app.filen.io"
let BACKGROUND_ID = PROVIDER + ".background"

// auth.json DEK keychain item — these MUST match the app side (fileProvider.ts via expo-secure-store).
// The team-prefixed access group is what lets the app and this extension share the item; the app group
// alone does not grant keychain sharing on iOS. NOTE: expo-secure-store appends ":no-auth" to the
// service for items stored without requireAuthentication, so the keychain queries below use
// "\(AUTH_DEK_SERVICE):no-auth" to match the item the app actually wrote.
let AUTH_DEK_ACCESS_GROUP = "7YTW5D2K7P.io.filen.sharedkeys"
let AUTH_DEK_SERVICE = "io.filen.fileprovider"
let AUTH_DEK_ACCOUNT = "fileProviderAuthKey"

class FileProviderExtension: NSFileProviderExtension {
	private static let logger = Logger(subsystem: PROVIDER, category: "FileProvider")
	let state: FilenMobileCacheState
	// Lazily cached, and the system invokes the overrides below concurrently — so this needs the
	// same locking as the two sets underneath it, not a bare var.
	private let cachedRootUuid = OSAllocatedUnfairLock<String?>(initialState: nil)
	/// Attempts for an `itemChanged` upload before the edit is given up on. Three with exponential
	/// backoff covers a transient blip without keeping a suspended-at-any-moment extension busy.
	static let uploadAttempts = 3
	public static var uploadingSet = TransfersInFlight(initialState: [:])
	public static var downloadingSet = TransfersInFlight(initialState: [:])

	// MARK: - Working with items and persistent identifiers

	func getRootUuid() throws -> String {
		if let cached = self.cachedRootUuid.withLock({ $0 }) { return cached }
		// Fetched outside the lock: it can throw and hits the cache DB, and a duplicate fetch on a
		// cold race is harmless — both callers compute the same immutable root uuid.
		let uuid = try self.state.rootUuid()
		self.cachedRootUuid.withLock { $0 = uuid }
		return uuid
	}

	// Reads the 32-byte auth.json DEK from the shared Keychain access group. The app stores it
	// base64-encoded via expo-secure-store; decode it back to raw bytes for the Rust cache. On any
	// failure (not provisioned yet, or the item is unavailable before first unlock) return empty
	// Data, which makes the Rust decrypt fail -> AuthFile::default() -> unauthenticated (fail-closed).
	// Never crash init(): self.state is non-optional.
	// Reads the auth.json DEK from the shared keychain, or nil if absent. expo-secure-store stores the
	// account as the UTF-8 Data of the key (Data(key.utf8)), NOT a String — the keychain matches
	// attributes by exact type, so we query with the same Data or SecItemCopyMatching won't find the
	// item the app wrote.
	private static func readAuthDek() -> Data? {
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: "\(AUTH_DEK_SERVICE):no-auth",
			kSecAttrAccount as String: Data(AUTH_DEK_ACCOUNT.utf8),
			kSecAttrAccessGroup as String: AUTH_DEK_ACCESS_GROUP,
			kSecReturnData as String: true,
			kSecMatchLimit as String: kSecMatchLimitOne,
		]
		var item: CFTypeRef?
		let status = SecItemCopyMatching(query as CFDictionary, &item)
		guard status == errSecSuccess,
			let stored = item as? Data,
			let base64 = String(data: stored, encoding: .utf8),
			let dek = Data(base64Encoded: base64)
		else {
			if status != errSecItemNotFound {
				Self.logger.error("auth DEK read failed (status \(status))")
			}
			return nil
		}
		return dek
	}

	// Load-or-provision the DEK. The extension isn't domain-gated, so the system can construct it
	// BEFORE the app enables the provider and provisions the key; since the Rust cache captures the
	// key at construction but re-reads auth.json on a poll, an absent-then-appearing key would strand
	// the provider unauthenticated until its process restarts. Provisioning here (idempotent — the app
	// reuses the same item) guarantees a valid, stable key up front. The item is written in
	// expo-secure-store's exact format so the app reads the identical key. Any failure returns empty
	// Data -> Rust decrypt fails -> unauthenticated (fail-closed). Never crashes init().
	private static func loadAuthDek() -> Data {
		if let existing = readAuthDek() {
			return existing
		}

		var dek = Data(count: 32)
		let generated = dek.withUnsafeMutableBytes { pointer in
			SecRandomCopyBytes(kSecRandomDefault, 32, pointer.baseAddress!)
		}

		guard generated == errSecSuccess else {
			Self.logger.error("auth DEK generation failed")
			return Data()
		}

		let accountData = Data(AUTH_DEK_ACCOUNT.utf8)
		let addQuery: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: "\(AUTH_DEK_SERVICE):no-auth",
			kSecAttrGeneric as String: accountData,
			kSecAttrAccount as String: accountData,
			kSecAttrAccessGroup as String: AUTH_DEK_ACCESS_GROUP,
			kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
			kSecValueData as String: Data(dek.base64EncodedString().utf8),
		]
		let status = SecItemAdd(addQuery as CFDictionary, nil)

		if status == errSecSuccess {
			return dek
		}

		// The app provisioned it concurrently — read the winner so both sides share one key.
		if status == errSecDuplicateItem {
			return Self.readAuthDek() ?? Data()
		}

		Self.logger.error("auth DEK provision failed (status \(status))")
		return Data()
	}

	override init() {
		let authFile =
			FileManager.default.containerURL(
				forSecurityApplicationGroupIdentifier: "group.io.filen.app")?.appending(
					component: "auth.json"
				).path(percentEncoded: false) ?? ""
		// The SQLite files (native_cache.db, db_state.json, SDK search DB) live in the
		// EXTENSION'S private container, not in documentStorage: documentStorage sits inside
		// the shared app-group container, and iOS kills a process that is suspended while
		// holding a file/SQLite lock there (RUNNINGBOARD 0xdead10cc) — both DBs are WAL, which
		// holds a lock even while idle. Content files stay under documentStorage. DB files an
		// earlier build left there are deliberately abandoned (nothing opens those paths again);
		// the fresh location reinitializes and re-syncs the cache once. Failure to create the
		// dir here is non-fatal by design — the Rust side create_dir_all's it again.
		var dbDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
			.appending(component: "database")
		try? FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
		// Re-syncable cache, wiped on logout — keep it out of iCloud/local backups (a restored
		// stale DB would just fail auth decryption and be wiped anyway).
		var backupValues = URLResourceValues()
		backupValues.isExcludedFromBackup = true
		try? dbDir.setResourceValues(backupValues)
		self.state = FilenMobileCacheState.newWithDbDir(
			filesDir: NSFileProviderManager.default.documentStorageURL.path(percentEncoded: false),
			dbDir: dbDir.path(percentEncoded: false),
			authFile: authFile,
			dek: Self.loadAuthDek())
	}

	/// The identifier handed to the system for an object: the whole-life
	/// stable id for files and directories (identifiers must not change when
	/// an item is edited, moved, or renamed), `fallback` for the root.
	/// Static because this is the single place deciding that files key off their stable id and
	/// directories off their uuid — the whole-life-identity invariant. Keeping it free of `self`
	/// makes it directly testable.
	static func itemIdentifier(for object: FfiObject, fallback: String)
		-> NSFileProviderItemIdentifier
	{
		switch object {
		case .file(let ffiFile):
			return NSFileProviderItemIdentifier("stable/" + ffiFile.stableUuid)
		case .dir(let ffiDir):
			// dirs have no stable id on the wire, by design: stable == uuid
			return NSFileProviderItemIdentifier("stable/" + ffiDir.uuid)
		case .root(_): return NSFileProviderItemIdentifier(fallback)
		}
	}

	/// The identifier of the container an object lives in (the original parent
	/// while trashed). Containers are directories, whose stable id IS their
	/// uuid, so no cache lookup is needed. Falls back to path-splitting the
	/// item's own identifier, which preserves the legacy behavior for path ids.
	///
	/// `rootUuid` is passed in rather than read from `self` so the mapping is testable; nil simply
	/// means the root is unknown, in which case no identifier can be the root container.
	static func containerIdentifier(
		for object: FfiObject, fallbackFrom identifier: NSFileProviderItemIdentifier,
		rootUuid: String?
	) -> NSFileProviderItemIdentifier {
		guard let parentUuid = objectToContainerUuid(object: object) else {
			return getParentItemIdentifier(itemIdentifier: identifier)
		}
		if parentUuid == rootUuid { return .rootContainer }
		return NSFileProviderItemIdentifier("stable/" + parentUuid)
	}

	/// Instance convenience supplying the cached root uuid.
	func containerIdentifier(
		for object: FfiObject, fallbackFrom identifier: NSFileProviderItemIdentifier
	) -> NSFileProviderItemIdentifier {
		Self.containerIdentifier(
			for: object, fallbackFrom: identifier, rootUuid: try? self.getRootUuid())
	}

	override func persistentIdentifierForItem(at url: URL) -> NSFileProviderItemIdentifier? {
		guard let uuid = uuidFromCacheItemURL(url) else {
			Self.logger.error("not a cache item URL: \(url.path(percentEncoded: false))")
			return nil
		}
		do {
			// items persist under their stable id; the uuid lookup below also
			// resolves a superseded uuid left in a stale URL
			if let object = try self.state.queryItemByUuid(uuid: uuid) {
				switch object {
				case .file(_), .dir(_):
					return Self.itemIdentifier(for: object, fallback: uuid)
				case .root(_): break
				}
			}
			guard let path = try self.state.queryPathForUuid(uuid: uuid) else {
				Self.logger.error("no path for uuid \(uuid)")
				return nil
			}
			let id = NSFileProviderItemIdentifier(rawValue: path)
			return id
		} catch {
			Self.logger.error("error getting path for uuid \(uuid): \(error)")
			return nil
		}
	}

	override func urlForItem(withPersistentIdentifier identifier: NSFileProviderItemIdentifier)
		-> URL?
	{
		let object: FfiObject?

		do { object = try self.objectForId(identifier: identifier) } catch {
			Self.logger.error("error getting url for \(identifier.rawValue): \(error)")
			return nil
		}
		guard let object = object else {
			Self.logger.error("no url for item \(identifier.rawValue)")
			return nil
		}
		switch object {
		case .file(let item):
			return NSFileProviderManager.default.documentStorageURL.appending(
				path: "cache", directoryHint: .isDirectory
			).appending(path: item.uuid, directoryHint: .isDirectory).appending(
				component: item.meta?.name ?? item.uuid, directoryHint: .notDirectory)
		case .dir(let item):
			return NSFileProviderManager.default.documentStorageURL.appending(
				path: "cache", directoryHint: .isDirectory
			).appending(path: item.uuid, directoryHint: .isDirectory).appending(
				component: item.meta?.name ?? item.uuid, directoryHint: .isDirectory)
		case .root(let item):
			return NSFileProviderManager.default.documentStorageURL.appending(
				path: "cache", directoryHint: .isDirectory
			).appending(path: item.uuid, directoryHint: .isDirectory).appending(
				component: "root", directoryHint: .isDirectory)
		}
	}

	override func item(for identifier: NSFileProviderItemIdentifier) throws -> NSFileProviderItem {
		let object: FfiObject?
		do { object = try self.objectForId(identifier: identifier) } catch let cacheError
			as CacheError
		{ throw cacheErrorToError(error: cacheError) }
		guard let object = object else { throw NSFileProviderError(.noSuchItem) }
		return FileProviderItem(
			itemIdentifier: identifier, object: object,
			parentItemIdentifier: self.containerIdentifier(for: object, fallbackFrom: identifier))
	}

	override func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier) throws
		-> NSFileProviderEnumerator
	{
		do {
			return FileProviderEnumerator(
				enumeratedItemIdentifier: containerItemIdentifier, state: self.state,
				rootUuid: try self.getRootUuid())
		} catch let cacheError as CacheError { throw cacheErrorToError(error: cacheError) }
	}

	// MARK: - Managing shared files

	/// What to do with a locally changed item, once its path lookup has been attempted.
	enum ItemChangedResolution: Equatable {
		/// Resolved — upload from this path.
		case upload(String)
		/// The cache genuinely does not know this uuid. There is nothing to retry.
		case unknownItem
		/// The lookup itself failed, so we do not know whether the item exists. The edit must not
		/// be dropped silently — signal so the system asks again.
		case needsRetry
	}

	/// Splits "look the item up" from "act on it" so the failure handling is testable.
	///
	/// A failed lookup and a missing item are NOT the same: swallowing a thrown lookup error would
	/// strand a local edit with no upload and no retry signal, silently losing the user's change.
	static func resolveItemChanged(
		uuid: String, queryPath: (String) throws -> String?
	) -> ItemChangedResolution {
		do {
			guard let path = try queryPath(uuid) else { return .unknownItem }
			return .upload(path)
		} catch {
			return .needsRetry
		}
	}

	/// Runs an operation, retrying a bounded number of times; nil on success, else the last error.
	///
	/// A failed upload out of `itemChanged` is a lost user edit — nothing re-triggers
	/// `itemChanged`, and the working-set signal that would normally ask the system to re-examine
	/// the item does not work here (see the TODOs below). Retrying recovers transient failures, a
	/// dropped connection or a server blip, which are the common case. It cannot recover a
	/// permanent failure or a process death mid-retry; those still need working-set support.
	static func retrying(
		attempts: Int,
		operation: () async throws -> Void,
		onRetry: (Int) async -> Void = { _ in }
	) async -> Error? {
		var lastError: Error?
		for attempt in 1...max(1, attempts) {
			do {
				try await operation()
				return nil
			} catch {
				lastError = error
				if attempt < attempts { await onRetry(attempt) }
			}
		}
		return lastError
	}

	override func itemChanged(at url: URL) {
		guard let uuid = uuidFromCacheItemURL(url) else {
			Self.logger.error("not a cache item URL: \(url.path(percentEncoded: false))")
			return
		}
		let resolution = Self.resolveItemChanged(uuid: uuid) { uuid in
			try self.state.queryPathForUuid(uuid: uuid)
		}

		let path: String
		switch resolution {
		case .upload(let resolved):
			path = resolved
		case .unknownItem:
			Self.logger.error("no item found for uuid \(uuid)")
			return
		case .needsRetry:
			// TODO: there is no retry mechanism to reach for yet. Signalling the working set is
			// the idiomatic way to ask the system to re-examine items needing sync, but this
			// provider does not implement `enumerateChanges`, and the working set's sentinel is
			// not even a resolvable cache id — enumerating it throws (pinned by
			// CacheStableIdTests.testTheWorkingSetSentinelIsNotAResolvableCacheId). Signalling it
			// would only generate error noise, so log loudly and drop through until working-set
			// support lands.
			Self.logger.error("could not resolve uuid \(uuid), local edit not uploaded")
			return
		}

		Task {
			// A fresh notifier per attempt: each one holds its own slot and releases it on the way
			// out, so a retry re-marks the item as uploading.
			let failure = await Self.retrying(
				attempts: Self.uploadAttempts,
				operation: {
					let _ = try await self.state.uploadFileIfChanged(
						path: path,
						progressCallback: ProgressNotifier(set: Self.uploadingSet, uuid: uuid))
				},
				onRetry: { attempt in
					Self.logger.error("itemChanged upload attempt \(attempt) failed for \(uuid)")
					try? await Task.sleep(for: .seconds(1 << (attempt - 1)))
				})

			if let failure {
				// TODO: the retries are exhausted and there is nothing left to fall back on. The
				// idiomatic move is to signal the working set so the system re-examines the item,
				// but this provider does not implement `enumerateChanges` and the working set's
				// sentinel is not a resolvable cache id — enumerating it throws (pinned by
				// CacheStableIdTests.testTheWorkingSetSentinelIsNotAResolvableCacheId). Until that
				// lands, an edit that fails this many times is lost until the item changes again.
				Self.logger.error(
					"itemChanged upload failed for uuid \(uuid), not persisted: \(failure)")
			}
		}
	}

	override func providePlaceholder(at url: URL) async throws {
		guard let identifier = persistentIdentifierForItem(at: url) else {
			throw NSFileProviderError(.noSuchItem)
		}

		let placeholderDirectoryUrl = url.deletingLastPathComponent()
		let fileProviderItem = try item(for: identifier)
		let placeholderURL = NSFileProviderManager.placeholderURL(for: url)

		if !FileManager.default.fileExists(atPath: placeholderDirectoryUrl.path) {
			try FileManager.default.createDirectory(
				at: placeholderDirectoryUrl, withIntermediateDirectories: true)
		}

		try NSFileProviderManager.writePlaceholder(
			at: placeholderURL, withMetadata: fileProviderItem)
	}

	override func startProvidingItem(at url: URL) async throws {
		do {
			guard let uuid = uuidFromCacheItemURL(url) else {
				throw NSFileProviderError(.noSuchItem)
			}
			guard let obj = try self.state.queryItemByUuid(uuid: uuid) else {
				throw NSFileProviderError(.noSuchItem)
			}
			if case .file(_) = obj {
				let _ = try await self.state.downloadFileIfChangedByUuid(
					uuid: uuid,
					progressCallback: ProgressNotifier(set: Self.downloadingSet, uuid: uuid))
			}

		} catch let cacheError as CacheError { throw cacheErrorToError(error: cacheError) }
	}

	override func stopProvidingItem(at url: URL) {
		guard let uuid = uuidFromCacheItemURL(url) else {
			Self.logger.error("not a cache item URL: \(url.path(percentEncoded: false))")
			return
		}
		// KNOWN GAP: this detached Task is uncancellable and nothing orders it against a
		// subsequent download of the same uuid — `clear_local_cache_by_uuid` selects then deletes
		// with no per-uuid lock on the Rust side either (remote.rs:842). If the system stops
		// providing an item and immediately re-requests it, the clear can land after the fresh
		// download and evict it, and the next open re-downloads. Recoverable and transient, so it
		// is documented rather than worked around; the fix is per-uuid serialisation in the cache,
		// not here. Deliberately untested: any assertion about which of two unordered operations
		// wins would be flaky by construction.
		Task {
			do {
				try await self.state.clearLocalCacheByUuid(uuid: uuid)
			} catch {
				Self.logger.error("stopProvidingItem failed for uuid \(uuid): \(error)")
			}
		}
	}

	// MARK: - Handling actions
	override func createDirectory(
		withName directoryName: String,
		inParentItemIdentifier parentItemIdentifier: NSFileProviderItemIdentifier
	) async throws -> NSFileProviderItem {
		do {
			let path =
				if parentItemIdentifier == .rootContainer { try self.getRootUuid() } else {
					parentItemIdentifier.rawValue
				}
			let resp = try await self.state.createDir(
				parentPath: path, name: directoryName, created: nil)

			return FileProviderItem(
				itemIdentifier: Self.itemIdentifier(for: FfiObject.dir(resp.dir), fallback: resp.id),
				object: FfiObject.dir(resp.dir),
				parentItemIdentifier: parentItemIdentifier)
		} catch let cacheError as CacheError { throw cacheErrorToError(error: cacheError) }
	}

	override func deleteItem(withIdentifier itemIdentifier: NSFileProviderItemIdentifier)
		async throws
	{
		do { try await self.state.deleteItem(item: itemIdentifier.rawValue) } catch let cacheError
			as CacheError
		{ throw cacheErrorToError(error: cacheError) }
	}

	override func importDocument(
		at fileURL: URL, toParentItemIdentifier parentItemIdentifier: NSFileProviderItemIdentifier
	) async throws -> NSFileProviderItem {
		do {
			if !fileURL.startAccessingSecurityScopedResource() {
				throw NSFileProviderError(.noSuchItem)
			}
			defer { fileURL.stopAccessingSecurityScopedResource() }
			let parent =
				if parentItemIdentifier == .rootContainer { try self.getRootUuid() } else {
					parentItemIdentifier.rawValue
				}
			let resourceValues = try fileURL.resourceValues(forKeys: [
				.nameKey, .isDirectoryKey, .creationDateKey, .contentModificationDateKey,
				.typeIdentifierKey,
			])
			guard let name = resourceValues.name else {
				throw NSFileProviderError(.noSuchItem)
			}
			let creationInterval = resourceValues.creationDate?.timeIntervalSince1970
			let creationTimeStamp = creationInterval.map { Int64($0 * 1000) }

			let isDirectory = resourceValues.isDirectory ?? false
			let item: FileProviderItem
			if isDirectory {
				let info = try await self.state.createDir(
					parentPath: parent, name: name, created: creationTimeStamp)
				item = FileProviderItem(
					itemIdentifier: Self.itemIdentifier(
						for: FfiObject.dir(info.dir), fallback: info.id),
					object: FfiObject.dir(info.dir),
					parentItemIdentifier: parentItemIdentifier)
			} else {
				let modificationInterval = resourceValues.contentModificationDate?
					.timeIntervalSince1970
				let modificationTimeStamp = modificationInterval.map { Int64($0 * 1000) }
				let info = UploadFileInfo(
					name: name, creation: creationTimeStamp, modification: modificationTimeStamp,
					mime: resourceValues.typeIdentifier.flatMap { UTType($0)?.preferredMIMEType })
				let resp = try await self.state.uploadNewFile(
					osPath: fileURL.path(percentEncoded: false), parentPath: parent, info: info,
					progressCallback: nil)
				item = FileProviderItem(
					itemIdentifier: Self.itemIdentifier(
						for: FfiObject.file(resp.file), fallback: resp.id),
					object: FfiObject.file(resp.file),
					parentItemIdentifier: parentItemIdentifier)
			}
			return item
		} catch let cacheError as CacheError { throw cacheErrorToError(error: cacheError) }
	}

	override func renameItem(
		withIdentifier itemIdentifier: NSFileProviderItemIdentifier, toName itemName: String
	) async throws -> NSFileProviderItem {
		do {
			let resp = try await self.state.renameItem(
				item: itemIdentifier.rawValue, newName: itemName)
			guard let item = resp else { throw NSFileProviderError(.filenameCollision) }
			let identifier = Self.itemIdentifier(for: item.object, fallback: item.id)
			return FileProviderItem(
				itemIdentifier: identifier, object: item.object,
				parentItemIdentifier: self.containerIdentifier(
					for: item.object, fallbackFrom: identifier))
		} catch let cacheError as CacheError { throw cacheErrorToError(error: cacheError) }
	}

	/// Moves an item and optionally renames it, rolling the move back if the rename fails.
	///
	/// The two steps are separate server calls with no transaction between them. Without the
	/// rollback a failed rename reports total failure while the move has already committed, so the
	/// system keeps showing the item in its old container while the server has it in the new one.
	/// Compensating means a thrown error truthfully says "nothing changed".
	///
	/// Static, and taking `state`, so the sequence is testable without a FileProviderExtension.
	static func reparent(
		state: FilenMobileCacheState,
		itemIdentifier: NSFileProviderItemIdentifier,
		newParent: String,
		newName: String?,
		parentItemIdentifier: NSFileProviderItemIdentifier
	) async throws -> FileProviderItem {
		do {
			// Captured before the move so the rollback knows where to put the item back.
			let originalParent = (try? state.queryItem(path: itemIdentifier.rawValue))
				.flatMap { $0 }
				.flatMap { objectToContainerUuid(object: $0) }

			let resp = try await state.moveItem(item: itemIdentifier.rawValue, newParent: newParent)
			let moved = FileProviderItem(
				itemIdentifier: Self.itemIdentifier(for: resp.object, fallback: resp.id),
				object: resp.object,
				parentItemIdentifier: parentItemIdentifier)

			guard let newName = newName, moved.filename != newName else { return moved }

			do {
				guard let renamed = try await state.renameItem(item: resp.id, newName: newName)
				else { throw NSFileProviderError(.filenameCollision) }
				return FileProviderItem(
					itemIdentifier: Self.itemIdentifier(for: renamed.object, fallback: renamed.id),
					object: renamed.object,
					parentItemIdentifier: parentItemIdentifier)
			} catch {
				// Best effort: if the rollback itself fails there is nothing further to try, but
				// the original error is still the truthful one to report.
				if let originalParent {
					do {
						_ = try await state.moveItem(item: resp.id, newParent: originalParent)
					} catch let rollbackError {
						Self.logger.error(
							"reparent rollback failed, item left moved: \(rollbackError)")
					}
				}
				throw error
			}
		} catch let cacheError as CacheError { throw cacheErrorToError(error: cacheError) }
	}

	override func reparentItem(
		withIdentifier itemIdentifier: NSFileProviderItemIdentifier,
		toParentItemWithIdentifier parentItemIdentifier: NSFileProviderItemIdentifier,
		newName: String?
	) async throws -> NSFileProviderItem {
		let newParent =
			if parentItemIdentifier == .rootContainer { try self.getRootUuid() } else {
				parentItemIdentifier.rawValue
			}
		return try await Self.reparent(
			state: self.state, itemIdentifier: itemIdentifier, newParent: newParent,
			newName: newName, parentItemIdentifier: parentItemIdentifier)
	}

	override func setFavoriteRank(
		_ favoriteRank: NSNumber?, forItemIdentifier itemIdentifier: NSFileProviderItemIdentifier
	) async throws -> NSFileProviderItem {
		do {
			let resp = try await self.state.setFavoriteRank(
				item: itemIdentifier.rawValue, favoriteRank: favoriteRank?.int64Value ?? 0)
			let identifier = Self.itemIdentifier(for: resp.object, fallback: resp.id)
			return FileProviderItem(
				itemIdentifier: identifier, object: resp.object,
				parentItemIdentifier: self.containerIdentifier(
					for: resp.object, fallbackFrom: identifier))
		} catch let cacheError as CacheError { throw cacheErrorToError(error: cacheError) }
	}

	override func setTagData(
		_ tagData: Data?, forItemIdentifier itemIdentifier: NSFileProviderItemIdentifier
	) async throws -> NSFileProviderItem {
		// todo
		do {
			let stringData = tagData?.count ?? 0 > 0 ? tagData?.base64EncodedString() : nil
			let obj = try self.state.insertIntoLocalDataForPath(
				path: itemIdentifier.rawValue, key: "TagData", value: stringData)
			return FileProviderItem(
				itemIdentifier: itemIdentifier, object: obj,
				parentItemIdentifier: self.containerIdentifier(
					for: obj, fallbackFrom: itemIdentifier))
		} catch let cacheError as CacheError { throw cacheErrorToError(error: cacheError) }
	}

	override func trashItem(withIdentifier itemIdentifier: NSFileProviderItemIdentifier)
		async throws -> NSFileProviderItem
	{
		do {
			let resp = try await self.state.trashItem(path: itemIdentifier.rawValue)
			// signal the container the item vanished from — its ORIGINAL
			// parent, which the trash response still carries (a stable file
			// identifier has no path structure to split a parent out of)
			try await NSFileProviderManager.default.signalEnumerator(
				for: self.containerIdentifier(for: resp.object, fallbackFrom: itemIdentifier))

			return FileProviderItem(
				itemIdentifier: Self.itemIdentifier(for: resp.object, fallback: resp.id),
				object: resp.object,
				parentItemIdentifier: self.containerIdentifier(
					for: resp.object, fallbackFrom: itemIdentifier))
		} catch let cacheError as CacheError { throw cacheErrorToError(error: cacheError) }
	}

	override func untrashItem(
		withIdentifier itemIdentifier: NSFileProviderItemIdentifier,
		toParentItemIdentifier parentItemIdentifier: NSFileProviderItemIdentifier?
	) async throws -> NSFileProviderItem {
		do {
			let uuid =
				if let lastSlash = itemIdentifier.rawValue.lastIndex(of: "/") {
					String(
						itemIdentifier.rawValue[itemIdentifier.rawValue.index(after: lastSlash)...])
				} else { throw NSFileProviderError(.noSuchItem) }
			let target: String? =
				if let parentItemIdentifier = parentItemIdentifier {
					parentItemIdentifier == .rootContainer
						? try self.getRootUuid() : parentItemIdentifier.rawValue
				} else { nil }
			let resp = try await self.state.restoreItem(
				uuid: uuid, to: target)
			let identifier = Self.itemIdentifier(for: resp.object, fallback: resp.id)
			return FileProviderItem(
				itemIdentifier: identifier, object: resp.object,
				parentItemIdentifier: self.containerIdentifier(
					for: resp.object, fallbackFrom: identifier))
		} catch let cacheError as CacheError { throw cacheErrorToError(error: cacheError) }
	}

	// MARK: - Accessing thumbnails

	// pretend @Sendable isn't a problem here in Swift 6,
	// uniffi requires that exposed traits be Send + Sync
	// so there is no other way to do this
	// this doesn't seem to have caused issues
	// but I do wish apple would fix this API becuase there's no reason
	// these shouldn't be @Sendable
	override func fetchThumbnails(
		for itemIdentifiers: [NSFileProviderItemIdentifier], requestedSize size: CGSize,
		perThumbnailCompletionHandler: @Sendable @escaping (
			NSFileProviderItemIdentifier, Data?, Error?
		) -> Void, completionHandler: @Sendable @escaping (Error?) -> Void
	) -> Progress {
		Self.logger.debug("fetchThumbnails for \(itemIdentifiers.count) items")
		let progress = Progress(totalUnitCount: Int64(itemIdentifiers.count))
		let fetchHandler = FetchThumbnailHandler(
			perThumbnailCompletionHandler: perThumbnailCompletionHandler,
			completionHandler: completionHandler, progress: progress)
		do {
			let thumbnailTask = try self.state.getThumbnails(
				items: itemIdentifiers.map { $0.rawValue }, requestedWidth: UInt32(size.width),
				requestedHeight: UInt32(size.height), callback: fetchHandler)
			progress.cancellationHandler = { thumbnailTask.cancel() }
		} catch let error {
			// getThumbnails should throw a CacheError, but guard against any
			// other error type so we never force-crash the extension
			if let cacheError = error as? CacheError {
				completionHandler(cacheErrorToError(error: cacheError))
			} else {
				completionHandler(error)
			}
		}
		return progress
	}

	// MARK: - Working with services

	override func supportedServiceSources(for itemIdentifier: NSFileProviderItemIdentifier) throws
		-> [NSFileProviderServiceSource]
	{ [] }

	func objectForId(identifier: NSFileProviderItemIdentifier) throws -> FfiObject? {
		do {
			let path =
				switch identifier {
				case NSFileProviderItemIdentifier.rootContainer: try self.getRootUuid()
				case NSFileProviderItemIdentifier.trashContainer: "trash"
				default: identifier.rawValue
				}

			return try self.state.queryItem(path: path)
		} catch let cacheError as CacheError { throw cacheErrorToError(error: cacheError) }
	}
}
