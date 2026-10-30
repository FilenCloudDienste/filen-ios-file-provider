import FileProvider
import Foundation
import os

/// Answers for the cache while it is known to be signed out, so a call the system repeats costs
/// a lock read instead of a cache call.
///
/// The system does not back off from every call it gets `.notAuthenticated` for: a job something
/// is waiting on — the domain root's import while a fresh domain is being presented — is
/// rescheduled at user-initiated priority the moment it fails, about every 10 ms. Each of those
/// reaching the cache takes its state lock and spawns a cleanup task, only to be told what the
/// cache already knows: it re-reads auth.json at most once per `window` while signed out
/// (`UNAUTH_UPDATE_INTERVAL`, filen-mobile-native-cache auth.rs). So for that long after a
/// signed-out answer the gate gives the same answer itself, and the first call after it goes to
/// the cache again — which keeps the cache's own transitions (the re-read, the disabled wipe)
/// running at the cadence they already had. One per cache state: a signed-out answer from one
/// state says nothing about the next.
final class AuthGate: Sendable {
	static let window: Duration = .seconds(1)

	private let closedUntil = OSAllocatedUnfairLock<ContinuousClock.Instant?>(initialState: nil)

	/// Throws `.notAuthenticated` while a signed-out answer is still current.
	func check(now: ContinuousClock.Instant = .now) throws {
		let closed = self.closedUntil.withLock { until -> Bool in
			guard let deadline = until else { return false }
			if now < deadline { return true }
			until = nil
			return false
		}
		if closed { throw NSFileProviderError(.notAuthenticated) }
	}

	/// Records what a cache call threw. Only a signed-out answer closes the gate.
	func observe(_ error: any Error, now: ContinuousClock.Instant = .now) {
		guard Self.isSignedOut(error) else { return }
		let deadline = now + Self.window
		self.closedUntil.withLock { $0 = deadline }
	}

	/// Sends the next call to the cache: a session has landed and the cache's own re-read is due.
	func reopen() {
		self.closedUntil.withLock { $0 = nil }
	}

	static func isSignedOut(_ error: any Error) -> Bool {
		switch error as? CacheError {
		case .Disabled, .Unauthenticated: return true
		default: return false
		}
	}
}
