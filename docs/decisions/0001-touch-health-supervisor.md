# ADR-0001: Local Touch Health Supervisor

**Status:** Accepted
**Date:** 2026-08-19
**Author:** Joshua Ruder / Codex

## Context

`touchutil` already runs continuously under launchd, listens for the configured eGalax HID device, and registers matching and removal callbacks. Those mechanisms are invisible to the operator, and the current implementation collapses distinct failures into the same symptom: touch does nothing.

The live ASUS MB16AMT incident demonstrated two independent failure classes:

1. The display/video path remained online while the USB 2 touch controller `0x0EEF:C000` never enumerated. No userspace driver can attach to a device macOS cannot see. Rotating the ASUS-end USB-C connector restored the missing three-port USB 2 hub and eGalax controller.
2. After the controller returned, the saved physical display identity was not present in `CGGetActiveDisplayList` because of display mirroring. `resolveDisplay()` silently selected the largest remaining external display, mapping touch to the vertical LG instead of the ASUS mirror group.

The current removal callback clears contact state but emits no durable state transition, user notification, or visible health status. Logs are written to `/tmp`, are not structured, and do not explain a current corrective action. This violates the operator-transparency and honest-status principles: a running process is not proof of end-to-end touch readiness.

## Decision

Build a local, zero-network health supervisor inside the existing signed macOS app bundle.

The supervisor will use a pure `TouchHealthMachine` to reduce environment observations into one of these operator states:

- `starting`
- `healthy`
- `displayDisconnected`
- `touchHardwareMissing`
- `permissionRequired`
- `mappingRequired`
- `driverDegraded`

Existing IOHID matching/removal callbacks and CoreGraphics display callbacks will feed the state machine immediately. A low-frequency local watchdog will reconcile the current environment so a missed callback cannot leave stale green status. When HID is present but the driver is not attached, the driver will reopen/rebind the matching device once before reporting degradation. It will not automatically reset arbitrary USB hubs.

The pure state machine will call the `TouchHealthReporting` port. A composite macOS adapter will:

- maintain a menu-bar status item with current state and actionable detail;
- send debounced Notification Center alerts only for actionable state transitions;
- append a bounded local JSONL diagnostic timeline;
- expose the same snapshot through `touchutil --doctor` and `--doctor-json`.

Display targeting will use online physical displays, not only active displays. A saved physical target that is mirrored will resolve to its active mirror master and bounds. Missing or ambiguous targets will produce `mappingRequired`; the driver will never silently fall back to an unrelated external display.

## Boundary

The repository inventory is new, so all rows are new to `BOUNDARIES.md`; several describe existing code rather than new vendor adoption.

- Apple IOKit / IOHIDManager — existing implementation, Medium swap risk. Wrapped by the proposed `TouchEnvironmentInspecting` port for health snapshots; the input driver remains the existing platform adapter.
- Apple CoreGraphics / AppKit display APIs — existing implementation, Medium swap risk. Wrapped behind the environment inspector and a pure display-target resolver.
- Apple Accessibility / CGEvent — existing implementation, Medium swap risk. Permission state becomes health input; event injection remains in the existing adapter.
- Apple AppKit `NSStatusItem` — new use, Low swap risk. Adapter for `TouchHealthReporting`.
- Apple UserNotifications — new use, Low swap risk. Adapter for `TouchHealthReporting`; denial does not break the menu-bar fallback.
- Local filesystem through Foundation — new bounded health-timeline use, Low swap risk. Adapter for `TouchHealthReporting`; no cloud or network data leaves the Mac.
- launchd — existing runtime integration, Low swap risk. It continues to own process liveness; the supervisor owns semantic readiness.

Vendor framework types may appear only in the macOS adapter and executable-composition code. `TouchHealthMachine`, its snapshots, transitions, recommendations, and tests remain vendor-neutral Swift values.

New capabilities proposed for `CAPABILITIES.md` after approval:

### TouchEnvironmentInspecting

Returns a local snapshot of display presence and topology, target mapping, eGalax HID presence and attachment, Accessibility/Input Monitoring permission state, and driver liveness. It processes only local device metadata and contains no user content.

### TouchHealthReporting

Publishes a semantic touch-health transition and its recommended action to one or more local operator surfaces. Implementations include menu-bar status, Notification Center, bounded JSONL history, and no-op/in-memory test doubles.

## Safety Rules

- Never report `healthy` unless the target display resolves, `0x0EEF:C000` is present, both permissions are granted, and the driver has attached the HID elements.
- Never silently map the touchscreen to a different physical display.
- Do not automatically reset a USB hub whose current topology has not been proven safe. This feature performs no hub resets by default.
- Debounce transient disconnects and notify only on state transitions; repeated polling must not generate notification spam.
- Keep the diagnostic timeline local, bounded, non-secret-bearing, and removable.
- Notification permission denial must not prevent touch operation or menu-bar status.
- Preserve launchd `KeepAlive` and the existing manual quit/unload path as the kill switch.

## Cost Rationalization

1. **Marginal cost:** $0 per observation or notification; all APIs are local macOS frameworks.
2. **Steady-state cost:** $0 monetary cost; one low-frequency timer and a bounded local file have negligible CPU/storage impact.
3. **Principled justification:** No paid or hosted service is used. Native local APIs are the only surfaces that can observe local HID/display state and present Mac status.
4. **Kill-switch + spend cap:** Monetary cap is fixed at $0. The operator can quit/unload `com.touchutil.agent`, disable notifications in System Settings, or uninstall the app.

## Alternatives Considered

| Alternative | Why rejected |
|---|---|
| Restart `touchutil` whenever touch fails | A restart cannot attach a USB device that did not enumerate and would keep the failure opaque. |
| Automatically cycle the last-known hub port | Hub paths change with rewiring, may carry unrelated devices, and previous cycles did not reboot the battery-backed ASUS controller. |
| Poll shell commands from a second daemon | Duplicates launch/runtime state and creates another black box; the app already receives native HID and display callbacks. |
| Log more text to `/tmp` | Improves post-hoc debugging but provides no current status, action, retention, or recovery. |
| Always map to the main or largest external display | Repeats the observed LG misrouting bug when mirror topology changes. |

## Acceptance Criteria

1. **Launch with a healthy setup → Expect** a green menu-bar status that names the ASUS target and confirms `0x0EEF:C000` is attached.
2. **Disconnect only the touch USB path while ASUS video remains online → Expect** one actionable alert after debounce: the touch USB path is missing and the ASUS connector should be reseated or rotated.
3. **Reconnect the eGalax controller → Expect** automatic HID reattachment and return to green without manually restarting the agent.
4. **Reconnect or change mirroring → Expect** mapping to the saved physical target or its active mirror master; never to the LG fallback.
5. **Remove Accessibility or Input Monitoring permission → Expect** a specific permission-required state and the relevant System Settings action.
6. **Run `touchutil --doctor` → Expect** a human-readable state, evidence for each prerequisite, and one recommended next action; `--doctor-json` returns the same semantic snapshot as JSON.
7. **Trigger repeated identical observations → Expect** no repeated notification; a bounded timeline records only transitions and material recovery attempts.
8. **Exercise state and mapping fixtures → Expect** unit tests for every state and mirrored-display resolution; physical acceptance covers tap, two-finger scroll, disconnect, reconnect, and alert/recovery behavior.

## Validation Evidence

- `swift test` passed all 14 tests, including every health state, mirror-master resolution, no unrelated-display fallback, transition deduplication, and gesture regression coverage.
- The signed universal app bundle (`1.4.0`, x86_64 + arm64) was installed under the existing launchd agent with both permissions granted.
- Live `--doctor` checks stayed `healthy` across multiple watchdog intervals while the current-state heartbeat advanced and the transition-log line count remained unchanged.
- Operator acceptance on 2026-08-19 confirmed tap, two-finger scroll, disconnect/reconnect detection, alert/recovery, and automatic return to working touch without restarting the agent.

## Swap / Sunset Plan

If UserNotifications behavior changes, remove that adapter while retaining menu-bar status, CLI doctor, and timeline reporting through `TouchHealthReporting`. If AppKit status items become unavailable, keep the notification and CLI adapters. If CoreGraphics display identity behavior changes, replace only the environment inspector/display adapter while preserving the pure target resolver and health-state contract.

Review this decision when macOS changes IOHID permission behavior, the ASUS hardware path is simplified or replaced, or a native DriverKit implementation becomes practical.
