import FileProvider
import Security
import XCTest

/// Cancelling a File Provider call has two halves, and only one of them was ever wired.
///
/// The framework's half is the immediate answer: `NSUserCancelledError`, exactly once, from the
/// `Progress` cancellation handler. The other half is the work itself — uniffi cannot cancel a Rust
/// future, so a cancelled transfer used to be merely abandoned and went on running against the
/// server. The three byte-moving calls now take an abort signal, and `InFlightWork` trips it on both
/// cancellation paths; that is what these pin, on the real Rust controller rather than a stand-in.
final class CancellationTests: XCTestCase {
	/// Everything a call answers the system with, so "exactly once" is checkable.
	private final class Answers: @unchecked Sendable {
		private let lock = NSLock()
		private var recorded: [NSError] = []

		func record(_ error: any Error) { lock.withLock { recorded.append(error as NSError) } }
		var all: [NSError] { lock.withLock { recorded } }
	}

	// MARK: - The cancellation paths

	/// Cancelling the `Progress` the call handed back: the system is answered once, and the Rust
	/// work is told to stop rather than left running.
	func testCancellingAnOperationAbortsTheRustSideAndAnswersExactlyOnce() async {
		let work = InFlightWork()
		let controller = FfiAbortController()
		let signal = controller.signal()
		let answers = Answers()
		let answer = CallOnce()
		XCTAssertFalse(signal.isAborted(), "nothing has been cancelled yet")

		let finished = expectation(description: "the operation gave up")
		let progress = work.run(
			Progress(),
			onCancel: { answer.fire { answers.record(userCancelledError()) } },
			abort: controller
		) {
			// Stands in for the FFI call: it runs until the signal is tripped and then fails the
			// way an aborted cache call fails. That failure must not answer the system a second
			// time — the cancellation handler already did.
			while !signal.isAborted() { await Task.yield() }
			answer.fire { answers.record(providerError(from: CacheError.Aborted("aborted"))) }
			finished.fulfill()
		}

		progress.cancel()
		await fulfillment(of: [finished], timeout: 10)

		XCTAssertTrue(
			signal.isAborted(), "cancelling must stop the Rust work, not just abandon it")
		XCTAssertEqual(
			answers.all.count, 1, "the system's completion handler must be answered exactly once")
		XCTAssertEqual(answers.all.first?.domain, NSCocoaErrorDomain)
		XCTAssertEqual(answers.all.first?.code, NSUserCancelledError)
	}

	/// The extension being discarded (`invalidate()`) is the same cancellation for every call at
	/// once — including the transfers, which is the whole point of registering the controller.
	func testInvalidatingTheExtensionAbortsEveryRunningOperation() async {
		let work = InFlightWork()
		let controllers = [FfiAbortController(), FfiAbortController()]
		let signals = controllers.map { $0.signal() }
		let stopped = expectation(description: "every operation gave up")
		stopped.expectedFulfillmentCount = controllers.count

		for (controller, signal) in zip(controllers, signals) {
			work.run(Progress(), abort: controller) {
				while !signal.isAborted() { await Task.yield() }
				stopped.fulfill()
			}
		}

		work.cancelAll()
		await fulfillment(of: [stopped], timeout: 10)

		XCTAssertTrue(signals.allSatisfy { $0.isAborted() })
	}

	/// The other direction: an operation nobody cancelled must not read as cancelled, or every
	/// finished transfer would look like one the user stopped.
	func testAnOperationThatRunsToCompletionIsNeverAborted() async {
		let work = InFlightWork()
		let controller = FfiAbortController()
		let signal = controller.signal()

		let done = expectation(description: "the operation finished")
		work.run(Progress(), abort: controller) { done.fulfill() }
		await fulfillment(of: [done], timeout: 10)

		XCTAssertFalse(signal.isAborted())
	}

	// MARK: - Against a real transfer

	/// Big enough that the transfer is unmistakably still in flight when the callback trips the
	/// abort — the payload the Rust live tests use for the same reason.
	private static let abortPayload = 8 * 1024 * 1024

	/// Trips the abort from inside the transfer, on the first thing it reports. This is the
	/// deterministic mid-flight hook rather than a timer: the callback only fires because bytes are
	/// actually moving, and there are far too many of them left for the download to beat it.
	private final class AbortOnProgress: ProgressCallback, @unchecked Sendable {
		private let controller: FfiAbortController
		private let lock = NSLock()
		private var calls = 0

		init(_ controller: FfiAbortController) { self.controller = controller }

		private func trip() {
			lock.withLock { calls += 1 }
			controller.abort()
		}

		func setTotal(size: UInt64) { trip() }
		func onProgress(bytesProcessed: UInt64) { trip() }

		/// Whether the transfer ever reported anything — i.e. whether the abort really was raised
		/// mid-flight rather than before the call got going.
		var tripped: Bool { lock.withLock { calls > 0 } }
	}

	private func liveState() throws -> FilenMobileCacheState {
		guard let credentials = TestAuth.credentialsFromEnvironment() else {
			throw XCTSkip(
				"""
				The live cancellation test needs a session in the environment: \
				\(TestAuth.requiredVariables.joined(separator: ", ")).
				""")
		}

		let workDir = FileManager.default.temporaryDirectory
			.appending(component: "filen-cancel-tests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
		addTeardownBlock { try? FileManager.default.removeItem(at: workDir) }

		let authFile = workDir.appending(component: "auth.json")
		let dek = try TestAuth.provision(authFile: authFile, credentials: credentials)
		return FilenMobileCacheState(
			filesDir: workDir.path(percentEncoded: false),
			authFile: authFile.path(percentEncoded: false),
			dek: dek)
	}

	/// Bytes on the device are a stake in the item, so the working set is where a materialised copy
	/// shows. The cache is a fresh one per run, so nothing else is in it.
	private func isMaterialised(_ state: FilenMobileCacheState, _ stableUuid: String) throws -> Bool
	{
		try state.queryWorkingSet().contains {
			if case .file(let file) = $0 { return file.stableUuid == stableUuid }
			return false
		}
	}

	private func randomBytes(_ count: Int) -> Data {
		var bytes = Data(count: count)
		bytes.withUnsafeMutableBytes { raw in
			_ = SecRandomCopyBytes(kSecRandomDefault, count, raw.baseAddress!)
		}
		return bytes
	}

	/// What `fetchContents` does when the system cancels it, driven at the seam a host-less suite
	/// can reach: the cache call it makes, with the same abort signal and the same error mapping.
	/// The call must give up, answer as a cancellation, and leave nothing behind claiming the
	/// device holds the file — a half-written slot would be served as if it were the whole thing.
	func testAnAbortedDownloadIsAnsweredAsCancelledAndLeavesNoCachedCopy() async throws {
		let state = try liveState()
		let rootUuid = try state.rootUuid()
		let dir = try await state.createDir(
			parentPath: rootUuid, name: "cancel-\(UUID().uuidString)", created: nil)
		addTeardownBlock { _ = try? await state.trashItem(path: dir.id) }

		let source = FileManager.default.temporaryDirectory
			.appending(component: "abort-download-\(UUID().uuidString).bin")
		try randomBytes(Self.abortPayload).write(to: source)
		addTeardownBlock { try? FileManager.default.removeItem(at: source) }

		let uploaded = try await state.uploadNewFile(
			osPath: source.path(percentEncoded: false), parentPath: dir.id,
			info: UploadFileInfo(
				name: "abort-download.bin", creation: nil, modification: nil,
				mime: "application/octet-stream"),
			progressCallback: nil)
		// The upload sends the caller's own file and stages nothing in the cache, so the download
		// below really goes to the server.
		XCTAssertFalse(
			try isMaterialised(state, uploaded.file.stableUuid), "nothing of it is on the device yet")

		let controller = FfiAbortController()
		let callback = AbortOnProgress(controller)
		do {
			_ = try await state.downloadFileIfChangedWithItem(
				id: uploaded.id, progressCallback: callback, abort: controller.signal())
			XCTFail("an aborted download must not report success")
		} catch {
			XCTAssertTrue(
				callback.tripped,
				"the abort must have been raised from inside the transfer, not before it")
			let answered = providerError(from: error) as NSError
			XCTAssertEqual(
				answered.domain, NSCocoaErrorDomain,
				"what fetchContents would answer the system with: \(error)")
			XCTAssertEqual(answered.code, NSUserCancelledError, "got \(error)")
		}

		XCTAssertFalse(
			try isMaterialised(state, uploaded.file.stableUuid),
			"an aborted download must not claim the device holds the file")
	}
}
