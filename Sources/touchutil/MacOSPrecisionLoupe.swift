import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

final class CoreGraphicsInputDeliverer: InputDelivering {
    private let source = CGEventSource(stateID: .hidSystemState)
    private let scrollScale: Double

    init(scrollScale: Double = 3) {
        self.scrollScale = scrollScale
    }

    func warpPointer(to point: PrecisionPoint) {
        CGWarpMouseCursorPosition(CGPoint(x: point.x, y: point.y))
    }

    func pointer(_ phase: InputPointerPhase, at point: PrecisionPoint, button: InputPointerButton) {
        let mouseButton: CGMouseButton = button == .right ? .right : .left
        let type: CGEventType
        switch (phase, button) {
        case (.moved, _): type = .mouseMoved
        case (.down, .left): type = .leftMouseDown
        case (.down, .right): type = .rightMouseDown
        case (.dragged, .left): type = .leftMouseDragged
        case (.dragged, .right): type = .rightMouseDragged
        case (.up, .left): type = .leftMouseUp
        case (.up, .right): type = .rightMouseUp
        }
        CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: CGPoint(x: point.x, y: point.y),
            mouseButton: mouseButton
        )?.post(tap: .cgAnnotatedSessionEventTap)
    }

    func click(at point: PrecisionPoint, button: InputPointerButton, count: Int) {
        let mouseButton: CGMouseButton = button == .right ? .right : .left
        let down: CGEventType = button == .right ? .rightMouseDown : .leftMouseDown
        let up: CGEventType = button == .right ? .rightMouseUp : .leftMouseUp
        let tap = clickEventTap(button: mouseButton, count: count)
        let cgPoint = CGPoint(x: point.x, y: point.y)

        if let event = CGEvent(
            mouseEventSource: source,
            mouseType: down,
            mouseCursorPosition: cgPoint,
            mouseButton: mouseButton
        ) {
            event.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, count)))
            event.post(tap: tap)
        }
        if let event = CGEvent(
            mouseEventSource: source,
            mouseType: up,
            mouseCursorPosition: cgPoint,
            mouseButton: mouseButton
        ) {
            event.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, count)))
            event.post(tap: tap)
        }
    }

    func scroll(deltaX: Double, deltaY: Double) {
        let x = Int32((deltaX * scrollScale).rounded())
        let y = Int32((deltaY * scrollScale).rounded())
        guard x != 0 || y != 0 else { return }
        CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 2,
            wheel1: y,
            wheel2: x,
            wheel3: 0
        )?.post(tap: .cghidEventTap)
    }

    func zoom(steps: Int) {
        let bounded = max(-4, min(4, steps))
        guard bounded != 0 else { return }
        let key: CGKeyCode = bounded > 0 ? 0x18 : 0x1B
        for _ in 0..<abs(bounded) {
            postKey(key, flags: .maskCommand)
        }
    }

    func navigate(_ direction: TouchNavigation) {
        switch direction {
        case .previousSpace: postKey(0x7B, flags: .maskControl)
        case .nextSpace: postKey(0x7C, flags: .maskControl)
        case .missionControl: postKey(0x7E, flags: .maskControl)
        case .appExpose: postKey(0x7D, flags: .maskControl)
        }
    }

    func missionControl() {
        let down = CGEvent(keyboardEventSource: source, virtualKey: 160, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 160, keyDown: false)
        if down == nil {
            postKey(0x7E, flags: .maskControl)
        } else {
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }

    private func postKey(_ key: CGKeyCode, flags: CGEventFlags = []) {
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

func makeScreenRegionSampler() -> ScreenRegionSampling {
    if #available(macOS 12.3, *) {
        return ScreenCaptureKitRegionSampler()
    }
    return NoOpScreenRegionSampler()
}

@available(macOS 12.3, *)
final class ScreenCaptureKitRegionSampler: NSObject, ScreenRegionSampling {
    private let outputQueue = DispatchQueue(label: "touchutil.precision.capture", qos: .userInteractive)
    private var stream: SCStream?
    private var request: ScreenRegionRequest?
    private var pendingRequest: ScreenRegionRequest?
    private var updateInFlight = false
    private var onFrame: ((SampledScreenFrame) -> Void)?
    private var onFailure: ((String) -> Void)?

    var authorization: ScreenCaptureAuthorization {
        CGPreflightScreenCaptureAccess() ? .authorized : .permissionRequired
    }

    func requestAuthorization(_ completion: @escaping (ScreenCaptureAuthorization) -> Void) {
        DispatchQueue.main.async {
            let granted = CGRequestScreenCaptureAccess()
            let state: ScreenCaptureAuthorization
            if CGPreflightScreenCaptureAccess() {
                state = .authorized
            } else if granted {
                state = .restartRequired
            } else {
                state = .permissionRequired
            }
            completion(state)
        }
    }

    func start(
        _ request: ScreenRegionRequest,
        onFrame: @escaping (SampledScreenFrame) -> Void,
        onFailure: @escaping (String) -> Void
    ) {
        stop()
        self.request = request
        self.onFrame = onFrame
        self.onFailure = onFailure

        guard authorization == .authorized else {
            onFailure("Screen Recording permission is required for live magnification.")
            return
        }

        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            guard let self else { return }
            if let error {
                self.fail("Unable to inspect shareable displays: \(error.localizedDescription)")
                return
            }
            guard let content,
                  let display = content.displays.first(where: { $0.displayID == request.displayID }) else {
                self.fail("The configured touchscreen display is unavailable to ScreenCaptureKit.")
                return
            }

            let ownApplications = content.applications.filter {
                $0.bundleIdentifier == Bundle.main.bundleIdentifier
            }
            let filter = SCContentFilter(
                display: display,
                excludingApplications: ownApplications,
                exceptingWindows: []
            )
            let configuration = self.configuration(for: request)
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            do {
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.outputQueue)
            } catch {
                self.fail("Unable to attach the loupe capture output: \(error.localizedDescription)")
                return
            }
            self.stream = stream
            stream.startCapture { [weak self] error in
                if let error {
                    self?.fail("Unable to start the touch loupe: \(error.localizedDescription)")
                }
            }
        }
    }

    func update(_ request: ScreenRegionRequest) {
        self.request = request
        pendingRequest = request
        applyPendingUpdate()
    }

    func stop() {
        pendingRequest = nil
        updateInFlight = false
        onFrame = nil
        onFailure = nil
        let current = stream
        stream = nil
        current?.stopCapture(completionHandler: nil)
    }

    private func configuration(for request: ScreenRegionRequest) -> SCStreamConfiguration {
        let source = request.sourceRect
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = CGRect(
            x: source.x,
            y: source.y,
            width: source.width,
            height: source.height
        )
        configuration.width = request.outputSize
        configuration.height = request.outputSize
        configuration.scalesToFit = true
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 2
        configuration.showsCursor = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        if #available(macOS 13.0, *) {
            configuration.capturesAudio = false
        }
        return configuration
    }

    private func applyPendingUpdate() {
        guard !updateInFlight, let stream, let next = pendingRequest else { return }
        pendingRequest = nil
        updateInFlight = true
        stream.updateConfiguration(configuration(for: next)) { [weak self] error in
            guard let self else { return }
            self.updateInFlight = false
            if let error {
                self.fail("Unable to move the touch loupe capture: \(error.localizedDescription)")
            }
            if self.pendingRequest != nil {
                self.applyPendingUpdate()
            }
        }
    }

    private func fail(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onFailure?(message)
        }
    }
}

@available(macOS 12.3, *)
extension ScreenCaptureKitRegionSampler: SCStreamOutput, SCStreamDelegate {
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              sampleBuffer.isValid,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bytes = Data(bytes: base, count: bytesPerRow * height)
        let frame = SampledScreenFrame(
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            bgraBytes: bytes
        )
        DispatchQueue.main.async { [weak self] in
            self?.onFrame?(frame)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fail("Touch loupe capture stopped: \(error.localizedDescription)")
    }
}

final class AppKitPrecisionOverlay: PrecisionOverlayPresenting {
    private let view = PrecisionLoupeView(frame: .zero)
    private var panel: NSPanel?
    private var latest: PrecisionLoupeState?

    func show(_ state: PrecisionLoupeState) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.latest = state
            self.ensurePanel(diameter: CGFloat(state.diameter))
            self.view.authorization = state.authorization
            self.view.frameImage = nil
            self.view.needsDisplay = true
            self.positionPanel(for: state)
            self.panel?.orderFrontRegardless()
        }
    }

    func update(_ state: PrecisionLoupeState) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.latest = state
            self.view.authorization = state.authorization
            self.view.needsDisplay = true
            self.positionPanel(for: state)
        }
    }

    func showFrame(_ frame: SampledScreenFrame) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.view.frameImage = Self.image(from: frame)
            self.view.needsDisplay = true
        }
    }

    func dismiss() {
        DispatchQueue.main.async { [weak self] in
            self?.panel?.orderOut(nil)
            self?.view.frameImage = nil
            self?.latest = nil
        }
    }

    private func ensurePanel(diameter: CGFloat) {
        let size = NSSize(width: diameter, height: diameter)
        if let panel, panel.frame.size == size { return }
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        view.frame = NSRect(origin: .zero, size: size)
        panel.contentView = view
        self.panel = panel
    }

    private func positionPanel(for state: PrecisionLoupeState) {
        guard let panel,
              let screen = NSScreen.screens.first(where: { screen in
                  (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
                      == state.displayID
              }) else { return }

        let cgBounds = CGDisplayBounds(state.displayID)
        func cocoaPoint(_ point: PrecisionPoint) -> NSPoint {
            NSPoint(
                x: screen.frame.minX + point.x - cgBounds.minX,
                y: screen.frame.maxY - (point.y - cgBounds.minY)
            )
        }

        let diameter = CGFloat(state.diameter)
        let finger = cocoaPoint(state.finger)
        var center = NSPoint(x: finger.x, y: finger.y + diameter * 0.82)
        if center.y + diameter / 2 > screen.frame.maxY - 8 {
            center.y = finger.y - diameter * 0.82
        }
        center.x = min(max(center.x, screen.frame.minX + diameter / 2 + 8),
                       screen.frame.maxX - diameter / 2 - 8)
        center.y = min(max(center.y, screen.frame.minY + diameter / 2 + 8),
                       screen.frame.maxY - diameter / 2 - 8)
        panel.setFrameOrigin(NSPoint(x: center.x - diameter / 2, y: center.y - diameter / 2))
    }

    private static func image(from frame: SampledScreenFrame) -> CGImage? {
        guard let provider = CGDataProvider(data: frame.bgraBytes as CFData) else { return nil }
        let bitmap = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        )
        return CGImage(
            width: frame.width,
            height: frame.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: frame.bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmap,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}

private final class PrecisionLoupeView: NSView {
    var frameImage: CGImage?
    var authorization: ScreenCaptureAuthorization = .permissionRequired

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let circle = bounds.insetBy(dx: 5, dy: 5)

        context.saveGState()
        context.addEllipse(in: circle)
        context.clip()
        context.setFillColor(NSColor(white: 0.08, alpha: 0.96).cgColor)
        context.fill(circle)
        if let frameImage {
            context.interpolationQuality = .high
            context.draw(frameImage, in: circle)
        }
        context.restoreGState()

        if frameImage == nil {
            let message: String
            switch authorization {
            case .authorized: message = "Starting loupe…"
            case .permissionRequired: message = "Allow Screen Recording\nfor live magnification"
            case .restartRequired: message = "Restart touchutil\nto enable magnification"
            case .unsupported: message = "Precision mode"
            case .failed: message = "Capture unavailable"
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let text = NSAttributedString(
                string: message,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: NSColor.white,
                    .paragraphStyle: paragraph,
                ]
            )
            let size = text.boundingRect(
                with: NSSize(width: circle.width - 24, height: circle.height),
                options: [.usesLineFragmentOrigin]
            ).size
            text.draw(in: NSRect(
                x: circle.midX - size.width / 2,
                y: circle.midY - size.height / 2,
                width: size.width,
                height: size.height
            ))
        }

        context.setStrokeColor(NSColor.white.withAlphaComponent(0.92).cgColor)
        context.setLineWidth(3)
        context.strokeEllipse(in: circle)
        context.setStrokeColor(NSColor.systemBlue.cgColor)
        context.setLineWidth(1.5)
        context.move(to: CGPoint(x: circle.midX - 13, y: circle.midY))
        context.addLine(to: CGPoint(x: circle.midX + 13, y: circle.midY))
        context.move(to: CGPoint(x: circle.midX, y: circle.midY - 13))
        context.addLine(to: CGPoint(x: circle.midX, y: circle.midY + 13))
        context.strokePath()
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fillEllipse(in: NSRect(x: circle.midX - 2.5, y: circle.midY - 2.5, width: 5, height: 5))
    }
}
