//
//  touchutil — Map an external USB touchscreen to its display on macOS.
//
//  macOS does not natively route absolute touch input from external USB
//  touchscreens to the correct display. This tool reads the digitizer's
//  contact reports via IOHIDManager and:
//    • 1 finger      → move cursor, tap-to-click, drag
//    • 2 fingers     → smooth scroll or pinch-to-zoom
//    • 3+ fingers    → Spaces / Mission Control / App Exposé
//    • double-tap    → double-click
//    • long-press    → right-click
//    • edge swipe    → Spaces / Mission Control / App Exposé (via shortcuts)
//
//  This is userspace gesture recognition, not native touch injection. Apps see
//  public mouse, scroll, zoom-shortcut, and navigation events. Native touch
//  contacts would require an entitlement-gated DriverKit HID extension.
//
//  Works on Apple Silicon and Intel. No kernel extension, no SIP changes.
//
//  Requires (granted to the app, or to the launching Terminal). The app
//  requests both automatically on launch (and registers itself in each list):
//    • Input Monitoring   — to read the touchscreen
//    • Accessibility      — to move the cursor and synthesize input
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import IOKit
import IOKit.hid

func clickEventTap(button: CGMouseButton, count: Int) -> CGEventTapLocation {
    .cghidEventTap
}

// MARK: - Config

struct Config {
    var vendorID: Int?
    var productID: Int?
    var displayIndex: Int?
    var displayVendor: UInt32?
    var displayModel: UInt32?
    var gestures = true
    var debug = false
    var debugLog = false
    var test = false
}

struct SavedConfig: Codable {
    var displayVendor: UInt32
    var displayModel: UInt32
    var displayName: String?
}

func configURL() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/touchutil/config.json")
}

func loadSavedConfig() -> SavedConfig? {
    guard let data = try? Data(contentsOf: configURL()) else { return nil }
    return try? JSONDecoder().decode(SavedConfig.self, from: data)
}

func saveConfig(_ c: SavedConfig) {
    let url = configURL()
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(c) { try? data.write(to: url) }
}

func savedDisplayTarget() -> SavedDisplayTarget? {
    guard let saved = loadSavedConfig() else { return nil }
    return SavedDisplayTarget(
        vendor: saved.displayVendor,
        model: saved.displayModel,
        name: saved.displayName
    )
}

func saveDisplayTarget(_ id: CGDirectDisplayID) {
    saveConfig(SavedConfig(
        displayVendor: CGDisplayVendorNumber(id),
        displayModel: CGDisplayModelNumber(id),
        displayName: displayName(id)
    ))
}

func configuredDisplayTarget(_ config: Config) -> SavedDisplayTarget? {
    if let vendor = config.displayVendor, let model = config.displayModel {
        let name = macOSOnlineDisplays().first {
            $0.vendor == vendor && $0.model == model
        }?.name
        return SavedDisplayTarget(vendor: vendor, model: model, name: name)
    }
    return savedDisplayTarget()
}

func resolveConfiguredDisplay(_ config: Config) -> ResolvedTouchDisplay? {
    if let index = config.displayIndex {
        let active = activeDisplays()
        guard index >= 0, index < active.count else { return nil }
        saveDisplayTarget(active[index])
    }
    return DisplayTargetResolver.resolve(
        target: configuredDisplayTarget(config),
        displays: macOSOnlineDisplays()
    )
}

func cgRect(_ bounds: TouchDisplayBounds) -> CGRect {
    CGRect(x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height)
}

// MARK: - Helpers

let debugLogURL = URL(fileURLWithPath: "/tmp/touchutil.debug.log")
var debugLogHandle: FileHandle? = nil

func err(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

func debugOut(_ s: String) {
    let line = s + "\n"
    if let h = debugLogHandle {
        h.write(line.data(using: .utf8)!)
    } else {
        FileHandle.standardError.write(line.data(using: .utf8)!)
    }
}

func activeDisplays() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &displays, &count)
    return displays
}

/// Human-readable name for a display. Some panels (e.g. cheap touchscreens)
/// report no EDID name — macOS returns "" — so fall back to a usable label.
func displayName(_ id: CGDirectDisplayID) -> String {
    for screen in NSScreen.screens {
        if let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
           num == id {
            let name = screen.localizedName.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return name }
        }
    }
    return "Unnamed display"
}

/// Name of the first detected touchscreen digitizer, if any.
func touchDeviceName() -> String? {
    guard let dev = touchDevices().first else { return nil }
    return IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String
}

// MARK: - List / inspect / setup modes

/// All connected touchscreen digitizers (usagePage 0x0D, usage 0x04).
func touchDevices() -> [IOHIDDevice] {
    let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(mgr, [
        kIOHIDDeviceUsagePageKey as String: 0x0D,
        kIOHIDDeviceUsageKey as String: 0x04,
    ] as CFDictionary)
    IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
    return (IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>).map(Array.init) ?? []
}

func listDisplays() {
    let mainID = CGMainDisplayID()
    let resolvedID = DisplayTargetResolver.resolve(
        target: savedDisplayTarget(),
        displays: macOSOnlineDisplays()
    )?.output.id
    let devices = touchDevices()
    let hasTouchHardware = !devices.isEmpty

    print("Active displays:")
    for (i, d) in activeDisplays().enumerated() {
        let b = CGDisplayBounds(d)
        let main = (d == mainID) ? "  [MAIN]" : ""
        // Touch column: mark the display configured as the touchscreen.
        var touch = "  touch: —"
        if resolvedID == d {
            touch = "  touch: ✓ configured"
        } else if hasTouchHardware {
            touch = "  touch: ? (run --setup to assign)"
        }
        print(String(format: "  [%d] id=%u  origin=(%d,%d)  size=%dx%d  vendor=%u  model=%u%@%@",
                     i, d, Int(b.origin.x), Int(b.origin.y),
                     Int(b.size.width), Int(b.size.height),
                     CGDisplayVendorNumber(d), CGDisplayModelNumber(d), main, touch))
    }

    print("\nDetected touchscreen devices:")
    if devices.isEmpty {
        print("  (none — no USB touchscreen detected, or Input Monitoring not granted)")
    } else {
        for dev in devices {
            let name = IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String ?? "?"
            let vid = IOHIDDeviceGetProperty(dev, kIOHIDVendorIDKey as CFString) as? Int ?? -1
            let pid = IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? Int ?? -1
            print(String(format: "  %@  vendor=0x%04X product=0x%04X", name, vid, pid))
        }
    }
    print("\nNote: macOS can't map a touch device to a specific display automatically;")
    print("use --setup to tell touchutil which display is the touchscreen.")
}

func listDevices() {
    let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(mgr, nil)
    IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
    guard let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> else {
        print("No HID devices found (Input Monitoring permission may be required)."); return
    }
    print("HID devices (touchscreens are usagePage=13 / usage=4):")
    for dev in set {
        let name = IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String ?? "?"
        let vid = IOHIDDeviceGetProperty(dev, kIOHIDVendorIDKey as CFString) as? Int ?? -1
        let pid = IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? Int ?? -1
        let up = IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? -1
        let u  = IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsageKey as CFString) as? Int ?? -1
        let touch = (up == 0x0D) ? "  <-- digitizer/touch" : ""
        print(String(format: "  %@  vendor=0x%04X product=0x%04X  usagePage=%d usage=%d%@",
                     name, vid, pid, up, u, touch))
    }
}

func inspectDevices() {
    let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(mgr, nil)
    IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
    guard let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> else {
        print("No HID devices (Input Monitoring may be required)."); return
    }
    for dev in set {
        let up = IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? -1
        guard up == 0x0D else { continue }
        let name = IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String ?? "?"
        print("Device: \(name)")
        guard let elements = IOHIDDeviceCopyMatchingElements(dev, nil, 0) as? [IOHIDElement] else { continue }
        var seen = Set<String>()
        for e in elements {
            let p = IOHIDElementGetUsagePage(e), u = IOHIDElementGetUsage(e)
            let key = String(format: "0x%02X/0x%02X", p, u)
            if seen.insert(key).inserted {
                print(String(format: "  page=0x%02X usage=0x%02X  logical=[%d..%d]",
                             p, u, IOHIDElementGetLogicalMin(e), IOHIDElementGetLogicalMax(e)))
            }
        }
        print("")
    }
}

/// Print every digitizer element, including its collection ancestry. Repeated
/// Finger collections are how multi-contact panels associate X/Y/tip values
/// with a contact identifier.
func inspectDeviceDetails() {
    let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(mgr, [
        kIOHIDDeviceUsagePageKey as String: 0x0D,
        kIOHIDDeviceUsageKey as String: 0x04,
    ] as CFDictionary)
    IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
    guard let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>, !set.isEmpty else {
        print("No touchscreen devices (Input Monitoring may be required)."); return
    }
    for dev in set {
        let name = IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String ?? "?"
        print("Device: \(name)")
        guard let elements = IOHIDDeviceCopyMatchingElements(dev, nil, 0) as? [IOHIDElement] else { continue }
        for e in elements {
            let p = IOHIDElementGetUsagePage(e), u = IOHIDElementGetUsage(e)
            var ancestors: [String] = []
            var parent = IOHIDElementGetParent(e)
            while let collection = parent {
                ancestors.append(String(format: "%02X/%02X", IOHIDElementGetUsagePage(collection), IOHIDElementGetUsage(collection)))
                parent = IOHIDElementGetParent(collection)
            }
            print(String(format: "  cookie=%-4d report=%-2d type=%-2d page=%02X usage=%02X logical=[%d..%d] parent=%@",
                         Int(IOHIDElementGetCookie(e)), IOHIDElementGetReportID(e), IOHIDElementGetType(e).rawValue,
                         p, u, IOHIDElementGetLogicalMin(e), IOHIDElementGetLogicalMax(e),
                         ancestors.joined(separator: "<")))
        }
        print("")
    }
}

func runSetup() {
    listDisplays()
    print("\nEnter the index of the touchscreen display: ", terminator: "")
    guard let line = readLine(),
          let idx = Int(line.trimmingCharacters(in: .whitespaces)) else { err("Invalid input."); exit(1) }
    let displays = activeDisplays()
    guard idx >= 0, idx < displays.count else { err("Index out of range."); exit(1) }
    let d = displays[idx]
    let v = CGDisplayVendorNumber(d), m = CGDisplayModelNumber(d)
    saveConfig(SavedConfig(displayVendor: v, displayModel: m, displayName: displayName(d)))
    print("Saved. Touchscreen display remembered (vendor=\(v) model=\(m)).")
}

// MARK: - Driver

final class TouchDriver {
    private let config: Config
    private var bounds: CGRect = .zero
    private var targetDisplayID: CGDirectDisplayID = CGMainDisplayID()
    private let input: InputDelivering = CoreGraphicsInputDeliverer()
    private var manager: IOHIDManager!
    private var driverAttached = false
    private var healthSupervisor: TouchHealthSupervisor?
    private var healthWatchdog: Timer?

    // Pointer state and raw HID contacts. Contacts are keyed by their nearest
    // Digitizers/Finger collection, so repeated X/Y/tip elements do not stomp
    // on one another.
    private struct RawContact {
        var identifier: Int?
        var tip = false
        var nx = 0.0
        var ny = 0.0
        var hasX = false
        var hasY = false
    }
    private var rawContacts: [Int: RawContact] = [:]
    private var elementSlots: [IOHIDElementCookie: Int] = [:]
    private var frameTimer: Timer?
    private var reportedContactCount: Int?
    private var multiTouch = MultiTouchInterpreter()
    private var precisionTouch = PrecisionGestureInterpreter()
    private let screenSampler: ScreenRegionSampling = makeScreenRegionSampler()
    private let precisionOverlay: PrecisionOverlayPresenting = AppKitPrecisionOverlay()
    private var captureAuthorization: ScreenCaptureAuthorization = .permissionRequired
    private var currentLoupeState: PrecisionLoupeState?
    private var requestedCapturePermissionThisRun = false
    private weak var menuBarReporter: MenuBarHealthReporter?

    // Single-finger pointer state.
    private var xLogicalMax = 4095.0
    private var yLogicalMax = 4095.0
    private var pNX = 0.0, pNY = 0.0
    private var pTip = false, pDown = false
    private var tipTimer: Timer?
    private let tipDebounce = 0.05   // 50 ms — coalesces rapid tip=1/tip=0 cycles per sample

    // Single-finger gesture recognizer state.
    private var fingerDown = false, mousePressed = false, movedBeyond = false
    private var edgeFired = false, longFired = false, edgeResolved = false
    private var scrollMode = false, dragEnabled = false
    private var nearL = false, nearR = false, nearT = false, nearB = false
    private var sStartPx = CGPoint.zero
    private var lastScrollPx = CGPoint.zero
    private var longTimer: Timer?
    private var dragTimer: Timer?
    private var lastTapTime = 0.0
    private var lastTapPx = CGPoint.zero
    private var lastClickCount = 0
    // Single-finger tunables.
    private let moveTol = 10.0
    private let longPressDelay = 0.5
    private let dragHoldDelay = 0.35  // hold 350ms before horizontal drag enables selection
    private let edgeMarginN = 0.12    // 12% from edge triggers edge-swipe mode
    private let edgeSwipeThreshold = 40.0  // px to travel before edge key fires
    private let doubleTapInterval = 0.6    // max gap between two taps to count as double-tap
    private let doubleTapDist = 70.0       // max finger travel between taps (px)

    var testWindow: TestWindow? = nil   // set when running --test
    private var signalSource: DispatchSourceSignal? = nil
    private var escapeMonitor: Any? = nil
    private var appDelegate: NSObject? = nil

    init(config: Config) { self.config = config }

    /// Expose resolved display bounds without starting the full driver (used by --test setup).
    func boundsForTest() -> CGRect {
        resolveDisplay() ?? CGDisplayBounds(CGMainDisplayID())
    }

    // MARK: Display resolution

    private func resolveDisplay() -> CGRect? {
        guard let resolved = resolveConfiguredDisplay(config) else {
            err("WARNING: saved touchscreen display is unavailable or ambiguous; touch mapping is paused.")
            return nil
        }
        let target = resolved.physical
        let output = resolved.output
        targetDisplayID = output.id
        if target.id == output.id {
            err("Using saved touchscreen display \(output.name) (vendor=\(target.vendor) model=\(target.model)).")
        } else {
            err("Using mirror master \(output.name) for saved display vendor=\(target.vendor) model=\(target.model).")
        }
        return cgRect(output.bounds)
    }

    // MARK: Event synthesis

    private func screenPoint(_ n: CGPoint) -> CGPoint {
        CGPoint(x: bounds.origin.x + n.x * bounds.size.width,
                y: bounds.origin.y + n.y * bounds.size.height)
    }

    private func precisionPoint(_ point: CGPoint) -> PrecisionPoint {
        PrecisionPoint(x: point.x, y: point.y)
    }

    private func cgPoint(_ point: PrecisionPoint) -> CGPoint {
        CGPoint(x: point.x, y: point.y)
    }

    private var precisionBounds: PrecisionRect {
        PrecisionRect(
            x: bounds.origin.x,
            y: bounds.origin.y,
            width: bounds.width,
            height: bounds.height
        )
    }

    private func postMouse(_ type: CGEventType, _ p: CGPoint, button: CGMouseButton = .left) {
        let phase: InputPointerPhase
        switch type {
        case .leftMouseDown, .rightMouseDown: phase = .down
        case .leftMouseDragged, .rightMouseDragged: phase = .dragged
        case .leftMouseUp, .rightMouseUp: phase = .up
        default: phase = .moved
        }
        input.pointer(
            phase,
            at: precisionPoint(p),
            button: button == .right ? .right : .left
        )
    }

    /// Trigger Mission Control (show all windows) via the F3 / Mission Control key.
    /// Falls back to Ctrl+Up which is the default keyboard shortcut.
    private func postMissionControl() {
        input.missionControl()
    }

    // MARK: HID element setup

    /// Find the logical max for the General Desktop X / Y axes so we can
    /// normalize the panel's absolute coordinates to 0..1.
    private func setupElements(_ dev: IOHIDDevice) {
        guard let elements = IOHIDDeviceCopyMatchingElements(dev, nil, 0) as? [IOHIDElement] else {
            driverAttached = false
            healthSupervisor?.refresh()
            return
        }
        for e in elements {
            let p = IOHIDElementGetUsagePage(e), u = IOHIDElementGetUsage(e)
            if p == 0x01 && u == 0x30 { xLogicalMax = max(xLogicalMax, Double(IOHIDElementGetLogicalMax(e))) }
            else if p == 0x01 && u == 0x31 { yLogicalMax = max(yLogicalMax, Double(IOHIDElementGetLogicalMax(e))) }
        }
        driverAttached = true
        err("Touch input mapped (gestures \(config.gestures ? "ON" : "OFF")).")
        healthSupervisor?.refresh()
    }

    // MARK: Per-value input

    private func handle(value: IOHIDValue) {
        guard bounds.width > 0 && bounds.height > 0 else { return }
        let element = IOHIDValueGetElement(value)
        let page = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let v = IOHIDValueGetIntegerValue(value)

        if config.debug {
            debugOut(String(format: "page=0x%02X usage=0x%02X val=%d", page, usage, v))
        }

        if page == 0x0D && usage == 0x54 {
            reportedContactCount = Int(v)
            scheduleFrame()
            return
        }

        // Tip Switch is the HID Digitizers standard. Button 1 is retained as a
        // compatibility fallback for panels that expose a mouse-like contact.
        let isTip = (page == 0x0D && usage == 0x42) || (page == 0x09 && usage == 0x01)
        let isContactID = page == 0x0D && usage == 0x51
        let isX = page == 0x01 && usage == 0x30
        let isY = page == 0x01 && usage == 0x31
        guard isTip || isContactID || isX || isY else { return }

        let slot = contactSlot(for: element)
        var contact = rawContacts[slot] ?? RawContact()
        if isTip {
            contact.tip = v != 0
        } else if isContactID {
            contact.identifier = Int(v)
        } else {
            let minimum = Double(IOHIDElementGetLogicalMin(element))
            let maximum = Double(IOHIDElementGetLogicalMax(element))
            let normalized = maximum > minimum ? (Double(v) - minimum) / (maximum - minimum) : 0
            if isX { contact.nx = min(1, max(0, normalized)); contact.hasX = true }
            if isY { contact.ny = min(1, max(0, normalized)); contact.hasY = true }
        }
        rawContacts[slot] = contact
        scheduleFrame()
    }

    /// Return the stable cookie for the nearest Digitizers/Finger collection.
    /// A zero fallback keeps older single-contact mouse-style panels working.
    private func contactSlot(for element: IOHIDElement) -> Int {
        let cookie = IOHIDElementGetCookie(element)
        if let cached = elementSlots[cookie] { return cached }
        var candidate: IOHIDElement? = element
        while let current = candidate {
            if IOHIDElementGetUsagePage(current) == 0x0D && IOHIDElementGetUsage(current) == 0x22 {
                let slot = Int(IOHIDElementGetCookie(current))
                elementSlots[cookie] = slot
                return slot
            }
            candidate = IOHIDElementGetParent(current)
        }
        elementSlots[cookie] = 0
        return 0
    }

    /// IOHIDManager delivers each element separately. Coalesce callbacks from
    /// one report into a contact frame before recognizing a gesture.
    private func scheduleFrame() {
        frameTimer?.invalidate()
        let timer = Timer(timeInterval: 0.001, repeats: false) { [weak self] _ in
            self?.processContactFrame()
        }
        frameTimer = timer
        RunLoop.current.add(timer, forMode: .common)
    }

    private func processContactFrame() {
        frameTimer = nil
        var contacts = rawContacts.compactMap { slot, raw -> TouchContact? in
            guard raw.tip, raw.hasX, raw.hasY else { return nil }
            return TouchContact(key: raw.identifier ?? slot,
                                normalizedPoint: CGPoint(x: raw.nx, y: raw.ny))
        }
        contacts.sort { $0.key < $1.key }
        if let reportedContactCount, reportedContactCount >= 0, contacts.count > reportedContactCount {
            contacts = Array(contacts.prefix(reportedContactCount))
        }
        if config.debug {
            let summary = contacts.map {
                String(format: "%d:(%.3f,%.3f)", $0.key, $0.normalizedPoint.x, $0.normalizedPoint.y)
            }.joined(separator: " ")
            debugOut("FRAME contacts=\(contacts.count) \(summary)")
        }

        let actions = multiTouch.process(contacts, displaySize: bounds.size)
        for action in actions {
            switch action {
            case .began:
                cancelSingleForMultitouch()
            case let .scroll(deltaX, deltaY):
                testWindow?.send(.gesture("✌️ Two-finger Scroll", .systemBlue))
                postScroll(deltaX: deltaX, deltaY: deltaY)
            case let .zoom(steps):
                testWindow?.send(.gesture(steps > 0 ? "🤏 Zoom In" : "🤏 Zoom Out", .systemTeal))
                postZoom(steps: steps)
            case let .navigate(direction):
                postNavigation(direction)
            case .ended:
                break
            }
        }

        guard contacts.count < 2, !multiTouch.suppressSingleFinger else { return }
        if let contact = contacts.first {
            pNX = contact.normalizedPoint.x
            pNY = contact.normalizedPoint.y
            pTip = true
            tipTimer?.invalidate(); tipTimer = nil
            if !config.gestures {
                simplePrimary()
            } else if !fingerDown {
                gestureDown()
            } else {
                gestureMove()
            }
        } else {
            pTip = false
            if !config.gestures {
                simplePrimary()
            } else if fingerDown {
                // Preserve the original release debounce for controllers that
                // briefly pulse Tip Switch off between otherwise valid frames.
                tipTimer?.invalidate()
                let timer = Timer(timeInterval: tipDebounce, repeats: false) { [weak self] _ in
                    guard let self, self.rawContacts.values.allSatisfy({ !$0.tip }) else { return }
                    self.gestureUp()
                }
                tipTimer = timer
                RunLoop.current.add(timer, forMode: .common)
            }
        }
    }

    private func cancelSingleForMultitouch() {
        tipTimer?.invalidate(); tipTimer = nil
        cancelLongTimer(); cancelDragTimer()
        handlePrecisionActions(precisionTouch.cancel())
        if mousePressed {
            let p = clamp(screenPoint(CGPoint(x: pNX, y: pNY)))
            postMouse(.leftMouseUp, p)
        }
        fingerDown = false; mousePressed = false; movedBeyond = false; longFired = false
        scrollMode = false; pDown = false
        testWindow?.send(.lift)
    }

    private func now() -> Double { ProcessInfo.processInfo.systemUptime }

    /// Plain pointer (used with --no-gestures): press on touch, drag, release.
    private func simplePrimary() {
        let p = screenPoint(CGPoint(x: pNX, y: pNY))
        if pTip && !pDown  { pDown = true;  postMouse(.leftMouseDown, p) }
        else if pTip       { postMouse(.leftMouseDragged, p) }
        else if pDown      { pDown = false; postMouse(.leftMouseUp, p) }
    }

    /// Send a click with an explicit clickState so macOS and apps know exactly
    /// whether this is a single (1) or double (2) click — no timing ambiguity.
    /// Without clickState, macOS infers count from timing: two taps within the
    /// system double-click window (~500ms) would be escalated to clickCount=2,
    /// causing one physical tap to behave like a double-click.
    private func postClick(_ p: CGPoint, _ button: CGMouseButton, _ count: Int = 1) {
        input.click(
            at: precisionPoint(p),
            button: button == .right ? .right : .left,
            count: count
        )
    }

    private func startLongTimer() {
        cancelLongTimer()
        let t = Timer(timeInterval: longPressDelay, repeats: false) { [weak self] _ in self?.longPressFired() }
        RunLoop.current.add(t, forMode: .common)
        longTimer = t
    }
    private func cancelLongTimer() { longTimer?.invalidate(); longTimer = nil }

    private func startDragTimer() {
        dragTimer?.invalidate()
        let t = Timer(timeInterval: dragHoldDelay, repeats: false) { [weak self] _ in
            self?.dragEnabled = true
        }
        RunLoop.current.add(t, forMode: .common)
        dragTimer = t
    }
    private func cancelDragTimer() { dragTimer?.invalidate(); dragTimer = nil }

    private func longPressFired() {
        guard fingerDown, !movedBeyond, !edgeFired, !longFired else { return }
        let actions = precisionTouch.arm()
        guard !actions.isEmpty else { return }
        longFired = true
        testWindow?.send(.gesture("🔎 Precision Loupe", .systemOrange))
        handlePrecisionActions(actions)
    }

    private func handlePrecisionActions(_ actions: [PrecisionGestureAction]) {
        for action in actions {
            switch action {
            case let .armed(finger, target):
                let state = makeLoupeState(finger: finger, target: target)
                currentLoupeState = state
                precisionOverlay.show(state)
                beginLoupeCapture(for: state)
            case let .moved(finger, target):
                guard var state = currentLoupeState else { continue }
                state.finger = finger
                state.target = target
                state.authorization = captureAuthorization
                currentLoupeState = state
                precisionOverlay.update(state)
                screenSampler.update(captureRequest(for: state))
            case let .commitLeft(point):
                finishLoupe()
                testWindow?.send(.gesture("🔎 Precision Click", .systemGreen))
                input.warpPointer(to: point)
                input.click(at: point, button: .left, count: 1)
            case let .commitRight(point):
                finishLoupe()
                testWindow?.send(.gesture("⚙️ Long Press → Right-click", .systemOrange))
                input.warpPointer(to: point)
                input.click(at: point, button: .right, count: 1)
            case .cancelled:
                finishLoupe()
            }
        }
    }

    private func makeLoupeState(finger: PrecisionPoint, target: PrecisionPoint) -> PrecisionLoupeState {
        PrecisionLoupeState(
            displayID: targetDisplayID,
            displayBounds: precisionBounds,
            finger: finger,
            target: precisionBounds.clamped(target),
            authorization: captureAuthorization
        )
    }

    private func captureRequest(for state: PrecisionLoupeState) -> ScreenRegionRequest {
        ScreenRegionRequest(
            displayID: state.displayID,
            displayBounds: state.displayBounds,
            target: state.target,
            sourceSize: state.diameter / state.magnification,
            outputSize: Int(state.diameter * 2)
        )
    }

    private func beginLoupeCapture(for state: PrecisionLoupeState) {
        guard captureAuthorization == .authorized else {
            requestCapturePermissionIfNeeded(showExplanation: true)
            return
        }
        screenSampler.start(
            captureRequest(for: state),
            onFrame: { [weak self] frame in self?.precisionOverlay.showFrame(frame) },
            onFailure: { [weak self] message in
                guard let self else { return }
                err("WARNING: \(message)")
                self.captureAuthorization = .failed
                self.menuBarReporter?.updateLoupeAuthorization(.failed)
                if var state = self.currentLoupeState {
                    state.authorization = .failed
                    self.currentLoupeState = state
                    self.precisionOverlay.update(state)
                }
            }
        )
    }

    private func finishLoupe() {
        screenSampler.stop()
        precisionOverlay.dismiss()
        currentLoupeState = nil
    }

    private func postScroll(deltaX: Double = 0, deltaY: Double) {
        input.scroll(deltaX: deltaX, deltaY: deltaY)
    }

    /// Public macOS APIs cannot inject native magnify contacts. Cmd-plus and
    /// Cmd-minus provide predictable zoom in browsers, Preview, and most
    /// document apps while keeping the implementation entirely userspace.
    private func postZoom(steps: Int) {
        input.zoom(steps: steps)
    }

    private func postNavigation(_ direction: TouchNavigation) {
        switch direction {
        case .previousSpace:
            testWindow?.send(.gesture("🤟 Previous Space", .systemPurple))
        case .nextSpace:
            testWindow?.send(.gesture("🤟 Next Space", .systemPurple))
        case .missionControl:
            testWindow?.send(.gesture("🤟 Mission Control", .systemPurple))
        case .appExpose:
            testWindow?.send(.gesture("🤟 App Exposé", .systemPurple))
        }
        input.navigate(direction)
    }

    private func gestureDown() {
        if config.debug { debugOut(String(format: "DOWN  nx=%.3f ny=%.3f  t=%.3f", pNX, pNY, now())) }
        fingerDown = true; mousePressed = false; movedBeyond = false
        edgeFired = false; longFired = false; scrollMode = false; dragEnabled = false
        sStartPx = clamp(screenPoint(CGPoint(x: pNX, y: pNY)))
        precisionTouch.begin(at: precisionPoint(sStartPx))
        lastScrollPx = sStartPx
        let m = edgeMarginN
        nearL = pNX < m; nearR = pNX > 1 - m; nearT = pNY < m; nearB = pNY > 1 - m
        edgeResolved = !(nearL || nearR || nearT || nearB)
        // Warp the cursor to the touch point immediately on touch-down so the
        // first tap lands on the touchscreen — not on whatever display the
        // cursor was previously on. Harmless for scroll (no button is pressed,
        // so the cursor just sits at the touch point without selecting).
        input.warpPointer(to: precisionPoint(sStartPx))
        testWindow?.send(.touch(normX: pNX, normY: pNY))
        if config.debug {
            debugOut(String(format: "touch: nx=%.3f ny=%.3f  nearL=%d nearR=%d nearT=%d nearB=%d edgeResolved=%d",
                pNX, pNY, nearL ? 1:0, nearR ? 1:0, nearT ? 1:0, nearB ? 1:0, edgeResolved ? 1:0))
        }
        startLongTimer()
        startDragTimer()
    }

    /// Clamp a screen point to the touchscreen display bounds so the cursor
    /// never jumps to another monitor due to edge noise or coordinate rounding.
    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(
            x: max(bounds.minX, min(bounds.maxX - 1, p.x)),
            y: max(bounds.minY, min(bounds.maxY - 1, p.y))
        )
    }

    private func gestureMove() {
        let cur = clamp(screenPoint(CGPoint(x: pNX, y: pNY)))
        let precisionActions = precisionTouch.move(to: precisionPoint(cur), within: precisionBounds)
        if precisionTouch.isArmed {
            handlePrecisionActions(precisionActions)
            return
        }
        let dist = hypot(cur.x - sStartPx.x, cur.y - sStartPx.y)
        if dist <= moveTol { return }   // wait for clear movement before committing to any gesture

        if !movedBeyond {
            movedBeyond = true
            cancelLongTimer()
            cancelDragTimer()
            handlePrecisionActions(precisionTouch.cancel())
            let dx = cur.x - sStartPx.x
            let dy = cur.y - sStartPx.y
            // Scroll when movement is vertical, UNLESS near top/bottom edge
            // (those have their own vertical gesture — Mission Control / App Exposé).
            // Near left/right edges still allow vertical scroll — only horizontal
            // movement near left/right triggers edge swipe.
            let nearVerticalEdge = nearT || nearB
            if abs(dy) > abs(dx) && !nearVerticalEdge {
                scrollMode = true
                lastScrollPx = cur
            }
            if config.debug {
                debugOut(String(format: "gesture: dx=%.1f dy=%.1f → %@", dx, dy, scrollMode ? "SCROLL" : "DRAG"))
            }
        }

        // Scroll mode — post wheel events, cursor stays put.
        if scrollMode {
            let deltaY = cur.y - lastScrollPx.y
            if abs(deltaY) > 0.5 {
                let dir = deltaY < 0 ? "↑ Scroll Up" : "↓ Scroll Down"
                testWindow?.send(.gesture(dir, .systemBlue))
            }
            postScroll(deltaY: deltaY)
            lastScrollPx = cur
            return
        }

        if edgeFired { return }
        if !edgeResolved {
            if dist < edgeSwipeThreshold { return }
            let dx = cur.x - sStartPx.x, dy = cur.y - sStartPx.y
            // Only the bottom-left corner triggers Mission Control. Left/right
            // edges fall through to normal drag so window resizing works there.
            if nearL && nearB && (dx > abs(dy) || -dy > abs(dx)) {
                testWindow?.send(.gesture("⬆ Corner → All Windows", .systemPurple))
                postMissionControl()
                edgeFired = true
                return
            }
            edgeResolved = true
        }
        // Drag/select only if: held long enough AND clearly more horizontal than vertical.
        // The 1.5x factor prevents an accidental horizontal wobble during a vertical
        // scroll from triggering drag/selection.
        let adx = abs(cur.x - sStartPx.x), ady = abs(cur.y - sStartPx.y)
        guard dragEnabled && adx > ady * 1.5 else { return }
        if !mousePressed {
            mousePressed = true
            testWindow?.send(.gesture("✊ Dragging…", .systemYellow))
            // Force the cursor to the touch start before grabbing, so the drag
            // grabs whatever is under the touchscreen point — not whatever the
            // cursor was previously over on another display.
            input.warpPointer(to: precisionPoint(sStartPx))
            postMouse(.mouseMoved, sStartPx)
            postMouse(.leftMouseDown, sStartPx)
        }
        testWindow?.send(.touch(normX: pNX, normY: pNY))
        postMouse(.leftMouseDragged, cur)
    }

    private func gestureUp() {
        guard fingerDown else { return }  // ignore spurious tip=0 after gesture already ended
        fingerDown = false; cancelLongTimer(); cancelDragTimer()
        let cur = clamp(screenPoint(CGPoint(x: pNX, y: pNY)))
        testWindow?.send(.lift)
        if precisionTouch.isArmed {
            handlePrecisionActions(precisionTouch.end())
            longFired = false
            return
        }
        _ = precisionTouch.cancel()
        if mousePressed { postMouse(.leftMouseUp, cur); mousePressed = false; return }
        if edgeFired || longFired || scrollMode { scrollMode = false; return }

        // Tap → click. Explicit clickState tells macOS + apps exactly what this is:
        // count=1 = single click, count=2 = double-click. This prevents macOS from
        // inferring a double-click from timing alone (which caused one tap to behave
        // like a double-click when two taps arrived within the 500ms system window).
        let time = now()
        var count = 1
        if time - lastTapTime < doubleTapInterval,
           hypot(cur.x - lastTapPx.x, cur.y - lastTapPx.y) < doubleTapDist {
            count = min(lastClickCount + 1, 3)
        }
        let label = count == 1 ? "👆 Tap" : count == 2 ? "👆👆 Double Tap" : "👆👆👆 Triple Tap"
        testWindow?.send(.gesture(label, .systemGreen))
        if config.debug { debugOut(String(format: "CLICK count=%d  t=%.3f", count, time)) }
        postClick(cur, .left, count)
        lastTapTime = time; lastTapPx = cur; lastClickCount = count
    }

    // MARK: Run loop

    // Check permissions silently — never pop a system dialog automatically.
    // Showing the dialog on every launch is intrusive; users grant once via
    // System Settings and the app remembers it. If not yet granted, print
    // clear instructions to stderr/log and let the run loop retry naturally.
    private func ensureAccessibility() {
        if AXIsProcessTrusted() { err("Accessibility: granted."); return }
        // Show system prompt — this fires after a fresh install/upgrade when
        // tccutil reset was run in the installer preflight.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        err("Accessibility: not granted — approve the prompt or enable in System Settings → Privacy & Security → Accessibility.")
    }

    private func ensureInputMonitoring() {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted:
            err("Input Monitoring: granted.")
        case kIOHIDAccessTypeDenied:
            err("Input Monitoring: denied — enable in System Settings → Privacy & Security → Input Monitoring.")
        default:
            // Unknown = fresh install or reset — show system banner once.
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            err("Input Monitoring: requested — approve in System Settings → Privacy & Security → Input Monitoring.")
        }
    }

    func run() {
        let app = NSApplication.shared
        ensureInputMonitoring()
        ensureAccessibility()
        if let resolvedBounds = resolveDisplay() {
            bounds = resolvedBounds
            err("Targeting display: origin=(\(Int(bounds.origin.x)),\(Int(bounds.origin.y))) size=\(Int(bounds.size.width))x\(Int(bounds.size.height))")
        } else {
            bounds = .zero
        }

        CGDisplayRegisterReconfigurationCallback({ _, _, ctx in
            guard let ctx = ctx else { return }
            let me = Unmanaged<TouchDriver>.fromOpaque(ctx).takeUnretainedValue()
            me.handlePrecisionActions(me.precisionTouch.cancel())
            me.bounds = me.resolveDisplay() ?? .zero
            me.healthSupervisor?.refresh()
        }, Unmanaged.passUnretained(self).toOpaque())

        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any]
        if let vid = config.vendorID, let pid = config.productID {
            match = [kIOHIDVendorIDKey as String: vid, kIOHIDProductIDKey as String: pid]
        } else {
            match = [kIOHIDDeviceUsagePageKey as String: 0x0D, kIOHIDDeviceUsageKey as String: 0x04]
        }
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)

        let r = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if r != kIOReturnSuccess {
            err("ERROR: IOHIDManagerOpen failed (0x\(String(r, radix: 16))).")
            err("--> Grant Input Monitoring under System Settings > Privacy & Security > Input Monitoring.")
            exit(1)
        }

        // Map elements from the matching device, and re-do it whenever the
        // touchscreen is (re)connected.
        if let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, let dev = set.first {
            setupElements(dev)
        } else {
            err("WARNING: no matching device to map elements from.")
        }
        let devCb: IOHIDDeviceCallback = { ctx, _, _, dev in
            guard let ctx = ctx else { return }
            let me = Unmanaged<TouchDriver>.fromOpaque(ctx).takeUnretainedValue()
            me.handlePrecisionActions(me.precisionTouch.cancel())
            me.rawContacts.removeAll()
            me.reportedContactCount = nil
            me.setupElements(dev)
        }
        IOHIDManagerRegisterDeviceMatchingCallback(manager, devCb, Unmanaged.passUnretained(self).toOpaque())
        let removeCb: IOHIDDeviceCallback = { ctx, _, _, _ in
            guard let ctx = ctx else { return }
            let me = Unmanaged<TouchDriver>.fromOpaque(ctx).takeUnretainedValue()
            me.rawContacts.removeAll()
            me.reportedContactCount = 0
            me.processContactFrame()
            // A single physical controller can expose more than one matching
            // HID service.  Do not mark the whole driver detached when one
            // service disappears; reconcile after IOKit has finished updating
            // the manager's device set and confirm the physical device is gone.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak me] in
                me?.reconcileHealth()
            }
        }
        IOHIDManagerRegisterDeviceRemovalCallback(manager, removeCb, Unmanaged.passUnretained(self).toOpaque())

        let cb: IOHIDValueCallback = { ctx, _, _, value in
            guard let ctx = ctx else { return }
            Unmanaged<TouchDriver>.fromOpaque(ctx).takeUnretainedValue().handle(value: value)
        }
        IOHIDManagerRegisterInputValueCallback(manager, cb, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

        installHealthSupervisor()

        // Handle SIGUSR1 — show the test window when signalled by a Finder launch.
        signal(SIGUSR1, SIG_IGN)
        let sigSrc = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        let driverRef = self
        sigSrc.setEventHandler { driverRef.showTestWindow() }
        sigSrc.resume()
        self.signalSource = sigSrc   // retain so it isn't deallocated

        err("Touch driver running. Press Ctrl+C to stop.")
        // Run through NSApplication so the reopen event (double-click in Finder
        // while already running) and signals are handled.
        let delegate = AppReopenDelegate(driver: self)
        app.delegate = delegate
        self.appDelegate = delegate   // retain
        app.setActivationPolicy(testWindow != nil ? .regular : .accessory)
        if testWindow != nil { app.activate(ignoringOtherApps: true) }
        app.run()
    }

    private func installHealthSupervisor() {
        let vendorID = config.vendorID ?? 0x0EEF
        let productID = config.productID ?? 0xC000
        let inspector = MacOSTouchEnvironmentInspector(
            vendorID: vendorID,
            productID: productID,
            targetProvider: { [config] in configuredDisplayTarget(config) },
            attachedProvider: { [weak self] in self?.driverAttached ?? false }
        )
        let menu = MenuBarHealthReporter()
        menu.onShowTester = { [weak self] in self?.showTestWindow() }
        installPrecisionLoupe(menu: menu)
        let reporter = CompositeTouchHealthReporter([
            menu,
            NotificationHealthReporter(),
            JSONLHealthReporter(),
        ])
        let supervisor = TouchHealthSupervisor(inspector: inspector, reporter: reporter)
        healthSupervisor = supervisor
        supervisor.refresh()

        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            self?.reconcileHealth()
        }
        RunLoop.main.add(timer, forMode: .common)
        healthWatchdog = timer
    }

    private func installPrecisionLoupe(menu: MenuBarHealthReporter) {
        menuBarReporter = menu
        captureAuthorization = screenSampler.authorization
        menu.updateLoupeAuthorization(captureAuthorization)
        menu.onEnablePrecisionLoupe = { [weak self] in
            self?.requestCapturePermissionIfNeeded(showExplanation: true, force: true)
        }
        menu.onRestartTouchutil = {
            NSApplication.shared.terminate(nil)
        }
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.handlePrecisionActions(self.precisionTouch.cancel())
            }
        }

        let promptKey = "precisionLoupe.permissionExplanationShown.v1"
        if captureAuthorization == .permissionRequired,
           !UserDefaults.standard.bool(forKey: promptKey) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.requestCapturePermissionIfNeeded(showExplanation: true)
            }
        }
    }

    private func requestCapturePermissionIfNeeded(showExplanation: Bool, force: Bool = false) {
        refreshPrecisionAuthorization()
        guard captureAuthorization != .authorized,
              captureAuthorization != .unsupported else { return }
        guard force || !requestedCapturePermissionThisRun else { return }

        let promptKey = "precisionLoupe.permissionExplanationShown.v1"
        if showExplanation && !UserDefaults.standard.bool(forKey: promptKey) {
            let alert = NSAlert()
            alert.messageText = "Enable the Precision Touch Loupe?"
            alert.informativeText = "touchutil needs Screen Recording permission to magnify the small area beneath your fingertip. Pixels stay on this Mac, are never saved, and capture runs only while the loupe is visible."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Enable Loupe")
            alert.addButton(withTitle: "Later")
            UserDefaults.standard.set(true, forKey: promptKey)
            NSApplication.shared.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        requestedCapturePermissionThisRun = true
        screenSampler.requestAuthorization { [weak self] authorization in
            guard let self else { return }
            self.captureAuthorization = authorization
            self.menuBarReporter?.updateLoupeAuthorization(authorization)
            if var state = self.currentLoupeState {
                state.authorization = authorization
                self.currentLoupeState = state
                self.precisionOverlay.update(state)
                if authorization == .authorized {
                    self.beginLoupeCapture(for: state)
                }
            }
        }
    }

    private func refreshPrecisionAuthorization() {
        let current = screenSampler.authorization
        guard current != captureAuthorization,
              captureAuthorization != .failed else { return }
        captureAuthorization = current
        menuBarReporter?.updateLoupeAuthorization(current)
        if var state = currentLoupeState {
            state.authorization = current
            currentLoupeState = state
            precisionOverlay.update(state)
            if current == .authorized {
                beginLoupeCapture(for: state)
            }
        }
    }

    private func reconcileHealth() {
        let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        if let device = devices.first {
            if !driverAttached { setupElements(device) }
        } else if !macOSTouchDevice(
            vendorID: config.vendorID ?? 0x0EEF,
            productID: config.productID ?? 0xC000
        ).present {
            driverAttached = false
        }
        refreshPrecisionAuthorization()
        healthSupervisor?.refresh()
    }

    /// Open the gesture test window (or bring it to front if already open).
    func showTestWindow() {
        if testWindow == nil {
            let overlay = TestWindow()
            overlay.displayOptions = buildDisplayOptions()
            overlay.touchHardwareName = touchDeviceName()
            overlay.onSelectDisplay = { [weak self] id in
                self?.selectDisplay(id)
            }
            overlay.open(on: boundsForTest())
            testWindow = overlay
        }
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        testWindow?.send(.gesture("👋 Gesture tester", .systemGreen))
    }

    /// Build the picker list from currently connected displays.
    private func buildDisplayOptions() -> [DisplayOption] {
        let mainID = CGMainDisplayID()
        let resolvedID = DisplayTargetResolver.resolve(
            target: configuredDisplayTarget(config),
            displays: macOSOnlineDisplays()
        )?.output.id
        return activeDisplays().enumerated().map { (i, d) in
            let b = CGDisplayBounds(d)
            let isMain = d == mainID
            let isCurrent = resolvedID == d
            // Index prefix distinguishes displays with identical names/resolutions.
            var label = "[\(i)] \(displayName(d))  ·  \(Int(b.width))×\(Int(b.height))"
            if isMain { label += "  (main)" }
            if isCurrent { label += "  ✓ current" }   // your saved touchscreen pick
            return DisplayOption(id: d, label: label, isCurrent: isCurrent)
        }
    }

    /// Save the chosen display and switch touch mapping to it immediately.
    private func selectDisplay(_ id: CGDirectDisplayID) {
        let v = CGDisplayVendorNumber(id), m = CGDisplayModelNumber(id)
        saveConfig(SavedConfig(displayVendor: v, displayModel: m, displayName: displayName(id)))
        bounds = CGDisplayBounds(id)
        err("Touchscreen display set via GUI: vendor=\(v) model=\(m).")
        healthSupervisor?.refresh()
    }
}

/// Handles the Finder "reopen" event (double-click the app while it's already
/// running as the LaunchAgent). macOS routes the open to the existing instance
/// instead of spawning a new process, so we show the test window here.
final class AppReopenDelegate: NSObject, NSApplicationDelegate {
    weak var driver: TouchDriver?
    init(driver: TouchDriver) { self.driver = driver }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        driver?.showTestWindow()
        return true
    }
}

// MARK: - Argument parsing

let version = "1.5.0-local"

func printUsage() {
    print("""
    touchutil — map a USB touchscreen to its display on macOS

    USAGE:
      touchutil [options]

    With no options it auto-detects the touchscreen display (or uses your saved
    --setup choice) and enables local touchscreen gestures.

    Single-finger gestures (work on any panel):
      • move              → cursor
      • tap               → click
      • double-tap        → double-click
      • hold (~0.5s)      → precision loupe; move + lift to click
      • stationary hold   → right-click on lift
      • vertical drag     → scroll up / down
      • horizontal drag   → drag / select text / move windows
      • edge swipe inward → left:prev Space  right:next Space
                            top:Mission Control  bottom:App Exposé

    Multi-finger gestures (on multi-contact HID panels):
      • two-finger move   → smooth horizontal / vertical scroll
      • two-finger pinch  → zoom in / out (Cmd-plus / Cmd-minus)
      • three+ swipe      → Spaces left/right, Mission Control, App Exposé

    OPTIONS:
      --no-gestures              Plain pointer only (no tap/long-press/edge gestures)
      --setup                    Interactively pick & remember the touchscreen display
      --list-displays            List displays, then exit
      --list-devices             List HID devices, then exit
      --inspect                  Show a touchscreen's HID capabilities, then exit
      --inspect-details          Show every HID element and Finger collection
      --doctor                   Explain current touch health and the next action
      --doctor-json              Print the same health snapshot as JSON
      --display-index N          Map touch to display at index N (remembered)
      --display-vendor V         Match target display by vendor number (remembered)
      --display-model M          Match target display by model number
      --vendor-id  0xVVVV        Match a specific touch device
      --product-id 0xPPPP        Match a specific touch device
      --test                     Open a gesture-feedback window on the touchscreen display
      --debug                    Log raw HID page/usage/value to stderr
      --debug-log                Log raw HID page/usage/value to /tmp/touchutil.debug.log
      --version                  Print version and exit
      -h, --help                 Show this help
    """)
}

func parseInt(_ s: String) -> Int? {
    if s.hasPrefix("0x") || s.hasPrefix("0X") { return Int(s.dropFirst(2), radix: 16) }
    return Int(s)
}

// If launched with no arguments (double-clicked from Finder):
// signal the running agent to show its test window and exit.
// The LaunchAgent always passes --agent so we can tell them apart.
let pidFile = "/tmp/touchutil.pid"
let selfPID = ProcessInfo.processInfo.processIdentifier
// --agent = started by LaunchAgent (background). No args = opened from Finder.
let isAgent = CommandLine.arguments.contains("--agent")
let launchedFromFinder = !isAgent && CommandLine.arguments.count == 1

func doctorSnapshot() -> TouchHealthSnapshot {
    if let current = JSONLHealthReporter.loadCurrent() { return current }
    let inspector = MacOSTouchEnvironmentInspector(
        vendorID: 0x0EEF,
        productID: 0xC000,
        targetProvider: { savedDisplayTarget() },
        attachedProvider: { false }
    )
    return TouchHealthMachine.snapshot(for: inspector.inspect())
}

if launchedFromFinder,
   let pidStr = try? String(contentsOfFile: pidFile, encoding: .utf8),
   let runningPID = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)),
   runningPID != selfPID,
   kill(runningPID, 0) == 0 {
    kill(runningPID, SIGUSR1)
    Thread.sleep(forTimeInterval: 0.3)
    exit(0)
}
// No running agent — Finder launch starts driver + test window automatically.

var config = Config()
if launchedFromFinder { config.test = true }   // show test window when opened from Finder
let args = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < args.count {
    let a = args[i]
    switch a {
    case "-h", "--help": printUsage(); exit(0)
    case "--version": print("touchutil \(version)"); exit(0)
    case "--setup": runSetup(); exit(0)
    case "--list-displays": listDisplays(); exit(0)
    case "--list-devices": listDevices(); exit(0)
    case "--inspect": inspectDevices(); exit(0)
    case "--inspect-details": inspectDeviceDetails(); exit(0)
    case "--doctor": printDoctor(doctorSnapshot(), json: false); exit(0)
    case "--doctor-json": printDoctor(doctorSnapshot(), json: true); exit(0)
    case "--no-gestures": config.gestures = false
    case "--display-index":
        i += 1
        guard i < args.count, let v = parseInt(args[i]) else { err("--display-index requires a value"); exit(2) }
        config.displayIndex = v
    case "--display-vendor":
        i += 1
        guard i < args.count, let v = parseInt(args[i]) else { err("--display-vendor requires a value"); exit(2) }
        config.displayVendor = UInt32(v)
    case "--display-model":
        i += 1
        guard i < args.count, let v = parseInt(args[i]) else { err("--display-model requires a value"); exit(2) }
        config.displayModel = UInt32(v)
    case "--vendor-id":
        i += 1
        guard i < args.count, let v = parseInt(args[i]) else { err("--vendor-id requires a value"); exit(2) }
        config.vendorID = v
    case "--product-id":
        i += 1
        guard i < args.count, let v = parseInt(args[i]) else { err("--product-id requires a value"); exit(2) }
        config.productID = v
    case "--agent": break   // passed by LaunchAgent — background mode, no UI on startup
    case "--test": config.test = true
    case "--debug": config.debug = true
    case "--debug-log":
        config.debug = true
        config.debugLog = true
        FileManager.default.createFile(atPath: debugLogURL.path, contents: nil)
        debugLogHandle = try? FileHandle(forWritingTo: debugLogURL)
        debugLogHandle?.seekToEndOfFile()
    default:
        err("Unknown option: \(a)"); printUsage(); exit(2)
    }
    i += 1
}

// Only a process that reaches the driver run loop owns the PID file. Read-only
// CLI commands such as --doctor must never overwrite the running agent's PID.
try? String(selfPID).write(toFile: pidFile, atomically: true, encoding: .utf8)

let driver = TouchDriver(config: config)

if config.test {
    let overlay = TestWindow()
    // Resolve display bounds early so the window opens on the right screen.
    let testBounds: CGRect = {
        var cfg = config; cfg.test = false
        // Use a temporary driver just for display resolution.
        return TouchDriver(config: cfg).boundsForTest()
    }()
    overlay.open(on: testBounds)
    driver.testWindow = overlay
}

driver.run()
