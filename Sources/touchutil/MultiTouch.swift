import CoreGraphics
import Foundation

struct TouchContact: Equatable {
    let key: Int
    let normalizedPoint: CGPoint
}

enum TouchNavigation: Equatable {
    case previousSpace
    case nextSpace
    case missionControl
    case appExpose
}

enum MultiTouchAction: Equatable {
    case began
    case scroll(deltaX: Double, deltaY: Double)
    case zoom(steps: Int)
    case navigate(TouchNavigation)
    case ended
}

/// Turns frames of absolute touchscreen contacts into gestures macOS can
/// receive through public CGEvent APIs. It deliberately does not emulate a
/// native trackpad: scroll, zoom shortcuts, and navigation shortcuts are the
/// portable userspace boundary available without a DriverKit extension.
struct MultiTouchInterpreter {
    private enum Mode {
        case undecided
        case scroll
        case zoom
        case navigation
    }

    private(set) var suppressSingleFinger = false
    private var previousCount = 0
    private var gestureClass = 0
    private var mode: Mode = .undecided
    private var startCentroid = CGPoint.zero
    private var previousCentroid = CGPoint.zero
    private var startDistance = 0.0
    private var previousDistance = 0.0
    private var zoomAccumulator = 0.0
    private var navigationFired = false

    private let scrollStartThreshold = 8.0
    private let zoomStartThreshold = 0.04       // about a 4% pinch
    private let zoomStepThreshold = 0.07        // about 7% per Cmd+/Cmd-
    private let navigationThreshold = 80.0

    mutating func process(_ contacts: [TouchContact], displaySize: CGSize) -> [MultiTouchAction] {
        let sorted = contacts.sorted { $0.key < $1.key }
        let count = sorted.count

        guard count >= 2 else {
            var actions: [MultiTouchAction] = []
            if previousCount >= 2 {
                actions.append(.ended)
                suppressSingleFinger = true
            }
            if count == 0 { suppressSingleFinger = false }
            previousCount = count
            return actions
        }

        suppressSingleFinger = true
        let currentClass = count == 2 ? 2 : 3
        let points = sorted.map {
            CGPoint(x: $0.normalizedPoint.x * displaySize.width,
                    y: $0.normalizedPoint.y * displaySize.height)
        }
        let centroid = points.reduce(CGPoint.zero) {
            CGPoint(x: $0.x + $1.x / CGFloat(points.count),
                    y: $0.y + $1.y / CGFloat(points.count))
        }
        let distance = currentClass == 2 ? hypot(points[0].x - points[1].x, points[0].y - points[1].y) : 0

        if previousCount < 2 || gestureClass != currentClass {
            gestureClass = currentClass
            mode = currentClass == 2 ? .undecided : .navigation
            startCentroid = centroid
            previousCentroid = centroid
            startDistance = max(distance, 1)
            previousDistance = max(distance, 1)
            zoomAccumulator = 0
            navigationFired = false
            previousCount = count
            return [.began]
        }

        defer {
            previousCentroid = centroid
            previousDistance = max(distance, 1)
            previousCount = count
        }

        if currentClass >= 3 {
            guard !navigationFired else { return [] }
            let dx = centroid.x - startCentroid.x
            let dy = centroid.y - startCentroid.y
            guard hypot(dx, dy) >= navigationThreshold else { return [] }
            navigationFired = true
            if abs(dx) > abs(dy) {
                // Trackpad-style direction: fingers moving left reveal the
                // Space to the right, and vice versa.
                return [.navigate(dx < 0 ? .nextSpace : .previousSpace)]
            }
            return [.navigate(dy < 0 ? .missionControl : .appExpose)]
        }

        let totalCentroidMovement = hypot(centroid.x - startCentroid.x, centroid.y - startCentroid.y)
        let totalScale = log(max(distance, 1) / startDistance)
        if mode == .undecided {
            let pinchMovement = abs(totalScale) * 180
            if abs(totalScale) >= zoomStartThreshold && pinchMovement > totalCentroidMovement {
                mode = .zoom
            } else if totalCentroidMovement >= scrollStartThreshold {
                mode = .scroll
            } else {
                return []
            }
        }

        switch mode {
        case .scroll:
            return [.scroll(deltaX: Double(centroid.x - previousCentroid.x),
                            deltaY: Double(centroid.y - previousCentroid.y))]
        case .zoom:
            zoomAccumulator += log(max(distance, 1) / previousDistance)
            let steps = Int(zoomAccumulator / zoomStepThreshold)
            guard steps != 0 else { return [] }
            zoomAccumulator -= Double(steps) * zoomStepThreshold
            return [.zoom(steps: steps)]
        case .undecided, .navigation:
            return []
        }
    }
}
