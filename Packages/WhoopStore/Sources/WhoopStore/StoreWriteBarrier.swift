import Foundation

/// Process-wide write barrier used by database restore.
///
/// A successful restore replaces the SQLite pathname while existing GRDB pools may still have the old
/// inode open. Without a barrier those pools can accept writes that appear to succeed and then vanish at
/// relaunch. The barrier closes that hole in two parts:
///
/// 1. every ordinary store/registry mutation obtains a short-lived write permit;
/// 2. restore suspends new permits and waits until every already-issued permit has returned BEFORE it
///    unlinks/swaps the database files.
///
/// The suspended state is intentionally process-local. A successful restore keeps it set until the app is
/// relaunched, at which point a fresh process starts unsuspended and opens the restored database normally.
/// A failed restore resumes writes in the current process.
public enum StoreWriteBarrier {
    private final class State: @unchecked Sendable {
        let condition = NSCondition()
        var suspended = false
        var activeWriters = 0
    }

    private static let state = State()

    /// Error returned by a mutation attempted after a successful restore but before the required relaunch.
    public struct WritesSuspendedError: LocalizedError, Equatable {
        public init() {}
        public var errorDescription: String? {
            String(localized: "The database was restored and is waiting for an app relaunch before more data can be saved.")
        }
    }

    /// Run one database mutation while holding a permit that restore can drain.
    ///
    /// Internal on purpose: production callers should mutate through `WhoopStore` or
    /// `DeviceRegistryStore`, which are the two persistence write spines.
    static func withWritePermit<T>(_ body: () throws -> T) throws -> T {
        state.condition.lock()
        guard !state.suspended else {
            state.condition.unlock()
            throw WritesSuspendedError()
        }
        state.activeWriters += 1
        state.condition.unlock()

        defer {
            state.condition.lock()
            state.activeWriters -= 1
            if state.activeWriters == 0 {
                state.condition.broadcast()
            }
            state.condition.unlock()
        }

        return try body()
    }

    /// Prevent new writes and synchronously wait for every already-started mutation to finish.
    ///
    /// Restore calls this immediately before taking its rollback snapshot / swapping files. Returning
    /// from this method therefore proves no permitted persistence mutation is still using the old file.
    public static func suspendAndDrainForRestore() {
        state.condition.lock()
        state.suspended = true
        while state.activeWriters > 0 {
            state.condition.wait()
        }
        state.condition.unlock()
    }

    /// Re-open the write gate after a restore attempt that did not complete.
    ///
    /// A successful restore deliberately never calls this: the existing pools point at the pre-restore
    /// inode, so writes must remain blocked until process relaunch.
    public static func resumeAfterFailedRestore() {
        state.condition.lock()
        state.suspended = false
        state.condition.broadcast()
        state.condition.unlock()
    }

    /// Test/diagnostic visibility without exposing the mutable state itself.
    public static var isSuspended: Bool {
        state.condition.lock()
        defer { state.condition.unlock() }
        return state.suspended
    }
}
