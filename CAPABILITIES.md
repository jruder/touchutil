# Capabilities

One entry per port or protocol this codebase owns. Each semantic description records what the protocol does, the data it processes, and its typical caller.

## TouchEnvironmentInspecting

Path: `Sources/touchutil/TouchHealth.swift`

Description: Returns a vendor-neutral snapshot of the local touchscreen environment: target-display presence and resolution, eGalax HID presence and driver attachment, Accessibility and Input Monitoring permissions, and current mapping. It processes local device metadata only and is called by the health supervisor, watchdog, and diagnostic CLI.

Implementations: `MacOSTouchEnvironmentInspector`, `StaticTouchEnvironmentInspector` (tests)

## TouchHealthReporting

Path: `Sources/touchutil/TouchHealth.swift`

Description: Publishes semantic touch-health transitions and their recommended operator action to local status surfaces, plus a lightweight current-state heartbeat for diagnostics. It processes `TouchHealthSnapshot` and `TouchHealthTransition` values; transition-aware adapters notify only when state materially changes.

Implementations: `CompositeTouchHealthReporter`, `MenuBarHealthReporter`, `NotificationHealthReporter`, `JSONLHealthReporter`, `RecordingTouchHealthReporter` (tests), `NoOpTouchHealthReporter`
