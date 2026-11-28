import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Auto-detected workout prompt (Today screen)
//
// A single, dismissible Today card that appears ONLY when the opt-in "Auto-detect workouts"
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
    @AppStorage(PuffinExperiment.autoDetectWorkoutsKey) private var autoDetectEnabled = false

    /// The current suggestion, loaded in `.task`. nil → nothing to show.
    @State private var candidate: DetectedWorkout?
    /// Advisory coarse label only. It seeds the editable review form and is never saved automatically.
    @State private var sportPrediction: WorkoutClassPrediction?
    /// Hide immediately on Save/X without waiting for the next reload (avoids a flash of the old card).
    @State private var handledThisSession = false
    /// Guards the Save button while the write is in flight.
    @State private var saving = false
    @State private var motionSupported = false
    @State private var review: Review?
    @State private var reloadGeneration = 0
    @State private var loadRevision = 0
    @State private var saveError = false

    var body: some View {
        Group {
            if autoDetectEnabled, !handledThisSession, let w = candidate {
                card(for: w)
            }
        }
        // Re-scan whenever the data refreshes (a sync bumps refreshSeq) or the toggle flips on.
        .task(id: AutoWorkoutLoadKey(seq: repo.refreshSeq, enabled: autoDetectEnabled, revision: loadRevision)) {
            await reload()
        }
        .sheet(item: $review, onDismiss: { loadRevision &+= 1 }) { openedReview in
            ManualWorkoutSheet(editing: openedReview.draft, reviewingSuggestion: true,
                                   onReviewedSave: { row in
                    saving = true
                    let saved = await repo.saveReviewedDetectedWorkout(row, suggestion: openedReview.candidate)
                    if candidate == openedReview.candidate { handledThisSession = saved }
                    saveError = !saved
                    if saved { await repo.refresh() }
                    saving = false
                    return saved
                }) { _, _ in }
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
                    Text("Looks like a workout")
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

                Text("Suggested sport: \(sportPrediction?.predictedClass.suggestionReviewLabel ?? "Other / unsure"). This is only a starting point. Review it, or choose Other if unsure.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)

                if saveError {
                    Text("Could not save this activity. Check the values and try again.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.statusWarning)
                }

                HStack(spacing: NoopMetrics.space3) {
                    Button { review = Review(candidate: w, prediction: sportPrediction) } label: {
                        Label("Review time & sport", systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(StrandPalette.accent)
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
            return String(localized: "Looks like a workout around \(start)-\(end) (avg HR \(w.avgBpm), \(w.durationMin) min). Save it?")
        }
        if cal.isDateInYesterday(startDate) {
            return String(localized: "Looks like a workout yesterday around \(start)-\(end) (avg HR \(w.avgBpm), \(w.durationMin) min). Save it?")
        }
        return String(localized: "Looks like a workout on \(Self.dateFmt.string(from: startDate)) around \(start)-\(end) (avg HR \(w.avgBpm), \(w.durationMin) min). Save it?")
    }

    private func reload() async {
        reloadGeneration &+= 1
        let generation = reloadGeneration
        guard autoDetectEnabled else {
            candidate = nil; sportPrediction = nil; motionSupported = false
            return
        }
        let next = await repo.autoDetectCandidate()
        guard !Task.isCancelled, generation == reloadGeneration, autoDetectEnabled else { return }
        if let next, next != candidate {
            async let motionRead = repo.autoDetectHasMotionEvidence(next)
            async let sportRead = repo.autoDetectSportSuggestion(next)
            let motion = await motionRead
            let prediction = await sportRead
            guard !Task.isCancelled, generation == reloadGeneration, autoDetectEnabled else { return }
            motionSupported = motion
            sportPrediction = prediction
        } else if next == nil {
            motionSupported = false
            sportPrediction = nil
        }
        // A fresh scan resets the session guard so a NEW window can surface after one is handled.
        if next != candidate {
            handledThisSession = false
            saveError = false
        }
        candidate = next
    }

    private func dismiss(_ w: DetectedWorkout) {
        repo.dismissDetectedSuggestion(w)
        handledThisSession = true
        candidate = nil
        loadRevision &+= 1
    }

    /// A presented review owns its original span and draft even when a sync replaces the card.
    /// Saving must dismiss the reviewed suggestion, never whichever candidate was loaded afterwards.
    struct Review: Identifiable {
        let candidate: DetectedWorkout
        let draft: WorkoutRow
        var id: String { "\(candidate.startSec):\(candidate.endSec)" }

        init?(candidate: DetectedWorkout, prediction: WorkoutClassPrediction?) {
            guard let draft = WorkoutSource.buildManualRowFromSpan(
                start: Date(timeIntervalSince1970: TimeInterval(candidate.startSec)),
                end: Date(timeIntervalSince1970: TimeInterval(candidate.endSec)),
                sport: prediction?.predictedClass.editableSportName ?? "Other",
                avgHr: candidate.avgBpm, energyKcal: nil) else { return nil }
            self.candidate = candidate
            self.draft = draft
        }
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
    let revision: Int
}
