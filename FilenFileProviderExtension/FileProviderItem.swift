import FileProvider
import UniformTypeIdentifiers

/// The trash, as the system's own container.
///
/// The cache has no row for it — it is reachable only through the dedicated trash calls — so the
/// one item the system may ask for by the trash sentinel is synthesized rather than looked up.
class TrashContainerItem: NSObject, NSFileProviderItem {
	var itemIdentifier: NSFileProviderItemIdentifier { .trashContainer }
	var parentItemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
	var filename: String { "Trash" }
	var contentType: UTType { .folder }
	var capabilities: NSFileProviderItemCapabilities { [.allowsContentEnumerating] }
	var itemVersion: NSFileProviderItemVersion {
		NSFileProviderItemVersion(
			contentVersion: Data("trash".utf8), metadataVersion: Data("trash".utf8))
	}
}

class FileProviderItem: NSObject, NSFileProviderItem {
	private let identifier: NSFileProviderItemIdentifier
	private let object: FfiObject
	// The container identifier this item was constructed under. File
	// identifiers are stable ids (no path structure), so their parent cannot
	// be derived by string-splitting — it must be carried explicitly.
	private let explicitParentIdentifier: NSFileProviderItemIdentifier?

	var filename: String {
		switch self.object {
		case .file(let ffiFile): return ffiFile.meta?.name ?? "CANNOT_DECRYPT_NAME_\(ffiFile.uuid)"
		case .dir(let ffiDir): return ffiDir.meta?.name ?? "CANNOT_DECRYPT_NAME_\(ffiDir.uuid)"
		case .root(_): return "Filen"
		}
	}

	/// `parentItemIdentifier` is what the system should see as the parent
	/// (`.rootContainer` for root children — the enumerator substitutes the
	/// root uuid only for its own cache queries).
	init(parentItemIdentifier: NSFileProviderItemIdentifier, object: FfiNonRootObject) {
		// Items are identified by their whole-life id, per the platform
		// contract ("A document's identifier ... should not change when the
		// document is edited, moved, or renamed"): for files the server-minted
		// stable id (the plain uuid is re-minted on every content edit and
		// version restore), for directories the uuid itself (stable == uuid on
		// the wire, by design). The Rust cache resolves the `stable/`
		// namespace for every operation.
		switch object {
		case let .file(ffiFile):
			self.object = FfiObject.file(ffiFile)
			self.identifier = NSFileProviderItemIdentifier("stable/" + ffiFile.stableUuid)
		case let .dir(ffiDir):
			self.object = FfiObject.dir(ffiDir)
			self.identifier = NSFileProviderItemIdentifier("stable/" + ffiDir.uuid)
		}
		self.explicitParentIdentifier = parentItemIdentifier
	}

	init(
		itemIdentifier: NSFileProviderItemIdentifier, object: FfiObject,
		parentItemIdentifier: NSFileProviderItemIdentifier? = nil
	) {
		self.identifier = itemIdentifier
		self.object = object
		self.explicitParentIdentifier = parentItemIdentifier
	}

	var itemIdentifier: NSFileProviderItemIdentifier { return identifier }

	var parentItemIdentifier: NSFileProviderItemIdentifier {
		#if os(macOS)
			// macOS has no `isTrashed`: an item is trashed exactly when its parent is the trash, so
			// a trashed item reporting its original parent would show up in that directory.
			if self.inTrash { return .trashContainer }
		#endif

		if let explicitParentIdentifier { return explicitParentIdentifier }

		// No explicit parent: derive it from the object, which carries its own container (its
		// ORIGINAL parent while trashed). Deriving it by string-splitting the identifier cannot
		// work — every identifier this app issues is `stable/<uuid>`, a single slash, which
		// `getParentItemIdentifier` collapses to `.rootContainer`; that would silently reparent
		// the item to the drive root.
		//
		// Callers that know the root uuid should still pass the parent explicitly, so that a root
		// child gets the `.rootContainer` sentinel rather than the root's own `stable/` form.
		if let containerUuid = objectToContainerUuid(object: self.object) {
			return NSFileProviderItemIdentifier("stable/" + containerUuid)
		}

		// Pre-migration path-form identifiers still split correctly.
		return getParentItemIdentifier(itemIdentifier: self.identifier)
	}

	var capabilities: NSFileProviderItemCapabilities {
		#if os(iOS)
			// iOS evicts only an item that allows it ("If this capability is not present, the item
			// will never be evicted." — NSFileProviderItem.h; the deprecation there is macOS-only,
			// where the content policy replaces it). Without it neither the system nor
			// `evictItem` frees a download ("content policy prevention", -2008). Leaving it off a
			// pinned item is the keep-downloaded iOS has.
			switch self.object {
			case .file(_), .dir(_):
				if !self.isPinned { return self.baseCapabilities.union(.allowsEvicting) }
			case .root(_): break
			}
		#endif
		return self.baseCapabilities
	}

	private var baseCapabilities: NSFileProviderItemCapabilities {
		switch self.object {
		case .file(_):
			if self.inTrash {
				// allowsTrashing also specifies that it can be restored. allowsWriting keeps the
				// replica unlocked: the system locks an item it may not write, and a locked item
				// it creates in the trash fails with EPERM and pauses the whole domain.
				[.allowsWriting, .allowsTrashing, .allowsDeleting]
			} else {
				[
					.allowsReading, .allowsWriting, .allowsRenaming, .allowsTrashing,
					.allowsReparenting, .allowsDeleting,
				]
			}
		case .dir(_):
			if self.inTrash {
				// See the file case; on a directory allowsWriting is allowsAddingSubItems.
				[.allowsWriting, .allowsTrashing, .allowsDeleting]
			} else {
				[
					.allowsContentEnumerating, .allowsAddingSubItems, .allowsRenaming,
					.allowsTrashing, .allowsReparenting, .allowsDeleting,
				]
			}
		case .root(_): [.allowsContentEnumerating, .allowsAddingSubItems]
		}
	}

	var documentSize: NSNumber? {
		switch self.object {
		case .file(let ffiFile): return NSNumber(value: ffiFile.size)
		case .dir(_): return nil
		case .root(_): return nil
		}
	}

	/// The two versions the system tracks: one for the bytes, one for everything else.
	///
	/// `contentVersion` is the file's uuid, which the server re-mints on every content edit and
	/// version restore and never touches for a rename, move, favourite or trash round-trip — so it
	/// moves exactly when the bytes do, which is what drives redownloads and thumbnail
	/// invalidation. A directory has no content, so its content version is a constant.
	///
	/// `metadataVersion` is the cache's `change_seq`, a local counter that rises whenever anything
	/// a replica renders about the item changes and stands still otherwise. Purely local state (a
	/// cached copy, an outstanding edit) deliberately does not move it. `ITEM_RENDERING_REVISION`
	/// follows it, so a change to how this type renders an unchanged row reaches existing replicas,
	/// and then the pin, which is local state a replica does render (userInfo, content policy,
	/// badge): the system keeps an item's metadata while its version stands still.
	var itemVersion: NSFileProviderItemVersion {
		switch self.object {
		case .file(let ffiFile):
			return NSFileProviderItemVersion(
				contentVersion: Data(ffiFile.uuid.utf8),
				metadataVersion: Self.versionBytes(ffiFile.changeSeq, pinned: self.isPinned))
		case .dir(let ffiDir):
			return NSFileProviderItemVersion(
				contentVersion: Data(DIRECTORY_CONTENT_VERSION.utf8),
				metadataVersion: Self.versionBytes(ffiDir.changeSeq, pinned: self.isPinned))
		case .root(_):
			// A root is never replicated as an item; it needs a version only because the system
			// reads one off whatever it is handed.
			return NSFileProviderItemVersion(
				contentVersion: Data(DIRECTORY_CONTENT_VERSION.utf8),
				metadataVersion: Self.versionBytes(0, pinned: false))
		}
	}

	private static func versionBytes(_ changeSeq: Int64, pinned: Bool) -> Data {
		var bytes = withUnsafeBytes(of: changeSeq.littleEndian) { Data($0) }
		bytes.append(ITEM_RENDERING_REVISION)
		bytes.append(pinned ? 1 : 0)
		return bytes
	}

	/// Whether the user pinned this item itself, as opposed to a directory above it.
	var isPinned: Bool {
		switch self.object {
		case .file(_), .dir(_): return PinnedItems.contains(self.identifier)
		case .root(_): return false
		}
	}

	/// A live file or directory; the root and the trash have nothing to keep.
	private var isPinnable: Bool {
		switch self.object {
		case .file(_), .dir(_): return !self.inTrash
		case .root(_): return false
		}
	}

	/// What the custom action rules in Info.plist read; see `KeepDownloaded`.
	var userInfo: [AnyHashable: Any]? {
		KeepDownloaded.userInfo(pinned: self.isPinned, pinnable: self.isPinnable)
	}

	#if os(macOS)
		var contentPolicy: NSFileProviderContentPolicy {
			KeepDownloaded.contentPolicy(pinned: self.isPinned)
		}
	#endif

	var contentType: UTType {
		switch self.object {
		case .file(let file):
			guard let meta = file.meta else {
				return .data  // default to data if no metadata
			}
			// prefer the authoritative mime type from metadata
			if let type = UTType(mimeType: meta.mime) {
				return type
			}
			let name = meta.name
			let lastDot = name.lastIndex(of: ".")
			guard let lastDot = lastDot else {
				return .data  // default to data if no extension
			}
			let ext = name[name.index(after: lastDot)...]
			if let type = UTType(filenameExtension: String(ext)) {
				return type
			} else {
				return .data
			}
		case .dir(_): return .folder
		case .root(_): return .folder
		}
	}

	private var inTrash: Bool {
		// File identifiers are stable ids with no `trash/` prefix, so trash
		// state comes from the object itself (a trashed item's parent renders
		// as the "trash" sentinel). The prefix check stays for identifiers
		// handed back by trash responses.
		if self.identifier.rawValue.starts(with: TRASH_CACHE_ID + "/") { return true }
		return objectIsTrashed(self.object)
	}

	#if os(iOS)
		var isTrashed: Bool { self.inTrash }
	#endif

	private static func date(_ millis: Int64) -> Date {
		Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
	}

	/// A date, or nil when the value is a placeholder: clients write 0 (the Unix epoch) or a
	/// negative value (the 1904 HFS epoch) when they have no date, which the Files app would show
	/// as 1970 or earlier.
	private static func knownDate(_ millis: Int64?) -> Date? {
		guard let millis, millis > 0 else { return nil }
		return Self.date(millis)
	}

	/// When the server minted the item's row: the one date the drive always knows, because it
	/// sits outside the encrypted metadata. Both dates below fall back to it — metadata that
	/// will not decrypt, or that was written without dates of its own, otherwise leaves the item
	/// dateless, which the Files app shows as "--" and sorts below everything that has a date.
	private var remoteTimestamp: Date? {
		switch self.object {
		case .file(let ffiFile): return Self.knownDate(ffiFile.timestamp)
		case .dir(let ffiDir): return Self.knownDate(ffiDir.timestamp)
		case .root(_): return nil
		}
	}

	var contentModificationDate: Date? {
		switch self.object {
		case .file(let ffiFile):
			return Self.knownDate(ffiFile.meta?.modified) ?? self.remoteTimestamp
		case .dir(let ffiDir):
			// A directory has no modification date of its own; its creation date is the closest
			// thing, and the row timestamp behind that.
			return Self.knownDate(ffiDir.meta?.created) ?? self.remoteTimestamp
		case .root(_): return nil
		}
	}

	var creationDate: Date? {
		switch self.object {
		case .file(let file): return Self.knownDate(file.meta?.created) ?? self.remoteTimestamp
		case .dir(let dir): return Self.knownDate(dir.meta?.created) ?? self.remoteTimestamp
		case .root(_): return nil
		}
	}

	#if os(iOS)
		var favoriteRank: NSNumber? {
			switch self.object {
			case .file(let ffiFile):
				if ffiFile.favoriteRank == 0 { return nil }
				return NSNumber(value: ffiFile.favoriteRank)
			case .dir(let ffiDir):
				if ffiDir.favoriteRank == 0 { return nil }
				return NSNumber(value: ffiDir.favoriteRank)
			case .root(_): return nil
			}
		}
	#endif

	/// The provider's own per-item scratch space, where the fields the drive has no column for
	/// live.
	private var localData: [String: String]? {
		switch self.object {
		case .file(let ffiFile): return ffiFile.localData
		case .dir(let ffiDir): return ffiDir.localData
		case .root(_): return nil
		}
	}

	var tagData: Data? {
		guard let tagData = self.localData?[LOCAL_DATA_TAGS] else { return nil }
		return Data(base64Encoded: tagData)
	}

	/// The drive has no last-used date, so the one the system sets is kept locally and handed
	/// straight back — the system's cue for the Recents view.
	var lastUsedDate: Date? {
		self.localData?[LOCAL_DATA_LAST_USED].flatMap(Int64.init).map(Self.date)
	}

	// Transfers are keyed by the item's whole-life identifier rather than its uuid: a file's uuid
	// is re-minted by the very upload being tracked, and a download is started from an identifier
	// before anything knows the uuid behind it.
	var isUploading: Bool {
		FileProviderExtension.uploadingSet.withLock { $0[self.identifier.rawValue] != nil }
	}

	var isDownloading: Bool {
		FileProviderExtension.downloadingSet.withLock { $0[self.identifier.rawValue] != nil }
	}
}

#if os(macOS)
	/// The badge on a pinned item. Declared under `NSFileProviderDecorations` in the macOS
	/// Info.plist, whose identifier is the extension's bundle id plus this suffix.
	let KEEP_DOWNLOADED_DECORATION_SUFFIX = ".keepDownloaded"

	extension FileProviderItem: NSFileProviderItemDecorating {
		var decorations: [NSFileProviderItemDecorationIdentifier]? {
			guard self.isPinned, let bundleId = Bundle.main.bundleIdentifier else { return nil }
			return [
				NSFileProviderItemDecorationIdentifier(
					rawValue: bundleId + KEEP_DOWNLOADED_DECORATION_SUFFIX)
			]
		}
	}
#endif
