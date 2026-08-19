import CoreGraphics
import XCTest
@testable import touchutil

final class MultiTouchInterpreterTests: XCTestCase {
    private let size = CGSize(width: 1920, height: 1080)

    private func contacts(_ points: [CGPoint]) -> [TouchContact] {
        points.enumerated().map { TouchContact(key: $0.offset, normalizedPoint: $0.element) }
    }

    func testClicksUseHIDEventTap() {
        XCTAssertEqual(clickEventTap(button: .left, count: 1), .cghidEventTap)
        XCTAssertEqual(clickEventTap(button: .left, count: 2), .cghidEventTap)
        XCTAssertEqual(clickEventTap(button: .right, count: 1), .cghidEventTap)
    }

    func testTwoFingerParallelMovementScrolls() {
        var subject = MultiTouchInterpreter()
        XCTAssertEqual(subject.process(contacts([CGPoint(x: 0.3, y: 0.3), CGPoint(x: 0.5, y: 0.3)]), displaySize: size), [.began])
        let actions = subject.process(contacts([CGPoint(x: 0.3, y: 0.35), CGPoint(x: 0.5, y: 0.35)]), displaySize: size)
        guard case let .scroll(deltaX, deltaY) = actions.first else { return XCTFail("expected scroll") }
        XCTAssertEqual(deltaX, 0, accuracy: 0.01)
        XCTAssertGreaterThan(deltaY, 50)
    }

    func testTwoFingerPinchProducesZoomSteps() {
        var subject = MultiTouchInterpreter()
        _ = subject.process(contacts([CGPoint(x: 0.4, y: 0.5), CGPoint(x: 0.6, y: 0.5)]), displaySize: size)
        let actions = subject.process(contacts([CGPoint(x: 0.35, y: 0.5), CGPoint(x: 0.65, y: 0.5)]), displaySize: size)
        guard case let .zoom(steps) = actions.first else { return XCTFail("expected zoom") }
        XCTAssertGreaterThan(steps, 0)
    }

    func testThreeFingerHorizontalSwipeNavigatesOnce() {
        var subject = MultiTouchInterpreter()
        _ = subject.process(contacts([CGPoint(x: 0.4, y: 0.4), CGPoint(x: 0.5, y: 0.4), CGPoint(x: 0.6, y: 0.4)]), displaySize: size)
        let moved = contacts([CGPoint(x: 0.3, y: 0.4), CGPoint(x: 0.4, y: 0.4), CGPoint(x: 0.5, y: 0.4)])
        XCTAssertEqual(subject.process(moved, displaySize: size), [.navigate(.nextSpace)])
        XCTAssertEqual(subject.process(moved, displaySize: size), [])
    }

    func testSingleFingerIsSuppressedUntilAllContactsLift() {
        var subject = MultiTouchInterpreter()
        _ = subject.process(contacts([CGPoint(x: 0.4, y: 0.4), CGPoint(x: 0.6, y: 0.4)]), displaySize: size)
        XCTAssertEqual(subject.process(contacts([CGPoint(x: 0.4, y: 0.4)]), displaySize: size), [.ended])
        XCTAssertTrue(subject.suppressSingleFinger)
        _ = subject.process([], displaySize: size)
        XCTAssertFalse(subject.suppressSingleFinger)
    }
}
