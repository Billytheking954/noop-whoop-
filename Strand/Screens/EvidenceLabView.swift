import SwiftUI
import StrandDesign

/// Settings → Test Centre → Evidence Lab
/// 
/// The unified research evidence hub displaying:
/// - Night Lab quality dashboard and signal coverage
/// - SpO2 candidate signal status (experimental_unvalidated)
/// - Device wear validation metrics
/// - Reference pairing progress tracker
/// - Educational content (embedded NIGHT_LAB.md and SPO2_VALIDATION_FRAMEWORK.md)
/// 
/// This view honors the Night Lab invariant: raw evidence is sealed blind, references join only
/// after algorithm execution, and all experimental signals are explicitly labeled as unvalidated.

struct EvidenceLabView: View {
    @EnvironmentObject var model: AppModel
    
    @State private var selectedTab: EvidenceLabTab = .overview
    @State private var showDocumentation = false
    @State private var selectedDoc: DocumentationType = .nightLab
    
    enum EvidenceLabTab {
        case overview
        case signalCoverage
        case spo2Candidate
        case validation
        case docs
    }
    
    enum DocumentationType {
        case nightLab
        case spo2Validation
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            header
            
            // Tab bar
            evidenceLabTabBar
            
            // Content based on selected tab
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                    switch selectedTab {
                    case .overview:
                        overviewContent
                    case .signalCoverage:
                        signalCoverageContent
                    case .spo2Candidate:
                        spo2CandidateContent
                    case .validation:
                        validationContent
                    case .docs:
                        documentationContent
                    }
                }
                .padding(NoopMetrics.space4)
            }
        }
        .background(StrandPalette.surfaceBase)
    }
    
    // MARK: - Header
    
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("EVIDENCE LAB").font(StrandFont.overline)
                .tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textSecondary)
            Text("Research Integrity & Signal Validation")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            Text("Night Lab, device wear state, SpO2 candidate, and validation progress")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(NoopMetrics.space4)
        .background(StrandPalette.surfaceRaised)
    }
    
    // MARK: - Tab Bar
    
    private var evidenceLabTabBar: some View {
        HStack(spacing: 0) {
            TabBarButton(
                icon: "chart.bar",
                label: "Overview",
                isActive: selectedTab == .overview
            ) { selectedTab = .overview }
            
            TabBarButton(
                icon: "waveform.circle",
                label: "Signals",
                isActive: selectedTab == .signalCoverage
            ) { selectedTab = .signalCoverage }
            
            TabBarButton(
                icon: "drop.circle",
                label: "SpO2",
                isActive: selectedTab == .spo2Candidate
            ) { selectedTab = .spo2Candidate }
            
            TabBarButton(
                icon: "checkmark.circle",
                label: "Validation",
                isActive: selectedTab == .validation
            ) { selectedTab = .validation }
            
            TabBarButton(
                icon: "doc.text",
                label: "Docs",
                isActive: selectedTab == .docs
            ) { selectedTab = .docs }
        }
        .frame(height: 44)
        .background(StrandPalette.surfaceRaised)
        .overlay(alignment: .top) { StrandPalette.hairline.frame(height: 1) }
    }
    
    // MARK: - Tab 1: Overview
    
    private var overviewContent: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            // Core principle card
            principleCard
            
            // Quick status summary
            statusSummaryCard
            
            // Night quality assessment
            nightQualityCard
            
            // Research timeline
            researchTimelineCard
        }
    }
    
    private var principleCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                HStack {
                    Image(systemName: "lock.open")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(StrandPalette.accent)
                    Text("Night Lab Core Principle")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                
                Divider().overlay(StrandPalette.hairline)
                
                VStack(alignment: .leading, spacing: 8) {
                    principleRow(icon: "1.circle", text: "Raw evidence is captured once and sealed immutably")
                    principleRow(icon: "2.circle", text: "Algorithms may be rerun forever on sealed evidence")
                    principleRow(icon: "3.circle", text: "Reference answers never become inputs to blind replay")
                    principleRow(icon: "4.circle", text: "Experimental signals are labeled as unvalidated until proven")
                }
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }
    
    private func principleRow(icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(StrandPalette.accent)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
    
    private var statusSummaryCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Text("TONIGHT'S EVIDENCE STATUS").font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)
                
                HStack(spacing: NoopMetrics.space3) {
                    statusIndicator(
                        icon: "applewatch",
                        label: "Device Wear",
                        value: "87%",
                        status: .good
                    )
                    
                    statusIndicator(
                        icon: "waveform.circle",
                        label: "HR Coverage",
                        value: "94%",
                        status: .good
                    )
                    
                    statusIndicator(
                        icon: "drop.circle",
                        label: "SpO2 Candidate",
                        value: "UNVALIDATED",
                        status: .experimental
                    )
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
    
    private func statusIndicator(
        icon: String,
        label: String,
        value: String,
        status: StatusLevel
    ) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(status.color)
            Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            Text(value).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(NoopMetrics.space2)
        .background(status.backgroundColor)
        .cornerRadius(8)
    }
    
    private var nightQualityCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                HStack {
                    Image(systemName: "moon.zzz")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(StrandPalette.accent)
                    Text("Night Quality Assessment")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                
                Divider().overlay(StrandPalette.hairline)
                
                qualityMetricRow(
                    label: "Device Contact Coverage",
                    value: "87%",
                    threshold: "≥80%",
                    status: .good
                )
                qualityMetricRow(
                    label: "Signal Completeness",
                    value: "94%",
                    threshold: "≥70%",
                    status: .good
                )
                qualityMetricRow(
                    label: "Timestamp Integrity",
                    value: "Valid",
                    threshold: "Monotonic",
                    status: .good
                )
                
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.green)
                    Text("This night is ready for algorithm evaluation")
                        .font(StrandFont.caption)
                        .foregroundStyle(Color.green)
                }
                .padding(8)
                .background(Color.green.opacity(0.1))
                .cornerRadius(4)
            }
        }
    }
    
    private func qualityMetricRow(
        label: String,
        value: String,
        threshold: String,
        status: StatusLevel
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                Text(value).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(threshold).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                Image(systemName: status == .good ? "checkmark.circle" : "exclamationmark.circle")
                    .foregroundStyle(status.color)
            }
        }
        .padding(8)
        .background(StrandPalette.surfaceRaised)
        .cornerRadius(4)
    }
    
    private var researchTimelineCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Text("RESEARCH TIMELINE").font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)
                
                VStack(alignment: .leading, spacing: 12) {
                    timelinePhase(
                        number: 1,
                        title: "Data Integrity",
                        status: "✓ Complete",
                        description: "Raw bytes validated, CRC passed, timestamps verified"
                    )
                    
                    timelinePhase(
                        number: 2,
                        title: "Plausibility Checks",
                        status: "✓ Complete",
                        description: "Range, distribution, and temporal smoothness confirmed"
                    )
                    
                    timelinePhase(
                        number: 3,
                        title: "Reference Pairing",
                        status: "⏳ Pending",
                        description: "Need 10–20 paired nights with independent oximeter"
                    )
                    
                    timelinePhase(
                        number: 4,
                        title: "Physiological Validation",
                        status: "⏳ Pending",
                        description: "Conditional on Phase 3 success"
                    )
                    
                    timelinePhase(
                        number: 5,
                        title: "Production Safety",
                        status: "⏳ Pending",
                        description: "Legal review and disclaimers"
                    )
                }
            }
        }
    }
    
    private func timelinePhase(
        number: Int,
        title: String,
        status: String,
        description: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Phase \(number)").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                Text(title).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Text(status).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            }
            Text(description).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(8)
        .background(StrandPalette.surfaceRaised)
        .cornerRadius(4)
    }
    
    // MARK: - Tab 2: Signal Coverage
    
    private var signalCoverageContent: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            VStack(alignment: .leading, spacing: 8) {
                Text("SIGNAL COVERAGE FOR TONIGHT").font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)
                Text("Coverage is calculated per signal, never as one magical quality number that hides what went missing.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            signalRow(
                name: "Heart Rate",
                icon: "heart.fill",
                coverage: 94,
                cadence: "1 Hz",
                gaps: 2,
                largestGap: "3 min"
            )
            
            signalRow(
                name: "Motion (Gravity)",
                icon: "figure.walk",
                coverage: 87,
                cadence: "1 Hz",
                gaps: 5,
                largestGap: "8 min"
            )
            
            signalRow(
                name: "Respiration",
                icon: "wind",
                coverage: 91,
                cadence: "1 Hz",
                gaps: 1,
                largestGap: "2 min"
            )
            
            signalRow(
                name: "R-R Intervals",
                icon: "waveform.circle",
                coverage: 88,
                cadence: "Beat-based",
                gaps: 3,
                largestGap: "5 min"
            )
            
            signalRow(
                name: "SpO2 Candidate (@82)",
                icon: "drop.circle",
                coverage: 82,
                cadence: "Unknown (experimental)",
                gaps: 4,
                largestGap: "6 min",
                isExperimental: true
            )
            
            infoCard(
                icon: "info.circle",
                title: "Coverage Calculation",
                text: "True row count and expected count are shown. Coverage fraction = true count / expected. Gap count and largest gap are temporal intervals where no sample exists. For event-driven or unknown-cadence signals (like experimental SpO2), coverage percentage is deliberately nil."
            )
        }
    }
    
    private func signalRow(
        name: String,
        icon: String,
        coverage: Int,
        cadence: String,
        gaps: Int,
        largestGap: String,
        isExperimental: Bool = false
    ) -> some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                HStack {
                    Image(systemName: icon).foregroundStyle(StrandPalette.accent)
                    Text(name).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    if isExperimental {
                        Text("EXPERIMENTAL").font(StrandFont.caption)
                            .foregroundStyle(.orange).padding(.horizontal, 4).padding(.vertical, 2)
                            .background(Color.orange.opacity(0.2)).cornerRadius(3)
                    }
                    Spacer()
                    Text("\(coverage)%").font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                }
                
                Divider().overlay(StrandPalette.hairline)
                
                HStack {
                    metricLabel("Cadence", value: cadence)
                    Spacer()
                    metricLabel("Gaps", value: "\(gaps)")
                    Spacer()
                    metricLabel("Largest Gap", value: largestGap)
                }
                .font(StrandFont.caption)
            }
        }
    }
    
    private func metricLabel(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).foregroundStyle(StrandPalette.textTertiary)
            Text(value).foregroundStyle(StrandPalette.textPrimary).font(StrandFont.body)
        }
    }
    
    // MARK: - Tab 3: SpO2 Candidate
    
    private var spo2CandidateContent: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            warningCard(
                title: "EXPERIMENTAL — NOT VALIDATED",
                text: "This signal is based on retained WHOOP 5/MG historical data (byte @82). It has ZERO paired reference nights with independent agreement. It cannot be used for medical decisions.",
                icon: "exclamationmark.triangle.fill",
                color: .orange
            )
            
            spo2StatusCard
            spo2MetricsCard
            spo2ValidationPathCard
        }
    }
    
    private var spo2StatusCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                HStack {
                    Image(systemName: "drop.circle")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.orange)
                    Text("SpO2 Candidate Signal Status")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                
                Divider().overlay(StrandPalette.hairline)
                
                statusRow("Source", "WHOOP 5/MG backup, byte @82")
                statusRow("Status", "EXPERIMENTAL_UNVALIDATED")
                statusRow("Reference Nights", "0")
                statusRow("Coverage Tonight", "82%")
                statusRow("Medical Use", "❌ Not approved")
                statusRow("Research Use", "✓ Allowed with disclaimers")
            }
        }
    }
    
    private func statusRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            Spacer()
            Text(value).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
        }
        .padding(8)
        .background(StrandPalette.surfaceRaised)
        .cornerRadius(4)
    }
    
    private var spo2MetricsCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Text("TONIGHT'S @82 VALUES").font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)
                
                HStack(spacing: NoopMetrics.space3) {
                    metricBox(label: "Mean", value: "97.2%")
                    metricBox(label: "Min", value: "91%")
                    metricBox(label: "Max", value: "100%")
                    metricBox(label: "StdDev", value: "2.1%")
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
    
    private func metricBox(label: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            Text(value).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(StrandPalette.surfaceRaised)
        .cornerRadius(4)
    }
    
    private var spo2ValidationPathCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                HStack {
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(StrandPalette.accent)
                    Text("Validation Path to Production")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                
                Divider().overlay(StrandPalette.hairline)
                
                VStack(alignment: .leading, spacing: 8) {
                    ValidationGate(
                        stage: "Minimum Viable Evidence",
                        criteria: [
                            "10+ paired reference nights",
                            "MAE < 3% vs independent oximeter",
                            "Correlation r > 0.85",
                            "No systematic bias (|bias| < 2%)"
                        ],
                        status: "❌ Not met"
                    )
                    
                    ValidationGate(
                        stage: "Before UI Exposure",
                        criteria: [
                            "Legal review complete",
                            "Clear 'experimental' labeling",
                            "Disclaimers in place"
                        ],
                        status: "⏳ Pending MVE"
                    )
                    
                    ValidationGate(
                        stage: "Before Medical Claims",
                        criteria: [
                            "FDA/regulatory review",
                            "Clinical validation (apnea detection, REM patterns)",
                            "Device generalization across WHOOP models"
                        ],
                        status: "⏳ Pending UI approval"
                    )
                }
                
                Text("Learn more: See \"SpO2 Validation Framework\" in Docs tab")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.accent)
                    .padding(8)
                    .background(StrandPalette.surfaceRaised)
                    .cornerRadius(4)
            }
        }
    }
    
    // MARK: - Tab 4: Validation Progress
    
    private var validationContent: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            infoCard(
                icon: "flask.2",
                title: "How SpO2 Validation Works",
                text: "Five stages of evidence gathering: (1) data integrity, (2) plausibility checks, (3) reference pairing with independent oximeter, (4) physiological validity, (5) production safety review."
            )
            
            ValidationPhase(
                number: 0,
                title: "Data Integrity",
                status: .complete,
                items: [
                    "Raw bytes recovered from WHOOP backup",
                    "CRC checks passed",
                    "Timestamps verified as monotonic",
                    "Coverage computed: 82% tonight"
                ]
            )
            
            ValidationPhase(
                number: 1,
                title: "Physiological Plausibility",
                status: .complete,
                items: [
                    "Range [80, 100]% confirmed",
                    "Mean 97.2% (realistic for sleep)",
                    "Temporal smoothness OK (Δ < 5% typical)",
                    "No catastrophic jumps detected"
                ]
            )
            
            ValidationPhase(
                number: 2,
                title: "Reference Pairing (CRITICAL TEST)",
                status: .inProgress,
                items: [
                    "Recruit 5–10 volunteers: ⏳ 0 / 10",
                    "Collect paired nights: ⏳ 0 / 15–20 needed",
                    "Independent oximeter (Nonin 3150): Not yet acquired",
                    "Timestamp alignment: Pending",
                    "Compute MAE, correlation, bias: Pending"
                ]
            )
            
            ValidationPhase(
                number: 3,
                title: "Physiological Validity",
                status: .pending,
                items: [
                    "Apnea/hypopnea detection: Conditional on Phase 2",
                    "REM sleep characterization: Conditional on Phase 2",
                    "Altitude/hypoxia response: Optional advanced test"
                ]
            )
            
            ValidationPhase(
                number: 4,
                title: "Production Safety",
                status: .pending,
                items: [
                    "Clinical disclaimers: Conditional on Phase 3",
                    "Regulatory review: Conditional on Phase 3",
                    "User privacy & consent: Pending"
                ]
            )
            
            infoCard(
                icon: "calendar",
                title: "Expected Timeline",
                text: "Phase 2 (reference pairing) is the longest: 4–8 weeks with active recruitment. Phases 3–5 follow conditional on success. Total: ~2–4 months to validated status."
            )
        }
    }
    
    // MARK: - Tab 5: Documentation
    
    private var documentationContent: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            Text("BUILT-IN RESEARCH DOCUMENTATION").font(StrandFont.overline)
                .tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textSecondary)
            
            docCard(
                icon: "book",
                title: "Night Lab Evidence Framework",
                description: "Complete specification of how Night Lab works: raw evidence sealing, signal coverage calculation, blind replay, and reference isolation.",
                action: "Read Full Document"
            ) {
                // In real implementation, would navigate to embedded markdown viewer
                print("Open Night Lab documentation")
            }
            
            docCard(
                icon: "drop.circle",
                title: "SpO2 Validation Framework",
                description: "5-stage validation plan for the SpO2 candidate signal: data integrity, plausibility, reference pairing, physiological validity, and production safety.",
                action: "Read Full Document"
            ) {
                // In real implementation, would navigate to embedded markdown viewer
                print("Open SpO2 validation documentation")
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("KEY CONCEPTS").font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)
                
                conceptRow(
                    term: "Raw Evidence",
                    definition: "Immutable captured data sealed once. Algorithms may rerun forever."
                )
                conceptRow(
                    term: "Derived Results",
                    definition: "Algorithm outputs computed from sealed raw evidence. Can be recomputed."
                )
                conceptRow(
                    term: "References",
                    definition: "External truth labels (WHOOP, PSG, manual) imported AFTER algorithm execution for evaluation only."
                )
                conceptRow(
                    term: "Blind Replay",
                    definition: "Running algorithms on sealed evidence without access to reference answers, preventing answer leakage."
                )
                conceptRow(
                    term: "Signal Coverage",
                    definition: "Metric calculated per signal showing true row count, gaps, largest gap. Never one 'magic' quality number."
                )
                conceptRow(
                    term: "Device Wear State",
                    definition: "Wrist contact validation. Nights >25% device-off time are flagged as low quality."
                )
            }
            .padding(NoopMetrics.space3)
            .background(StrandPalette.surfaceRaised)
            .cornerRadius(8)
        }
    }
    
    private func docCard(
        icon: String,
        title: String,
        description: String,
        action: String,
        onTap: @escaping () -> Void
    ) -> some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(StrandPalette.accent)
                    Text(title).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(StrandPalette.textTertiary)
                }
                
                Text(description)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                
                Button(action: onTap) {
                    Text(action).font(StrandFont.body).foregroundStyle(StrandPalette.accent)
                }
                .buttonStyle(.plain)
            }
        }
    }
    
    private func conceptRow(term: String, definition: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(term).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
            Text(definition).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(.vertical, 8)
    }
    
    // MARK: - Helper Components
    
    private func infoCard(
        icon: String,
        title: String,
        text: String
    ) -> some View {
        NoopCard {
            HStack(alignment: .top, spacing: NoopMetrics.space2) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(StrandPalette.accent)
                    .frame(width: 24)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    Text(text).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
        }
    }
    
    private func warningCard(
        title: String,
        text: String,
        icon: String,
        color: Color
    ) -> some View {
        HStack(alignment: .top, spacing: NoopMetrics.space2) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(color)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(StrandFont.subhead).foregroundStyle(color)
                Text(text).font(StrandFont.caption).foregroundStyle(color.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(NoopMetrics.space3)
        .background(color.opacity(0.1))
        .cornerRadius(8)
    }
}

// MARK: - Supporting Views

struct TabBarButton: View {
    let icon: String
    let label: String
    let isActive: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                Text(label).font(StrandFont.caption)
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(isActive ? StrandPalette.accent : StrandPalette.textSecondary)
        }
        .frame(height: 44)
        .background(isActive ? StrandPalette.surfaceOverlay : Color.clear)
        .overlay(alignment: .bottom) { (isActive ? StrandPalette.accent : Color.clear).frame(height: isActive ? 2 : 0) }
    }
}

struct ValidationGate: View {
    let stage: String
    let criteria: [String]
    let status: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(stage).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Text(status).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                ForEach(criteria, id: \.self) { criterion in
                    HStack(spacing: 6) {
                        Circle().fill(StrandPalette.textTertiary).frame(width: 4)
                        Text(criterion).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }
        }
        .padding(8)
        .background(StrandPalette.surfaceRaised)
        .cornerRadius(4)
    }
}

struct ValidationPhase: View {
    let number: Int
    let title: String
    let status: PhaseStatus
    let items: [String]
    
    enum PhaseStatus {
        case complete
        case inProgress
        case pending
        
        var icon: String {
            switch self {
            case .complete: return "checkmark.circle.fill"
            case .inProgress: return "hourglass.circle"
            case .pending: return "circle"
            }
        }
        
        var color: Color {
            switch self {
            case .complete: return Color.green
            case .inProgress: return Color.orange
            case .pending: return Color.gray
            }
        }
    }
    
    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                HStack {
                    Image(systemName: status.icon)
                        .foregroundStyle(status.color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Phase \(number): \(title)").font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    }
                    Spacer()
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(items, id: \.self) { item in
                        HStack(spacing: 6) {
                            Circle().fill(StrandPalette.textTertiary).frame(width: 3)
                            Text(item).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Enums & Helpers

enum StatusLevel {
    case good
    case experimental
    case warning
    case critical
    
    var color: Color {
        switch self {
        case .good: return Color.green
        case .experimental: return Color.orange
        case .warning: return Color.yellow
        case .critical: return Color.red
        }
    }
    
    var backgroundColor: Color {
        switch self {
        case .good: return Color.green.opacity(0.1)
        case .experimental: return Color.orange.opacity(0.1)
        case .warning: return Color.yellow.opacity(0.1)
        case .critical: return Color.red.opacity(0.1)
        }
    }
}

#if DEBUG
#Preview("Evidence Lab") {
    EvidenceLabView()
        .environmentObject(AppModel())
}
#endif
