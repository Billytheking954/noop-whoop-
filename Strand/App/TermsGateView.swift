import SwiftUI
import StrandDesign

/// First-run acknowledgment gate (clickwrap). Shown over EVERYTHING — before onboarding, pairing, or
/// any Bluetooth access — until the current `Terms.currentVersion` is accepted, and again if the
/// terms materially change. The user must tick the (un-pre-checked) box and tap Accept; the accepted
/// version is then stored locally, the on-device equivalent of a consent record. See `Terms` / `TERMS.md`.
struct TermsGateView: View {
    let onAccept: () -> Void
    /// One flag per `Terms.attestations` entry; every one must be ticked before Accept enables.
    @State private var checks: [Bool] = Array(repeating: false, count: Terms.attestations.count)

    private var allChecked: Bool { checks.allSatisfy { $0 } }
    private var confirmedCount: Int { checks.filter { $0 }.count }

    var body: some View {
        ZStack {
            StrandPalette.surfaceBase.ignoresSafeArea()

            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    Text("Before you use NOOP")
                        .font(StrandFont.title1)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("Please read the points below, then confirm each statement.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .multilineTextAlignment(.center)
                    ProgressView(value: Double(confirmedCount), total: Double(max(1, checks.count)))
                        .tint(StrandPalette.accent)
                        .accessibilityLabel("Please confirm each of these:")
                        .accessibilityValue("\(confirmedCount) of \(checks.count)")
                    Text(verbatim: "\(confirmedCount) / \(checks.count)")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .padding(.horizontal, 30)
                .padding(.top, 28)
                .padding(.bottom, 18)

                ScrollView {
                    VStack(alignment: .leading, spacing: NoopVisualStyle.itemGap) {
                        ForEach(Array(Terms.points.enumerated()), id: \.offset) { index, point in
                            HStack(alignment: .top, spacing: 12) {
                                Text("\(index + 1)")
                                    .font(StrandFont.footnote.weight(.bold))
                                    .foregroundStyle(StrandPalette.accent)
                                    .frame(width: 28, height: 28)
                                    .background(StrandPalette.accent.opacity(0.12), in: Circle())

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(point.0)
                                        .font(StrandFont.headline)
                                        .foregroundStyle(StrandPalette.textPrimary)
                                    Text(point.1)
                                        .font(StrandFont.footnote)
                                        .foregroundStyle(StrandPalette.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(NoopVisualStyle.cardPadding)
                            .background {
                                NoopPanelSurface(cornerRadius: NoopVisualStyle.cardRadius)
                            }
                        }

                        Rectangle()
                            .fill(StrandPalette.hairline)
                            .frame(height: 1)
                            .padding(.vertical, 2)

                        Text("Please confirm each of these:")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)

                        ForEach(Array(Terms.attestations.enumerated()), id: \.offset) { idx, line in
                            confirmationRow(index: idx, line: line)
                        }

                        Text("The full terms are in TERMS.md, shipped with NOOP. This is not legal advice.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .padding(.top, 2)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 18)
                }
                #if os(iOS)
                // #697/#horizontal-swipe parity, see ScreenScaffold. Shown before onboarding/pairing,
                // on top of everything, so this is the very first screen a new install sees.
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                #endif

                Rectangle()
                    .fill(StrandPalette.hairline)
                    .frame(height: 1)

                Button(action: onAccept) {
                    Text("Accept & Continue")
                        .font(StrandFont.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.borderedProminent)
                .tint(StrandPalette.accent)
                .disabled(!allChecked)
                .keyboardShortcut(.defaultAction)
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
            }
            .frame(maxWidth: 560, maxHeight: 780)
        }
    }

    private func confirmationRow(index: Int, line: String) -> some View {
        Button {
            checks[index].toggle()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: checks[index] ? "checkmark.square.fill" : "square")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(checks[index] ? StrandPalette.accent : StrandPalette.textTertiary)
                    .frame(width: 24)
                Text(line)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(line)
        .accessibilityValue(checks[index] ? "Confirmed" : "Not confirmed")
        .accessibilityAddTraits(checks[index] ? .isSelected : [])
    }
}
