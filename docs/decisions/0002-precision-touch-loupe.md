# ADR-0002: Precision Touch Loupe

**Status:** Accepted
**Date:** 2026-08-19
**Author:** Joshua Ruder / Codex

## Context

`touchutil` maps the ASUS panel's absolute HID coordinates to a macOS display and synthesizes public mouse, scroll, zoom-shortcut, and navigation events. A fingertip obscures small controls and text insertion points, so the current one-to-one pointer placement is difficult to fine-tune even when display calibration is correct.

The requested interaction is the familiar Apple touch loupe: after a deliberate hold, show a circular, live magnification of the screen region under the touch target above the finger; let finger movement refine a crosshair; and commit the final click on lift. The existing 0.5-second stationary hold produces a right-click, while movement before that threshold resolves to scroll or drag. The new interaction must preserve those behaviors.

Displaying pixels from other applications introduces a new macOS ScreenCaptureKit boundary and Screen Recording permission. The app must explain and request that permission explicitly, never capture audio, never persist frames, and remain usable when capture permission is absent.

## Decision

Add a local precision-loupe mode to the existing signed `touchutil` agent.

### Interaction contract

1. A single finger that lifts before the 0.5-second hold threshold remains a normal tap.
2. Movement that exceeds the existing tolerance before the threshold remains normal scroll/drag arbitration; the loupe never steals it.
3. A stationary 0.5-second hold arms and displays the loupe above the finger.
4. Movement after the loupe is armed enters precision placement. Relative finger deltas move the target at a reduced gain, while the circular loupe and fixed crosshair show the exact final point.
5. Lifting after precision movement dismisses the loupe and posts one left click at the crosshair.
6. Lifting after a stationary hold dismisses the loupe and posts the existing right-click, preserving long-press behavior.
7. A second contact, display loss, HID loss, Escape, or app shutdown cancels the loupe without posting a click.
8. The loupe flips below or beside the finger near display edges, never leaves the saved touchscreen bounds, never activates another app, and never appears in its own captured pixels.

### Permission and capture flow

On first loupe use, `ScreenRegionSampling` preflights Screen Recording permission. If permission is undetermined or denied, the app presents a short local explanation and invokes the system permission request. Until permission is effective, `PrecisionOverlayPresenting` shows a permission-free crosshair/precision indicator rather than failing touch input. The menu-bar surface names the missing permission and offers the relevant System Settings action. If macOS requires an agent restart after approval, touchutil offers a restart action and launchd resumes it.

When authorized, a ScreenCaptureKit adapter starts only while the loupe is visible. It selects the configured display, captures a small logical source rectangle centered on the precision target, excludes touchutil's own application windows, emits no audio, keeps a shallow frame queue, and stops immediately when the interaction ends. Frames are displayed in memory and never written to disk or included in diagnostics.

### Architecture

Add vendor-neutral precision values and these ports:

- `PrecisionGestureInterpreting` receives single-contact lifecycle events and points and emits arm, move, commit-left, commit-right, and cancel actions. The driver's existing timer provides an explicit hold-to-arm signal, keeping the state machine deterministic in unit tests.
- `ScreenRegionSampling` reports capture authorization, requests it explicitly, and produces transient sampled frames for a target display region. Implementations: `ScreenCaptureKitRegionSampler` and `NoOpScreenRegionSampler`.
- `PrecisionOverlayPresenting` presents or dismisses loupe state and frames without changing application focus. Implementations: `AppKitPrecisionOverlay` and `NoOpPrecisionOverlay`.
- `InputDelivering` posts semantic pointer actions such as move, left click, right click, drag, scroll, zoom, and navigation. The existing CGEvent implementation moves behind `CoreGraphicsInputDeliverer`.

ScreenCaptureKit, CoreMedia, CoreVideo/IOSurface, AppKit, and CoreGraphics types remain inside macOS adapters and executable composition. Gesture state, target geometry, sampled-frame metadata, and tests remain vendor-neutral Swift values.

## Boundary

- Reuse `BOUNDARIES.md` row 1, IOKit / IOHIDManager (Medium), for raw local contact input.
- Reuse row 2, CoreGraphics / AppKit display APIs (Medium), for saved-display resolution and overlay placement.
- Reuse row 3, Accessibility / CGEvent (Medium), through the new `InputDelivering` port for final pointer delivery.
- Reuse row 4, AppKit status item (Low), to explain capture permission and offer settings/restart actions.
- Introduce Apple ScreenCaptureKit + CoreMedia/CoreVideo/IOSurface (Medium) for transient local screen-region sampling behind `ScreenRegionSampling`.
- Extend AppKit usage (Low) with a nonactivating, click-through loupe panel behind `PrecisionOverlayPresenting`.

Capability scan result: neither existing capability matches the loupe's function or data shape above a Low threshold. `TouchEnvironmentInspecting` remains useful only as an adjacent source of resolved display/permission facts, and `TouchHealthReporting` remains useful only as an adjacent operator-status surface. The four ports above are therefore new capabilities rather than forced reuse.

## Safety Rules

- Request Screen Recording permission only with a local explanation and never infer approval from process liveness.
- Capture screen video only while a visible loupe is active; capture no audio or microphone data.
- Never persist, transmit, log, or include captured pixels in diagnostic bundles.
- Exclude touchutil's own windows from capture to prevent recursive imagery.
- Permission denial or capture failure must fall back to a crosshair and must never disable ordinary touch gestures.
- A cancelled or interrupted loupe must never emit a click.
- Final clicks remain clamped to the resolved ASUS display bounds.
- `--no-gestures` disables the loupe along with other interpreted gestures.
- launchd unload/quit remains the application kill switch; `--no-gestures` disables the loupe while retaining plain pointer delivery.

## Cost Rationalization

1. **Marginal cost:** $0; all sampling and rendering use local macOS frameworks.
2. **Steady-state cost:** $0 monetary cost. CPU/GPU use exists only during a visible loupe and is bounded by a small source region, shallow queue, and capped frame rate.
3. **Principled justification:** Native ScreenCaptureKit is the supported local path for live macOS screen pixels. No hosted service is involved or appropriate.
4. **Kill-switch + spend cap:** Monetary cap is $0. The operator can disable the loupe, deny Screen Recording, or unload the existing launchd agent.

## Alternatives Considered

| Alternative | Why rejected |
|---|---|
| Permission-free crosshair only | Useful fallback, but it does not show the content hidden by the fingertip and does not satisfy the requested Apple-style loupe. |
| Legacy CoreGraphics screenshots on every movement | Less controllable and not the preferred high-performance capture path; repeated snapshots are more likely to stutter. |
| Capture the entire display continuously | Wastes WindowServer/GPU resources and expands the privacy surface when the loupe is idle. |
| Accessibility text-caret APIs only | Does not work consistently across arbitrary applications or non-text controls. |
| Replace long-press right-click | Unnecessary regression; stationary long-press can remain right-click while hold-and-move becomes precision placement. |
| DriverKit virtual HID | Does not by itself render a magnified screen region and introduces entitlement/distribution risk unrelated to this feature. |

## Acceptance Criteria

1. **Tap and lift before 0.5 seconds → Expect** one ordinary left click and no loupe.
2. **Move vertically before 0.5 seconds → Expect** existing scroll behavior and no loupe.
3. **Hold one finger still for 0.5 seconds → Expect** a circular loupe above the finger with a fixed crosshair and no click yet.
4. **Move after the loupe appears → Expect** reduced-gain target movement and live magnified pixels centered on the exact target.
5. **Lift after precision movement → Expect** one left click at the crosshair and immediate loupe dismissal.
6. **Hold without precision movement and lift → Expect** one right-click and immediate loupe dismissal.
7. **Add a second finger or press Escape while active → Expect** dismissal with no click, scroll, zoom, or navigation leakage.
8. **Deny Screen Recording → Expect** ordinary touch to continue, a permission-free crosshair fallback, and a clear menu action explaining how to enable the full loupe.
9. **Grant Screen Recording and restart if macOS requests it → Expect** live pixels without touchutil's overlay appearing recursively.
10. **Use the loupe at every screen edge and in a full-screen app → Expect** an onscreen, click-through loupe that does not steal focus.
11. **Disconnect/reconnect the ASUS touch path → Expect** cancellation during loss and normal health-supervisor recovery afterward.
12. **Run automated gesture fixtures → Expect** deterministic coverage of tap, pre-threshold movement, stationary long-press, hold-and-move, left/right commit, cancellation, and existing multitouch regressions.

Automated tests must cover the pure state transitions and cancellation invariants. The operator must physically verify criteria 3 through 10 on the ASUS panel before the feature is committed as accepted.

## Validation Evidence

- `swift test` passed all 21 tests: seven precision-loupe fixtures plus the existing multitouch, click-delivery, display-resolution, and health-supervisor suites.
- The signed universal app bundle (`1.5.0`, x86_64 + arm64) was installed under the existing launchd agent; `--doctor` remained `healthy` with the ASUS display, eGalax controller, permissions, mapping, and HID attachment all verified.
- Screen Recording permission was exercised with live in-memory capture; captured pixels were displayed in the click-through overlay without affecting ordinary touch delivery.
- Operator acceptance on 2026-08-19 confirmed the corrected frame orientation and accepted the coarser `0.65` movement gain with `2.2×` magnification as good for the current release.

## Swap / Sunset Plan

If ScreenCaptureKit behavior or permission policy changes, replace only `ScreenRegionSampling`; retain the precision gesture interpreter and permission-free overlay. If live sampling proves too expensive, use on-demand screenshots behind the same port at a lower frame rate. If the overlay interferes with future macOS window management, replace `PrecisionOverlayPresenting` while preserving gesture and input contracts.

Review this decision when the minimum supported macOS version changes, Apple changes ScreenCaptureKit permission/restart behavior, or a DriverKit/native direct-touch architecture becomes available.
