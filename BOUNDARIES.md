# Boundaries

Each row is one external surface this codebase calls into. See the boundary-first architecture doctrine for the governing rules.

| # | Boundary | Vendor | Capability | Swap risk | Wrapped? | Alternatives | Last reviewed |
|---|---|---|---|---|---|---|---|
| 1 | IOKit / IOHIDManager | Apple | Observe and read local HID touchscreen devices | Medium | `TouchEnvironmentInspecting`; input adapter remains platform-specific | DriverKit; no-op/in-memory fixtures | 2026-08-19 |
| 2 | CoreGraphics / AppKit display APIs | Apple | Inventory displays and resolve the physical touch target or mirror master | Medium | `TouchEnvironmentInspecting`; pure display resolver | Manual display selection | 2026-08-19 |
| 3 | Accessibility / CGEvent | Apple | Check permissions and synthesize local pointer/gesture events | Medium | Existing touch driver adapter | DriverKit virtual HID | 2026-08-19 |
| 4 | AppKit status item | Apple | Present current touch readiness in the menu bar | Low | `TouchHealthReporting` | CLI-only status | 2026-08-19 |
| 5 | UserNotifications | Apple | Alert on actionable local touch-health transitions | Low | `TouchHealthReporting` | Menu-bar-only status | 2026-08-19 |
| 6 | Local filesystem through Foundation | Apple | Retain a bounded, local JSONL health timeline | Low | `TouchHealthReporting` | Unified logging only | 2026-08-19 |
| 7 | launchd | Apple | Keep the local touch agent alive across login and crashes | Low | LaunchAgent plist | Manual launch | 2026-08-19 |
| 8 | ScreenCaptureKit / CoreMedia / CoreVideo / IOSurface | Apple | Sample a transient screen region for the precision touch loupe | Medium | `ScreenRegionSampling` | Permission-free crosshair; legacy screenshots | 2026-08-19 |
| 9 | AppKit overlay window | Apple | Present a nonactivating, click-through precision loupe | Low | `PrecisionOverlayPresenting` | Crosshair-only indicator | 2026-08-19 |
