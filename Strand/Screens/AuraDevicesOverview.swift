#if os(iOS)
import SwiftUI
import StrandDesign
import WhoopStore

/// Aura-only visual shell for V2's authoritative pairing and device-management flows.
/// Does not own scanning, connection state, BLE sessions, battery caching or persistence.
struct AuraDevicesOverview: View {
    @ObservedObject var registry: DeviceRegistry
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState
    @State private var showingAdd = false
    @State private var showingManager = false

    private var active: PairedDevice? {
        registry.devices.first { $0.status == .active && !$0.isImportSource }
    }

    /// Hide any disconnected/mismatched battery rather than applying the wrong device's value.
    private var battery: Int? {
        guard let device = active else { return nil }
        return DeviceBatteryPresentation.percent(
            connected: live.connected,
            activeIsWhoop: SourceCoordinator.isWhoop(device),
            whoopPct: live.batteryPct,
            ringPct: device.sourceKind == .oura ? live.ouraBatteryPct : nil
        )
    }

    private var canSync: Bool {
        active.map(SourceCoordinator.isWhoop) == true &&
        live.connected && live.bonded && live.historyReady && !live.backfilling
    }

    var body: some View {
        ZStack {
            NoopPalette.canvas.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        NoopSpecCaption(String(localized: "Your device", table: "AuraPreview"))
                        Text(String(localized: "Devices", table: "AuraPreview"))
                            .font(NoopSpecType.screenTitle)
                            .foregroundStyle(NoopPalette.textPrimary)
                    }

                    NoopSpecCard(.hero) {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(spacing: 8) {
                                Image(systemName: live.connected && active != nil ? "checkmark.circle.fill" : "circle.dotted")
                                    .foregroundStyle(live.connected && active != nil ? NoopPalette.accent : NoopPalette.textSecondary)
                                Text(active == nil
                                     ? String(localized: "No active device", table: "AuraPreview")
                                     : live.connected
                                       ? String(localized: "Connected", table: "AuraPreview")
                                       : String(localized: "Disconnected", table: "AuraPreview"))
                                    .font(NoopSpecType.cardTitle)
                                    .foregroundStyle(NoopPalette.textSecondary)
                                Spacer()
                            }

                            Text(active?.displayName ?? String(localized: "Pair a wearable", table: "AuraPreview"))
                                .font(NoopSpecType.headline)
                                .foregroundStyle(NoopPalette.textPrimary)

                            if let device = active {
                                Text(device.model)
                                    .font(NoopSpecType.bodySmall)
                                    .foregroundStyle(NoopPalette.textSecondary)

                                HStack(alignment: .firstTextBaseline) {
                                    NoopSpecCaption(String(localized: "Battery", table: "AuraPreview"))
                                    Spacer()
                                    Text(battery.map { "\($0)%" } ?? "—")
                                        .font(NoopSpecType.headline)
                                        .monospacedDigit()
                                        .foregroundStyle(NoopPalette.textPrimary)
                                        .accessibilityIdentifier("noop.device.battery")
                                }
                                if battery == nil {
                                    Text(String(localized: "Battery unavailable or disconnected", table: "AuraPreview"))
                                        .font(NoopSpecType.finePrint)
                                        .foregroundStyle(NoopPalette.textSecondary)
                                }
                                if let guide = live.reconnectGuide {
                                    Text(guide)
                                        .font(NoopSpecType.bodySmall)
                                        .foregroundStyle(NoopPalette.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                if let hint = live.pairingHint {
                                    Text(hint)
                                        .font(NoopSpecType.bodySmall)
                                        .foregroundStyle(NoopPalette.effort)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if active != nil {
                        NoopSpecCard {
                            VStack(alignment: .leading, spacing: 12) {
                                NoopSpecCaption(String(localized: "Sync", table: "AuraPreview"))
                                Text(live.lastSyncedAt.map {
                                    Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .shortened)
                                } ?? String(localized: "No completed sync yet", table: "AuraPreview"))
                                    .font(NoopSpecType.body)
                                    .foregroundStyle(NoopPalette.textSecondary)
                                if live.backfilling {
                                    ProgressView()
                                        .tint(NoopPalette.accent)
                                        .accessibilityLabel(Text(String(localized: "Sync in progress", table: "AuraPreview")))
                                }
                                Button {
                                    guard canSync else { return }
                                    model.ble.syncNow()
                                } label: {
                                    auraActionLabel(
                                        String(localized: "Sync now", table: "AuraPreview"),
                                        symbol: "arrow.triangle.2.circlepath")
                                }
                                .disabled(!canSync)
                                .accessibilityIdentifier("noop.device.sync")
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    Button { showingAdd = true } label: {
                        auraActionLabel(String(localized: "Pair a device", table: "AuraPreview"), symbol: "plus")
                    }
                    .accessibilityIdentifier("noop.device.pair")

                    Button { showingManager = true } label: {
                        auraActionLabel(String(localized: "Manage paired devices", table: "AuraPreview"),
                                        symbol: "square.stack.3d.up")
                    }
                    .accessibilityIdentifier("noop.device.manage")
                }
                .padding(18)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingAdd) {
            AddDeviceWizard(live: live) { showingAdd = false }
                .environmentObject(model)
                .environmentObject(live)
        }
        .sheet(isPresented: $showingManager) {
            NavigationStack {
                ScreenScaffold(title: "Devices", subtitle: "Pair and manage the bands NOOP reads from.") {
                    DevicesContent(registry: registry)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { showingManager = false }
                    }
                }
            }
        }
    }

    private func auraActionLabel(_ title: String, symbol: String) -> some View {
        NoopSpecCard(.row) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .foregroundStyle(NoopSpecTokens.auraPale)
                Text(title)
                    .font(NoopSpecType.buttonLabel)
                    .foregroundStyle(NoopPalette.textPrimary)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .foregroundStyle(NoopPalette.textSecondary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
    }
}
#endif
