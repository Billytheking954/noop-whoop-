import Foundation
import Combine
import StrandAnalytics

@MainActor
final class NightLabInspectionModel: ObservableObject {
    @Published private(set) var nights: [NightLabInspectionEntry] = []
    @Published private(set) var inspection: NightLabInspection?
    @Published private(set) var error: String?
    @Published private(set) var transferMessage: String?
    @Published private(set) var transferring = false
    @Published private(set) var loading = false
    @Published var selectedID: String?
    private var archive: NightLabFileStore?
    private var generation = 0

    init(archive: NightLabFileStore? = nil) { self.archive = archive }

    func exportSelectedNight() async -> Data? {
        guard let nightID = selectedID else { return nil }
        transferring = true
        transferMessage = nil
        defer { transferring = false }
        do {
            let archive = try archiveStore()
            let data = try await archive.exportBundle(nightID: nightID)
            transferMessage = "Bundle verified and ready to export."
            return data
        } catch {
            transferMessage = "Export failed: \(error)"
            return nil
        }
    }

    func importBundle(from url: URL) async {
        transferring = true
        transferMessage = nil
        defer { transferring = false }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let archive = try archiveStore()
            let result = try await archive.importBundle(data)
            selectedID = result.nightID
            transferMessage = result.disposition == .imported
                ? "Bundle verified and imported."
                : "This exact bundle is already in Night Lab."
            await refresh(preserveTransferMessage: true)
        } catch {
            transferMessage = "Import rejected: \(error)"
        }
    }

    func refresh(preserveTransferMessage: Bool = false) async {
        generation += 1
        let request = generation
        loading = true
        inspection = nil
        error = nil
        if !preserveTransferMessage { transferMessage = nil }
        defer { if request == generation { loading = false } }
        do {
            let archive = try archiveStore()
            let entries = try await archive.inspectionNights()
            guard request == generation, !Task.isCancelled else { return }
            nights = entries
            if !entries.contains(where: { $0.id == selectedID }) { selectedID = entries.first?.id }
            if let id = selectedID {
                let result = try await NightLabInspection.load(archive: archive, nightID: id)
                guard request == generation, selectedID == id, !Task.isCancelled else { return }
                inspection = result
            }
        } catch {
            guard request == generation, !Task.isCancelled else { return }
            self.error = String(describing: error)
        }
    }

    private func archiveStore() throws -> NightLabFileStore {
        if archive == nil { archive = NightLabFileStore(rootDirectory: try StorePaths.nightLabRoot()) }
        return archive!
    }
}
