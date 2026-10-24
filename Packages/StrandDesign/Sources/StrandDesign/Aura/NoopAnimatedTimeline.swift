import SwiftUI

/// A lightweight animation clock shared by the ported Aura primitives.
/// It preserves V2's existing low-power, quiet-motion and obscured-window gate.
public struct NoopTimelineContext {
    public let date: Date
}

public struct NoopAnimatedTimeline<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var motion = NoopMotionState.shared

    private let minimumInterval: TimeInterval
    private let paused: Bool
    private let content: (NoopTimelineContext) -> Content

    public init(
        minimumInterval: TimeInterval = 1.0 / 30.0,
        paused: Bool = false,
        @ViewBuilder content: @escaping (NoopTimelineContext) -> Content
    ) {
        self.minimumInterval = minimumInterval
        self.paused = paused
        self.content = content
    }

    public var body: some View {
        if paused || motion.poseStill(reduceMotion) {
            content(NoopTimelineContext(date: Date()))
        } else {
            TimelineView(.animation(minimumInterval: minimumInterval)) { context in
                content(NoopTimelineContext(date: context.date))
            }
        }
    }
}
