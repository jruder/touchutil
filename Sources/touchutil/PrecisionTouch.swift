import Foundation

struct PrecisionPoint: Codable, Equatable {
    var x: Double
    var y: Double

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
    }

    static func - (lhs: Self, rhs: Self) -> Self {
        Self(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
    }

    static func * (lhs: Self, rhs: Double) -> Self {
        Self(x: lhs.x * rhs, y: lhs.y * rhs)
    }
}

struct PrecisionRect: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    func clamped(_ point: PrecisionPoint) -> PrecisionPoint {
        PrecisionPoint(
            x: min(max(point.x, x), x + max(0, width - 1)),
            y: min(max(point.y, y), y + max(0, height - 1))
        )
    }
}

enum ScreenCaptureAuthorization: String, Codable, Equatable {
    case authorized
    case permissionRequired
    case restartRequired
    case unsupported
    case failed
}

struct ScreenRegionRequest: Equatable {
    var displayID: UInt32
    var displayBounds: PrecisionRect
    var target: PrecisionPoint
    var sourceSize: Double
    var outputSize: Int

    var sourceRect: PrecisionRect {
        let localX = target.x - displayBounds.x
        let localY = target.y - displayBounds.y
        let half = sourceSize / 2
        return PrecisionRect(
            x: min(max(localX - half, 0), max(0, displayBounds.width - sourceSize)),
            y: min(max(localY - half, 0), max(0, displayBounds.height - sourceSize)),
            width: min(sourceSize, displayBounds.width),
            height: min(sourceSize, displayBounds.height)
        )
    }
}

struct SampledScreenFrame: Equatable {
    var width: Int
    var height: Int
    var bytesPerRow: Int
    var bgraBytes: Data
}

struct PrecisionLoupeState: Equatable {
    var displayID: UInt32
    var displayBounds: PrecisionRect
    var finger: PrecisionPoint
    var target: PrecisionPoint
    var authorization: ScreenCaptureAuthorization
    var diameter: Double = 172
    var magnification: Double = 2.2
}

enum PrecisionGestureAction: Equatable {
    case armed(finger: PrecisionPoint, target: PrecisionPoint)
    case moved(finger: PrecisionPoint, target: PrecisionPoint)
    case commitLeft(PrecisionPoint)
    case commitRight(PrecisionPoint)
    case cancelled
}

protocol PrecisionGestureInterpreting {
    var isArmed: Bool { get }
    mutating func begin(at point: PrecisionPoint)
    mutating func arm() -> [PrecisionGestureAction]
    mutating func move(to point: PrecisionPoint, within bounds: PrecisionRect) -> [PrecisionGestureAction]
    mutating func end() -> [PrecisionGestureAction]
    mutating func cancel() -> [PrecisionGestureAction]
}

struct PrecisionGestureInterpreter: PrecisionGestureInterpreting {
    private enum Phase {
        case idle
        case tracking(start: PrecisionPoint, current: PrecisionPoint)
        case armed(
            startFinger: PrecisionPoint,
            previousFinger: PrecisionPoint,
            currentFinger: PrecisionPoint,
            target: PrecisionPoint,
            moved: Bool
        )
    }

    private var phase: Phase = .idle
    private let precisionGain: Double
    private let precisionMovementThreshold: Double

    init(precisionGain: Double = 0.65, precisionMovementThreshold: Double = 6) {
        self.precisionGain = precisionGain
        self.precisionMovementThreshold = precisionMovementThreshold
    }

    var isArmed: Bool {
        if case .armed = phase { return true }
        return false
    }

    mutating func begin(at point: PrecisionPoint) {
        phase = .tracking(start: point, current: point)
    }

    mutating func arm() -> [PrecisionGestureAction] {
        guard case let .tracking(start, current) = phase else { return [] }
        phase = .armed(
            startFinger: start,
            previousFinger: current,
            currentFinger: current,
            target: start,
            moved: false
        )
        return [.armed(finger: current, target: start)]
    }

    mutating func move(to point: PrecisionPoint, within bounds: PrecisionRect) -> [PrecisionGestureAction] {
        switch phase {
        case .idle:
            return []
        case let .tracking(start, _):
            phase = .tracking(start: start, current: point)
            return []
        case let .armed(startFinger, previousFinger, _, target, moved):
            let delta = point - previousFinger
            let nextTarget = bounds.clamped(target + delta * precisionGain)
            let distance = hypot(point.x - startFinger.x, point.y - startFinger.y)
            phase = .armed(
                startFinger: startFinger,
                previousFinger: point,
                currentFinger: point,
                target: nextTarget,
                moved: moved || distance >= precisionMovementThreshold
            )
            return [.moved(finger: point, target: nextTarget)]
        }
    }

    mutating func end() -> [PrecisionGestureAction] {
        defer { phase = .idle }
        guard case let .armed(startFinger, _, _, target, moved) = phase else { return [] }
        return [moved ? .commitLeft(target) : .commitRight(startFinger)]
    }

    mutating func cancel() -> [PrecisionGestureAction] {
        defer { phase = .idle }
        guard case .armed = phase else { return [] }
        return [.cancelled]
    }
}

protocol ScreenRegionSampling: AnyObject {
    var authorization: ScreenCaptureAuthorization { get }
    func requestAuthorization(_ completion: @escaping (ScreenCaptureAuthorization) -> Void)
    func start(
        _ request: ScreenRegionRequest,
        onFrame: @escaping (SampledScreenFrame) -> Void,
        onFailure: @escaping (String) -> Void
    )
    func update(_ request: ScreenRegionRequest)
    func stop()
}

final class NoOpScreenRegionSampler: ScreenRegionSampling {
    var authorization: ScreenCaptureAuthorization { .unsupported }
    func requestAuthorization(_ completion: @escaping (ScreenCaptureAuthorization) -> Void) {
        completion(.unsupported)
    }
    func start(
        _ request: ScreenRegionRequest,
        onFrame: @escaping (SampledScreenFrame) -> Void,
        onFailure: @escaping (String) -> Void
    ) {
        onFailure("Live screen sampling is unavailable on this version of macOS.")
    }
    func update(_ request: ScreenRegionRequest) {}
    func stop() {}
}

protocol PrecisionOverlayPresenting: AnyObject {
    func show(_ state: PrecisionLoupeState)
    func update(_ state: PrecisionLoupeState)
    func showFrame(_ frame: SampledScreenFrame)
    func dismiss()
}

final class NoOpPrecisionOverlay: PrecisionOverlayPresenting {
    func show(_ state: PrecisionLoupeState) {}
    func update(_ state: PrecisionLoupeState) {}
    func showFrame(_ frame: SampledScreenFrame) {}
    func dismiss() {}
}

enum InputPointerButton: Equatable {
    case left
    case right
}

enum InputPointerPhase: Equatable {
    case moved
    case down
    case dragged
    case up
}

protocol InputDelivering: AnyObject {
    func warpPointer(to point: PrecisionPoint)
    func pointer(_ phase: InputPointerPhase, at point: PrecisionPoint, button: InputPointerButton)
    func click(at point: PrecisionPoint, button: InputPointerButton, count: Int)
    func scroll(deltaX: Double, deltaY: Double)
    func zoom(steps: Int)
    func navigate(_ direction: TouchNavigation)
    func missionControl()
}
