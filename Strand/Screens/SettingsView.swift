Warning: truncated output (original token count: 57247)
Total output lines: 3968

import SwiftUI
#if os(macOS)
import AppKit
#endif
#if os(iOS)
import UIKit
#endif
import UniformTypeIdentifiers
import PhotosUI
import StrandDesign
import StrandAnalytics
import WhoopStore
// #174: the R22 card reads the flag COUNT off `Whoop5Config.enableR22Sequence` rather than restating it —
// the hardcoded "15" outlived the sequence growing to 16 and declared success a flag early.
import WhoopProtocol

/// Settings — profile (powers zones / calories / recovery), strap connection, and about.
/// Grouped cards on surface.raised with a two-column form feel.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var live: LiveState
    @EnvironmentObject var profile: ProfileStore

    /// Profile-photo picker selection (PhotosUI). Cleared back to nil once the bytes are loaded.
    @State private var avatarPickerItem: PhotosPickerItem?

    /// Custom background image (#custom-background). The store owns the decoded image + toggles; the
    /// picker selection + the file-importer flag are local UI state.
    @ObservedObject private var backgroundStore = BackgroundImageStore.shared
    @State private var backgroundPickerItem: PhotosPickerItem?
    @State private var showBackgroundFileImporter = false

    /// Backup & restore UI state.
    @State private var backupBusy = false
    @State private var backupAlertTitle = ""
    @State private var backupAlertMessage = ""
    @State private var showBackupAlert = false
    /// #1807: a restore refused ONLY for size is recoverable, so it gets its own two-button alert rather
    /// than the shared single-OK one every other backup outcome uses.
    @State private var showOversizeRestoreConfirm = false
    @State private var oversizeRestoreMessage = ""

    /// Opt-in WHOOP 5/MG protocol experiments (off by default). See [PuffinExperiment].
    @AppStorage(PuffinExperiment.defaultsKey) private var puffinExperiments = false

    /// Opt-in WHOOP 5/MG raw-frame capture to a file (off by default). See [PuffinFrameRecorder].
    @AppStorage(PuffinFrameRecorder.enabledKey) private var puffinCapture = false

    /// Opt-in WHOOP 5/MG "R22" deep-data unlock (off by default) — the one probe that writes a
    /// persistent feature flag to the strap. See [PuffinExperiment.deepDataKey]. (#174)
    @AppStorage(PuffinExperiment.deepDataKey) private var deepDataEnabled = false

    /// #174: set when the deep-data switch is turned OFF, so the app can OFFER to clear the flags on the
    /// strap instead of silently leaving them set. The switch alone has never written anything in either
    /// direction — it gates sends — so turning it off used to change nothing on the hardware while reading
    /// like an undo. Asking is the right shape rather than writing automatically: the strap may not be
    /// connected, and a write to bonded hardware is not something a toggle should do unannounced.
    @State private var confirmingDeepDataDisable = false

    /// Opt-in "Broadcast heart rate" (off by default) — makes the strap advertise its HR as a standard
    /// BLE sensor for Garmin/Zwift/gym kit. See [PuffinExperiment.broadcastHrKey]. (#181)
    @AppStorage(PuffinExperiment.broadcastHrKey) private var broadcastHrEnabled = false

    /// #891 opt-in: writes the device-config key `enable_raw_data_w_ecg` on an attested WHOOP MG. A
    /// persistent strap write, so it gets its own deliberate switch like #174 and #181.
    /// See [PuffinExperiment.ecgRawDataKey].
    @AppStorage(PuffinExperiment.ecgRawDataKey) private var ecgRawDataEnabled = false

    /// #103 opt-in: surfaces the WHOOP 5/MG `spo2_candidate_82` nightly mean in the Blood Oxygen tile
    /// as a "strap estimate (unverified)" fallback when no calibrated `spo2Pct` exists. Display-only —
    /// writes nothing to the strap. See [PuffinExperiment.spo2CandidateDisplayKey].
    @AppStorage(PuffinExperiment.spo2CandidateDisplayKey) private var spo2CandidateDisplayEnabled = false

    /// #463 opt-in: score the intraday stress timeline against a PERSONAL cross-day baseline
    /// (`.baselineRelative`) instead of the day's own calm hours. Default off — the r≈0.6 margin is
    /// single-subject so far. Display-only; never feeds recovery/illness. See
    /// [PuffinExperiment.stressPersonalBaselineKey].
    @AppStorage(PuffinExperiment.stressPersonalBaselineKey) private var stressPersonalBaselineEnabled = false
    /// #1545 opt-in: score Effort with Banister's exponential TRIMP instead of Edwards' heart-rate zones.
    /// Default OFF — it re-scores the whole window against a different recipe. See
    /// [PuffinExperiment.banisterEffortKey].
    @AppStorage(PuffinExperiment.banisterEffortKey) private var banisterEffortEnabled = false

    /// True when the connected strap has positively attested itself a WHOOP MG. The variant is published as
    /// its label string (`LiveState.whoop5Variant`); "MG" is `Whoop5Variant.mg.label`. nil / not-yet-
    /// identified / a plain 5.0 is not an MG.
    private var ecgVariantIsMG: Bool { live.whoop5Variant == Whoop5Variant.mg.label }

    /// The #891 ECG-gate buttons need the same encrypted bond the R22 writes do (a config write over the
    /// live-HR-only link silently fails, #269) AND a strap that has positively attested itself an MG. Not
    /// wear-gated: this stores a value, it does not start an on-wrist stream.
    private var ecgGateReady: Bool {
        #if os(macOS)
        return false
        #else
        return live.encryptedBond && ecgVariantIsMG
        #endif
    }

    /// The reason line under the #891 buttons. Each case names the ONE thing that is missing.
    private var ecgGateReason: String {
        #if os(macOS)
        return String(localized: "The ECG gate needs an iPhone or Android. A Mac can't form the encrypted bond a 5/MG requires.")
        #else
        if !live.encryptedBond {
            return String(localized: "Needs the full encrypted bond: close the official WHOOP app and pair the strap to NOOP first (a live-HR-only link can't carry a config write).")
        }
        if !ecgVariantIsMG {
            // A nil / non-MG variant lands here too, and deliberately: an unattested strap is not an MG.
            return String(localized: "Waiting for your strap to identify itself as an MG. Only a WHOOP MG has ECG electrodes, so NOOP won't write this key to anything else.")
        }
        return String(localized: "One tap writes the key; NOOP then reads it back off the strap and reports the value it actually stores — the write's own \"success\" is not treated as proof.")
        #endif
    }

    /// Icon per read-back verdict. Only a confirmed read-back gets the success mark.
    private func ecgGateIcon(_ v: EcgRawDataGateReport.Verdict) -> String {
        switch v {
        case .confirmed: return "checkmark.seal.fill"
        case .unchanged: return "xmark.seal.fill"
        case .pending:   return "ellipsis"
        default:         return "questionmark.circle"
        }
    }

    /// Tint per read-back verdict. Anything that isn't a confirmed read-back is never shown as positive.
    private func ecgGateTint(_ v: EcgRawDataGateReport.Verdict) -> Color {
        switch v {
        case .confirmed: return StrandPalette.statusPositive
        case .unchanged: return StrandPalette.statusWarning
        default:         return StrandPalette.textSecondary
        }
    }

    /// WHOOP MG ECG ("Labrador") experiment. Unlocks the gated, user-initiated ECG probe on the Devices
    /// card. Default off; with it off the four ECG opcodes are dropped by the command allowlist, so no
    /// ECG byte can reach a strap. See [PuffinExperiment.ecgKey].
    @AppStorage(PuffinExperiment.ecgKey) private var ecgEnabled = false

    /// Opt-in "Continuous HRV capture" (off by default) — holds the dense realtime stream armed 24/7 so
    /// the strap banks beat-to-beat R-R for better overnight HRV/recovery/sleep, at a battery cost.
    /// See [PuffinExperiment.keepRealtimeForDataKey].
    @AppStorage(PuffinExperiment.keepRealtimeForDataKey) private var continuousHrvEnabled = false

    /// #927 "Overnight only" refinement of Continuous HRV capture (off by default): arm the stream only
    /// inside the nightly quiet-hours window instead of 24/7. Composed with the base toggle (base on +
    /// this off = ALWAYS, the pre-#927 behaviour); existing installs are pinned to OFF by
    /// `PuffinExperiment.migrateContinuousHrvOvernightDefault()` at launch, so they still see no change.
    ///
    /// The `@AppStorage` default MUST match `PuffinExperiment.continuousHrvOvernightOnlyEnabled` (#1008).
    /// They read the same key by different routes, so a mismatch shows the toggle OFF on a fresh install
    /// while capture is actually overnight-only — and a user "correcting" that would write an explicit
    /// false and get the 24/7 behaviour they were trying to avoid.
    @AppStorage(PuffinExperiment.continuousHrvOvernightOnlyKey) private var continuousHrvOvernightOnly = true

    // #477 Power saving moved OUT of this screen into `PowerSavingView` — a first-class More row on
    // iPhone (between Test Centre and Settings) and its own sidebar item on macOS. Its `@AppStorage`
    // keys live there now; nothing here reads them.

    /// "Experimental sleep staging (V2)" (ON by default, promoted after the 44-subject cross-subject
    /// benchmark). When on, detected nights are re-staged with `SleepStagerV2` (the transparent
    /// cardiorespiratory recipe) instead of the older V1 stager. Read at the staging call site in
    /// `Repository`. See [PuffinExperiment.experimentalSleepV2Key].
    @AppStorage(PuffinExperiment.experimentalSleepV2Key) private var experimentalSleepV2Enabled = true

    /// "Motion-aware wake refinement" (#364 follow-up, OFF by default). A post-pass over the already-staged
    /// hypnogram: reclassifies a scored WAKE segment to `light` when its per-minute step-tick cadence shows
    /// no locomotion and its per-minute gravity posture is stable outside a minority of isolated burst
    /// minutes. Self-gates on OBSERVED gravity + step density (#345) — a no-op on a sparse night (e.g.
    /// WHOOP 4.0) regardless of this switch. See [PuffinExperiment.motionAwareWakeKey].
    @AppStorage(PuffinExperiment.motionAwareWakeKey) private var motionAwareWakeEnabled = false

    // Display preferences. `units.system` remains the body-measurement choice for compatibility;
    // exercise distance/pace can override it independently. Stored data is always SI.
    /// #1821: Clock format. Defaults to `.system`, so upgrading changes nobody's displayed times.
    /// #1841: shared with Android by name and meaning; each platform keeps its own store. Default FALSE
    /// on Apple (Android defaults true) because the system behaviour may not fire on our
    /// `NavigationStack(path:)` tabs — see RootTabView.
    /// The Coach master switch, under the same `noop.` key Android writes. Default ON, so nothing changes
    /// for an install that never opens this row. Read by `RootTabView` (the tab), Today (the launcher card)
    /// and `CoachBriefScheduler` (the daily background brief).
    @AppStorage("noop.coachEnabled") private var coachEnabled = true
    @AppStorage("noop.bottomBarAutoHide") private var bottomBarAutoHide = false
    @AppStorage(ClockFormatPreference.defaultsKey)
    private var clockFormatRaw = ClockFormatPreference.system.rawValue
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.distanceSystemKey) private var distanceSystemRaw = ""
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""
    @AppStorage(UnitPrefs.skinTempDisplayKey) private var skinTempDisplayRaw = ""   // #1846
    // Effort display scale (#268). Display-only — Effort stays stored 0–100, this only chooses whether
    // it's shown on NOOP's 0–100 axis or WHOOP's 0–21 Day Strain axis.
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    @AppStorage(UnitPrefs.trendChartStyleKey) private var trendChartStyleRaw = TrendChartStyle.line.rawValue
    @AppStorage(UnitPrefs.hrvWindowKey) private var hrvWindowRaw = HrvWindow.whole.rawValue
    // Live-HR Live Activity (Lock Screen + Dynamic Island), iOS only (#336). Default on.
    @AppStorage(UnitPrefs.liveActivityKey) private var liveActivityEnabled = true
    // Strap-sync Live Activity, iOS only. Separate from the live-HR one on purpose. Default on.
    @AppStorage(UnitPrefs.syncLiveActivityKey) private var syncLiveActivityEnabled = true
    @AppStorage(DayCycleMode.storageKey) private var dayCycleModeRaw = DayCycleMode.sleepOnset.rawValue
    // Alternate app icon (iOS only) — false = Titanium (primary AppIcon), true = Blue Titanium
    // ("AppIcon-Navy"). Display-only preference; the live switch goes through setAlternateIconName.
    @AppStorage("appIcon.alt") private var useNavyIcon = false
    // Light/Dark/System theme. Read by both app roots' .preferredColorScheme; default follows the OS.
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.system.rawValue
    // App-owned copy language. Apple binds a bundle localization at process launch, so this writes the
    // standard AppleLanguages override and takes effect after the user reopens NOOP.
    @AppStorage(AppLanguage.storageKey) private var appLanguageRaw = AppLanguage.system.rawValue
    // Chart colour style: Titanium (brand) or Classic (throwback red→green). Re-colours gauges + charts.
    @AppStorage(ChartStyle.storageKey) private var chartStyleRaw = ChartStyle.titanium.rawValue
    // Sleep tab stage-CHART shape: Classic per-stage rows, or the WHOOP-style stepped hypnogram Filled/Ribbon.
    @AppStorage(SleepChartStyle.storageKey) private var sleepChartStyleRaw = SleepChartStyle.classic.rawValue
    // Chrome accent colour (mint / WHOOP blue / custom). Chrome only — never the data colour worlds.
    @AppStorage(AccentColor.storageKey) private var accentRaw = AccentColor.mint.rawValue
    @AppStorage(AccentColor.customHexKey) private var accentCustomHex = AccentColor.defaultCustomHex
    // Day-cycle scene backdrop behind Today (#698). Default ON. Off swaps the scene for a plain dark
    // canvas. TodayView reads the same key to gate its SceneScreenBackground.
    @AppStorage(SceneBackgroundPrefs.enabledKey) private var showDayCycleBackground = true
    // "Sky behind cards" (default ON): extend the day-cycle sky behind the whole Today scroll so
    // Card transparency reveals it under every card. User-toggleable below. Mirrors Kotlin NoopPrefs.skyBehindCards.
    @AppStorage(SkyBehindCardsPrefs.enabledKey) private var skyBehindCards = true
    // Card-surface opacity percent (100 = solid). Reactive — moving the slider live-updates every card.
    @AppStorage(CardAppearancePrefs.opacityKey) private var cardOpacityPercent = CardAppearancePrefs.defaultPercent
    // "Reduce motion in NOOP" (default OFF): pose every looping animation still and stop the decorative
    // tilt sensor, without needing system Low Power Mode or system Reduce Motion. Apple-only so far —
    // Android has no such toggle yet and its gate reads two signals, not three (#941).
    @AppStorage(QuietMotionPrefs.enabledKey) private var quietMotion = false
    // Hydration tracker (opt-in, MVP). Default OFF — when off the hydration dashboard card + detail are
    // hidden. Mirrors the Android pref so the toggle reads the same on both platforms.
    @AppStorage(HydrationStore.enabledKey) private var hydrationEnabled = false

    /// Opt-in "Auto-detect workouts" (default OFF). When ON, Today scans the last day or two of HR for a
    /// sustained-elevated window and offers — via a single dismissible card — to save it as a workout.
    /// Nothing is ever created automatically. Mirrors the Android `NoopPrefs.KEY_AUTO_DETECT_WORKOUTS`.
    @AppStorage(PuffinExperiment.autoDetectWorkoutsKey) private var autoDetectWorkoutsEnabled = false

    /// "Journal reminder" (#627, default ON). When ON, Today shows the persistent journal widget
    /// (last-7-days strip + tap-through). Mirrors the Android `NoopPrefs.KEY_JOURNAL_REMINDER_ENABLED`.
    @AppStorage(PuffinExperiment.journalReminderKey) private var journalReminderEnabled = true

    /// Opt-in "Keep screen on during a workout" (default OFF, #703). When ON, the live-workout view
    /// holds the screen awake while a manual recording is running so you can glance at your live HR
    /// without the device dimming. The live-workout view reads this same key. The string is shared
    /// verbatim with the Android twin (SharedPreferences "workoutKeepScreenOn").
    @AppStorage("workoutKeepScreenOn") private var workoutKeepScreenOn = false

    /// Opt-in "Keep screen on while syncing" (default OFF, iOS only). `SyncKeepAwake` holds the screen awake
    /// for as long as a strap history sync runs while this is on.
    @AppStorage(ScreenIdle.strapSyncKeepAwakeKey) private var syncKeepScreenOn = false

    /// The strap model the user last picked (same key the scan pickers write). Gates the WHOOP 4.0-only
    /// rename control in the strap card — renaming uses the Harvard command set, which a 5/MG doesn't share.
    @AppStorage("selectedWhoopModel") private var selectedWhoopModelRaw = WhoopModel.whoop4.rawValue
    /// Draft text for the strap-rename field (strap card). Empty placeholder; never pre-seeded so the
    /// current name stays visible separately above it.
    @State private var strapNameDraft = ""

    /// Whether to surface the WHOOP 5/MG-only probes (puffin/R22/broadcast-HR/frame-capture). Gated so a
    /// confident 4.0 owner never sees 5/MG controls that can't touch their strap (#22). The model
    /// preference DEFAULTS to whoop4, so we deliberately do NOT hide on the raw default alone — the same
    /// `"selectedWhoopModel"` key is rewritten to the family that actually advertised when a strap
    /// connects (BLEManager, PR#195), so a real 5/MG owner who never opened the model picker still flips
    /// this true the moment their strap is discovered. We hide the 5/MG block only when the user is
    /// confidently on a 4.0 (pref says whoop4 AND nothing 5/MG is connected). The always-on raw-CSV
    /// diagnostic stays visible on every model regardless.
    private var showFiveMGControls: Bool {
        selectedWhoopModelRaw == WhoopModel.whoop5mg.rawValue
    }

    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }
    private var distanceUnitSystem: UnitSystem {
        UnitPrefs.resolveDistance(system: unitSystem, override: distanceSystemRaw)
    }
    private var distanceSystemBinding: Binding<String> {
        Binding(get: { distanceUnitSystem.rawValue }, set: { distanceSystemRaw = $0 })
    }
    private var temperatureUnit: TemperatureUnit {
        UnitPrefs.resolveTemperature(system: unitSystem, override: temperatureRaw)
    }

    /// Raw-sensor CSV export (experimental diagnostic, #308/#276/#322). Holds the last-written file so
    /// macOS can "Reveal in Finder" after a share, mirroring the puffin-capture export.
    @State private var rawCsvBusy = false
    @State private var lastRawCsvURL: URL?

    /// #646/#651: the "Export raw + log" button's zip build now runs off the main actor, so a second tap
    /// mid-export would fire a second `exportPair` — two staged zips, two save panels / stacked share
    /// sheets (see the `present(activityItems:)` #455 comment). Same disable-while-busy guard as
    /// `rawCsvBusy` above.
    @State private var rawAndLogBusy = false

    /// Passive WHOOP 5/MG optical experiment: the picker writes local timestamp markers into the
    /// durable deep-buffer JSONL. It never calls a BLE write path.
    @State private var showOpticalPhasePicker = false
    @State private var opticalPhaseStatus = ""

    /// Confirm gate for the "Recalibrate Charge baseline" action (it re-learns the HRV anchor from tonight).
    @State private var showRecalibrateConfirm = false

    /// "What's New" changelog sheet, reachable any time from About.
    @State private var showWhatsNew = false

    /// "How your scores work" explainer sheet, reachable any time from About.
    @State private var showScoringGuide = false

    /// "How NOOP works" primer sheet (the four-section explainability primer), reachable any
    /// time from About — covers how sleep is sorted, how scores + calibration work, what
    /// recording means, and where the provenance badges come from.
    @State private var showHowNoopWorks = false

    /// "Set up Apple Watch" sheet: the honest watch onboarding flow (what it's great at, where
    /// it's lighter, then the Health permission request). Presented from the About page's primary
    /// action. iOS does the real HealthKit request; macOS reads as an iPhone-only step.
    @State private var showAppleWatchSetup = false

    /// Steps-estimate calibration sheet (WHOOP 4.0). Reached from the Profile card's "Steps estimate"
    /// tap-through; explains the estimate, shows the current fit + a recent estimated-vs-phone table,
    /// and offers a manual coefficient override. See [StepsCalibrationSheet].
    @State private var showStepsCalibration = false

    /// iOS environment-diagnostics sheet (device, iOS+build, Data Protection, background refresh,
    /// low-power, sideload + cert expiry). iOS-only; the macOS strap log already carries OS + version.
    @State private var showDiagnostics = false

    /// User-initiated GitHub release check behind the About "Check for updates" button.
    @StateObject private var updateChecker = UpdateChecker()
    /// #1659. Default comes from `UpdateAvailability.defaultEnabled` so the toggle and the launch check
    /// cannot disagree about what "unset" means.
    @AppStorage(UpdateWatch.Keys.enabled) private var autoCheckUpdates = UpdateAvailability.defaultEnabled
    @Environment(\.openURL) private var openURL

    /// Whether the "Advanced" disclosure (Recovery, Test Centre, experimental probes, Backup &
    /// restore) is expanded. Default FALSE so a first-run user lands on the handful of everyday
    /// sections (profile, units, appearance, strap, features) instead of the full wall of 11 cards
    /// (S3). Nothing is removed; every section below stays one tap away by expanding this group.
    /// Persisted so it remembers the user's choice; mirrors the Android `noop.settingsAdvancedOpen` key.
    @AppStorage(SettingsDisclosureDefaults.advancedOpenKey) private var advancedOpen = SettingsDisclosureDefaults.advancedOpenDefault

    var body: some View {
        ScreenScaffold(title: "Settings",
                       subtitle: "Your numbers, your strap, and how NOOP works. All on \(Platform.deviceNounPhrase).",
                       // The day-of-sky liquid backdrop, matching Today / Health / Sleep / Trends / Devices:
                       // a fixed, full-bleed time-of-day sky behind the scroll content (it does not scroll).
                       // Settings' own frosted cards sit on the dark canvas below the sky band, unchanged.
                       topBackground: liquidScaffoldSky()) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                // Everyday sections stay expanded (S3): the ones a first-run user actually needs.
                profileCard.staggeredAppear(index: 0)
                unitsCard.staggeredAppear(index: 1)
                appearanceCard.staggeredAppear(index: 2)
                strapCard.staggeredAppear(index: 3)
                streakCard.staggeredAppear(index: 4)
                featuresCard.staggeredAppear(index: 5)
                #if os(iOS)
                syncCard.staggeredAppear(index: 6)
                #endif

                // Lower-frequency sections collapse behind a single default-closed disclosure so the
                // screen opens at ~6 sections instead of 11. Nothing is removed; every section here
                // (Recovery / advanced scoring, Test Centre, the experimental probes + raw-capture, and
                // Backup & restore) stays one tap away. Modelled on the Test Centre "Advanced" group.
                SettingsDisclosureGroup(
                    title: "Advanced",
                    subtitle: "Recovery, HRV tuning, Test Centre, experimental probes, and backup. Tucked away to keep the everyday screen tidy.",
                    isExpanded: $advancedOpen
                ) {
                    recoveryCard
                    hrvCard   // #518: Continuous HRV capture + HRV window moved here out of the always-visible Strap card
                    testCentreCard
                    experimentalCard
                    backupCard
                }
                .staggeredAppear(index: 6)

                // About stays expanded at the foot (version, links and the help sheets people return to).
                aboutCard.staggeredAppear(index: 7)
            }
        }
        .alert(backupAlertTitle, isPresented: $showBackupAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(backupAlertMessage)
        }
        // Title and buttons reuse catalogue strings that already carry all nine locales, rather than
        // minting new copy that would ship English everywhere until someone translated it. The message
        // below is where the specifics live. (#1807)
        .alert("Backup problem", isPresented: $showOversizeRestoreConfirm) {
            Button("Restore") { runImport(allowOversize: true) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(oversizeRestoreMessage)
        }
        .confirmationDialog("Recalibrate your Charge baseline?",
                            isPresented: $showRecalibrateConfirm, titleVisibility: .visible) {
            Button("Recalibrate") { recalibrateHrvBaseline() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This restarts the roughly 4-night build-up for Charge and your HRV baseline. Your history stays. Use it if a bad first week, like wearing it while sick, set your baseline off.")
        }
        // #174: the switch going OFF is the moment to offer the undo. Declining leaves the flags set and
        // says so — which is still an improvement on the old behaviour, where the same tap silently left
        // them set with no indication either way.
        .confirmationDialog("Clear the R22 flags on your strap?",
                            isPresented: $confirmingDeepDataDisable, titleVisibility: .visible) {
            Button("Clear flags on strap") { model.ble.disableWhoop5DeepData() }
            Button("Just stop sending", role: .cancel) { }
        } message: {
            Text("Turning this switch off only stops NOOP sending the unlock. The flags it already wrote stay on the strap until something clears them. NOOP can write the off value to all 16 now and read each one back so you can see what the strap actually stores. Needs the strap connected and bonded.")
        }
        .confirmationDialog("Mark optical experiment phase",
                            isPresented: $showOpticalPhasePicker, titleVisibility: .visible) {
            ForEach(PuffinOpticalExperimentPhase.allCases, id: \.self) { phase in
                Button(phase.displayName) { markOpticalPhase(phase) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("A marker starts the selected phase and ends the previous one. This only timestamps the local capture file; it sends nothing to the strap.")
        }
        .sheet(isPresented: $showWhatsNew) {
            WhatsNewView(onClose: { showWhatsNew = false })
        }
        .sheet(isPresented: $showScoringGuide) {
            ScoringGuideView(onClose: { showScoringGuide = false })
        }
        .sheet(isPresented: $showHowNoopWorks) {
            HowNoopWorksView(onClose: { showHowNoopWorks = false })
        }
        .sheet(isPresented: $showAppleWatchSetup) {
            AppleWatchSetupView(onClose: { showAppleWatchSetup = false })
        }
        .sheet(isPresented: $showStepsCalibration) {
            StepsCalibrationSheet(repo: model.repo, onClose: { showStepsCalibration = false })
                .environmentObject(profile)
        }
        #if os(iOS)
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsSheet(onClose: { showDiagnostics = false })
        }
        #endif
    }

    // MARK: - Profile

    private var profileCard: some View {
        SettingsSection(
            icon: "person.fill",
            title: "Profile",
            blurb: "These power your heart-rate zones, calorie estimates and recovery baselines. Keep them accurate."
        ) {
            VStack(spacing: 0) {
                profilePhotoRow
                rowDivider
                FormRow(label: "Date of birth") {
                    HStack(spacing: 12) {
                        Text("\(profile.age)")
                            .font(StrandFont.bodyNumber)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .frame(minWidth: 28, alignment: .trailing)
                        // #146: age is derived from the date of birth, so it advances on its own.
                        DatePicker("Date of birth",
                                   selection: $profile.dateOfBirth,
                                   in: ProfileStore.dateOfBirthRange,
                                   displayedComponents: .date)
                            .labelsHidden()
                            .tint(StrandPalette.accent)
                            .accessibilityLabel("Date of birth, age \(profile.age) years")
                    }
                }
                rowDivider
                FormRow(label: "Sex") {
                    Picker("Sex", selection: $profile.sex) {
                        Text("Male").tag("male")
                        Text("Female").tag("female")
                        Text("Non-binary").tag("nonbinary")
                    }
                    .labelsHidden()
                    // #43: .menu, not .segmented + .fixedSize(). In FormRow's label(∞)+control HStack a
                    // segmented picker collapses WITHOUT .fixedSize() but OVERFLOWS the screen WITH it once
                    // the labels are long (German "Nicht-binär") or Text Size is enlarged — the oversized
                    // Settings screen users reported. A menu is a compact button that fits any label length.
                    .pickerStyle(.menu)
                    .tint(StrandPalette.accent)
                    .accessibilityLabel("Sex")
                }
                rowDivider
                FormRow(label: "Weight") {
                    // Imperial mode steps in pounds and stores the kg equivalent; metric steps in kg.
                    if unitSystem == .imperial {
                        poundsField(weightKg: $profile.weightKg)
                    } else {
                        measureField(value: $profile.weightKg, unit: "kg",
                                     range: 30...250, step: 0.5, format: "%.1f",
                                     accessibility: String(localized: "Weight in kilograms"))
                    }
                }
                rowDivider
                FormRow(label: "Height") {
                    // Imperial mode steps in whole inches and stores the cm equivalent; metric steps in cm.
                    if unitSystem == .imperial {
                        feetInchesField(heightCm: $profile.heightCm)
                    } else {
                        measureField(value: $profile.heightCm, unit: "cm",
                                     range: 120...230, step: 1, format: "%.0f",
                                     accessibility: String(localized: "Height in centimetres"))
                    }
                }
                rowDivider
                // Waist (optional). Unlike the rows above it, an empty waist is valid (0 = unset).
                // VO₂max is ALWAYS offered (the Uth HR-ratio fallback needs no waist, #1391); a waist just
                // upgrades it to the more accurate Nes waist-based estimate. It does NOT sharpen the Fitness
                // Age itself (the body term cancels in the Nes model), so the note says it makes VO₂max more
                // accurate rather than implying it tunes the age.
                FormRow(label: "Waist (optional)") {
                    // Imperial mode steps in whole inches and stores the cm equivalent; metric steps in cm.
                    if unitSystem == .imperial {
                        waistInchesField(waistCm: $profile.waistCm)
                    } else {
                        waistCentimetresField(waistCm: $profile.waistCm)
                    }
                }
                Text("Optional: VO₂max builds from about 4 nights of heart rate; a waist makes it more accurate. The Fitness Age itself doesn't need it. Measure around your middle, at the navel.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                rowDivider
                FormRow(label: "Max heart rate") {
                    VStack(alignment: .trailing, spacing: 6) {
                        hrMaxField
                        Text(profile.hrMaxOverride > 0
                             ? "Manual override"
                             : "Auto · \(profile.hrMax) bpm (Tanaka)")
                            .font(StrandFont.footnote)
                            .foregroundStyle(profile.hrMaxOverride > 0
                                             ? StrandPalette.accent
                                             : StrandPalette.textTertiary)
                    }
                }
                rowDivider
                // Custom HR zones (#531, @kavemang): replace the conventional %HRmax bands with five
                // personalized inclusive BPM lower bounds. Off = the effective set stays conventional.
                FormRow(label: "Custom HR zones") {
                    Toggle("Custom HR zones", isOn: Binding(
                        get: { profile.hasCustomHRZones },
                        set: { profile.setCustomHRZonesEnabled($0) }
                    ))
                    .labelsHidden()
                    .accessibilityLabel("Custom HR zones")
                }
                if profile.hasCustomHRZones {
                    Text("Set the BPM where each zone begins. Turn off to restore the default percentage-of-max zones.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(profile.hrZoneThresholds.indices, id: \.self) { index in
                        rowDivider
                        FormRow(label: "Zone \(index + 1) starts") {
                            hrZoneThresholdField(index: index)
                        }
                    }
                }
                rowDivider
                FormRow(label: "Day cycle") {
                    Picker("Day starts", selection: Binding(
                        get: { DayCycleMode.persisted(dayCycleModeRaw) },
                        set: { mode in
                            dayCycleModeRaw = mode.rawValue
                            Task { await model.intelligence.analyzeRecent(); await model.repo.refresh() }
                        }
                    )) {
                        Text("Main sleep").tag(DayCycleMode.sleepOnset)
                        Text("00:00").tag(DayCycleMode.midnight)
             …39247 tokens truncated…                       Text(title)
                            .font(StrandFont.title2)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(subtitle)
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: NoopMetrics.space2)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(LiquidPressStyle())
            .accessibilityLabel(title)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Shows the advanced settings sections")
            .accessibilityAddTraits(.isButton)

            if isExpanded {
                content()
            }
        }
    }
}

// MARK: - Section card

/// A grouped settings card: a "Settings" overline + icon + title header, an explanatory blurb,
/// then content. The surface stays neutral; accent blue is reserved for the icon and controls.
private struct SettingsSection<Content: View>: View {
    let icon: String
    let title: LocalizedStringKey
    let blurb: LocalizedStringKey
    @ViewBuilder var content: () -> Content

    var body: some View {
        StrandCard(padding: NoopMetrics.space5) {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Settings").strandOverline()
                    HStack(spacing: NoopMetrics.space2 + 2) {
                        Image(systemName: icon)
                            .foregroundStyle(StrandPalette.accent)
                            .accessibilityHidden(true)
                        Text(title)
                            .font(StrandFont.title2)
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                }
                Text(blurb)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                content()
            }
        }
    }
}

// MARK: - iOS diagnostics sheet

#if os(iOS)
/// A read-only environment dump for bug reports: device, iOS+build, Data Protection (#222),
/// background refresh, low-power, sideload + cert expiry — with a one-tap Copy.
private struct DiagnosticsSheet: View {
    let onClose: () -> Void

    /// Captured once at presentation; a snapshot, not a live monitor.
    private let lines: [String] = IOSDiagnostics.capture().summaryLines()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Diagnostics").font(StrandFont.title2)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("Attach this to a bug report.").font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            .padding(20)

            Divider().overlay(StrandPalette.hairline)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if lines.isEmpty {
                        Text("No iOS diagnostics available.")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textTertiary)
                    } else {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(StrandFont.mono(12))
                                .foregroundStyle(StrandPalette.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(StrandPalette.surfaceInset,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(20)
            }
            #if os(iOS)
            // #697/#horizontal-swipe parity, see ScreenScaffold.
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            #endif

            Divider().overlay(StrandPalette.hairline)

            HStack {
                Spacer()
                Button {
                    // UIPasteboard via the shared cross-platform wrapper.
                    PlatformPasteboard.copy(lines.joined(separator: "\n"))
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .frame(minWidth: 120)
                }
                .buttonStyle(NoopButtonStyle(.primary))
                .disabled(lines.isEmpty)
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StrandPalette.surfaceBase)
    }
}
#endif

// MARK: - Steps estimate calibration

/// Small shared formatters for the steps-estimate calibration UI — kept apart from the sheet so the
/// Profile-card summary row and the sheet agree on the confidence wording. Mirrors the Android
/// `StepsCalibrationFormat` object.
enum StepsCalibrationFormat {
    /// A 0–1 confidence as Low / Medium / High — the honest read-out the sheet and the summary row share.
    /// Thirds: < 0.34 Low, < 0.67 Medium, else High. A manual coefficient is confidence 1.0 → "High".
    static func confidenceLabel(_ confidence: Double) -> String {
        switch confidence {
        case ..<0.34: return String(localized: "Low")
        case ..<0.67: return String(localized: "Medium")
        default:      return String(localized: "High")
        }
    }
}

/// One recent day's estimated-vs-phone steps comparison row, for the sheet's accuracy table.
private struct StepsComparisonRow: Identifiable {
    let day: String          // yyyy-MM-dd
    let estimated: Int
    let actual: Int
    var id: String { day }
    /// Signed error of the estimate against the phone count, as a percentage (estimate − actual) / actual.
    var errorPct: Double { actual > 0 ? Double(estimated - actual) / Double(actual) * 100 : 0 }
}

/// WHOOP 4.0 steps-ESTIMATE calibration — honest explainer + current fit + a recent estimated-vs-phone
/// table + a manual coefficient override with a live preview. Presented as a sheet from Settings →
/// Profile → "Steps estimate". Reads the SAME data the engine fits against (the computed `steps_est`
/// series and the phone's `steps`), never recomputing the headline. Mirrors Android `StepsCalibrationScreen`.
// Internal (not file-private) so the Today Steps tile can present the SAME calibration sheet directly
// when it's showing an ESTIMATE for a WHOOP 4.0 user — one shared entry point, no duplicated screen (H6).
struct StepsCalibrationSheet: View {
    let repo: Repository
    let onClose: () -> Void
    @EnvironmentObject var profile: ProfileStore

    /// Recent days that have BOTH an estimate and a real phone step count, newest first — the accuracy table.
    @State private var comparison: [StepsComparisonRow] = []
    /// A representative recent motion volume (median of recent days' motion), used so the manual-coefficient
    /// preview reflects a TYPICAL day. nil until loaded / no recent estimated day with a known motion.
    @State private var sampleMotion: Double?

    /// The draft manual coefficient the slider edits, committed to ProfileStore on release. 0 = auto-fit.
    @State private var draftManual: Double = 0
    @State private var didLoad = false

    /// The strap has banked no motion, and we have looked.
    ///
    /// Named once because two places depend on it and they must stay exactly complementary: the
    /// no-motion banner appears, and the calibration countdown does NOT. Written as two separate
    /// expressions they drifted immediately — the guard's first draft tested `sampleMotion == nil`
    /// alone, which is also true during the load, so the countdown vanished in a window where the
    /// banner had not appeared yet and the card explained nothing at all.
    private var strapHasNoMotion: Bool { didLoad && sampleMotion == nil }

    /// #107: the sheet's guidance depends on the strap family. A WHOOP 4.0 streams motion automatically, so
    /// "let it sync" is right; a 5/MG only streams motion once the experimental deep-data unlock is on, so
    /// the 4.0 advice is futile there and the empty state must say so instead.
    @AppStorage("selectedWhoopModel") private var selectedWhoopModelRaw = WhoopModel.whoop4.rawValue
    @AppStorage(PuffinExperiment.deepDataKey) private var deepDataEnabled = false
    private var is5MG: Bool { selectedWhoopModelRaw == WhoopModel.whoop5mg.rawValue }

    /// The coefficient the slider's max anchors to — generous headroom over whatever the auto-fit found so
    /// a manual nudge in either direction is reachable. Floor keeps the slider usable before any fit.
    private var sliderMax: Double {
        max(profile.stepsCalibrationCoefficient, profile.stepsManualCoefficient, 50) * 2
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(StrandPalette.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                    explainerCard
                    if strapHasNoMotion { noMotionNote }
                    currentFitCard
                    comparisonCard
                    manualAdjustCard
                }
                .padding(20)
            }
            #if os(iOS)
            // #697/#horizontal-swipe parity, see ScreenScaffold.
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            #endif
            Divider().overlay(StrandPalette.hairline)
            footerBar
        }
        #if os(macOS)
        .frame(width: 560, height: 680)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .noopSheetPresentation(largeFirst: true)
        #endif
        .background(StrandPalette.surfaceBase)
        .task { await loadIfNeeded() }
    }

    // MARK: Header / footer

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("STEPS ESTIMATE").font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textTertiary)
                Text("Calibrate your steps").font(StrandFont.rounded(26, weight: .bold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(is5MG ? "WHOOP 5.0 / MG · motion → steps" : "WHOOP 4.0 · motion → steps").font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(20)
    }

    private var footerBar: some View {
        HStack {
            Spacer()
            Button(action: onClose) {
                Text("Done").frame(minWidth: 120)
            }
            .buttonStyle(NoopButtonStyle(.primary))
            .keyboardShortcut(.defaultAction)
        }
        .padding(NoopMetrics.space4)
    }

    // MARK: Cards

    /// The honest "it's an estimate, not a step counter" framing — reused verbatim from the engine doc.
    private var explainerCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("How this works", systemImage: "figure.walk.motion")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(is5MG
                     ? String(localized: "NOOP estimates your steps from your WHOOP's stored motion, calibrated to your phone's step count. It's an estimate, not a hardware step counter; normal WHOOP 5/MG history sync supplies the motion data.")
                     : String(localized: "NOOP estimates your steps from your WHOOP's motion, calibrated to your phone's step count. It's an estimate, not a step counter. A WHOOP 4.0 doesn't transmit steps."))
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("On the days your phone also counted steps, NOOP learns how much your motion maps to steps, then applies that to the strap-only days. The more matching days it has, the more it trusts the estimate.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Shown when the strap has banked NO motion yet (sampleMotion is nil) — the real reason a fresh
    /// WHOOP 4.0 shows zero steps (#37 bringiton321). Steps are built from the strap's synced motion
    /// history, so without a backfill there is nothing to estimate from — calibration can't help yet.
    ///
    /// #107: family-aware. A 4.0 streams motion automatically → "let it sync" is right. A 5/MG only streams
    /// motion once the experimental deep-data unlock is ON — so on a 5/MG the honest advice is "turn that on
    /// and reconnect", not "wait for a sync" (which never comes). Imports don't supply strap motion either.
    private var noMotionNote: some View {
        NoopCard(tint: StrandPalette.metricAmber) {
            VStack(alignment: .leading, spacing: 10) {
                Label("No motion synced yet", systemImage: "antenna.radiowaves.left.and.right.slash")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(noMotionLead)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(noMotionAction)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The "why it's empty" line — a 5/MG needs the deep-data unlock before it streams motion at all.
    private var noMotionLead: String {
        if is5MG {
            return String(localized: "We're not seeing motion from your WHOOP 5.0 / MG yet. Keep NOOP connected and let strap history finish syncing; the experimental R22 flags are not required. Account or Apple Health imports do not contain the raw strap motion this estimate needs.")
        }
        return String(localized: "We're not seeing any motion from your strap yet. Steps are estimated from your WHOOP's banked motion history, so your strap needs to sync that history before NOOP has anything to count.")
    }

    /// The "what to do" line — 5/MG points at the deep-data toggle (unless it's already on, then just sync).
    private var noMotionAction: String {
        if is5MG && !deepDataEnabled {
            return String(localized: "Open NOOP near the strap and let WHOOP 5/MG history finish syncing. The step estimate and calibration fill in once enough stored motion has arrived; the legacy R22 experiment is not required.")
        }
        if is5MG {
            return String(localized: "Deep data is on — open NOOP near your strap and let it sync its motion history (a full first-run sync can take a while). Once a day or two of motion lands, your step estimate and the calibration below fill in.")
        }
        return String(localized: "Open NOOP near your strap and let it catch up (a full history sync can take a while on first run). Once a day or two of motion lands, your step estimate and the calibration below will start to fill in.")
    }

    /// The current calibration read-out: coefficient, sample days, and a Low/Medium/High confidence —
    /// or, if nothing's fit yet and no manual value is set, an honest "what we still need" prompt.
    private var currentFitCard: some View {
        NoopCard(tint: StrandPalette.accent) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Current calibration").strandOverline()
                if profile.stepsCalibrationCoefficient > 0 || profile.stepsManualCoefficient > 0 {
                    let coeff = profile.stepsManualCoefficient > 0
                        ? profile.stepsManualCoefficient : profile.stepsCalibrationCoefficient
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(String(format: "%.1f", coeff))
                            .font(StrandFont.number(30))
                            .foregroundStyle(StrandPalette.accent)
                        Text("steps per motion unit")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    if profile.stepsManualCoefficient > 0 {
                        statLine(String(localized: "Source"), String(localized: "Manual (you set this by hand)"))
                    } else {
                        statLine(String(localized: "Fitted from"),
                                 profile.stepsCalibrationSampleDays == 1
                                     ? String(localized: "1 day your phone also counted")
                                     : String(localized: "\(profile.stepsCalibrationSampleDays) days your phone also counted"))
                        statLine(String(localized: "Confidence"), "\(StepsCalibrationFormat.confidenceLabel(profile.stepsCalibrationConfidence)) · \(Int((profile.stepsCalibrationConfidence * 100).rounded()))%")
                    }
                } else {
                    Text("Not calibrated yet")
                        .font(StrandFont.bodyNumber)
                        .foregroundStyle(StrandPalette.textPrimary)
                    // Only ask for phone-step days when phone-step days are what is actually missing.
                    //
                    // A step estimate is `motion * coefficient` (`StepsEstimateEngine.estimate`) and a
                    // calibration point is the ratio `steps / motion`, so BOTH halves are required. With no
                    // banked strap motion neither the estimate nor the fit can move however many days the
                    // phone counts. The countdown below then names the half the user already has and hides
                    // the half they do not — a field report asked whether entering Apple Health steps by
                    // hand would start the calibration, which is exactly the conclusion it invites.
                    //
                    // The no-motion banner at the top of this sheet already explains the real blocker, so
                    // the honest move is to stop competing with it rather than to add more copy.
                    if !strapHasNoMotion {
                    // #589: a concrete countdown instead of a vague "a few days". Headline comes straight
                    // from the engine's needsMoreDays state so the wording matches the Today steps tile.
                    // #693: drive `have` off `profile.stepsCalibrationSampleDays` — the value the engine
                    // persists for the not-yet-calibrated case (IntelligenceEngine.swift sets it to the
                    // usable-day `have`, the SAME source the Today tile reads). `usableMatchedDays` can't be
                    // used here: `loadIfNeeded` early-returns before computing it when coeff == 0 (no fit
                    // yet), so it would always read 0 and the card was stuck on "Need 3 more days".
                    Text(StepsEstimateEngine.CalibrationStatus
                        .needsMoreDays(have: profile.stepsCalibrationSampleDays,
                                       need: StepsEstimateEngine.minCalibrationDays)
                        .headline)
                        .font(StrandFont.bodyNumber)
                        .foregroundStyle(StrandPalette.accent)
                    Text("These are the days where your phone also counted steps, so NOOP can learn how your motion maps to steps. Or set the coefficient manually below.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// The accuracy table: recent days that have BOTH an estimate and a phone count, side by side, so the
    /// user can SEE how close the estimate runs. Empty until enough both-have days exist.
    private var comparisonCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Estimated vs your phone").strandOverline()
                if comparison.isEmpty {
                    Text("No days yet where both NOOP and your phone counted steps. Once your phone logs a few days alongside the strap, they'll appear here so you can see how close the estimate is.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    // Column header.
                    HStack {
                        Text("Day").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Est.").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                            .frame(width: 64, alignment: .trailing)
                        Text("Phone").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                            .frame(width: 64, alignment: .trailing)
                        Text("Δ").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                            .frame(width: 52, alignment: .trailing)
                    }
                    ForEach(comparison) { row in
                        HStack {
                            Text(Self.shortDay(row.day))
                                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(Self.grouped(row.estimated))
                                .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textPrimary)
                                .frame(width: 64, alignment: .trailing)
                            Text(Self.grouped(row.actual))
                                .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textPrimary)
                                .frame(width: 64, alignment: .trailing)
                            Text(String(format: "%+.0f%%", row.errorPct))
                                .font(StrandFont.captionNumber)
                                .foregroundStyle(abs(row.errorPct) <= 15
                                                 ? StrandPalette.metricCyan : StrandPalette.statusWarning)
                                .frame(width: 52, alignment: .trailing)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(Self.shortDay(row.day)): estimated \(row.estimated) steps, phone \(row.actual) steps, \(Int(row.errorPct.rounded())) percent difference")
                    }
                    Text("These days are excluded from the estimate (your phone's real count is shown instead). They're here only so you can judge the estimate's accuracy.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
        }
    }

    /// Manual override: a slider bound to a draft, committed on release, with a live preview of what a
    /// typical recent day would estimate at the chosen coefficient. 0 returns to auto-fit.
    private var manualAdjustCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Adjust manually").strandOverline()
                Text("Override the automatic fit with your own steps-per-motion value. Useful if your phone has no step history to learn from, or the estimate runs consistently high or low. Set it back to auto by dragging to the far left.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(draftManual > 0 ? String(format: "%.1f", draftManual) : String(localized: "Auto"))
                        .font(StrandFont.number(24))
                        .foregroundStyle(draftManual > 0 ? StrandPalette.accent : StrandPalette.textSecondary)
                    Text(draftManual > 0 ? "steps / motion unit" : "fit from your phone")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                    Spacer()
                }

                Slider(value: $draftManual, in: 0...sliderMax, step: 0.5) {
                    Text("Manual steps coefficient")
                } minimumValueLabel: {
                    Text("Auto").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                } maximumValueLabel: {
                    Text("High").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                } onEditingChanged: { editing in
                    // Commit on release — snap a tiny drag back to 0 (auto) so "auto" is reachable.
                    if !editing { profile.stepsManualCoefficient = draftManual < 0.5 ? 0 : draftManual }
                }
                .tint(StrandPalette.accent)
                .accessibilityValue(draftManual > 0
                                    ? "\(String(format: "%.1f", draftManual)) steps per motion unit"
                                    : "Automatic")

                // Live preview: a typical recent day re-estimated at the draft coefficient.
                if let motion = sampleMotion {
                    let effective = draftManual > 0 ? draftManual : profile.stepsCalibrationCoefficient
                    if effective > 0 {
                        let preview = Int((motion * effective).rounded())
                        statLine(String(localized: "A typical recent day"),
                                 draftManual > 0
                                     ? String(localized: "≈ \(Self.grouped(preview)) steps at this setting")
                                     : String(localized: "≈ \(Self.grouped(preview)) steps (auto)"))
                    }
                }
                if draftManual > 0 {
                    Text("Takes effect on the next analytics pass (after the next sync).")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
    }

    /// A small "label … value" line shared by the fit + preview cards.
    private func statLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            Spacer(minLength: 12)
            Text(value).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: Data

    /// Build the comparison table + a typical-day motion, once. The engine stores `steps_est` ONLY for
    /// strap-only days (a phone-covered day uses the phone's real count), so an estimate and a phone count
    /// never co-exist in storage. To still SHOW "how close the estimate is", we reconstruct what the
    /// estimate WOULD have been on recent phone-covered days: read each day's motion volume the same way
    /// the engine does (gravity over [localMidnight, +24h)) and run the public `StepsEstimateEngine` with
    /// the live calibration. This reuses the engine, never invents a number, and needs no extra storage.
    private func loadIfNeeded() async {
        guard !didLoad else { return }
        didLoad = true
        draftManual = profile.stepsManualCoefficient

        // Effective calibration in force right now: a manual override wins, else the persisted auto-fit.
        let coeff = profile.stepsManualCoefficient > 0
            ? profile.stepsManualCoefficient : profile.stepsCalibrationCoefficient

        // Phone reference steps from Apple Health daily rows (steps > 0 only), newest first.
        let appleRows = await repo.appleDailyRows()
        let phoneDays = appleRows
            .compactMap { row -> (day: String, steps: Int)? in
                guard let s = row.steps, s > 0 else { return nil }
                return (row.day, s)
            }
            .sorted { $0.day > $1.day }

        // Reconstruct the estimate for the most recent phone-covered days, motion-by-motion.
        guard coeff > 0 else { return }
        let cal = StepsEstimateEngine.Calibration(coefficient: coeff,
                                                  sampleDays: profile.stepsCalibrationSampleDays,
                                                  confidence: profile.stepsCalibrationConfidence,
                                                  manual: profile.stepsManualCoefficient > 0)
        let dayParser = DateFormatter(); dayParser.locale = Locale(identifier: "en_US_POSIX"); dayParser.dateFormat = "yyyy-MM-dd"
        let calendar = Calendar.current
        var rows: [StepsComparisonRow] = []
        var motions: [Double] = []
        for entry in phoneDays.prefix(10) {           // scan a few extra to fill 7 after motion gaps
            guard let dayDate = dayParser.date(from: entry.day) else { continue }
            let mid = Int(calendar.startOfDay(for: dayDate).timeIntervalSince1970)
            // #1643: the UNION, not `repo.deviceId` alone — a re-added strap leaves motion under both the
            // active id and the canonical one, and reading either by itself makes this screen disagree
            // with the estimator it is supposed to be reconstructing.
            let grav = await repo.gravitySamplesUnion(from: mid, to: mid + 86_400 - 1)
            let motion = StepsEstimateEngine.dayMotionIntensity(grav)
            guard motion > 0, let est = StepsEstimateEngine.estimate(motion: motion, calibration: cal) else { continue }
            motions.append(motion)
            rows.append(StepsComparisonRow(day: entry.day, estimated: est, actual: entry.steps))
            if rows.count >= 7 { break }
        }
        comparison = rows
        // #693: the "Need N more days…" countdown is now driven by `profile.stepsCalibrationSampleDays`
        // (the engine-persisted usable-day count, read directly in the card) — NOT a local match count
        // computed here. This scan reaches here ONLY when coeff > 0 (already calibrated), so a local count
        // would never reflect the not-yet-calibrated state the countdown describes. The rows still feed the
        // accuracy table (`comparison`) above.

        // Typical recent day's motion for the live preview = median of the motions we just measured.
        if !motions.isEmpty {
            let s = motions.sorted()
            sampleMotion = s[s.count / 2]
        }
    }

    // MARK: Formatting

    private static func grouped(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
    /// "yyyy-MM-dd" → "EEE d MMM" for the table's day column.
    private static func shortDay(_ key: String) -> String {
        let inF = DateFormatter(); inF.locale = Locale(identifier: "en_US_POSIX"); inF.dateFormat = "yyyy-MM-dd"
        guard let d = inF.date(from: key) else { return key }
        let outF = DateFormatter(); outF.dateFormat = "EEE d MMM"
        return outF.string(from: d)
    }
}

// MARK: - Two-column form row

/// Label on the left, control on the right — the two-column form feel.
private struct FormRow<Control: View>: View {
    let label: LocalizedStringKey
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: NoopMetrics.space4) {
            Text(label)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            control()
                .layoutPriority(1)
        }
        .frame(minHeight: 32)
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Settings") {
    let model = AppModel()
    model.live.bonded = true
    model.live.connected = true
    model.live.batteryPct = 64
    return SettingsView()
        .environmentObject(model)
        .environmentObject(model.live)
        .environmentObject(model.profile)
        // iPhone-width (402pt) so the narrow Backup row stays in the preview's blast radius —
        // at 720 the three-up button row had slack and the truncation regression slipped through. (#188)
        .frame(width: 402, height: 900)
        .background(StrandPalette.surfaceBase)
        .preferredColorScheme(.dark)
}
#endif

// MARK: - Custom accent colour bridge

private extension Color {
    /// sRGB hex (`#RRGGBB`) for persisting a `ColorPicker` selection into `AccentColor.customHexKey`.
    /// Falls back to nil if the colour can't resolve to sRGB (the caller then keeps the default).
    var noopAccentHex: String? {
        #if os(iOS)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        #elseif os(macOS)
        guard let ns = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let r = ns.redComponent, g = ns.greenComponent, b = ns.blueComponent
        #endif
        return String(format: "#%02X%02X%02X",
                      Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }
}
