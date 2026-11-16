# NOOP Precision Token Specification

Status: v1 foundation.  
Figma file: `lXwVuJNb40MhkUBNXOojOm`  
Source branch: `design/noop-precision-foundations-20261009`

## Figma variable collections

| Collection | Token pattern | Use |
|---|---|---|
| NOOP / Primitives | `neutral/*`, `metric/*`, `data/*` | Raw values; do not bind directly in product components |
| NOOP / Color | `light/*`, `dark/*`, `metric/*`, `sleep/*` | Semantic fills, text and strokes |
| NOOP / Spacing | `space/4…32` | Gaps and container spacing |
| NOOP / Radius | `radius/0…full` | Surface shape only |

The current Figma MCP host permits a single variable mode per collection. Consequently, explicit `light/` and `dark/` semantic paths are used until multi-mode editing is available. They are not a substitute for SwiftUI dynamic colours.

## Figma-to-SwiftUI map

| Figma semantic token | SwiftUI target | Purpose |
|---|---|---|
| `light/surface/canvas` / `dark/surface/canvas` | `StrandPalette.surfaceBase` or system background | App canvas |
| `light/surface/raised` / `dark/surface/raised` | existing `NoopCard` / `ChartCard` surface | Grouped analysis |
| `light/text/primary` / `dark/text/primary` | `StrandPalette.textPrimary` | Main labels and values |
| `light/text/secondary` / `dark/text/secondary` | `StrandPalette.textSecondary` | Context and metadata |
| `light/border/subtle` | existing separator token/system separator | Structure, not decoration |
| `metric/charge` | new or existing semantic charge token | Charge ring/value |
| `metric/effort` | new or existing semantic effort token | Effort ring/value |
| `metric/rest` | new or existing semantic rest token | Rest ring/value |
| `sleep/awake`, `sleep/rem`, `sleep/light`, `sleep/deep` | stage palette in `RecordedNightMap` | Stage identity only |
| `space/*` | `NoopMetrics` spacing constants | Layout rhythm |
| `radius/*` | shared card/control radius constants | Surface geometry |

## Implementation rules

1. Audit `StrandDesign` before adding any Swift token; reuse a matching semantic token when present.
2. Map Figma values to semantic SwiftUI names, never numbers in view bodies.
3. Keep data colours separate from status colours and destructive/action tint.
4. Use native system semantic colours for standard controls and lists when they are a better fit.
5. Dark mode must derive from real SwiftUI dynamic colours or an asset catalog, not from a hard-coded Figma export.
6. Do not modify scoring, sleep-stage logic, BLE, HealthKit, storage, FIT export or Night Lab while applying visual tokens.

## Component inventory for approval phase

- `MetricTriad`: Charge / Effort / Rest, three equal indicators, clear units and tap routes
- `MetricRing`: labelled metric, value, track, accessibility summary
- `SectionHeader`: title, optional detail route
- `DataStatusRow`: measured / estimated / missing / experimental state
- `ChartContainer`: title, unit, context, plot, accessibility summary
- `SleepStageLegend`: stage colour plus text label
- `GroupedMetricRow`: label, value, comparison, disclosure
- `ProvenanceNote`: concise source/method caveat
- `EmptyState`: availability explanation and next action

All components must have editable Figma layers, Auto Layout and the semantic bindings available in the foundation.
