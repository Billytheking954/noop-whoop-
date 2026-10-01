# NOOP V2 Build & IPA Integration Plan

## Objective
Build a new unsigned iPhone IPA that integrates:
1. **Night Lab evidence integrity framework** (from NIGHT_LAB.md)
2. **SpO2 validation framework** (from SPO2_VALIDATION_FRAMEWORK.md)
3. **Wrist contact quality gates** (from recent updates)
4. **Device wear state validation** (from recent updates)
5. **New UI displays** showing evidence quality, signal coverage, and validation status

---

## Phase 0: Pre-Build Checklist

### A. Code Changes Required

**Night Lab Integration**:
- [ ] Add `NightLabManifest` schema field: `device_contact_coverage_percent`
- [ ] Add `NightLabManifest` schema field: `largest_contact_gap_seconds`
- [ ] Add `NightLabManifest` schema field: `contact_validation_status` (enum: valid/low_quality/unknown)
- [ ] Update `NightLabFileStore.seal()` to compute and enforce wrist contact metrics
- [ ] Update `NightLabArchiveLoader.load()` to validate timestamps against wrist contact state (step 6)
- [ ] Add validator: reject nights with >25% device-off time (flag as low_quality)

**SpO2 Candidate Signal**:
- [ ] Add `NightLabManifest` support for SpO2 @82 byte candidate signal
- [ ] Mark signal status as: `experimental_unvalidated` (cannot be changed without Phase 3 validation)
- [ ] Store alongside raw signals with explicit provenance: "WHOOP retained backup, byte @82, unverified"
- [ ] Add coverage metrics for @82 (similar to HR/motion)
- [ ] Add validation check: @82 timestamps must fall within wrist-on intervals

**UI Components**:
- [ ] Create `NightQualityDashboard` view showing:
  - Device wear % (per night)
  - Signal coverage (HR, motion, respiration, @82 candidate)
  - Wrist contact gaps (visualized timeline)
  - Overall night quality score (0–100%, composite)
  - Low-quality flag (>25% off-wrist)
- [ ] Create `SpO2CandidateInfoPanel` showing:
  - "EXPERIMENTAL — not validated"
  - Mean, min, max @82 values
  - Coverage %
  - Link to validation framework docs
  - Current status: "0 reference nights paired"
- [ ] Add `NightLabInsight` card showing:
  - "This night is ready for algorithm evaluation" (green)
  - "This night has incomplete signal coverage" (yellow)
  - "This night is low-quality, not recommended for training" (red)

**Data Model Changes**:
- [ ] Update `NightSignalCoverage` to include wrist-contact validity checks
- [ ] Add `DeviceWearState` type (on_wrist/off_wrist/unknown with timestamp)
- [ ] Add `SignalQualityMetrics` including:
  - coverage_percent
  - gap_count
  - largest_gap_seconds
  - temporal_validity (timestamps within wear window: yes/no)

**Test Coverage**:
- [ ] Add regression tests for wrist-contact validation in `NightLabArchiveLoader`
- [ ] Add tests: reject @82 sample if timestamp falls outside on-wrist interval
- [ ] Add tests: flag night as low-quality if >25% off-wrist
- [ ] Add tests: manifest round-trip preserves contact coverage metrics

---

## Phase 1: Code Compilation & Validation

### Step 1: Update Package Manifest
```swift
// StrandHealth/Package.swift (existing)
// Add docs reference:
.copy("../../docs/SPO2_VALIDATION_FRAMEWORK.md"),
.copy("../../docs/NIGHT_LAB.md"),
```

### Step 2: Add UI Components
Create new Swift file: `StrandiOS/Health/NightQualityComponents.swift`
```swift
import SwiftUI
import StrandHealth

struct NightQualityDashboard: View {
    let night: NightLabArchive
    
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Label("Device Wear", systemImage: "applewatch")
                Spacer()
                Text("\(Int(night.manifest.device_contact_coverage_percent))%")
                    .font(.system(.headline, design: .monospaced))
            }
            .foregroundColor(night.manifest.device_contact_coverage_percent >= 80 ? .green : .orange)
            
            HStack {
                Label("Signal Coverage", systemImage: "waveform.circle")
                Spacer()
                Text("\(Int(night.signalCoverage.hr_coverage_percent))% HR")
                    .font(.caption)
            }
            
            if night.manifest.contact_validation_status == .low_quality {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("Low quality night (>25% device-off). Not recommended for training.")
                        .font(.caption)
                    Spacer()
                }
                .padding(8)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(4)
            }
            
            Divider()
            
            // SpO2 Candidate Signal Info
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("SpO2 Candidate (@82)", systemImage: "drop.circle")
                    Spacer()
                    Text("EXPERIMENTAL")
                        .font(.caption).bold()
                        .foregroundColor(.orange)
                }
                
                if let spo2Coverage = night.signalCoverage.spo2_candidate {
                    HStack {
                        Text("Coverage: \(Int(spo2Coverage.coverage_percent))%")
                            .font(.caption)
                        Spacer()
                        Text("Mean: \(spo2Coverage.mean ?? 0)%")
                            .font(.caption2)
                    }
                }
                
                Text("⚠️ Signal not validated. Zero reference nights paired. See docs for validation path.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(8)
            .background(Color.blue.opacity(0.05))
            .cornerRadius(4)
        }
        .padding()
    }
}

struct NightLabInsightCard: View {
    let night: NightLabArchive
    
    var insight: (title: String, message: String, color: Color) {
        if night.manifest.contact_validation_status == .low_quality {
            return (
                "Low Quality Night",
                "Device was off >25% of the time. Not suitable for algorithm training.",
                .orange
            )
        } else if night.signalCoverage.hr_coverage_percent < 70 {
            return (
                "Incomplete Signals",
                "HR coverage is \(Int(night.signalCoverage.hr_coverage_percent))%. Consider excluding from validation.",
                .yellow
            )
        } else {
            return (
                "Ready for Evaluation",
                "All signals present, device worn properly. Suitable for blind baseline evaluation.",
                .green
            )
        }
    }
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: insight.color == .green ? "checkmark.circle.fill" : "info.circle.fill")
                .font(.title2)
                .foregroundColor(insight.color)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(insight.title).font(.headline)
                Text(insight.message).font(.caption).foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding(12)
        .background(insight.color.opacity(0.1))
        .cornerRadius(8)
    }
}
```

### Step 3: Integrate Into Settings → Test Centre → Night Lab
Update: `StrandiOS/Settings/NightLabInspector.swift`
```swift
// Add to night detail view:
Section("Quality Assessment") {
    NightQualityDashboard(night: selectedNight)
    NightLabInsightCard(night: selectedNight)
}

Section("Documentation") {
    Link(destination: URL(string: "internal://docs/NIGHT_LAB.md")!) {
        Label("Night Lab Evidence Framework", systemImage: "doc")
    }
    Link(destination: URL(string: "internal://docs/SPO2_VALIDATION_FRAMEWORK.md")!) {
        Label("SpO2 Validation Status & Path", systemImage: "drop.circle")
    }
}
```

### Step 4: Compile and Test Locally
```bash
cd noop-whoop-
xcodegen generate
swift build

# Run Swift package tests
swift test

# Run iPhone Simulator build
xcodebuild -scheme NOOPiOS -configuration Debug -destination 'generic/platform=iOS Simulator' build
```

**Validation gates**:
- ✅ No compiler errors
- ✅ No linker errors
- ✅ All unit tests pass (including new wrist-contact validation tests)
- ✅ iPhone Simulator build succeeds
- ✅ New UI components render without crashes

---

## Phase 2: Build Unsigned IPA

### Step 1: Create Unsigned Release Archive
```bash
# Clean previous builds
rm -rf build/

# Build for Release configuration (unsigned)
xcodebuild \
  -scheme NOOPiOS \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/ \
  -arch arm64 \
  build

# Create unsigned archive
xcodebuild \
  -scheme NOOPiOS \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/ \
  -archivePath build/NOOPiOS.xcarchive \
  archive

# Extract IPA without signing
cd build/NOOPiOS.xcarchive
mkdir -p Products/Applications/
unzip -q ../NOOPiOS.xcarchive/Products/Applications/NOOP.app -d Products/Applications/

# Verify app structure (no code signing)
codesign -v Products/Applications/NOOP.app/ 2>&1 | grep -i "not signed" || echo "Warning: app appears signed"
```

### Step 2: Package IPA
```bash
# Create unsigned IPA
mkdir -p unsigned-ipa/Payload
cp -r build/NOOPiOS.xcarchive/Products/Applications/NOOP.app unsigned-ipa/Payload/

# Package
cd unsigned-ipa
zip -r -q ../NOOP-V2-unsigned-$(date +%Y%m%d-%H%M%S).ipa .

# Verify IPA contents
unzip -l ../NOOP-V2-unsigned-*.ipa | head -20
```

### Step 3: Embed Provenance Info
Before packaging, embed build metadata:
```swift
// Create InfoPlist with build info
let buildInfo = """
{
  "build_timestamp": "\(Date().iso8601WithFractionalSeconds)",
  "source_commit_sha": "$(git rev-parse HEAD)",
  "source_branch": "$(git rev-parse --abbrev-ref HEAD)",
  "features": [
    "Night Lab evidence integrity gates",
    "Device wear state validation",
    "SpO2 candidate signal (experimental_unvalidated)",
    "Quality-based night filtering",
    "Wrist contact coverage metrics"
  ],
  "signing_status": "unsigned",
  "can_be_sideloaded": true
}
"""
// Store in app bundle as: NOOP.app/BuildInfo.json
```

---

## Phase 3: Validation Checklist

### Before Release:

**Code Quality**:
- [ ] No Swift compiler warnings
- [ ] No runtime crashes on first launch
- [ ] No data loss on app restart
- [ ] All new UI components respond to touch

**Feature Validation**:
- [ ] Night Lab inspector shows quality metrics ✅
- [ ] Device wear % displays correctly ✅
- [ ] Low-quality nights are flagged ✅
- [ ] SpO2 candidate shows "EXPERIMENTAL" label ✅
- [ ] Documentation links work ✅

**Evidence Integrity**:
- [ ] Manifest format round-trips correctly
- [ ] Wrist contact validator rejects invalid samples
- [ ] Coverage metrics persist across app restarts
- [ ] Night quality score is deterministic (same night = same score)

**Test Coverage**:
- [ ] New unit tests pass (wrist-contact, coverage, SpO2 candidate)
- [ ] No regression in existing tests
- [ ] Edge cases handled (0% coverage, all device-off, etc.)

---

## Phase 4: IPA Distribution

### Output Artifact
```
NOOP-V2-unsigned-20261001-131716.ipa
├── Payload/
│   └── NOOP.app/
│       ├── BuildInfo.json  (provenance)
│       ├── Executable
│       ├── Resources/
│       │   ├── docs/NIGHT_LAB.md
│       │   ├── docs/SPO2_VALIDATION_FRAMEWORK.md
│       │   └── ...
│       └── Info.plist
└── [zip structure]

SHA-256: [computed hash]
Size: [MB]
Signing Status: UNSIGNED (sideload only, requires manual installation)
Install Method: Xcode or iMazing
```

### Installation Instructions
```markdown
## Installing the Unsigned IPA

### Prerequisites
- Mac with Xcode
- iPhone running iOS 16+
- USB cable or WiFi pairing

### Method 1: Xcode (Easiest)
1. Open Xcode
2. Window → Devices and Simulators
3. Select your iPhone
4. Drag NOOP-V2-unsigned-*.ipa onto device
5. Wait for installation to complete

### Method 2: iMazing (Alternative)
1. Download iMazing from iMazing.com
2. Open iMazing, connect iPhone
3. Apps → Install → Select NOOP-V2-unsigned-*.ipa
4. Confirm and wait

### Verification
- App should launch to "NOOP Today" screen
- Settings → Test Centre → Night Lab should show new UI
- Long-press on any night to see quality dashboard

### Security Note
- This is an unsigned development build
- Do not distribute publicly
- Contains experimental features marked EXPERIMENTAL_UNVALIDATED
- SpO2 data is research-only, not for medical use
```

---

## Phase 5: New Features Documentation

### In-App Help Text

**Settings → Test Centre → Night Lab → [Any Night]**:
```
Device Wear Coverage: X%
├─ Shows % of sleep window where device was on-wrist
├─ <80% = low quality, not recommended for training
└─ View gap timeline to see when device was off

Signal Quality Dashboard:
├─ HR Coverage: X% (heart rate samples)
├─ Motion Coverage: X% (gravity/acceleration)
├─ Respiration Coverage: X% (breathing rate)
├─ SpO2 Candidate: X% (EXPERIMENTAL — not validated)
└─ Each shows gaps and largest continuous gap

Quality Status Card:
├─ 🟢 Green: Ready for evaluation (all signals >80%, device worn well)
├─ 🟡 Yellow: Incomplete (signals <80% or partial device wear)
└─ 🔴 Red: Low quality (>25% device-off time)

SpO2 Candidate Signal:
├─ Source: Retained WHOOP 5/MG backup byte @82
├─ Status: EXPERIMENTAL_UNVALIDATED (0 reference nights paired)
├─ Purpose: Research only, not for medical use
├─ Next Steps: See validation framework for proof plan
└─ Learn More: [Link to SPO2_VALIDATION_FRAMEWORK.md]
```

---

## Phase 6: Git & Release

### Commit Message Template
```
feat(night-lab): add device wear validation and quality gates

- Add device_contact_coverage_percent to manifest
- Add largest_contact_gap_seconds tracking
- Add contact_validation_status (valid/low_quality/unknown)
- Validate timestamps fall within on-wrist intervals
- Flag nights >25% device-off as low_quality
- Add NightQualityDashboard UI component
- Add SpO2 candidate signal display with EXPERIMENTAL label
- Add regression tests for contact validation
- Embed BuildInfo.json with feature list and signing status

Features:
- Device wear state validation (wrist contact)
- Signal coverage metrics per signal type
- Night quality dashboard (Settings → Test Centre → Night Lab)
- SpO2 candidate evidence display (with explicit "unvalidated" status)
- Documentation links to validation framework

Unsigned IPA:
- No code signing (sideload-only)
- Installable via Xcode or iMazing
- Contains NIGHT_LAB.md and SPO2_VALIDATION_FRAMEWORK.md
- BuildInfo.json embeds commit SHA and feature list

Validation:
- All unit tests pass
- iPhone Simulator build succeeds
- No compiler warnings
- Quality gates are deterministic

Refs: NIGHT_LAB.md, SPO2_VALIDATION_FRAMEWORK.md, PR #29, PR #34
```

### Tag & Release
```bash
git add docs/SPO2_VALIDATION_FRAMEWORK.md
git add StrandiOS/Health/NightQualityComponents.swift
git add (other modified files)

git commit -m "feat(night-lab): add device wear validation and quality gates

See commit message for full details"

git tag -a v11.8-research-$(date +%Y%m%d) -m "Unsigned research IPA with Night Lab quality gates and SpO2 validation framework"

git push origin main --tags
```

---

## Summary: What Users Get

**New in This IPA**:

1. **Night Lab Quality Dashboard**
   - See device wear % for each archived night
   - See all signal coverage metrics
   - Identify which nights are suitable for training vs. which are low-quality

2. **SpO2 Candidate Signal Tracking**
   - View @82 byte data alongside other signals
   - See coverage % for SpO2 candidate
   - Clear "EXPERIMENTAL — not validated" labeling
   - Link to validation framework showing what's needed to prove it

3. **Device Wear Validation**
   - Automatically flags nights where device was off >25% of time
   - Visual timeline showing wear gaps
   - Prevents low-quality nights from contaminating training datasets

4. **Built-In Documentation**
   - NIGHT_LAB.md accessible in-app
   - SPO2_VALIDATION_FRAMEWORK.md accessible in-app
   - Links explain evidence integrity rules and validation path

5. **Deterministic Quality Scoring**
   - Each night gets reproducible quality score
   - Scores persist across app restarts
   - Transparent: all metrics visible in UI

**What Is NOT Claimed**:
- SpO2 is not promoted to production scoring
- SpO2 is not written to HealthKit
- SpO2 is not claimed as accurate
- Device wear validation does not change sleep algorithm
- This is research & development mode only

---

## Next Steps After IPA Build

1. **Test the IPA** on your own iPhone (sideload via Xcode)
2. **Verify UI** renders correctly and shows real night data
3. **Collect feedback** from testers on usability
4. **Plan Phase 3** (SpO2 reference pairing study if signals look promising)
5. **Continue** with regular development PRs (#25–34) in parallel

---

## Build Timeline

| Phase | Task | Estimated Time | Status |
|-------|------|-----------------|--------|
| 0 | Code changes & unit tests | 2–3 days | 🔄 |
| 1 | Swift compilation & validation | 1 day | ⏳ |
| 2 | Unsigned IPA build | 2–4 hours | ⏳ |
| 3 | Validation checklist | 1–2 days | ⏳ |
| 4 | Documentation & distribution | 1 day | ⏳ |
| 5 | Git commit & tag | 1 hour | ⏳ |
| **Total** | | **~7–9 days** | |

---

## Troubleshooting

**IPA won't install**:
- Verify iPhone OS matches minimum requirement
- Check Xcode / iMazing logs for codesign errors
- Confirm device UUID is authorized for sideload

**New UI doesn't show**:
- Verify Settings → Test Centre → Night Lab is enabled
- Confirm at least one night is archived locally
- Check console logs for Swift runtime errors

**App crashes on launch**:
- Check iPhone console (Xcode Devices) for error messages
- Verify BuildInfo.json is properly embedded
- Rebuild with clean derived data

---

## Questions?

Refer to:
- **Night Lab Design**: `docs/NIGHT_LAB.md`
- **SpO2 Validation Path**: `docs/SPO2_VALIDATION_FRAMEWORK.md`
- **Build Errors**: Check Xcode build log for Swift compiler diagnostics
- **Feature Requests**: Open GitHub issue with specifics
