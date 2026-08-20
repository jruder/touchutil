import XCTest
@testable import touchutil

final class PrecisionTouchTests: XCTestCase {
    private let bounds = PrecisionRect(x: 0, y: 0, width: 1920, height: 1080)
    private let start = PrecisionPoint(x: 500, y: 400)

    func testQuickTouchNeverArmsOrCommitsPrecisionAction() {
        var subject = PrecisionGestureInterpreter()
        subject.begin(at: start)

        XCTAssertFalse(subject.isArmed)
        XCTAssertEqual(subject.end(), [])
        XCTAssertFalse(subject.isArmed)
    }

    func testHoldArmsLoupeAtOriginalTarget() {
        var subject = PrecisionGestureInterpreter()
        subject.begin(at: start)

        XCTAssertEqual(subject.arm(), [.armed(finger: start, target: start)])
        XCTAssertTrue(subject.isArmed)
    }

    func testHoldAndMoveUsesCoarsePrecisionGainThenCommitsLeftClick() {
        var subject = PrecisionGestureInterpreter()
        subject.begin(at: start)
        _ = subject.arm()

        let finger = PrecisionPoint(x: 600, y: 450)
        let target = PrecisionPoint(x: 565, y: 432.5)
        XCTAssertEqual(
            subject.move(to: finger, within: bounds),
            [.moved(finger: finger, target: target)]
        )
        XCTAssertEqual(subject.end(), [.commitLeft(target)])
    }

    func testStationaryHoldPreservesRightClickAtOriginalPoint() {
        var subject = PrecisionGestureInterpreter(precisionMovementThreshold: 6)
        subject.begin(at: start)
        _ = subject.arm()

        _ = subject.move(to: PrecisionPoint(x: 503, y: 402), within: bounds)
        XCTAssertEqual(subject.end(), [.commitRight(start)])
    }

    func testSecondContactCancellationNeverCommitsClick() {
        var subject = PrecisionGestureInterpreter()
        subject.begin(at: start)
        _ = subject.arm()

        XCTAssertEqual(subject.cancel(), [.cancelled])
        XCTAssertFalse(subject.isArmed)
        XCTAssertEqual(subject.end(), [])
    }

    func testPrecisionTargetClampsToDisplayBounds() {
        var subject = PrecisionGestureInterpreter(precisionGain: 1)
        let edge = PrecisionPoint(x: 1918, y: 1078)
        subject.begin(at: edge)
        _ = subject.arm()

        let finger = PrecisionPoint(x: 2200, y: 1400)
        XCTAssertEqual(
            subject.move(to: finger, within: bounds),
            [.moved(finger: finger, target: PrecisionPoint(x: 1919, y: 1079))]
        )
    }

    func testCaptureSourceRectStaysInsideDisplayAtEveryEdge() {
        let topLeft = ScreenRegionRequest(
            displayID: 1,
            displayBounds: bounds,
            target: PrecisionPoint(x: 0, y: 0),
            sourceSize: 64,
            outputSize: 344
        )
        XCTAssertEqual(topLeft.sourceRect, PrecisionRect(x: 0, y: 0, width: 64, height: 64))

        let bottomRight = ScreenRegionRequest(
            displayID: 1,
            displayBounds: bounds,
            target: PrecisionPoint(x: 1919, y: 1079),
            sourceSize: 64,
            outputSize: 344
        )
        XCTAssertEqual(
            bottomRight.sourceRect,
            PrecisionRect(x: 1856, y: 1016, width: 64, height: 64)
        )
    }
}
