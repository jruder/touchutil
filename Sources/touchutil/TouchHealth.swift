import Foundation

enum TouchPermissionState: String, Codable, Equatable {
    case granted
    case denied
    case unknown
}

struct TouchDisplayBounds: Codable, Equatable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int
}

struct TouchDisplayDescriptor: Codable, Equatable {
    var id: UInt32
    var name: String
    var vendor: UInt32
    var model: UInt32
    var bounds: TouchDisplayBounds
    var isActive: Bool
    var isMain: Bool
    var isBuiltin: Bool
    var mirrorsDisplayID: UInt32?
}

struct SavedDisplayTarget: Codable, Equatable {
    var vendor: UInt32
    var model: UInt32
    var name: String?
}

struct ResolvedTouchDisplay: Codable, Equatable {
    var physical: TouchDisplayDescriptor
    var output: TouchDisplayDescriptor
}

enum DisplayTargetResolver {
    static func resolve(
        target: SavedDisplayTarget?,
        displays: [TouchDisplayDescriptor]
    ) -> ResolvedTouchDisplay? {
        guard let target else { return nil }

        var matches = displays.filter {
            $0.vendor == target.vendor && $0.model == target.model
        }
        if let name = target.name, !name.isEmpty {
            let named = matches.filter { $0.name == name }
            if !named.isEmpty { matches = named }
        }

        guard !matches.isEmpty else { return nil }
        let physical: TouchDisplayDescriptor
        if matches.count == 1 {
            physical = matches[0]
        } else if let active = matches.first(where: { $0.isActive }) {
            physical = active
        } else {
            // Multiple inactive physical matches are ambiguous. Never guess and
            // silently route touch to an unrelated display.
            return nil
        }

        if physical.isActive {
            return ResolvedTouchDisplay(physical: physical, output: physical)
        }
        guard let mirrorID = physical.mirrorsDisplayID,
              let mirror = displays.first(where: { $0.id == mirrorID && $0.isActive }) else {
            return nil
        }
        return ResolvedTouchDisplay(physical: physical, output: mirror)
    }
}

struct TouchEnvironmentObservation: Codable, Equatable {
    var targetDisplayPresent: Bool
    var targetDisplayName: String?
    var targetBounds: TouchDisplayBounds?
    var touchDevicePresent: Bool
    var touchDeviceName: String?
    var inputMonitoring: TouchPermissionState
    var accessibilityGranted: Bool
    var mappingResolved: Bool
    var driverAttached: Bool
}

enum TouchHealthState: String, Codable, Equatable {
    case starting
    case healthy
    case displayDisconnected
    case touchHardwareMissing
    case permissionRequired
    case mappingRequired
    case driverDegraded

    var isActionable: Bool {
        switch self {
        case .touchHardwareMissing, .permissionRequired, .mappingRequired, .driverDegraded:
            return true
        case .starting, .healthy, .displayDisconnected:
            return false
        }
    }
}

struct TouchHealthSnapshot: Codable, Equatable {
    var state: TouchHealthState
    var observedAt: Date
    var title: String
    var detail: String
    var recommendedAction: String
    var environment: TouchEnvironmentObservation
}

struct TouchHealthTransition: Codable, Equatable {
    var previousState: TouchHealthState?
    var current: TouchHealthSnapshot
}

protocol TouchEnvironmentInspecting {
    func inspect() -> TouchEnvironmentObservation
}

protocol TouchHealthReporting: AnyObject {
    func refresh(_ snapshot: TouchHealthSnapshot)
    func report(_ transition: TouchHealthTransition)
}

extension TouchHealthReporting {
    func refresh(_ snapshot: TouchHealthSnapshot) {}
}

final class NoOpTouchHealthReporter: TouchHealthReporting {
    func report(_ transition: TouchHealthTransition) {}
}

final class StaticTouchEnvironmentInspector: TouchEnvironmentInspecting {
    var observation: TouchEnvironmentObservation

    init(_ observation: TouchEnvironmentObservation) {
        self.observation = observation
    }

    func inspect() -> TouchEnvironmentObservation { observation }
}

struct TouchHealthMachine {
    private(set) var current: TouchHealthSnapshot?

    static func snapshot(
        for environment: TouchEnvironmentObservation,
        at date: Date = Date()
    ) -> TouchHealthSnapshot {
        let state: TouchHealthState
        let title: String
        let detail: String
        let action: String

        if !environment.targetDisplayPresent {
            state = .displayDisconnected
            title = "Touch display disconnected"
            detail = "The configured touchscreen display is not currently online."
            action = "Reconnect or power on the configured touchscreen display."
        } else if !environment.touchDevicePresent {
            state = .touchHardwareMissing
            title = "ASUS touch USB is missing"
            detail = "The display is online, but macOS cannot see the eGalax touch controller."
            action = "Reseat or rotate the USB-C connector at the ASUS end."
        } else if environment.inputMonitoring != .granted || !environment.accessibilityGranted {
            state = .permissionRequired
            title = "Touch permission required"
            if environment.inputMonitoring != .granted && !environment.accessibilityGranted {
                detail = "Input Monitoring and Accessibility are not both granted."
                action = "Enable touchutil in Input Monitoring and Accessibility."
            } else if environment.inputMonitoring != .granted {
                detail = "Input Monitoring is not granted to touchutil."
                action = "Enable touchutil in Privacy & Security → Input Monitoring."
            } else {
                detail = "Accessibility is not granted to touchutil."
                action = "Enable touchutil in Privacy & Security → Accessibility."
            }
        } else if !environment.mappingResolved {
            state = .mappingRequired
            title = "Touch display mapping required"
            detail = "The touch controller is present, but its saved physical display cannot be resolved safely."
            action = "Open the touch tester and select the ASUS touchscreen display."
        } else if !environment.driverAttached {
            state = .driverDegraded
            title = "Touch driver is reconnecting"
            detail = "The controller is present, but the input driver has not attached its HID elements."
            action = "Wait for one automatic retry; if it remains red, open diagnostics."
        } else {
            state = .healthy
            title = "ASUS touch ready"
            let device = environment.touchDeviceName ?? "eGalax touch controller"
            let display = environment.targetDisplayName ?? "configured display"
            detail = "\(device) is attached and mapped to \(display)."
            action = "No action needed."
        }

        return TouchHealthSnapshot(
            state: state,
            observedAt: date,
            title: title,
            detail: detail,
            recommendedAction: action,
            environment: environment
        )
    }

    mutating func observe(
        _ environment: TouchEnvironmentObservation,
        at date: Date = Date()
    ) -> TouchHealthTransition? {
        let next = Self.snapshot(for: environment, at: date)
        let previous = current
        current = next

        guard previous?.state != next.state || previous?.environment != next.environment else {
            return nil
        }
        return TouchHealthTransition(previousState: previous?.state, current: next)
    }
}

final class TouchHealthSupervisor {
    private let inspector: TouchEnvironmentInspecting
    private let reporter: TouchHealthReporting
    private var machine = TouchHealthMachine()

    init(inspector: TouchEnvironmentInspecting, reporter: TouchHealthReporting) {
        self.inspector = inspector
        self.reporter = reporter
    }

    @discardableResult
    func refresh(at date: Date = Date()) -> TouchHealthSnapshot {
        let observation = inspector.inspect()
        if let transition = machine.observe(observation, at: date) {
            reporter.report(transition)
            reporter.refresh(transition.current)
            return transition.current
        }
        let snapshot = machine.current ?? TouchHealthMachine.snapshot(for: observation, at: date)
        reporter.refresh(snapshot)
        return snapshot
    }
}
