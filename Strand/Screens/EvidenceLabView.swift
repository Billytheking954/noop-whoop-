import SwiftUI
import StrandDesign

/// Research entry point. Evidence is resolved from a selected archive in Night Lab.
struct EvidenceLabView: View {
    var body: some View {
        ScreenScaffold(title: "Evidence Lab", subtitle: "Inspect recorded evidence") {
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    Text("No night selected").font(StrandFont.headline)
                    Text("Select an archived night to inspect signal coverage, missing data and saved replay results.")
                        .foregroundStyle(StrandPalette.textSecondary)
                    Text("Coverage describes available data. It does not establish sleep-stage accuracy or show that a change improves sleep.")
                        .font(StrandFont.caption)
                    NavigationLink(destination: NightLabView()) {
                        Label("Open Night Lab", systemImage: "moon.stars")
                    }
                }
            }
        }
    }
}
