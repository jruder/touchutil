import XCTest
@testable import touchutil

final class TouchHealthTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func observation(
        display: Bool = true,
        touch: Bool = true,
        input: TouchPermissionState = .granted,
        accessibility: Bool = true,
        mapping: Bool = true,
        attached: Bool = true
    ) -> TouchEnvironmentObservation {
        TouchEnvironmentObservation(
            targetDisplayPresent: display,
            targetDisplayName: display ? "ASUS MB16AMT" : nil,
            targetBounds: mapping ? TouchDisplayBounds(x: 0, y: 0, width: 1920, height: 1080) : nil,
            touchDevicePresent: touch,
            touchDeviceName: touch ? "eGalaxTouch EXC3200" : nil,
            inputMonitoring: input,
            accessibilityGranted: accessibility,
            mappingResolved: mapping,
            driverAttached: attached
        )
    }

    func testHealthyRequiresEveryPrerequisite() {
        let snapshot = TouchHealthMachine.snapshot(for: observation(), at: now)
        XCTAssertEqual(snapshot.state, .healthy)
        XCTAssertEqual(snapshot.recommendedAction, "No action needed.")
    }

    func testDisplayDisconnectedHasPriorityWhenTargetIsOffline() {
        let snapshot = TouchHealthMachine.snapshot(
            for: observation(display: false, touch: false, mapping: false, attached: false),
            at: now
        )
        XCTAssertEqual(snapshot.state, .displayDisconnected)
        XCTAssertFalse(snapshot.state.isActionable)
    }

    func testMissingTouchHardwareProducesConnectorAction() {
        let snapshot = TouchHealthMachine.snapshot(
            for: observation(touch: false, attached: false),
            at: now
        )
        XCTAssertEqual(snapshot.state, .touchHardwareMissing)
        XCTAssertTrue(snapshot.recommendedAction.contains("rotate"))
    }

    func testPermissionStateNamesMissingPermission() {
        let input = TouchHealthMachine.snapshot(
            for: observation(input: .denied),
            at: now
        )
        XCTAssertEqual(input.state, .permissionRequired)
        XCTAssertTrue(input.recommendedAction.contains("Input Monitoring"))

        let accessibility = TouchHealthMachine.snapshot(
            for: observation(accessibility: false),
            at: now
        )
        XCTAssertEqual(accessibility.state, .permissionRequired)
        XCTAssertTrue(accessibility.recommendedAction.contains("Accessibility"))
    }

    func testMappingFailureNeverReportsHealthy() {
        let snapshot = TouchHealthMachine.snapshot(
            for: observation(mapping: false),
            at: now
        )
        XCTAssertEqual(snapshot.state, .mappingRequired)
    }

    func testPresentDeviceWithoutAttachmentIsDegraded() {
        let snapshot = TouchHealthMachine.snapshot(
            for: observation(attached: false),
            at: now
        )
        XCTAssertEqual(snapshot.state, .driverDegraded)
    }

    func testMirroredPhysicalDisplayResolvesToActiveMaster() {
        let physical = display(
            id: 10,
            name: "Built-in display",
            vendor: 1552,
            model: 41028,
            active: false,
            mirror: 20
        )
        let asus = display(
            id: 20,
            name: "ASUS MB16AMT",
            vendor: 1715,
            model: 5729,
            active: true
        )
        let lg = display(
            id: 30,
            name: "LG ULTRAFINE",
            vendor: 7789,
            model: 23499,
            active: true
        )

        let result = DisplayTargetResolver.resolve(
            target: SavedDisplayTarget(vendor: 1552, model: 41028, name: nil),
            displays: [physical, asus, lg]
        )
        XCTAssertEqual(result?.physical.id, 10)
        XCTAssertEqual(result?.output.id, 20)
        XCTAssertNotEqual(result?.output.id, 30)
    }

    func testMissingSavedDisplayDoesNotFallBackToLargestExternal() {
        let lg = display(
            id: 30,
            name: "LG ULTRAFINE",
            vendor: 7789,
            model: 23499,
            active: true
        )
        let result = DisplayTargetResolver.resolve(
            target: SavedDisplayTarget(vendor: 1715, model: 5729, name: "ASUS MB16AMT"),
            displays: [lg]
        )
        XCTAssertNil(result)
    }

    func testSupervisorReportsOnlyMaterialChanges() {
        let inspector = StaticTouchEnvironmentInspector(observation())
        let reporter = RecordingTouchHealthReporter()
        let supervisor = TouchHealthSupervisor(inspector: inspector, reporter: reporter)

        supervisor.refresh(at: now)
        supervisor.refresh(at: now.addingTimeInterval(5))
        XCTAssertEqual(reporter.transitions.count, 1)
        XCTAssertEqual(reporter.refreshes.count, 2)

        inspector.observation = observation(touch: false, attached: false)
        supervisor.refresh(at: now.addingTimeInterval(10))
        XCTAssertEqual(reporter.transitions.map(\.current.state), [.healthy, .touchHardwareMissing])
        XCTAssertEqual(reporter.refreshes.count, 3)
    }

    private func display(
        id: UInt32,
        name: String,
        vendor: UInt32,
        model: UInt32,
        active: Bool,
        mirror: UInt32? = nil
    ) -> TouchDisplayDescriptor {
        TouchDisplayDescriptor(
            id: id,
            name: name,
            vendor: vendor,
            model: model,
            bounds: TouchDisplayBounds(x: 0, y: 0, width: 1920, height: 1080),
            isActive: active,
            isMain: false,
            isBuiltin: false,
            mirrorsDisplayID: mirror
        )
    }
}

private final class RecordingTouchHealthReporter: TouchHealthReporting {
    var transitions: [TouchHealthTransition] = []
    var refreshes: [TouchHealthSnapshot] = []

    func refresh(_ snapshot: TouchHealthSnapshot) {
        refreshes.append(snapshot)
    }

    func report(_ transition: TouchHealthTransition) {
        transitions.append(transition)
    }
}
