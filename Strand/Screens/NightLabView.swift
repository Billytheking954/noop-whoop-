import SwiftUI
import Charts
import UniformTypeIdentifiers
import StrandAnalytics
import StrandDesign

struct NightLabView: View {
    @StateObject private var model = NightLabInspectionModel()
    @State private var showingImporter = false
    @State private var showingExporter = false
    @State private var exportDocument: NightLabBundleDocument?
    @State private var exportName = "night-lab"

    var body: some View {
        ScreenScaffold(title: "Night Lab", subtitle: "Archived evidence, saved replay results and portable bundles") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                HStack {
                    Button("Refresh") { Task { await model.refresh() } }
                    Button("Import bundle…") { presentImporter() }
                    Button("Export selected…") {
                        Task {
                            guard let data = await model.exportSelectedNight(),
                                  let nightID = model.selectedID else { return }
                            exportName = nightID
                            exportDocument = NightLabBundleDocument(data: data)
                            showingExporter = true
                        }
                    }
                    .disabled(model.selectedID == nil || model.transferring)
                }
                if model.loading { ProgressView() }
                if model.transferring { ProgressView("Verifying bundle…") }
                if let message = model.transferMessage { Text(message) }
                if !model.nights.isEmpty {
                    Picker("Archived night", selection: $model.selectedID) {
                        ForEach(model.nights) { entry in
                            Text(selectorTitle(entry)).tag(Optional(entry.id))
                        }
                    }
                } else if !model.loading && model.error == nil {
                    Text("No archived nights")
                }
                if let error = model.error { Text("Inspection failed: \(error)").foregroundStyle(.red) }
                if let value = model.inspection { detail(value) }
            }
        }
        .task { await model.refresh() }
        .task(id: model.selectedID) {
            if model.selectedID != nil { await model.refresh() }
        }
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [.nightLabBundle, .json],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { Task { await model.importBundle(from: url) } }
            case .failure(let error):
                NSLog("Night Lab bundle picker failed: \(error.localizedDescription)")
            }
        }
        .fileExporter(isPresented: $showingExporter,
                      document: exportDocument,
                      contentType: .nightLabBundle,
                      defaultFilename: exportName) { result in
            if case .failure(let error) = result {
                NSLog("Night Lab bundle export failed: \(error.localizedDescription)")
            }
            exportDocument = nil
        }
    }

    private func selectorTitle(_ entry: NightLabInspectionEntry) -> String {
        guard let m = entry.manifest else { return entry.id + " • Invalid archive" }
        return entry.id + " • " + NightLabInspectionFormatting.timestamp(m.windowStartUnix,
            offset: m.timezoneOffsetSeconds) + " • " + m.state.rawValue
    }

    private func presentImporter() {
        #if os(iOS)
        Task {
            guard let url = await DocumentPicker.importFile([.nightLabBundle, .json]) else { return }
            await model.importBundle(from: url)
        }
        #else
        showingImporter = true
        #endif
    }

    @ViewBuilder private func detail(_ value: NightLabInspection) -> some View {
        let m = value.manifest
        NoopCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Captured evidence").font(.headline)
                field("Night", m.nightID)
                field("State", m.state.rawValue)
                field("Unix interval", NightLabInspectionFormatting.interval(start: m.windowStartUnix, end: m.windowEndUnix))
                field("Start", NightLabInspectionFormatting.timestamp(m.windowStartUnix, offset: m.timezoneOffsetSeconds))
                field("End (exclusive)", NightLabInspectionFormatting.timestamp(m.windowEndUnix, offset: m.timezoneOffsetSeconds))
                field("Creation timestamp", "Not recorded in this archive schema")
                field("Manifest schema", String(m.schemaVersion))
                field("Device ID", m.sourceDeviceID)
                field("Device model", m.sourceDeviceModel)
                field("Firmware", m.sourceFirmware)
                field("Source NOOP", m.noopVersion)
                field("Store schema", m.sourceStoreSchemaVersion.map(String.init))
                field("Source fingerprint", m.sourceStreamFingerprint)
                if m.state == .sealed {
                    Text("Raw evidence verified")
                } else {
                    Text("Incomplete archive")
                }
                ForEach(m.rawAssets, id: \.id) { asset in
                    field(asset.id + " • " + asset.kind.rawValue, "\(asset.sampleCount) rows • SHA: \(asset.digest ?? "Not recorded")")
                }
            }
        }
        if m.state == .sealed {
            dataQuality(value)
            coverage(value)
            NightLabSpO2DiagnosticsCard(inspection: value)
            NoopCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Derived baseline").font(.headline)
                    if let error = value.baselineError {
                        Text("Saved baseline validation failed: \(error)").foregroundStyle(.red)
                    } else if let baseline = value.baseline {
                        field("Saved file SHA-256", value.baselineSHA256)
                        field("Algorithm", baseline.algorithm.id + " / " + baseline.algorithm.version)
                        field("Repository commit", baseline.implementation.noopCommitSHA)
                        field("Stager source blob", baseline.implementation.stagerSourceBlobSHA)
                        Text("Saved baseline validated without replay")
                        NightLabHypnogramView(baseline: baseline)
                    } else {
                        Text("Baseline not generated")
                    }
                }
            }
            NoopCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Execution receipts").font(.headline)
                    if let error = value.receiptsError { Text("Receipt read failed: \(error)").foregroundStyle(.red) }
                    if value.receipts.isEmpty && value.receiptsError == nil { Text("No saved execution receipts") }
                    ForEach(value.receipts, id: \.fileName) { item in
                        field("File", item.fileName)
                        if let r = item.receipt {
                            field("Executed", NightLabInspectionFormatting.timestamp(r.executedAtUnix, offset: m.timezoneOffsetSeconds))
                            field("Duration", "\(r.durationNanoseconds) ns")
                            field("Baseline SHA", r.baselineSHA256)
                            field("Commit", r.noopCommitSHA)
                        }
                        if let error = item.error { Text(error).foregroundStyle(.red) }
                        Divider()
                    }
                }
            }
        }
    }

    private func dataQuality(_ value: NightLabInspection) -> some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Signal coverage").font(.headline)
                Text("Coverage describes data availability, not staging accuracy.")
                if let quality = value.dataQuality {
                    field("Archive integrity", quality.archiveIntegrityVerified ? "Verified" : "Not verified")
                    field("Saved sleep result evidence", evidenceLabel(quality.savedResultEvidence))
                    if !quality.limitingSignals.isEmpty {
                        field("Limited signals", signalList(quality.limitingSignals))
                    }
                    if !quality.unknownCompletenessSignals.isEmpty {
                        field("Completeness unknown", signalList(quality.unknownCompletenessSignals))
                    }
                    ForEach(quality.signals, id: \.kind) { signal in
                        field(signal.kind.rawValue, availabilityLabel(signal.availability))
                    }
                } else {
                    Text("Incomplete archive")
                }
            }
        }
    }

    private func availabilityLabel(_ value: NightSignalAvailability) -> String {
        switch value {
        case .complete: "Complete"
        case .partial: "Partial"
        case .unavailable: "Unavailable"
        case .completenessUnknown: "Available; completeness unknown"
        }
    }

    private func evidenceLabel(_ value: NightSavedResultEvidence) -> String {
        switch value {
        case .noSavedResult: "No saved result"
        case .complete: "Complete measured inputs"
        case .limited: "Produced from limited evidence"
        case .completenessUnknown: "Produced; some input completeness is unknown"
        }
    }

    private func signalList(_ signals: [NightSignalKind]) -> String {
        signals.map(\.rawValue).joined(separator: ", ")
    }

    private func coverage(_ value: NightLabInspection) -> some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Signal coverage").font(.headline)
                Text("Coverage describes data availability, not staging accuracy.")
                ForEach(value.coverage, id: \.kind) { report in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(report.kind.rawValue).font(.headline)
                        field("Availability", report.sampleCount == 0 ? "Unavailable: no archived rows" : "Available")
                        field("Rows / events", String(report.sampleCount))
                        field("Expected rows", report.expectedSamples.map(String.init))
                        field("Temporal coverage", NightLabInspectionFormatting.percentage(report.coverageFraction))
                        field("Gap count", report.gapCount.map(String.init))
                        field("Largest timestamp spacing (seconds)", report.largestGapSeconds.map(String.init))
                        if report.coverageFraction == nil {
                            Text("Unknown cadence or event-driven signal")
                        }
                        Text("Exact gap boundaries unavailable")
                    }
                    Divider()
                }
                ForEach(value.manifest.rawAssets.filter { !["hr", "rr", "gravity", "respiration", "wrist-status"].contains($0.id) }, id: \.id) { asset in
                    field(asset.id, "Archived bytes verified • \(asset.sampleCount) declared rows • Coverage unavailable for this asset format")
                }
            }
        }
    }

    private func field(_ name: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.caption).foregroundStyle(.secondary)
            Text(value ?? "Not recorded").textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private extension UTType {
    static let nightLabBundle = UTType(filenameExtension: "nightlab") ?? .json
}

private struct NightLabBundleDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.nightLabBundle, .json] }
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private struct NightLabHypnogramView: View {
    let baseline: SleepStagerV2BaselineArtifact

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Chart {
                if let leading = baseline.leadingBoundary {
                    RectangleMark(xStart: .value("Start", leading.startUnix), xEnd: .value("End", leading.endUnix),
                                  y: .value("Stage", leading.stage.rawValue))
                        .foregroundStyle(by: .value("Stage", leading.stage.rawValue))
                }
                ForEach(baseline.epochs, id: \.startUnix) { epoch in
                    RectangleMark(xStart: .value("Start", epoch.startUnix), xEnd: .value("End", epoch.endUnix),
                                  y: .value("Stage", epoch.stage.rawValue))
                        .foregroundStyle(by: .value("Stage", epoch.stage.rawValue))
                }
            }
            .chartXScale(domain: baseline.windowStartUnix...baseline.windowEndUnix)
            .chartYScale(domain: ["deep", "light", "rem", "wake"])
            .frame(height: 180)
            .accessibilityLabel("Saved sleep stages")
            DisclosureGroup("Exact saved epoch intervals (Unix seconds)") {
                if let leading = baseline.leadingBoundary {
                    Text("Leading fragment \(NightLabInspectionFormatting.interval(start: leading.startUnix, end: leading.endUnix)): \(leading.stage.rawValue)")
                }
                ForEach(baseline.epochs, id: \.startUnix) { epoch in
                    Text("\(NightLabInspectionFormatting.interval(start: epoch.startUnix, end: epoch.endUnix)): \(epoch.stage.rawValue)")
                }
            }
        }
    }
}
