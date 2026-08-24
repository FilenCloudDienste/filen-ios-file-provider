import FileProvider
import Foundation
import Security
import UniformTypeIdentifiers
import os

let PROVIDER = "app.filen.io"

// auth.json DEK keychain item — these MUST match the app side (fileProvider.ts via expo-secure-store).
// The team-prefixed access group is what lets the app and this extension share the item; the app group
// alone does not grant keychain sharing on iOS. NOTE: expo-secure-store appends ":no-auth" to the
// service for items stored without requireAuthentication, so the keychain queries below use
// "\(AUTH_DEK_SERVICE):no-auth" to match the item the app actually wrote.
let AUTH_DEK_ACCESS_GROUP = "7YTW5D2K7P.io.filen.sharedkeys"
let AUTH_DEK_SERVICE = "io.filen.fileprovider"
let AUTH_DEK_ACCOUNT = "fileProviderAuthKey"

/// Runs the first block handed to it and drops every later one.
///
/// Each File Provider call must answer its completion handler exactly once, and two paths race to
/// do it: the task body, and the `Progress` cancellation handler, which the framework requires to
/// answer the call itself ("If the NSProgress returned by this method is cancelled, the extension
/// should call the completion handler with (... NSUserCancelledError) in the NSProgress
/// cancellation handler." — NSFileProviderReplicatedExtension.h). Whichever gets here first wins.
final class CallOnce: Sendable {
	private let spent = OSAllocatedUnfairLock<Bool>(initialState: false)

	func fire(_ body: () -> Void) {
		let alreadySpent = self.spent.withLock { spent -> Bool in
			if spent { return true }
			spent = true
			return false
		}
		guard !alreadySpent else { return }
		body()
	}
}

/// The work the system is waiting on, so `invalidate()` can drop it.
///
/// Every call the framework makes hands back a `Progress`; cancelling it answers that one call and
/// cancels its task, and cancelling the extension does the same for all of them. Nothing here
/// retains the extension: the task bodies capture what they need themselves.
///
/// UniFFI has no cancellation hook — a Rust future cannot be cancelled from Swift — so the three
/// calls that move bytes take an abort signal instead and give up on it in band. Handing `run` the
/// controller is what wires that up: both cancellation paths trip it, so the transfer really stops
/// rather than being abandoned while it keeps running against the server.
///
/// Everything else — the metadata calls, the working-set refresh — has no signal to hand in and
/// still runs to completion when its call is cancelled. That is deliberate and safe under v1's
/// server-wins policy: the change was already on disk, which is the state the drive is being caught
/// up to, and an upload whose completion nobody is waiting for is still recorded by the cache's
/// pending-upload marker, so the launch drain finishes the job if the process dies first.
final class InFlightWork: Sendable {
	private struct Work: Sendable {
		let task: Task<Void, Never>
		/// Answers the system's completion handler with `NSUserCancelledError`, through the same
		/// `CallOnce` the task body answers through — so whichever happens first is the only one.
		let cancel: @Sendable () -> Void
		/// The Rust side of the same cancellation, for an operation that took a signal.
		let abort: FfiAbortController?
	}

	private let running = OSAllocatedUnfairLock<[UUID: Work]>(initialState: [:])

	/// Runs `body` as a task the system can cancel through `progress`, and hands `progress` back
	/// so the caller can return it verbatim. `onCancel` answers the call being cancelled, and
	/// `abort` — the controller whose signal `body` handed to the cache — stops the Rust work.
	@discardableResult
	func run(
		_ progress: Progress, onCancel: @escaping @Sendable () -> Void = {},
		abort: FfiAbortController? = nil,
		_ body: @escaping () async -> Void
	) -> Progress {
		let id = UUID()
		let running = self.running
		// Registered under the lock rather than after starting the task: a task that finished
		// before the insert landed would leave its own entry behind forever.
		let task = running.withLock { work -> Task<Void, Never> in
			let task = Task {
				await body()
				running.withLock { $0[id] = nil }
			}
			work[id] = Work(task: task, cancel: onCancel, abort: abort)
			return task
		}
		progress.cancellationHandler = {
			onCancel()
			abort?.abort()
			task.cancel()
		}
		return progress
	}

	/// Registers work this class does not drive — a call whose completion arrives through a
	/// callback rather than an `async` body, which `run` cannot model. `cancel` runs on
	/// `cancelAll` exactly as a task's would; the returned closure deregisters it and MUST be
	/// called when the work finishes, or the entry outlives it.
	func register(cancel: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
		let id = UUID()
		let running = self.running
		running.withLock { $0[id] = Work(task: Task {}, cancel: cancel, abort: nil) }
		return { running.withLock { $0[id] = nil } }
	}

	func cancelAll() {
		for work in running.withLock({ work in
			let all = work
			work = [:]
			return all
		}).values {
			work.cancel()
			work.abort?.abort()
			work.task.cancel()
		}
	}
}

/// Passes the cache's "something in your working set moved" on to the system.
///
/// Tracking lands a change in the cache on its own schedule — nobody is waiting on a call when it
/// happens — so this signal is the only way the system learns to come and ask for the diff.
/// Best-effort by design: a failed signal costs freshness until the next enumeration, never
/// correctness, so it is logged and dropped.
final class WorkingSetSignaller: WorkingSetUpdateListener, @unchecked Sendable {
	private static let logger = Logger(subsystem: PROVIDER, category: "FileProvider")
	/// How long after a signal further changes ride the same window. Every signal costs the
	/// system an `enumerateChanges` round trip, and a burst — a bulk upload landing on another
	/// device, one socket event per file — is ONE thing to tell it about, not fifty.
	private static let coalesceDelay: UInt64 = 2_000_000_000
	private let manager: NSFileProviderManager?
	private enum Window {
		case closed
		case open
		case openWithJoiners
	}
	/// Where the suppression window stands. Signalling is leading-edge: the common case is one
	/// isolated change after a quiet period, and making it sit out the window is pure added
	/// latency — worse, a wait the extension does not survive loses the signal outright, because
	/// the watermark advanced at apply time and the relaunch gap-check sees no gap to re-signal.
	/// So the first change signals immediately and opens the window; a change that lands while
	/// it is open JOINS it instead of replacing it — the cancel-and-reschedule shape
	/// `materializedItemsDidChange` uses is fine for a callback stream that ends, but here it
	/// would starve: a steady event stream never pauses long enough for the delay to elapse, and
	/// the system would learn nothing until the stream stopped. A window that closes with
	/// joiners in it signals once more and stays open, so a stream is reported once per window;
	/// every transition happens before the send it decides on is awaited, so a change landing
	/// during a send either marks a window that is still open — which flushes it — or finds the
	/// window closed and opens its own. Neither path can drop it.
	private let window = OSAllocatedUnfairLock<Window>(initialState: .closed)

	init(manager: NSFileProviderManager?) {
		self.manager = manager
	}

	func workingSetChanged() {
		guard let manager = self.manager else { return }
		let opened = self.window.withLock { window -> Bool in
			switch window {
			case .closed:
				window = .open
				return true
			case .open:
				window = .openWithJoiners
				return false
			case .openWithJoiners:
				return false
			}
		}
		guard opened else { return }
		Task {
			await Self.signal(manager)
			while true {
				try? await Task.sleep(nanoseconds: Self.coalesceDelay)
				let joined = self.window.withLock { window -> Bool in
					switch window {
					case .openWithJoiners:
						window = .open
						return true
					case .open, .closed:
						window = .closed
						return false
					}
				}
				guard joined else { return }
				await Self.signal(manager)
			}
		}
	}

	private static func signal(_ manager: NSFileProviderManager) async {
		do {
			try await manager.signalEnumerator(for: .workingSet)
		} catch {
			Self.logger.error("signalling the working set failed: \(error)")
		}
	}
}

/// Collects one page of an enumeration into an array, resuming a continuation with the items and
/// the page to continue from. Drives `enumeratorForMaterializedItems` (see
/// `reportMaterializedContainers`); the system delivers a page's callbacks serially, which is
/// what makes the bare `var` safe.
private final class MaterializedPageObserver: NSObject, NSFileProviderEnumerationObserver,
	@unchecked Sendable
{
	private let continuation:
		CheckedContinuation<(items: [NSFileProviderItem], next: NSFileProviderPage?), Error>
	private var items: [NSFileProviderItem] = []

	init(
		continuation: CheckedContinuation<
			(items: [NSFileProviderItem], next: NSFileProviderPage?), Error
		>
	) {
		self.continuation = continuation
	}

	func didEnumerate(_ updatedItems: [NSFileProviderItem]) {
		self.items.append(contentsOf: updatedItems)
	}

	func finishEnumerating(upTo nextPage: NSFileProviderPage?) {
		self.continuation.resume(returning: (self.items, nextPage))
	}

	func finishEnumeratingWithError(_ error: Error) {
		self.continuation.resume(throwing: error)
	}
}

final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension,
	NSFileProviderThumbnailing
{
	private static let logger = Logger(subsystem: PROVIDER, category: "FileProvider")
	/// Longest side we will ever ask the cache to produce, whatever the system
	/// requests. See `fetchThumbnails` for why the request cannot be honoured
	/// literally; 256 matches what other providers ship and is comfortably
	/// above what any icon in Files.app actually draws.
	private static let maxThumbnailPixels: CGFloat = 256
	let state: FilenMobileCacheState
	/// The domain's own manager. It owns the temporary directory downloaded content is staged
	/// through, which has to be on the same volume as the replica for the system to clone from it.
	private let manager: NSFileProviderManager?
	// Lazily cached, and the system invokes the methods below concurrently — so this needs the
	// same locking as the two sets underneath it, not a bare var.
	private let cachedRootUuid = OSAllocatedUnfairLock<String?>(initialState: nil)
	private let inFlight = InFlightWork()
	/// The debounced re-drain `materializedItemsDidChange` schedules; replaced (and the old one
	/// cancelled) on every callback, so a burst coalesces into one drain.
	private let materializedRedrain = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
	/// Attempts for a content upload before the edit is given up on. Three with exponential
	/// backoff covers a transient blip without keeping a suspended-at-any-moment extension busy.
	static let uploadAttempts = 3
	public static var uploadingSet = TransfersInFlight(initialState: [:])
	public static var downloadingSet = TransfersInFlight(initialState: [:])

	// MARK: - Identity

	func getRootUuid() throws -> String {
		if let cached = self.cachedRootUuid.withLock({ $0 }) { return cached }
		// Fetched outside the lock: it can throw and hits the cache DB, and a duplicate fetch on a
		// cold race is harmless — both callers compute the same immutable root uuid.
		let uuid = try self.state.rootUuid()
		self.cachedRootUuid.withLock { $0 = uuid }
		return uuid
	}

	/// The cache id an identifier names. The system's two container sentinels have cache forms of
	/// their own; every other identifier this provider issues is already one (`stable/<id>`).
	static func cacheId(for identifier: NSFileProviderItemIdentifier, rootUuid: String) -> String {
		switch identifier {
		case .rootContainer: return rootUuid
		case .trashContainer: return TRASH_CACHE_ID
		default: return identifier.rawValue
		}
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
	/// while trashed — the system ignores the parent of a trashed item and reads
	/// `isTrashed` instead). Containers are directories, whose stable id IS their
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

	// MARK: - Lifecycle

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

	required init(domain: NSFileProviderDomain) {
		let manager = NSFileProviderManager(for: domain)
		self.manager = manager
		let authFile =
			FileManager.default.containerURL(
				forSecurityApplicationGroupIdentifier: "group.io.filen.app")?.appending(
					component: "auth.json"
				).path(percentEncoded: false) ?? ""
		// The SQLite files (native_cache.db, db_state.json, SDK search DB) live in the
		// EXTENSION'S private container, not in documentStorage: documentStorage sits inside
		// the shared app-group container, and iOS kills a process that is suspended while
		// holding a file/SQLite lock there (RUNNINGBOARD 0xdead10cc) — both DBs are WAL, which
		// holds a lock even while idle. Content files stay under the app group. DB files an
		// earlier build left elsewhere are deliberately abandoned (nothing opens those paths
		// again); the fresh location reinitializes and re-syncs the cache once. Failure to
		// create the dir here is non-fatal by design — the Rust side create_dir_all's it again.
		//
		// Keyed BY DOMAIN: every domain instance the process hosts gets its own database. With a
		// shared path, two instances (e.g. the legacy default-domain instance the removed
		// NSExtensionFileProviderDocumentGroup plist key used to invite) raced init_db's
		// unlink-and-recreate against each other's live WAL connection at construction — and one
		// instance's unauthenticated cleanup could delete the other's live database.
		let legacyDbDir = FileManager.default.urls(
			for: .applicationSupportDirectory, in: .userDomainMask)[0]
			.appending(component: "database")
		var dbDir = legacyDbDir.appending(component: domain.identifier.rawValue)
		try? FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
		// One-time cleanup: builds before the per-domain split kept the database directly under
		// database/, OUTSIDE the (per-domain) logout wipe's reach — and a leftover -wal carries
		// the most recent decrypted names, which must not outlive a logout. Best-effort; gone
		// means done.
		for legacyFile in [
			"native_cache.db", "native_cache.db-wal", "native_cache.db-shm", "db_state.json",
			"sdk_search_cache.db", "sdk_search_cache.db-wal", "sdk_search_cache.db-shm",
		] {
			try? FileManager.default.removeItem(at: legacyDbDir.appending(component: legacyFile))
		}
		// Re-syncable cache, wiped on logout — keep it out of iCloud/local backups (a restored
		// stale DB would just fail auth decryption and be wiped anyway).
		var backupValues = URLResourceValues()
		backupValues.isExcludedFromBackup = true
		try? dbDir.setResourceValues(backupValues)
		// The download cache keeps living in the app group, where the app can reach it too — at
		// the exact path the legacy NSExtensionFileProviderDocumentGroup key used to derive
		// (documentStorage = <group container>/File Provider Storage), so existing content
		// caches survive; spelled explicitly because that plist key is gone (see the dbDir
		// comment above for why it had to go). It is this provider's own storage, not what the
		// system serves from: a replicated extension hands content to the system by staging a
		// copy (see `stagedContents`).
		let groupContainer = FileManager.default.containerURL(
			forSecurityApplicationGroupIdentifier: "group.io.filen.app")
		if groupContainer == nil {
			Self.logger.error("app group container unavailable; content cache falls back to tmp")
		}
		let filesDir =
			groupContainer?.appending(component: "File Provider Storage")
			?? FileManager.default.temporaryDirectory.appending(component: "File Provider Storage")
		self.state = FilenMobileCacheState.newWithDbDir(
			filesDir: filesDir.path(percentEncoded: false),
			dbDir: dbDir.path(percentEncoded: false),
			authFile: authFile,
			dek: Self.loadAuthDek())

		super.init()

		// Registered before anything else asks the cache for work: from here on, a tracked file
		// that changes on the drive reaches the system without the system having asked.
		self.state.setWorkingSetListener(listener: WorkingSetSignaller(manager: manager))

		// An edit whose upload failed stays marked in the cache, and nothing drains those markers
		// on its own. This process is the only thing that reliably runs after a failure, so drain
		// on the way up. Registered as in-flight work so a discarded instance lets go of it; a
		// slow drain must not delay the first operation the system asks for, hence no await.
		let state = self.state
		self.inFlight.run(Progress()) {
			do {
				let uploaded = try await state.retryPendingUploads()
				if uploaded > 0 {
					Self.logger.info("Recovered \(uploaded) pending upload(s) on launch")
					// The recovered versions are new to the system: the working set is how a
					// replicated provider says so.
					try await manager?.signalEnumerator(for: .workingSet)
				}
			} catch {
				Self.logger.error("Draining pending uploads failed: \(error)")
			}
		}

		// Report the containers the system holds materialized — the directories it will never
		// re-enumerate on its own, whose contents the cache's live path is therefore responsible
		// for keeping fresh through the working set. Fire-and-forget for the same reason as the
		// drain above; failures keep the cache's last-known (persisted) set.
		self.inFlight.run(Progress()) { [weak self] in
			await self?.reportMaterializedContainers()
		}
	}

	func invalidate() {
		self.inFlight.cancelAll()
		self.materializedRedrain.withLock { pending in
			pending?.cancel()
			pending = nil
		}
		// A discarded extension must not leave its socket subscription applying in the
		// background; the next instance's auth brings the live path back up and rebuilds
		// everything from the database, so nothing is lost. The listener goes too — its manager
		// belongs to this instance.
		self.state.stopLiveUpdates()
		self.state.setWorkingSetListener(listener: nil)
	}

	// MARK: - Materialized set

	/// Drains `enumeratorForMaterializedItems` and hands the cache the set of materialized
	/// CONTAINERS. Filtered to folders here: the materialized set holds every downloaded FILE
	/// too, and each unknown id costs the cache a guaranteed-404 `get_dir` probe on the
	/// post-wipe path. Wholesale replace on the Rust side, so this is idempotent and a missed
	/// callback self-heals on the next drain. A failed page aborts WITHOUT reporting — a partial
	/// set would silently drop containers from freshness; the cache keeps its last-known set.
	private func reportMaterializedContainers() async {
		guard let manager = self.manager else { return }
		let enumerator = manager.enumeratorForMaterializedItems()
		var containers: [String] = []
		var page: NSFileProviderPage? = NSFileProviderPage(rawValue: Data())
		while let current = page {
			let result: (items: [NSFileProviderItem], next: NSFileProviderPage?)
			do {
				result = try await withCheckedThrowingContinuation { continuation in
					enumerator.enumerateItems(
						for: MaterializedPageObserver(continuation: continuation),
						startingAt: current)
				}
			} catch {
				Self.logger.error("draining the materialized set failed: \(error)")
				return
			}
			for item in result.items {
				let identifier = item.itemIdentifier
				// The sentinels are not containers of ours; the root is injected by the cache
				// unconditionally.
				guard identifier != .rootContainer, identifier != .trashContainer,
					identifier != .workingSet
				else { continue }
				guard (item.contentType ?? nil) == .folder else { continue }
				containers.append(identifier.rawValue)
			}
			page = result.next
		}
		do {
			try await self.state.setMaterializedContainers(ids: containers)
			Self.logger.info("reported \(containers.count) materialized container(s)")
		} catch {
			Self.logger.error("reporting the materialized containers failed: \(error)")
		}
	}

	/// The system's cue that its materialized set moved, in either direction. Answered
	/// immediately and acted on as a debounced timed task, exactly as the header prescribes
	/// ("set a flag and perform any resulting work as a timed task"); the work is always a full
	/// re-drain + wholesale replace — idempotent, one code path, self-healing.
	func materializedItemsDidChange(completionHandler: @escaping () -> Void) {
		completionHandler()
		let task = Task { [weak self] in
			try? await Task.sleep(nanoseconds: 2_000_000_000)
			guard !Task.isCancelled else { return }
			await self?.reportMaterializedContainers()
		}
		self.materializedRedrain.withLock { pending in
			pending?.cancel()
			pending = task
		}
	}

	// MARK: - Reading items

	/// The item an identifier names: the cache first, the server only when the cache has never
	/// heard of it.
	///
	/// Static, and taking `state`, so it is testable without a FileProviderExtension — which
	/// cannot be constructed outside the extension process.
	static func resolveItem(
		state: FilenMobileCacheState, identifier: NSFileProviderItemIdentifier, rootUuid: String
	) async throws -> NSFileProviderItem {
		// The trash is a container the cache has no row for — it is reachable only through the
		// dedicated trash API — so the system's view of it is synthesized here.
		if identifier == .trashContainer { return TrashContainerItem() }
		// The working set is computed, not held: the sentinel is not even a resolvable cache id
		// (CacheStableIdTests.testTheWorkingSetSentinelIsNotAResolvableCacheId pins that the cache
		// rejects it outright). Left to fall through it reads as a miss, and a miss answers
		// `.noSuchItem` — which for the working set means "the item has been removed from the
		// domain and [the system] will attempt to delete it from disk"
		// (NSFileProviderReplicatedExtension.h). A transient failure is the honest answer: there is
		// nothing to look up, and a retry costs nothing.
		if identifier == .workingSet {
			throw transientError("the working set is a computed set, not an item")
		}

		let id = cacheId(for: identifier, rootUuid: rootUuid)
		var object: FfiObject?
		do {
			object = try state.queryItem(path: id)
		} catch CacheError.DoesNotExist(_) {
			// An id naming no local row is a miss, not a failure: the server may still have it.
			object = nil
		}
		if object == nil { object = try await state.updateAndQueryItem(id: id) }

		guard let object else { throw NSFileProviderError(.noSuchItem) }
		return FileProviderItem(
			itemIdentifier: identifier, object: object,
			parentItemIdentifier: containerIdentifier(
				for: object, fallbackFrom: identifier, rootUuid: rootUuid))
	}

	func item(
		for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
		completionHandler: @escaping (NSFileProviderItem?, (any Error)?) -> Void
	) -> Progress {
		let state = self.state
		let answer = CallOnce()
		return self.inFlight.run(
			Progress(),
			onCancel: { answer.fire { completionHandler(nil, userCancelledError()) } }
		) { [weak self] in
			do {
				guard let self else { throw CancellationError() }
				let rootUuid = try self.getRootUuid()
				let item = try await Self.resolveItem(
					state: state, identifier: identifier, rootUuid: rootUuid)
				answer.fire { completionHandler(item, nil) }
			} catch {
				answer.fire { completionHandler(nil, providerError(from: error)) }
			}
		}
	}

	/// A copy of `path` the system may take ownership of.
	///
	/// The system "clones and unlinks the received fileContents" (NSFileProviderReplicatedExtension.h,
	/// File ownership), so handing over the cache slot itself would evict the download the moment
	/// it is served. The copy goes in the domain's temporary directory because that is the only
	/// place guaranteed to be on the replica's volume, which is what lets the system clone it.
	private func stagedContents(at path: String) throws -> URL {
		guard let manager = self.manager else { throw NSFileProviderError(.cannotSynchronize) }
		let directory = try manager.temporaryDirectoryURL()
		let staged = directory.appending(component: UUID().uuidString, directoryHint: .notDirectory)
		try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: staged)
		// ponytail: a crash between here and the system's unlink leaks this copy; sweeping the
		// directory on init would race a second instance of the same domain staging into it.
		// Revisit with a mtime-gated sweep if the leak ever shows up in disk usage.
		return staged
	}

	func fetchContents(
		for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?,
		request: NSFileProviderRequest,
		completionHandler: @escaping (URL?, NSFileProviderItem?, (any Error)?) -> Void
	) -> Progress {
		let state = self.state
		let progress = Progress()
		let answer = CallOnce()
		let abort = FfiAbortController()
		return self.inFlight.run(
			progress,
			onCancel: { answer.fire { completionHandler(nil, nil, userCancelledError()) } },
			abort: abort
		) { [weak self] in
			do {
				// A nil `self` is this instance being discarded mid-call, not a fact about the
				// item: `.noSuchItem` here would have the system delete it from disk. A cancelled
				// operation is transient, which is what it actually was.
				guard let self else { throw CancellationError() }
				let rootUuid = try self.getRootUuid()
				let id = Self.cacheId(for: itemIdentifier, rootUuid: rootUuid)
				let response = try await state.downloadFileIfChangedWithItem(
					id: id,
					progressCallback: ProgressNotifier(
						set: Self.downloadingSet, id: itemIdentifier.rawValue, progress: progress),
					abort: abort.signal())
				let object = FfiObject.file(response.file)
				// Known, accepted race: the download holds the item's per-file lock only for as
				// long as it runs, so the lock is gone by the time this copy starts. A
				// `modifyFileContent` landing in that window uploads the edit and renames the slot
				// under the freshly minted uuid, and the copy then cannot find the path it was
				// handed. What surfaces is a plain Cocoa not-found, which is not an
				// `NSFileProviderError` — so the system retries the fetch rather than acting on it,
				// and a retry is the right answer: the item really did move. Closing it means
				// staging Rust-side instead: a download variant that copies into the domain's
				// temporary directory while it still holds the lock and hands back that path.
				// Deferred deliberately — a retried fetch costs one round trip, and the FFI half is
				// the larger part of the fix.
				let staged = try self.stagedContents(at: response.path)
				let item = FileProviderItem(
					itemIdentifier: itemIdentifier, object: object,
					parentItemIdentifier: Self.containerIdentifier(
						for: object, fallbackFrom: itemIdentifier, rootUuid: rootUuid))
				answer.fire { completionHandler(staged, item, nil) }
			} catch {
				answer.fire { completionHandler(nil, nil, providerError(from: error)) }
			}
		}
	}

	// MARK: - Writing items

	/// Whether a create template describes a directory rather than a file.
	///
	/// Conformance to `.directory`, not `.folder`: a package (`com.apple.package` — .rtfd, .key,
	/// .app) is a directory on disk that conforms to `public.directory` but NOT to `public.folder`.
	/// Taken for a file it arrives with nil contents, is created as an empty file, and syncs as a
	/// 0-byte item whose children then have nowhere to be created.
	static func createsDirectory(contentType: UTType?) -> Bool {
		contentType?.conforms(to: .directory) ?? false
	}

	func createItem(
		basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields,
		contents url: URL?, options: NSFileProviderCreateItemOptions,
		request: NSFileProviderRequest,
		completionHandler: @escaping (
			NSFileProviderItem?, NSFileProviderItemFields, Bool, (any Error)?
		) -> Void
	) -> Progress {
		let state = self.state
		let progress = Progress()
		let answer = CallOnce()
		let abort = FfiAbortController()
		return self.inFlight.run(
			progress,
			onCancel: { answer.fire { completionHandler(nil, [], false, userCancelledError()) } },
			abort: abort
		) { [weak self] in
			do {
				// Discarded mid-call. Transient, not an answer about the item.
				guard let self else { throw CancellationError() }
				let rootUuid = try self.getRootUuid()
				let parentIdentifier = itemTemplate.parentItemIdentifier
				let parent = Self.cacheId(for: parentIdentifier, rootUuid: rootUuid)
				let name = itemTemplate.filename
				// Optional-of-optional throughout: every one of these is an @optional protocol member on an
				// existential, so the value is `T??` — absent because the item does not implement it, or
				// implemented and nil.
				let created = (itemTemplate.creationDate ?? nil).map {
					Int64($0.timeIntervalSince1970 * 1000)
				}
				let contentType = itemTemplate.contentType ?? nil

				var object: FfiObject
				// Whether the system should re-fetch the item's contents after this create — set
				// on the adopt path below when the local copy's bytes cannot be assumed to match
				// the adopted server head.
				var fetchContents = false
				// Placing the item is all any branch has in common; what else it carries over
				// depends on the call it makes. Whatever is left of `fields` comes back as
				// stillPendingFields, which is how the system learns what this provider cannot
				// carry: "If the provider is not able to apply all the fields at once, it should
				// return a set of stillPendingFields in its completion handler."
				var applied: NSFileProviderItemFields = [.filename, .parentItemIdentifier]
				if Self.createsDirectory(contentType: contentType) {
					object = .dir(
						try await state.createDir(parentPath: parent, name: name, created: created)
							.dir)
					applied.insert(.creationDate)
				} else if let url {
					// A reimport with contents (backup restore, device migration, fileproviderd
					// rebuild — the system re-creates ALL cached-on-disk items this way, clean
					// ones included): ADOPT the existing server item for this (parent, name)
					// instead of uploading. Uploading replaced the server head with whatever
					// bytes this replica happened to hold — a stale-but-clean replica silently
					// rolled back every edit made elsewhere. The system reconciles contents
					// itself once it has the adopted item; genuinely dirty local bytes still
					// reach the server through its own conflict handling. Only when the server
					// has no such item is the local copy the only copy, and uploading it is
					// exactly right.
					var adopted: FfiObject?
					if options.contains(.mayAlreadyExist) {
						switch try await state.updateAndQueryChild(parent: parent, name: name) {
						case .file(let existing):
							// Divergence check before trusting the local bytes as the adopted
							// head's content: a size mismatch defers to the server; matching
							// sizes compare the server's plaintext BLAKE3 against the local
							// file's (size equality alone would mislabel a same-length edit);
							// and no server hash re-fetches — the safe direction.
							let localSize =
								(try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
								?? nil
							if localSize.map({ Int64($0) != existing.size }) ?? true {
								fetchContents = true
							} else if let serverHash = existing.meta?.hash {
								let localHash = try await state.blake3HashFile(
									osPath: url.path(percentEncoded: false))
								fetchContents = localHash != serverHash
							} else {
								fetchContents = true
							}
							adopted = .file(existing)
						case .dir(let existingDir):
							// The name belongs to a DIRECTORY server-side now. Falling through
							// to the upload planted a same-named file next to the real folder
							// (the server's name dedup is per item type) from possibly-stale
							// bytes, silently. A collision carrying the colliding ITEM is the
							// header-prescribed answer ("use fileProviderErrorForCollision"),
							// so the system can resolve against it.
							throw NSError.fileProviderErrorForCollision(
								with: FileProviderItem(
									itemIdentifier: Self.itemIdentifier(
										for: .dir(existingDir), fallback: parent),
									object: .dir(existingDir),
									parentItemIdentifier: parentIdentifier))
						case .root:
							// A root can never legitimately answer a child-name probe; treat it
							// as a plain collision (there is no representable colliding item).
							throw NSFileProviderError(.filenameCollision)
						case nil:
							break
						}
					}
					if let adopted {
						object = adopted
						applied.formUnion([.contents, .creationDate, .contentModificationDate])
					} else {
						let modified = (itemTemplate.contentModificationDate ?? nil).map {
							Int64($0.timeIntervalSince1970 * 1000)
						}
						let info = UploadFileInfo(
							name: name, creation: created, modification: modified,
							mime: contentType?.preferredMIMEType)
						object = .file(
							try await state.uploadNewFileAbortable(
								osPath: url.path(percentEncoded: false), parentPath: parent,
								info: info,
								progressCallback: ProgressNotifier(
									set: Self.uploadingSet, id: itemTemplate.itemIdentifier.rawValue,
									progress: progress),
								abort: abort.signal()
							).file)
						applied.formUnion([.contents, .creationDate, .contentModificationDate])
					}
				} else if options.contains(.mayAlreadyExist) {
					// A reimport of a dataless file: there are no bytes to send, and we cannot
					// match it to an item of ours from a name alone. Refusing it (nil item, no
					// error) drops the placeholder from disk; the item itself is untouched on the
					// server and comes back with the next enumeration.
					Self.logger.info("refusing to reimport dataless item \(name)")
					answer.fire { completionHandler(nil, [], false, nil) }
					return
				} else {
					// The empty-file call carries no dates, so neither date is applied here.
					object = .file(
						try await state.createEmptyFile(
							parentPath: parent, name: name, mime: contentType?.preferredMIMEType
						).file)
				}

				if fields.contains(.tagData), let tagData = itemTemplate.tagData ?? nil {
					object = try state.insertIntoLocalDataForPath(
						path: Self.itemIdentifier(for: object, fallback: parent).rawValue,
						key: LOCAL_DATA_TAGS, value: tagData.base64EncodedString())
					applied.insert(.tagData)
				}

				let item = FileProviderItem(
					itemIdentifier: Self.itemIdentifier(for: object, fallback: parent),
					object: object, parentItemIdentifier: parentIdentifier)
				answer.fire {
					completionHandler(item, fields.subtracting(applied), fetchContents, nil)
				}
			} catch {
				answer.fire { completionHandler(nil, [], false, providerError(from: error)) }
			}
		}
	}

	/// One cache operation a `modifyItem` call breaks down into.
	enum ModifyStep: Equatable {
		/// Replace the file's bytes with the ones the system handed over.
		case contents
		case trash
		/// Restore out of the trash, into `to` when the system asked for a specific parent (the
		/// cache moves it there itself) or back where it came from when it did not.
		case restore(to: String?)
		case move(to: String)
		case rename(String)
		case favoriteRank(Int64)
		/// Provider-local metadata the drive itself has no field for.
		case localData(key: String, value: String?)
	}

	/// The steps a change dispatches to, in the order they are applied.
	///
	/// Content first: the bytes are what the user is waiting on, and the id addressing the file
	/// survives every other step. Trash/restore/move before the rename, so a rename that collides
	/// collides in the container the item ends up in. Purely local fields last — they cannot fail
	/// in a way that should abandon the rest.
	///
	/// A step that fails part-way leaves the earlier ones applied, deliberately: the change is
	/// already on disk, which is the state this call is catching the drive up to, so undoing a
	/// committed step would push down a change the user never made. The system retries the whole
	/// modification, and every step here replays as a no-op once it has landed.
	///
	/// Pure, and taking the pieces rather than the extension, so the dispatch table is testable.
	static func modifySteps(
		changedFields: NSFileProviderItemFields, item: NSFileProviderItem, hasContents: Bool,
		currentlyTrashed: Bool, rootUuid: String
	) -> [ModifyStep] {
		var steps: [ModifyStep] = []
		// `.contents` without a file to read is the system telling us the content changed while
		// having nothing to hand over; there is nothing to upload.
		if changedFields.contains(.contents) && hasContents { steps.append(.contents) }
		if changedFields.contains(.parentItemIdentifier) {
			let parent = item.parentItemIdentifier
			if parent == .trashContainer {
				steps.append(.trash)
			} else if currentlyTrashed {
				steps.append(.restore(to: cacheId(for: parent, rootUuid: rootUuid)))
			} else {
				steps.append(.move(to: cacheId(for: parent, rootUuid: rootUuid)))
			}
		}
		if changedFields.contains(.filename) { steps.append(.rename(item.filename)) }
		if changedFields.contains(.favoriteRank) {
			steps.append(.favoriteRank((item.favoriteRank ?? nil)?.int64Value ?? 0))
		}
		if changedFields.contains(.tagData) {
			let tagData = item.tagData ?? nil
			steps.append(
				.localData(
					key: LOCAL_DATA_TAGS,
					value: (tagData?.isEmpty ?? true) ? nil : tagData?.base64EncodedString()))
		}
		if changedFields.contains(.lastUsedDate) {
			steps.append(
				.localData(
					key: LOCAL_DATA_LAST_USED,
					value: (item.lastUsedDate ?? nil).map {
						String(Int64($0.timeIntervalSince1970 * 1000))
					}))
		}
		return steps
	}

	/// The field a step is the application of — the inverse of the dispatch above.
	private static func field(of step: ModifyStep) -> NSFileProviderItemFields {
		switch step {
		case .contents: return .contents
		case .trash, .restore, .move: return .parentItemIdentifier
		case .rename: return .filename
		case .favoriteRank: return .favoriteRank
		case .localData(let key, _): return key == LOCAL_DATA_TAGS ? .tagData : .lastUsedDate
		}
	}

	/// What the system asked for that the dispatch above does not apply.
	///
	/// This is the answer to `stillPendingFields`, and it is how the system learns what this
	/// provider carries: "If the provider is not able to apply all the fields at once, it should
	/// return a set of stillPendingFields in its completion handler. In that case, the system will
	/// attempt to modify the item later by calling modifyItem with those fields. [...] if the set
	/// of stillPendingFields returned by the provider is identical to the set of fields passed to
	/// modifyItem, then the system will consider that these fields are not supported by the
	/// provider." Reporting none instead claims every field landed, so the system writes its own
	/// copy back over the disk and re-sends the same field forever.
	static func stillPendingFields(
		changedFields: NSFileProviderItemFields, steps: [ModifyStep]
	) -> NSFileProviderItemFields {
		changedFields.subtracting(steps.reduce(into: []) { $0.formUnion(field(of: $1)) })
	}

	/// Runs one step and hands back what the item became.
	///
	/// `abort` is the only cancellable step's signal — the upload. The rest are single round trips
	/// that answer or fail long before a cancellation could be acted on.
	static func apply(
		_ step: ModifyStep, state: FilenMobileCacheState, id: String, contents: URL?,
		progress: Progress?, abort: FfiAbortSignal? = nil
	) async throws -> FfiObject {
		switch step {
		case .contents:
			guard let contents else { throw NSFileProviderError(.noSuchItem) }
			// The upload is the one step whose failure loses the user's bytes, so it is the one
			// step worth retrying. A failure past the retries still leaves the edit marked in the
			// cache for the launch drain to deliver.
			var uploaded: FileWithPathResponse?
			let failure = await retrying(
				attempts: uploadAttempts,
				operation: {
					uploaded = try await state.modifyFileContent(
						id: id, osPath: contents.path(percentEncoded: false),
						progressCallback: ProgressNotifier(
							set: uploadingSet, id: id, progress: progress),
						abort: abort)
				},
				onRetry: { attempt in
					Self.logger.error("content upload attempt \(attempt) failed for \(id)")
					try? await Task.sleep(for: .seconds(1 << (attempt - 1)))
				})
			if let failure { throw failure }
			guard let uploaded else { throw NSFileProviderError(.cannotSynchronize) }
			return .file(uploaded.file)
		case .trash:
			return try await state.trashItem(path: id).object
		case .restore(let to):
			// The cache moves the item on if the requested parent is not the one it was trashed
			// out of, so this is the whole of an untrash-somewhere-else.
			return try await state.restoreItem(uuid: id, to: to).object
		case .move(let to):
			return try await state.moveItem(item: id, newParent: to).object
		case .rename(let name):
			guard let renamed = try await state.renameItem(item: id, newName: name) else {
				// nil is the cache saying "already named that" — the replay of a rename that
				// was applied before the reply got lost. Answer with the current item as a
				// success: throwing .filenameCollision here made every such replay read as a
				// conflict the system then tried to resolve against the item itself.
				guard let current = try await state.updateAndQueryItem(id: id) else {
					throw NSFileProviderError(.noSuchItem)
				}
				return current
			}
			return renamed.object
		case .favoriteRank(let rank):
			return try await state.setFavoriteRank(item: id, favoriteRank: rank).object
		case .localData(let key, let value):
			return try state.insertIntoLocalDataForPath(path: id, key: key, value: value)
		}
	}

	func modifyItem(
		_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion,
		changedFields: NSFileProviderItemFields, contents newContents: URL?,
		options: NSFileProviderModifyItemOptions, request: NSFileProviderRequest,
		completionHandler: @escaping (
			NSFileProviderItem?, NSFileProviderItemFields, Bool, (any Error)?
		) -> Void
	) -> Progress {
		let state = self.state
		let progress = Progress()
		let answer = CallOnce()
		let abort = FfiAbortController()
		return self.inFlight.run(
			progress,
			onCancel: { answer.fire { completionHandler(nil, [], false, userCancelledError()) } },
			abort: abort
		) { [weak self] in
			do {
				// Discarded mid-call. Transient, not an answer about the item.
				guard let self else { throw CancellationError() }
				let rootUuid = try self.getRootUuid()
				let identifier = item.itemIdentifier
				let id = Self.cacheId(for: identifier, rootUuid: rootUuid)

				// `baseVersion` is deliberately not compared against the item we hold: v1 policy
				// is server-wins, so a remote edit made since the system last saw the item is not
				// a conflict to reject — the upload lands on top of it and the change feed tells
				// the system what the file became. (The provider does not declare
				// NSExtensionFileProviderSupportsFailingUploadOnConflict, so the system never
				// asks for the other behaviour through `.failOnConflict` either.)
				// A lookup failure is not "not trashed": reading a trashed item as live turns the
				// restore into a move, which leaves it in the trash under a new parent. A miss is
				// different — the item may only exist on the server — and still means .move.
				var cached: FfiObject?
				do {
					cached = try state.queryItem(path: id)
				} catch CacheError.DoesNotExist(_) {
					cached = nil
				}
				let currentlyTrashed = objectIsTrashed(cached)
				let steps = Self.modifySteps(
					changedFields: changedFields, item: item, hasContents: newContents != nil,
					currentlyTrashed: currentlyTrashed, rootUuid: rootUuid)
				let stillPending = Self.stillPendingFields(
					changedFields: changedFields, steps: steps)

				var object: FfiObject?
				for step in steps {
					object = try await Self.apply(
						step, state: state, id: id, contents: newContents, progress: progress,
						abort: abort.signal())
				}

				// Nothing to do (or nothing we handle): answer with the item as it stands, which
				// is what the system compares its own copy against.
				guard let object else {
					let unchanged = try await Self.resolveItem(
						state: state, identifier: identifier, rootUuid: rootUuid)
					answer.fire { completionHandler(unchanged, stillPending, false, nil) }
					return
				}
				let modified = FileProviderItem(
					itemIdentifier: identifier, object: object,
					parentItemIdentifier: Self.containerIdentifier(
						for: object, fallbackFrom: identifier, rootUuid: rootUuid))
				answer.fire { completionHandler(modified, stillPending, false, nil) }
			} catch {
				answer.fire { completionHandler(nil, [], false, providerError(from: error)) }
			}
		}
	}

	/// Whether `id` names a directory that still holds something — the question a non-recursive
	/// delete has to answer before the cache takes a whole subtree with it.
	///
	/// Nothing here fails open. A lookup error propagates, because a failed read says nothing about
	/// emptiness and reading it as empty deletes the children. An empty cached listing does not
	/// prove emptiness either — a directory nobody has enumerated has no child rows at all — so it
	/// costs one relist to tell the two apart. Only directories get that far: for a file the first
	/// lookup answers no.
	static func isNonEmptyDirectory(state: FilenMobileCacheState, id: String) async throws -> Bool {
		var object = try state.queryItem(path: id)
		if object == nil { object = try await state.updateAndQueryItem(id: id) }
		guard case .dir(_) = object else { return false }

		// ponytail: a cached child is taken at face value — if it was deleted remotely since, this
		// refuses a deletion that would have been legal, and the system re-creates the directory
		// from the metadata it has. Refusing is the safe direction; relist here too if it bites.
		if let cached = try state.queryDirChildren(path: id, orderBy: nil), !cached.objects.isEmpty {
			return true
		}
		// One row is enough to refuse the deletion; the relist itself is what this is for.
		let listed = try await state.updateAndQueryDirChildrenPage(
			path: id, orderBy: nil, offset: 0, limit: 1, refresh: true)
		return !(listed?.objects.isEmpty ?? true)
	}

	func deleteItem(
		identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
		options: NSFileProviderDeleteItemOptions, request: NSFileProviderRequest,
		completionHandler: @escaping ((any Error)?) -> Void
	) -> Progress {
		let state = self.state
		let answer = CallOnce()
		return self.inFlight.run(
			Progress(),
			onCancel: { answer.fire { completionHandler(userCancelledError()) } }
		) { [weak self] in
			do {
				// Discarded mid-call. Transient, not an answer about the item.
				guard let self else { throw CancellationError() }
				let rootUuid = try self.getRootUuid()
				let id = Self.cacheId(for: identifier, rootUuid: rootUuid)

				// The cache deletes a directory with everything under it. Without the recursive
				// option the header requires the opposite: "If the options don't include
				// NSFileProviderDeleteItemRecursive and the deletion targets a non-empty directory,
				// the extension must reject the deletion with the NSFileProviderErrorDirectoryNotEmpty
				// error code." — NSFileProviderReplicatedExtension.h
				if !options.contains(.recursive),
					try await Self.isNonEmptyDirectory(state: state, id: id)
				{
					throw NSFileProviderError(.directoryNotEmpty)
				}

				try await state.deleteItem(item: id)
				answer.fire { completionHandler(nil) }
			} catch CacheError.DoesNotExist(_) {
				// "If the deletion targets an item that is unknown from the extension because that
				// item may have already been deleted remotely, then the extension should report a
				// success." — NSFileProviderReplicatedExtension.h
				answer.fire { completionHandler(nil) }
			} catch {
				answer.fire { completionHandler(providerError(from: error)) }
			}
		}
	}

	// MARK: - Enumeration

	func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest)
		throws -> NSFileProviderEnumerator
	{
		do {
			if containerItemIdentifier == .workingSet {
				return WorkingSetEnumerator(
					state: self.state, rootUuid: try self.getRootUuid(), inFlight: self.inFlight)
			}
			return FileProviderEnumerator(
				enumeratedItemIdentifier: containerItemIdentifier, state: self.state,
				rootUuid: try self.getRootUuid())
			// Everything, not just CacheError: "Errors must be in one of the following domains:
			// NSCocoaErrorDomain, NSFileProviderErrorDomain." — NSFileProviderReplicatedExtension.h
		} catch { throw providerError(from: error) }
	}

	// MARK: - Retrying

	/// Runs an operation, retrying a bounded number of times; nil on success, else the last error.
	///
	/// A failed content upload is a lost user edit. Retrying recovers transient failures, a
	/// dropped connection or a server blip, which are the common case. It cannot recover a
	/// permanent failure or a process death mid-retry; the cache's pending-upload marker and the
	/// drain at launch cover those.
	///
	/// A cancelled operation is not a failure and is never retried: the call it belongs to has
	/// already been answered from the `Progress` cancellation handler, so a retry would upload the
	/// file again for nobody. That covers both spellings a cancellation arrives in — a Swift
	/// `CancellationError`, and `CacheError.Aborted`, which is the same cancellation coming back
	/// out of the cache because the abort signal is how a Rust call is stopped. The check is at the
	/// top of the loop because the backoff swallows cancellation (`try? await Task.sleep`) — this
	/// is where a loop cancelled mid-sleep stops.
	static func retrying(
		attempts: Int,
		operation: () async throws -> Void,
		onRetry: (Int) async -> Void = { _ in }
	) async -> Error? {
		var lastError: Error?
		for attempt in 1...max(1, attempts) {
			if Task.isCancelled { return lastError ?? CancellationError() }
			do {
				try await operation()
				return nil
			} catch is CancellationError {
				return CancellationError()
			} catch CacheError.Aborted(let reason) {
				return CacheError.Aborted(reason)
			} catch {
				lastError = error
				if attempt < attempts { await onRetry(attempt) }
			}
		}
		return lastError
	}

	// MARK: - Thumbnails

	// pretend @Sendable isn't a problem here in Swift 6,
	// uniffi requires that exposed traits be Send + Sync
	// so there is no other way to do this
	// this doesn't seem to have caused issues
	// but I do wish apple would fix this API becuase there's no reason
	// these shouldn't be @Sendable
	func fetchThumbnails(
		for itemIdentifiers: [NSFileProviderItemIdentifier], requestedSize size: CGSize,
		perThumbnailCompletionHandler: @escaping (
			NSFileProviderItemIdentifier, Data?, Error?
		) -> Void, completionHandler: @escaping (Error?) -> Void
	) -> Progress {
		// The system asks for 2048x2048 for EVERY item, on every device, no
		// matter how small the icon it is about to draw: it caches one
		// thumbnail per item version and rescales that one image for every
		// use, so it requests the largest size it might ever want. The size is
		// an upper bound, not a demand — QuickLook documents the sibling API's
		// size as a maximum and downscales to fit, Apple's own WWDC sample
		// ignores the parameter outright, and ownCloud's provider clamps it to
		// 256 exactly like this.
		//
		// We must clamp, because this extension is strictly memory bound: a
		// file provider gets roughly 20 MB before jetsam kills it, and a
		// 2048x2048 RGBA buffer is 16 MB on its own — honouring the request
		// literally is not possible, let alone the decode that produces it.
		// Asking the Rust pipeline for 2048 made it refuse nearly every real
		// photo as over-budget, and the system caches that refusal until the
		// item's contentVersion changes, so the thumbnails never came back.
		let requested = min(max(size.width, size.height), Self.maxThumbnailPixels)
		Self.logger.debug(
			"fetchThumbnails for \(itemIdentifiers.count) items at \(size.width)x\(size.height), serving \(requested)"
		)
		let progress = Progress(totalUnitCount: Int64(itemIdentifiers.count))
		// This call has a real cancellation hook — the Rust thumbnail task takes one — but the
		// framework still wants the completion answered from the cancellation handler, and the
		// cancelled task may answer it too.
		let answer = CallOnce()
		// Deregistration runs from the completion handler, so the entry never outlives the
		// work; `register` before the call so a teardown racing it still finds something.
		let deregister = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)
		let fetchHandler = FetchThumbnailHandler(
			perThumbnailCompletionHandler: perThumbnailCompletionHandler,
			completionHandler: { error in
				deregister.withLock { $0?() }
				answer.fire { completionHandler(error) }
			},
			progress: progress)
		do {
			let thumbnailTask = try self.state.getThumbnails(
				items: itemIdentifiers.map { $0.rawValue }, requestedWidth: UInt32(requested),
				requestedHeight: UInt32(requested), callback: fetchHandler)
			// In the registry as well as on the progress: `invalidate()` cancels through
			// `cancelAll` only, so without this the one call with a real Rust-side cancel was
			// the one teardown could not stop.
			let unregister = self.inFlight.register {
				answer.fire { completionHandler(userCancelledError()) }
				thumbnailTask.cancel()
			}
			deregister.withLock { $0 = unregister }
			progress.cancellationHandler = {
				unregister()
				answer.fire { completionHandler(userCancelledError()) }
				thumbnailTask.cancel()
			}
		} catch let error {
			// getThumbnails should throw a CacheError, but guard against any
			// other error type so we never force-crash the extension
			answer.fire { completionHandler(providerError(from: error)) }
		}
		return progress
	}
}
