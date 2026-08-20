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
		switch self.object {
		case .file(_):
			if self.isTrashed {
				// allowsTrashing also specifies that it can be restored
				[.allowsTrashing, .allowsDeleting]
			} else {
				[
					.allowsReading, .allowsWriting, .allowsRenaming, .allowsTrashing,
					.allowsReparenting, .allowsDeleting,
				]
			}
		case .dir(_):
			if self.isTrashed {
				// allowsTrashing also specifies that it can be restored
				[.allowsTrashing, .allowsDeleting]
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
	/// cached copy, an outstanding edit) deliberately does not move it.
	var itemVersion: NSFileProviderItemVersion {
		switch self.object {
		case .file(let ffiFile):
			return NSFileProviderItemVersion(
				contentVersion: Data(ffiFile.uuid.utf8),
				metadataVersion: Self.versionBytes(ffiFile.changeSeq))
		case .dir(let ffiDir):
			return NSFileProviderItemVersion(
				contentVersion: Data(DIRECTORY_CONTENT_VERSION.utf8),
				metadataVersion: Self.versionBytes(ffiDir.changeSeq))
		case .root(_):
			// A root is never replicated as an item; it needs a version only because the system
			// reads one off whatever it is handed.
			return NSFileProviderItemVersion(
				contentVersion: Data(DIRECTORY_CONTENT_VERSION.utf8),
				metadataVersion: Self.versionBytes(0))
		}
	}

	private static func versionBytes(_ changeSeq: Int64) -> Data {
		withUnsafeBytes(of: changeSeq.littleEndian) { Data($0) }
	}

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

	var isTrashed: Bool {
		// File identifiers are stable ids with no `trash/` prefix, so trash
		// state comes from the object itself (a trashed item's parent renders
		// as the "trash" sentinel). The prefix check stays for identifiers
		// handed back by trash responses.
		if self.identifier.rawValue.starts(with: TRASH_CACHE_ID + "/") { return true }
		return objectIsTrashed(self.object)
	}
	var contentModificationDate: Date? {
		switch self.object {
		case .file(let ffiFile):
			guard let modified = ffiFile.meta?.modified else { return nil }
			return Date(timeIntervalSince1970: TimeInterval(modified) / 1000)
		case .dir(let dir):
			guard let created = dir.meta?.created else { return nil }
			return Date(timeIntervalSince1970: TimeInterval(created) / 1000)
		case .root(_): return nil
		}
	}

	var creationDate: Date? {
		switch self.object {
		case .file(let ffiFile):
			guard let created = ffiFile.meta?.created else { return nil }
			return Date(timeIntervalSince1970: TimeInterval(created) / 1000)
		case .dir(let dir):
			guard let created = dir.meta?.created else { return nil }
			return Date(timeIntervalSince1970: TimeInterval(created) / 1000)
		case .root(_): return nil
		}
	}

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
		guard let millis = self.localData?[LOCAL_DATA_LAST_USED].flatMap(Int64.init) else {
			return nil
		}
		return Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
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
