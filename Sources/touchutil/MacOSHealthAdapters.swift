import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import IOKit.hid
import UserNotifications

func macOSOnlineDisplays() -> [TouchDisplayDescriptor] {
    var count: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetOnlineDisplayList(count, &ids, &count)

    var names: [CGDirectDisplayID: String] = [:]
    for screen in NSScreen.screens {
        if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
            names[id] = screen.localizedName.trimmingCharacters(in: .whitespaces)
        }
    }

    return ids.map { id in
        let bounds = CGDisplayBounds(id)
        let mirror = CGDisplayMirrorsDisplay(id)
        let fallbackName = CGDisplayIsBuiltin(id) != 0 ? "Built-in display" : "Unnamed display"
        return TouchDisplayDescriptor(
            id: id,
            name: names[id].flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName,
            vendor: CGDisplayVendorNumber(id),
            model: CGDisplayModelNumber(id),
            bounds: TouchDisplayBounds(
                x: Int(bounds.origin.x),
                y: Int(bounds.origin.y),
                width: Int(bounds.width),
                height: Int(bounds.height)
            ),
            isActive: CGDisplayIsActive(id) != 0,
            isMain: CGDisplayIsMain(id) != 0,
            isBuiltin: CGDisplayIsBuiltin(id) != 0,
            mirrorsDisplayID: mirror == kCGNullDirectDisplay ? nil : mirror
        )
    }
}

func macOSTouchDevice(vendorID: Int, productID: Int) -> (present: Bool, name: String?) {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(manager, [
        kIOHIDVendorIDKey as String: vendorID,
        kIOHIDProductIDKey as String: productID,
    ] as CFDictionary)
    let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
    guard result == kIOReturnSuccess,
          let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
          let device = devices.first else {
        return (false, nil)
    }
    let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String
    return (true, name)
}

func currentInputMonitoringState() -> TouchPermissionState {
    switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
    case kIOHIDAccessTypeGranted: return .granted
    case kIOHIDAccessTypeDenied: return .denied
    default: return .unknown
    }
}

final class MacOSTouchEnvironmentInspector: TouchEnvironmentInspecting {
    private let vendorID: Int
    private let productID: Int
    private let targetProvider: () -> SavedDisplayTarget?
    private let attachedProvider: () -> Bool

    init(
        vendorID: Int,
        productID: Int,
        targetProvider: @escaping () -> SavedDisplayTarget?,
        attachedProvider: @escaping () -> Bool
    ) {
        self.vendorID = vendorID
        self.productID = productID
        self.targetProvider = targetProvider
        self.attachedProvider = attachedProvider
    }

    func inspect() -> TouchEnvironmentObservation {
        let displays = macOSOnlineDisplays()
        let target = targetProvider()
        let resolved = DisplayTargetResolver.resolve(target: target, displays: displays)
        let physicalPresent: Bool
        if let target {
            physicalPresent = displays.contains {
                $0.vendor == target.vendor && $0.model == target.model
            }
        } else {
            physicalPresent = displays.contains { $0.isActive && !$0.isBuiltin }
        }
        let device = macOSTouchDevice(vendorID: vendorID, productID: productID)

        return TouchEnvironmentObservation(
            targetDisplayPresent: physicalPresent,
            targetDisplayName: resolved?.output.name ?? target?.name,
            targetBounds: resolved?.output.bounds,
            touchDevicePresent: device.present,
            touchDeviceName: device.name,
            inputMonitoring: currentInputMonitoringState(),
            accessibilityGranted: AXIsProcessTrusted(),
            mappingResolved: resolved != nil,
            driverAttached: attachedProvider()
        )
    }
}

final class CompositeTouchHealthReporter: TouchHealthReporting {
    private let reporters: [TouchHealthReporting]

    init(_ reporters: [TouchHealthReporting]) {
        self.reporters = reporters
    }

    func refresh(_ snapshot: TouchHealthSnapshot) {
        reporters.forEach { $0.refresh(snapshot) }
    }

    func report(_ transition: TouchHealthTransition) {
        reporters.forEach { $0.report(transition) }
    }
}

final class MenuBarHealthReporter: NSObject, TouchHealthReporting {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var latest: TouchHealthSnapshot?
    var onShowTester: (() -> Void)?

    override init() {
        super.init()
        if let button = statusItem.button {
            button.toolTip = "Touch health starting"
            setButton(state: .starting)
        }
        rebuildMenu()
    }

    func report(_ transition: TouchHealthTransition) {
        DispatchQueue.main.async { [weak self] in
            self?.latest = transition.current
            self?.setButton(state: transition.current.state)
            self?.rebuildMenu()
        }
    }

    private func setButton(state: TouchHealthState) {
        guard let button = statusItem.button else { return }
        let color: NSColor
        switch state {
        case .healthy: color = .systemGreen
        case .starting, .displayDisconnected: color = .systemYellow
        case .touchHardwareMissing, .permissionRequired, .mappingRequired, .driverDegraded:
            color = .systemRed
        }
        button.attributedTitle = NSAttributedString(
            string: "●",
            attributes: [
                .foregroundColor: color,
                .font: NSFont.systemFont(ofSize: 14, weight: .bold),
            ]
        )
        button.toolTip = latest?.title ?? "Touch health starting"
        button.setAccessibilityLabel(latest?.title ?? "Touch health starting")
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let title = NSMenuItem(title: latest?.title ?? "Touch health starting", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        if let latest {
            let detail = NSMenuItem(title: latest.detail, action: nil, keyEquivalent: "")
            detail.isEnabled = false
            menu.addItem(detail)
            let action = NSMenuItem(title: latest.recommendedAction, action: nil, keyEquivalent: "")
            action.isEnabled = false
            menu.addItem(action)
        }

        menu.addItem(.separator())
        let tester = NSMenuItem(title: "Open Touch Tester…", action: #selector(showTester), keyEquivalent: "t")
        tester.target = self
        menu.addItem(tester)

        let copy = NSMenuItem(title: "Copy Diagnostics", action: #selector(copyDiagnostics), keyEquivalent: "c")
        copy.target = self
        copy.isEnabled = latest != nil
        menu.addItem(copy)

        if latest?.state == .permissionRequired {
            let input = NSMenuItem(title: "Open Input Monitoring Settings", action: #selector(openInputMonitoring), keyEquivalent: "")
            input.target = self
            menu.addItem(input)
            let accessibility = NSMenuItem(title: "Open Accessibility Settings", action: #selector(openAccessibility), keyEquivalent: "")
            accessibility.target = self
            menu.addItem(accessibility)
        }

        statusItem.menu = menu
    }

    @objc private func showTester() { onShowTester?() }

    @objc private func copyDiagnostics() {
        guard let latest else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(formatDoctor(latest), forType: .string)
    }

    @objc private func openInputMonitoring() {
        openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    @objc private func openAccessibility() {
        openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private func openSystemSettings(_ value: String) {
        guard let url = URL(string: value) else { return }
        NSWorkspace.shared.open(url)
    }
}

final class NotificationHealthReporter: NSObject, TouchHealthReporting, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private var pending: DispatchWorkItem?
    private var latestState: TouchHealthState = .starting
    private var sentActionableAlert = false

    override init() {
        super.init()
        center.delegate = self
        center.getNotificationSettings { [weak self] settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            self?.center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    func report(_ transition: TouchHealthTransition) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.latestState = transition.current.state
            self.pending?.cancel()
            self.pending = nil

            if transition.current.state == .healthy {
                if self.sentActionableAlert {
                    self.send(
                        title: "ASUS touch restored",
                        body: transition.current.detail,
                        sound: false
                    )
                }
                self.sentActionableAlert = false
                return
            }
            guard transition.current.state.isActionable else { return }

            let expectedState = transition.current.state
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.latestState == expectedState else { return }
                self.send(
                    title: transition.current.title,
                    body: "\(transition.current.detail) \(transition.current.recommendedAction)",
                    sound: true
                )
                self.sentActionableAlert = true
            }
            self.pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        }
    }

    private func send(title: String, body: String, sound: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }
        center.add(UNNotificationRequest(
            identifier: "touchutil.health.\(UUID().uuidString)",
            content: content,
            trigger: nil
        ))
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

enum TouchHealthFiles {
    static var timelineURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/touchutil/health.jsonl")
    }

    static var currentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/touchutil/health.json")
    }
}

final class JSONLHealthReporter: TouchHealthReporting {
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let queue = DispatchQueue(label: "touchutil.health.timeline")
    private let maximumEntries: Int

    init(maximumEntries: Int = 200) {
        self.maximumEntries = maximumEntries
    }

    func refresh(_ snapshot: TouchHealthSnapshot) {
        queue.async { [encoder] in
            do {
                try FileManager.default.createDirectory(
                    at: TouchHealthFiles.currentURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let current = try encoder.encode(snapshot)
                try current.write(to: TouchHealthFiles.currentURL, options: .atomic)
            } catch {
                err("WARNING: could not refresh current touch health: \(error.localizedDescription)")
            }
        }
    }

    func report(_ transition: TouchHealthTransition) {
        queue.async { [encoder, maximumEntries] in
            let manager = FileManager.default
            do {
                try manager.createDirectory(
                    at: TouchHealthFiles.timelineURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let encoded = try encoder.encode(transition)
                var lines: [Data] = []
                if let existing = try? Data(contentsOf: TouchHealthFiles.timelineURL) {
                    lines = [UInt8](existing).split(separator: 0x0A).map { Data($0) }
                }
                lines.append(encoded)
                if lines.count > maximumEntries {
                    lines = Array(lines.suffix(maximumEntries))
                }
                var output = Data()
                for line in lines {
                    output.append(line)
                    output.append(0x0A)
                }
                try output.write(to: TouchHealthFiles.timelineURL, options: .atomic)
            } catch {
                err("WARNING: could not write touch health timeline: \(error.localizedDescription)")
            }
        }
    }

    static func loadCurrent(maximumAge: TimeInterval = 15) -> TouchHealthSnapshot? {
        guard let data = try? Data(contentsOf: TouchHealthFiles.currentURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(TouchHealthSnapshot.self, from: data),
              Date().timeIntervalSince(snapshot.observedAt) <= maximumAge else {
            return nil
        }
        return snapshot
    }
}

func formatDoctor(_ snapshot: TouchHealthSnapshot) -> String {
    let env = snapshot.environment
    let bounds = env.targetBounds.map { "\($0.width)x\($0.height) at (\($0.x),\($0.y))" } ?? "unresolved"
    return """
    Touch Health: \(snapshot.state.rawValue.uppercased())
    Status: \(snapshot.title)
    Display: \(env.targetDisplayPresent ? "connected" : "missing") — \(env.targetDisplayName ?? "unknown") — \(bounds)
    Touch USB: \(env.touchDevicePresent ? "connected" : "missing") — \(env.touchDeviceName ?? "eGalax 0EEF:C000")
    Input Monitoring: \(env.inputMonitoring.rawValue)
    Accessibility: \(env.accessibilityGranted ? "granted" : "denied")
    Mapping: \(env.mappingResolved ? "resolved" : "unresolved")
    Driver attachment: \(env.driverAttached ? "attached" : "not attached")
    Recommended action: \(snapshot.recommendedAction)
    Observed: \(ISO8601DateFormatter().string(from: snapshot.observedAt))
    """
}

func printDoctor(_ snapshot: TouchHealthSnapshot, json: Bool) {
    if json {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(snapshot), let value = String(data: data, encoding: .utf8) {
            print(value)
        }
    } else {
        print(formatDoctor(snapshot))
    }
}
