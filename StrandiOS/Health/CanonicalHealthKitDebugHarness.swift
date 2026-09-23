#if DEBUG && os(iOS)
import Foundation
import StrandHealth
import StrandHealthKit

/// Explicit developer-only bridge from the iOS app into the new canonical HealthKit pipeline.
///
/// Nothing calls this unless the process is launched with one of the canonical HealthKit debug arguments.
/// The normal app continues to use `HealthKitBridge`; this lane exists only to exercise the provider →
/// coordinator → atomic canonical store chain on a real entitled iOS build before any production observer
/// is switched.
enum CanonicalHealthKitDebugHarness {
    /// Preserve the original narrow smoke test: one bounded heart-rate transaction.
    static let launchArgument = "--canonical-healthkit-sync"
    /// Exercise one bounded transaction for every quantity stream whose canonical mapping is already
    /// explicit. This remains DEBUG-only and never changes the shipping HealthKit path.
    static let allQuantitiesLaunchArgument = "--canonical-healthkit-sync-all"

    static func runIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) {
        let kinds: [HealthKitQuantityKind]
        if arguments.contains(allQuantitiesLaunchArgument) {
            kinds = Array(HealthKitQuantityKind.allCases)
        } else if arguments.contains(launchArgument) {
            kinds = [.heartRate]
        } else {
            return
        }

        Task {
            do {
                guard let applicationSupport = FileManager.default.urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask
                ).first else {
                    throw HarnessError.applicationSupportUnavailable
                }

                let root = applicationSupport
                    .appendingPathComponent("NOOP", isDirectory: true)
                    .appendingPathComponent("CanonicalHealth-v1", isDirectory: true)
                let store = FileObservationStore(rootDirectory: root)
                let coordinator = ObservationIngestionCoordinator()

                // Run streams sequentially. Each owns an independent cursor and a bounded HealthKit query,
                // so one debug launch cannot turn bootstrap into ten simultaneous high-frequency reads.
                for kind in kinds {
                    let provider = HealthKitObservationProvider(kind: kind)
                    do {
                        let batch = try await coordinator.sync(
                            providerIdentifier: provider.providerIdentifier,
                            provider: provider,
                            store: store
                        )

                        // Developer console only. Report identity + counts, never health values. A failure in
                        // one permission/type must not prevent the remaining independent streams being tested.
                        print(
                            "[canonical-healthkit] committed \(kind.rawValue) batch: "
                            + "observations=\(batch.observations.count) deletions=\(batch.deletions.count)"
                        )
                    } catch {
                        print("[canonical-healthkit] \(kind.rawValue) sync failed: \(error)")
                    }
                }
            } catch {
                print("[canonical-healthkit] harness failed: \(error)")
            }
        }
    }

    private enum HarnessError: Error {
        case applicationSupportUnavailable
    }
}
#endif