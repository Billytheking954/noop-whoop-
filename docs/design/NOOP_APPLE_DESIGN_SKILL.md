# NOOP Apple Design Skill

Status: authoritative design standard for NOOP V2 UI work.  
Scope: iPhone-only SwiftUI product; preserve production scoring, BLE, persistence, HealthKit, FIT export, Night Lab and experimental SpO₂ isolation.

## 1. Product identity
NOOP Precision is calm, capable, data-rich iPhone software for understanding personal activity, sleep, recovery and device data. It is not a medical device. Its identity comes from clear measurement provenance, a compact daily hierarchy, and Charge / Effort / Rest—not decorative effects.

## 2. Apple HIG rules
Use native navigation, semantic system behaviour, SF Pro/Dynamic Type, SF Symbols and standard sheets/toolbars where they meet the task. Prefer system surfaces and semantic colours over re-created controls. Refer to Apple HIG: <https://developer.apple.com/design/human-interface-guidelines/>.

## 3. Visual hierarchy
One screen has one primary question. Use a title, a primary result or task, compact context, then deeper analysis. A value without unit, date, comparison, provenance or action is incomplete. Do not use a large number simply as decoration.

## 4. Navigation
The persistent tab structure is Today, Sleep, Activity, Trends and Settings. Tabs navigate; they never trigger actions. Detail views push from a clear summary. Editing uses a sheet only when it is a focused, temporary task. Experimental tools live under Night Lab, never in the daily path.

## 5. Typography and Dynamic Type
Use SF Pro text roles: large title for page title, title/heading for section focus, body for explanation, footnote/caption for secondary measurement context. Support Dynamic Type and Bold Text; never rely on fixed text frames, truncation or 10pt labels for essential content. Units remain visually subordinate but readable.

## 6. Semantic colours and data colours
Use semantic surface/text/border colours for layout. Data colour has a stable meaning:
- Charge: teal
- Effort: amber
- Rest: blue
- Awake: rose
- REM: violet
- Light: indigo
- Deep: teal-dark
Colour never supplies the only meaning: use labels, shape, order or values too. Provide light and dark values. Do not recolour a metric to make a screen look nicer.

## 7. Layout and spacing
Base spacing is 4pt with common steps of 8, 12, 16, 20, 24 and 32. iPhone content gutters are normally 16pt and group spacing is 24pt. Use 44pt minimum actionable targets. Align related labels, values and controls to the same column; avoid arbitrary offsets.

## 8. Grouping and cards
Use grouped surfaces only when they establish a semantic unit: a measurement, a short related list, a chart, or a task. Prefer native grouped lists where that is the natural structure. Card radius is restrained (8–16pt); no floating-card wallpaper, decorative borders, or shadow stacks. A card must have a task, destination or clear informational purpose.

## 9. Charts
Every chart needs a title, unit, time or categorical axis, data context and an honest empty state. Data is the visual priority; axes and labels are subordinate. Scrubbing applies to the full plot area, not tiny marks. Recorded values, estimates and missing regions must be visibly distinct. Follow Apple’s chart guidance: <https://developer.apple.com/design/human-interface-guidelines/charts>.

## 10. Interaction
Use standard tap, drag, sheet and navigation behaviour. Provide the same chart inspection through touch, sequential controls and VoiceOver adjustable actions when practical. Haptics and animation clarify a completed action or a direct manipulation; they never compensate for unclear hierarchy.

## 11. Accessibility
Support VoiceOver, Dynamic Type, Reduce Motion, Increased Contrast and Switch Control. Write measurement labels as meaning plus value and unit, not colour or visual position. Ensure each screen works without colour recognition. Audit screen-reader order and focus order before release.

## 12. Light and dark appearances
Use semantic colours and asset variants, not inverted hard-coded values. Each new component must be checked in light, dark and increased-contrast contexts. Figma’s current MCP host supports only one variable mode per collection; paired `light/` and `dark/` tokens are an explicit design-file limitation, not a claim of automatic mode switching.

## 13. Motion
Use short, Reduce-Motion-safe transitions to preserve orientation after navigation or reveal a selection. No ambient glow, endlessly moving dashboards, or animation for a value that has not changed.

## 14. Provenance and missing data
Every health datum must be understandable as measured, calculated, estimated, imported, unavailable or experimental. Never fabricate a physiological trace from averages. Never bridge missing time-series samples. Aggregate-only sleep data uses a proportional breakdown, not a reconstructed Night Map.

## 15. Empty, loading, error and offline states
State what is unavailable, why when known, and the next useful action. Loading shows structure without invented values. Errors retain prior verified data rather than presenting it as empty. Offline or device states show freshness and retry guidance without overstating the connection status.

## 16. Figma components
Create editable auto-layout components for recurring roles: metric indicator, grouped row, data-status row, section header, chart container, empty state and provenance note. Use component properties for text/state, token bindings for surface/text/border/spacing/radius and SF-symbol-compatible icon slots. Never ship flattened screenshots as design screens.

## 17. SwiftUI conventions
Build on StrandDesign and existing shared components. Use `NavigationStack`, `TabView`, native toolbar/sheet/list controls and semantic `Color` assets where appropriate. Use adaptive stacks/grids and reusable small views; do not translate Figma into absolute-positioned SwiftUI. Do not change production algorithms or persistence to fit a visual proposal.

## 18. Screenshot validation
For each implemented major screen: compile, launch, seed only clearly-labelled test data, capture an actual simulator screenshot, compare to the approved Figma frame, fix objective differences, and re-capture. Check iPhone 13 mini and a larger iPhone, light/dark, Dynamic Type, empty/loading/error states and safe areas.

## 19. Forbidden anti-patterns
- Generic dashboard tile walls
- Symbol glyphs typed as text instead of suitable SF Symbols
- Glow, gradients, glass or shadows without function
- Repeated oversized numbers without context
- Random colour meanings
- Fake graph lines, fabricated samples or claim-like medical copy
- Custom imitation tab bars, toolbars or controls where native components work
- A screen that only works at one device size
- Duplicating working components or deleting hidden functionality

## 20. Objective acceptance criteria
A design is acceptable only when it:
1. answers a user task in two seconds and exposes deeper detail in navigation;
2. uses consistent semantic token meanings;
3. has accessible labels, 44pt actions and Dynamic Type-safe layout;
4. shows real/missing/estimated data honestly;
5. uses a coherent native navigation model;
6. is represented by editable Figma layers and reusable components;
7. has a matched, genuine simulator screenshot before release.

## Source references
- Apple HIG: <https://developer.apple.com/design/human-interface-guidelines/>
- Designing for iOS: <https://developer.apple.com/design/human-interface-guidelines/designing-for-ios>
- Colour: <https://developer.apple.com/design/human-interface-guidelines/color>
- Accessibility: <https://developer.apple.com/design/human-interface-guidelines/accessibility>
- Tab bars: <https://developer.apple.com/design/human-interface-guidelines/tab-bars>
- Materials: <https://developer.apple.com/design/human-interface-guidelines/materials>
