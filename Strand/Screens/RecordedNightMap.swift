import SwiftUI
import StrandDesign
import WhoopStore

/// Touch-first, time-faithful rendering of recorded stage intervals.
/// Presentation only: never infer stage sequences from aggregate totals.
struct RecordedNightMap: View {
    let intervals: [SleepInterval]
    let startDate: Date
    let endDate: Date
    let heartRate: [HRBucket]
    let highlightedStage: SleepStage?
    var allowsExpansion: Bool = true

    @State private var inspectedOffset: TimeInterval?
    @State private var showExpanded = false

    private var duration: TimeInterval {
        max(1, endDate.timeIntervalSince(startDate))
    }

    private var recorded: [SleepInterval] {
        intervals.filter {
            $0.start.isFinite && $0.end.isFinite &&
            $0.end > $0.start && $0.end > 0 && $0.start < duration
        }.sorted { $0.start < $1.start }
    }

    private var selectedInterval: SleepInterval? {
        guard let inspectedOffset else { return nil }
        return recorded.first { inspectedOffset >= $0.start && inspectedOffset < $0.end }
    }

    private var selectedHR: HRBucket? {
        guard let inspectedOffset else { return nil }
        let timestamp = startDate.timeIntervalSince1970 + inspectedOffset
        // A bucket is a sample, not a continuous trace; never invent a value in a gap.
        return heartRate.min(by: {
            abs(Double($0.ts) - timestamp) < abs(Double($1.ts) - timestamp)
        }).flatMap { abs(Double($0.ts) - timestamp) <= 150 ? $0 : nil }
    }

    private var containsGaps: Bool {
        guard let first = recorded.first, let last = recorded.last else { return false }
        if first.start > 60 || last.end < duration - 60 { return true }
        return zip(recorded, recorded.dropFirst()).contains { lhs, rhs in
            rhs.start - lhs.end > 60
        }
    }

    private var stages: [SleepStage] { [.awake, .rem, .light, .deep] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("RECORDED STAGES")
                    .font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer(minLength: 8)
                if containsGaps {
                    Text("Gaps present")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                if allowsExpansion {
                    Button {
                        showExpanded = true
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Expand Night Map")
                }
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 0) {
                    ForEach(stages, id: \.rawValue) { stage in
                        Text(stage.label)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .frame(height: 40)
                    }
                }
                .frame(width: 44)

                VStack(spacing: 8) {
                    GeometryReader { geometry in
                        Canvas { context, size in
                            let rowHeight = size.height / 4
                            for (index, stage) in stages.enumerated() {
                                let lane = CGRect(x: 0, y: CGFloat(index) * rowHeight + 4,
                                                  width: size.width, height: rowHeight - 8)
                                context.fill(Path(roundedRect: lane, cornerRadius: 2),
                                             with: .color(StrandPalette.sleepStageColor(stage).opacity(0.06)))
                            }
                            for segment in recorded {
                                let left = CGFloat(max(0, segment.start) / duration) * size.width
                                let right = CGFloat(min(duration, segment.end) / duration) * size.width
                                guard right > left else { continue }
                                let row = CGFloat(segment.stage.bandRank)
                                let bar = CGRect(x: left, y: row * rowHeight + 10,
                                                 width: max(1, right - left), height: rowHeight - 20)
                                let faded = highlightedStage != nil && segment.stage != highlightedStage
                                context.fill(Path(bar), with: .color(
                                    StrandPalette.sleepStageColor(segment.stage).opacity(faded ? 0.25 : 0.95)
                                ))
                            }
                            if let inspectedOffset {
                                let x = CGFloat(inspectedOffset / duration) * size.width
                                var marker = Path()
                                marker.move(to: CGPoint(x: x, y: 0))
                                marker.addLine(to: CGPoint(x: x, y: size.height))
                                context.stroke(marker, with: .color(StrandPalette.textPrimary),
                                               style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                            }
                        }
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                            guard geometry.size.width > 0 else { return }
                            inspectedOffset = min(duration, max(0,
                                Double(gesture.location.x / geometry.size.width) * duration))
                        })
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Recorded sleep stage timeline")
                        .accessibilityValue(inspectorAccessibilityValue)
                        .accessibilityHint("Swipe up or down to inspect the next or previous stage interval")
                        .accessibilityAdjustableAction { direction in
                            switch direction {
                            case .increment: step(1)
                            case .decrement: step(-1)
                            @unknown default: break
                            }
                        }
                    }
                    .frame(height: 160)

                    HStack(spacing: 0) {
                        Text(clock(startDate))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(clock(startDate.addingTimeInterval(duration / 2)))
                            .frame(maxWidth: .infinity, alignment: .center)
                        Text(clock(endDate))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .font(StrandFont.footnote)
                    .monospacedDigit()
                    .foregroundStyle(StrandPalette.textSecondary)
                }
            }

            if heartRate.count >= 2 {
                VStack(alignment: .leading, spacing: 8) {
                    Text("HEART RATE · BPM")
                        .font(StrandFont.overline)
                        .tracking(StrandFont.overlineTracking)
                        .foregroundStyle(StrandPalette.textSecondary)
                    // Exactly the same absolute time domain and leading inset as stage rows.
                    HStack(spacing: 12) {
                        Color.clear.frame(width: 44, height: 76)
                        Canvas { context, size in
                            let samples = heartRate.filter {
                                Double($0.ts) >= startDate.timeIntervalSince1970 &&
                                Double($0.ts) <= endDate.timeIntervalSince1970 &&
                                $0.bpm.isFinite && $0.bpm > 0
                            }.sorted { $0.ts < $1.ts }
                            if samples.count >= 2 {
                                let lo = (samples.map(\.bpm).min() ?? 40) - 5
                                let hi = (samples.map(\.bpm).max() ?? 90) + 5
                                var path = Path()
                                var previous: HRBucket?
                                for sample in samples {
                                    let offset = Double(sample.ts) - startDate.timeIntervalSince1970
                                    let x = CGFloat(offset / duration) * size.width
                                    let y = size.height * (1 - CGFloat((sample.bpm - lo) / max(1, hi - lo)))
                                    let point = CGPoint(x: x, y: y)
                                    if let previous, sample.ts - previous.ts <= 300 {
                                        path.addLine(to: point)
                                    } else {
                                        path.move(to: point)
                                    }
                                    previous = sample
                                }
                                context.stroke(path, with: .color(StrandPalette.restColor),
                                               style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                            }
                            if let inspectedOffset {
                                let x = CGFloat(inspectedOffset / duration) * size.width
                                var marker = Path()
                                marker.move(to: CGPoint(x: x, y: 0))
                                marker.addLine(to: CGPoint(x: x, y: size.height))
                                context.stroke(marker, with: .color(StrandPalette.textPrimary.opacity(0.7)),
                                               style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                            }
                        }
                        .frame(height: 76)
                        .accessibilityLabel("Recorded overnight heart rate, with gaps in missing samples")
                    }
                }
            } else {
                Text("No continuous overnight heart-rate record is available.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
            }

            Divider().overlay(StrandPalette.hairline)
            if let inspectedOffset {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(selectedInterval?.stage.label ?? "No recorded stage")
                            .font(StrandFont.headline)
                        Spacer(minLength: 8)
                        if let selectedInterval {
                            Text(elapsed(selectedInterval.duration))
                                .font(StrandFont.captionNumber)
                                .monospacedDigit()
                        }
                    }
                    if let selectedInterval {
                        Text("\(clock(startDate.addingTimeInterval(selectedInterval.start), withZone: true)) – \(clock(startDate.addingTimeInterval(selectedInterval.end), withZone: true))")
                            .font(StrandFont.footnote)
                            .monospacedDigit()
                    } else {
                        Text("No stage observation at \(clock(startDate.addingTimeInterval(inspectedOffset), withZone: true)).")
                            .font(StrandFont.footnote)
                    }
                    if let selectedHR {
                        Text("Nearby measured heart rate: \(Int(selectedHR.bpm.rounded())) bpm")
                            .font(StrandFont.footnote)
                    } else {
                        Text("No nearby heart-rate sample")
                            .font(StrandFont.footnote)
                    }
                }
                .foregroundStyle(StrandPalette.textPrimary)
                .accessibilityElement(children: .combine)
            } else {
                Text("Drag across the map to inspect recorded intervals and missing periods.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
            }

            HStack(spacing: 12) {
                Button { step(-1) } label: {
                    Label("Previous", systemImage: "chevron.left")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .disabled(recorded.isEmpty)
                Button { step(1) } label: {
                    Label("Next", systemImage: "chevron.right")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .disabled(recorded.isEmpty)
            }
            .buttonStyle(.bordered)

            Text("Stage intervals are device estimates. Blank spans indicate missing records, not wakefulness.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .sheet(isPresented: $showExpanded) {
            NavigationStack {
                ScrollView {
                    RecordedNightMap(intervals: intervals, startDate: startDate,
                                     endDate: endDate, heartRate: heartRate,
                                     highlightedStage: highlightedStage, allowsExpansion: false)
                        .padding(16)
                }
                .navigationTitle("Night Map")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showExpanded = false }
                    }
                }
            }
        }
    }

    private var inspectorAccessibilityValue: String {
        guard let inspectedOffset else { return "No interval selected" }
        return selectedInterval.map {
            "\($0.stage.label), \(clock(startDate.addingTimeInterval($0.start), withZone: true)) to \(clock(startDate.addingTimeInterval($0.end), withZone: true))"
        } ?? "No recorded stage at \(clock(startDate.addingTimeInterval(inspectedOffset), withZone: true))"
    }

    private func step(_ direction: Int) {
        guard !recorded.isEmpty else { return }
        let index: Int
        if let inspectedOffset, let current = recorded.firstIndex(where: {
            inspectedOffset >= $0.start && inspectedOffset < $0.end
        }) {
            index = min(recorded.count - 1, max(0, current + direction))
        } else if let inspectedOffset {
            let next = recorded.firstIndex(where: { $0.start > inspectedOffset }) ?? (recorded.count - 1)
            index = min(recorded.count - 1, max(0, direction > 0 ? next : next - 1))
        } else {
            index = direction > 0 ? 0 : recorded.count - 1
        }
        inspectedOffset = (recorded[index].start + recorded[index].end) / 2
    }

    private static let zonedClock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("jmmz")
        return formatter
    }()

    private func clock(_ date: Date, withZone: Bool = false) -> String {
        if withZone { return Self.zonedClock.string(from: date) }
        return date.formatted(date: .omitted, time: .shortened)
    }

    private func elapsed(_ seconds: TimeInterval) -> String {
        let count = Int(max(0, seconds).rounded())
        let hours = count / 3600
        let minutes = (count % 3600) / 60
        let remainder = count % 60
        return hours > 0 ? "\(hours)h \(minutes)m" :
               minutes > 0 ? "\(minutes)m \(remainder)s" : "\(remainder)s"
    }
}
