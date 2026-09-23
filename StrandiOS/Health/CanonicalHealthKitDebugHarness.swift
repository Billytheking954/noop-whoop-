#if DEBUG && os(iOS)
import Foundation
import StrandHealth
import StrandHealthKit

/// Explicit developer-only bridge from the iOS app into the new canonical HealthKit pipeline.
///
/// Nothing calls this unless the process is launched with `--canonical-healthkit-sync`. The normal app
/// continues to use `HealthKitBridge`; this lane exists only to exercise the provider → coordinator →
/// atomic canonical store chain on a real entitled iOS build before any production observer is switched.
enum CanonicalHealthKitDebugHarness {
    static let launchArgument = "--canonical-healthkit-sync"

    static func runIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard arguments.contains(launchArgument) else { return }

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
                let provider = HealthKitObservationProvider(kind: .heartRate)
                let batch = try await ObservationIngestionCoordinator().sync(
                    providerIdentifier: provider.providerIdentifier,
                    provider: provider,
                    store: store
                )

                // Developer console only. Do not surface physiology or sample values here; the purpose of
                // this lane is transaction/cursor integration, not a hidden second health UI.
                print(
                    "[canonical-healthkit] committed heart-rate batch: "
                    + "observations=\(batch.observations.count) deletions=\(batch.deletions.count)"
                )
            } catch {
                print("[canonical-healthkit] sync failed: \(error)")
            }
        }
    }

    private enum HarnessError: Error {
        case applicationSupportUnavailable
    }
}
#endif
