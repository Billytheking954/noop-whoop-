import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - Possible activity review (Today and Activity)
//
// A single, dismissible card that appears ONLY when the opt-in "Auto-detect workouts"
// toggle is on and `Repository.autoDetectCandidate()` finds a recent sustained-elevated HR
// window that isn't already saved and wasn't previously dismissed.
//
// It only ever SUGGESTS: tapping Save creates a manual-style "Workout" for the window (via the
// same manual-save path the edit sheet uses); the X dismisses it durably so it never re-prompts.
// Nothing is created automatically. Design-Reset compliant — a flat NoopCard using NoopMetrics /
// StrandPalette / StrandFont, no gold, matching the other Today cards.

struct AutoWorkoutCard: View {

    @EnvironmentObject var repo: Repository

    /// Whether the toggle is on. Read here too so the card disappears the instant it's switched off.
    @AppStorage(PuffinExperiment.autoDetectWorkoutsKey) private var autoDetectEnabled = true

    /// The current suggestion, loaded in `.task`. Nil shows the scan state.
    @State private var candidate: DetectedWorkout?
    /// Hide immediately on Save/X without waiting for the next reload (avoids a flash of the old card).
    @State private var handledThisSession = false
    /// Guards the Save button while the write is in flight.
    @State private var saving = false
    @State private var scanning = false
    @State private var scanRequested = 0
    @State private var motionSupported = false
    @State private var hasRecentHR = false
    // Keep the sheet tied to the activity the user opened, even if a sync changes the card.
    @State private var editingCandidate: DetectedWorkout?
    @State private var showEdit = false
    @State private var saveError = false

    var body: some View {
        Group {
            if autoDetectEnabled, !handledThisSession, let w = candidate {
                card(for: w)
            } else if autoDetectEnabled, !handledThisSession {
                NoopCard(tint: StrandPalette.accent) {
                    VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                        Text("Activity check")
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(scanning
                             ? String(localized: "Checking recent strap data…")
                             : (hasRecentHR
                                ? String(localized: "No possible activity found in the last two days. Shorter or gentler activity may need to be added manually.")
                                : String(localized: "No recent heart-rate data is stored. Connect and sync your strap, then check again.")))
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                        Button("Check stored data") { scanRequested += 1 }
                            .disabled(scanning)
                    }
                }
            }
        }
        // Re-scan whenever the data refreshes (a sync bumps refreshSeq) or the toggle flips on.
        .task(id: AutoWorkoutLoadKey(seq: repo.refreshSeq, enabled: autoDetectEnabled,
                                     request: scanRequested)) {
            await reload()
        }
        .sheet(isPresented: $showEdit, onDismiss: { editingCandidate = nil }) {
            if let candidate = editingCandidate,
               let draft = WorkoutSource.buildManualRow(
                   start: Date(timeIntervalSince1970: TimeInterval(candidate.startSec)),
                   durationMin: max(1, candidate.durationMin), sport: "Workout",
                   avgHr: candidate.avgBpm, energyKcal: nil) {
                ManualWorkoutSheet(editing: draft) { row, _ in
                    guard !saving else { return }
                    saving = true
                    saveError = false
                    Task {
                        let saved = await repo.saveEditedDetectedWorkout(row, suggestion: candidate)
                        await finishSave(saved)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func card(for w: DetectedWorkout) -> some View {
        NoopCard(tint: StrandPalette.accent) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                HStack(spacing: NoopMetrics.space2) {
                    Image(systemName: "figure.run")
                        .font(.system(size: 18))
                        .foregroundStyle(StrandPalette.accent)
                        .accessibilityHidden(true)
                    Text("Possible activity")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    Button {
                        dismiss(w)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .padding(NoopMetrics.space1)
                    }
                    .buttonStyle(.plain)
                    .disabled(saving)
                    .accessibilityLabel("Dismiss this workout suggestion")
                }

                Text(promptText(w))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(motionSupported
                     ? String(localized: "Heart-rate pattern and movement recorded. Please confirm the activity.")
                     : String(localized: "Heart-rate pattern only. NOOP cannot confirm this was exercise."))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)

                if saveError {
                    Text("Could not save this activity. Check the values and try again.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.statusWarning)
                }

                HStack(spacing: NoopMetrics.space3) {
                    Button {
                        save(w)
                    } label: {
                        Label("Save it", systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(StrandPalette.accent)
                    .disabled(saving)

                    Button("Edit") {
                        editingCandidate = w
                        showEdit = true
                    }
                        .buttonStyle(.bordered)
                        .disabled(saving)

                    Button("Not a workout") { dismiss(w) }
                        .buttonStyle(.bordered)
                        .disabled(saving)
                    Spacer()
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// "Looks like a workout [yesterday ]around 14:05–14:32 (avg HR 148, 27 min). Save it?"
    /// Three whole-phrase variants (today / yesterday / dated, #719) so translators see complete
    /// sentences rather than a stitched day-label fragment.
    private func promptText(_ w: DetectedWorkout) -> String {
        let startDate = Date(timeIntervalSince1970: TimeInterval(w.startSec))
        let start = Self.timeFmt.string(from: startDate)
        let end = Self.timeFmt.string(from: Date(timeIntervalSince1970: TimeInterval(w.endSec)))
        let cal = Calendar.current
        if cal.isDateInToday(startDate) {
            return String(localized: "Heart rate suggests possible activity around \(start)-\(end) (avg HR \(w.avgBpm), \(w.durationMin) min). Was this a workout?")
        }
        if cal.isDateInYesterday(startDate) {
            return String(localized: "Heart rate suggests possible activity yesterday around \(start)-\(end) (avg HR \(w.avgBpm), \(w.durationMin) min). Was this a workout?")
        }
        return String(localized: "Heart rate suggests possible activity on \(Self.dateFmt.string(from: startDate)) around \(start)-\(end) (avg HR \(w.avgBpm), \(w.durationMin) min). Was this a workout?")
    }

    private func reload() async {
        guard !saving else { return }
        guard autoDetectEnabled else { candidate = nil; motionSupported = false; return }
        scanning = true
        defer { scanning = false }
        let next = await repo.autoDetectCandidate()
        if next == nil {
            let now = Int(Date().timeIntervalSince1970)
            let count = (await repo.hrFingerprint(from: now - 2 * 86_400, to: now))?.count ?? 0
            hasRecentHR = count >= 2
        } else {
            hasRecentHR = true
        }
        let supported: Bool
        if let next {
            supported = await repo.autoDetectHasMotionEvidence(next)
        } else {
            supported = false
        }
        // A superseded scan must not restore a suggestion while its save is in flight.
        guard !Task.isCancelled, !saving else { return }
        motionSupported = supported
        if next != candidate { saveError = false }
        handledThisSession = false
        candidate = next
    }

    private func save(_ w: DetectedWorkout) {
        guard !saving else { return }
        saving = true
        saveError = false
        Task {
            let saved = await repo.saveDetectedWorkout(w)
            await finishSave(saved)
        }
    }

    private func finishSave(_ saved: Bool) async {
        handledThisSession = saved
        saveError = !saved
        if saved { await repo.refresh() }
        saving = false
        // Refresh can leave refreshSeq unchanged. Explicitly request the next suggestion regardless.
        if saved { scanRequested += 1 }
    }

    private func dismiss(_ w: DetectedWorkout) {
        guard !saving else { return }
        repo.dismissDetectedSuggestion(w)
        handledThisSession = true
        candidate = nil
        saveError = false
        scanRequested += 1
    }

    /// HH:mm in the user's locale/timezone.
    /// #1821: routed through AppClock so the Clock format setting reaches this label. Was a `static
    /// let`, which would have frozen the reader's choice at first use until the app relaunched.
    private static var timeFmt: DateFormatter { AppClock.hourMinuteFormatter() }

    /// Localized medium date ("Jun 23, 2026") for a bout older than yesterday.
    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = AppLanguage.activeLocale
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
}

/// Reload key: a new sync (seq) or a toggle flip re-runs detection.
private struct AutoWorkoutLoadKey: Equatable {
    let seq: Int
    let enabled: Bool
    let request: Int
}
