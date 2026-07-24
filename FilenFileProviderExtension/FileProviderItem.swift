import CryptoKit
import FileProvider
import UniformTypeIdentifiers

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

	var versionIdentifier: Data? {
		// build a stable, metadata-inclusive digest so renames / recolors /
		// favorite changes produce a staleness signal for every item type
		var components: [String]
		switch self.object {
		case .file(let ffiFile):
			components = [
				"file", ffiFile.uuid, ffiFile.parent, "\(ffiFile.size)",
				"\(ffiFile.favoriteRank)", ffiFile.meta?.name ?? "", ffiFile.meta?.mime ?? "",
				"\(ffiFile.meta?.modified ?? 0)",
				ffiFile.meta?.hash?.base64EncodedString() ?? "",
			]
		case .dir(let ffiDir):
			components = [
				"dir", ffiDir.uuid, ffiDir.parent, "\(ffiDir.favoriteRank)",
				ffiDir.meta?.name ?? "", ffiDir.color ?? "", "\(ffiDir.meta?.created ?? 0)",
			]
		case .root(let ffiRoot):
			components = ["root", ffiRoot.uuid]
		}
		let digest = SHA256.hash(data: Data(components.joined(separator: "\u{0}").utf8))
		return Data(digest)
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
		if self.identifier.rawValue.starts(with: "trash/") { return true }
		switch self.object {
		case .file(let ffiFile): return ffiFile.parent == "trash"
		case .dir(let ffiDir): return ffiDir.parent == "trash"
		case .root(_): return false
		}
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

	var tagData: Data? {
		switch self.object {
		case .file(let ffiFile):
			if let tagData = ffiFile.localData?["TagData"] as? String {
				return Data(base64Encoded: tagData)
			} else {
				return nil
			}
		case .dir(let ffiDir):
			if let tagData = ffiDir.localData?["TagData"] as? String {
				return Data(base64Encoded: tagData)
			} else {
				return nil
			}
		case .root(_): return nil
		}
	}

	var isUploading: Bool {
		let uuid = objectToUuid(object: self.object)
		return FileProviderExtension.uploadingSet.withLock { set in return set.contains(uuid) }
	}

	var isDownloading: Bool {
		let uuid = objectToUuid(object: self.object)
		return FileProviderExtension.downloadingSet.withLock { set in return set.contains(uuid) }
	}
}
