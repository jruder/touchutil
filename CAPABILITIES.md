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

## PrecisionGestureInterpreting

Path: `Sources/touchutil/PrecisionTouch.swift`

Description: Converts vendor-neutral touchscreen contact lifecycle events and points into precision-loupe actions while preserving ordinary tap, pre-threshold movement, stationary long-press, cancellation, and final left/right commit semantics. It processes local point and contact-count values and is called by the touch driver, whose existing timer supplies the explicit hold-to-arm signal.

Implementations: `PrecisionGestureInterpreter`

## ScreenRegionSampling

Path: `Sources/touchutil/PrecisionTouch.swift`

Description: Reports and requests local screen-capture authorization and produces transient, in-memory frames for a small logical display region centered on a precision target. It processes display identifiers, rectangles, and bounded BGRA frame data and is called only while the loupe is visible.

Implementations: `ScreenCaptureKitRegionSampler`, `NoOpScreenRegionSampler`

## PrecisionOverlayPresenting

Path: `Sources/touchutil/PrecisionTouch.swift`

Description: Presents, updates, and dismisses a click-through precision overlay from vendor-neutral loupe state and sampled frames without changing application focus. It processes target geometry, overlay placement, authorization state, and transient frame bytes.

Implementations: `AppKitPrecisionOverlay`, `NoOpPrecisionOverlay`

## InputDelivering

Path: `Sources/touchutil/PrecisionTouch.swift`

Description: Delivers semantic pointer, scroll, zoom, and navigation actions to the local operating system without exposing vendor event types to gesture-domain code. It processes screen points, pointer buttons, pixel deltas, zoom steps, and navigation commands.

Implementations: `CoreGraphicsInputDeliverer`
