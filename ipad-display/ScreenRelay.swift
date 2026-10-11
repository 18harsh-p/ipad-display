// ScreenRelay.swift
//
// Relays frames from a portrait virtual display to a landscape stream display,
// rotating each frame 90 degrees in hardware via Metal and CoreImage.
// This allows Moonlight on iOS (which only streams in landscape) to display an
// upright portrait macOS desktop with zero black bars.

import AppKit
import CoreGraphics
import CoreImage
import Metal
import QuartzCore
import ScreenCaptureKit

enum RelayError: LocalizedError {
    case targetScreenNotFound
    case sourceDisplayNotFound
    case metalUnavailable

    var errorDescription: String? {
        switch self {
        case .targetScreenNotFound:
            return "Could not find the target relay screen in macOS."
        case .sourceDisplayNotFound:
            return "Could not find the source portrait display for capture."
        case .metalUnavailable:
            return "Metal hardware acceleration is not available on this Mac."
        }
    }
}

final class RelayRenderer: NSObject, SCStreamOutput, @unchecked Sendable {
    let metalLayer: CAMetalLayer
    let ciContext: CIContext
    let orientation: CGImagePropertyOrientation

    init(metalLayer: CAMetalLayer, ciContext: CIContext, orientation: CGImagePropertyOrientation) {
        self.metalLayer = metalLayer
        self.ciContext = ciContext
        self.orientation = orientation
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        render(pixelBuffer: imageBuffer)
    }

    private func render(pixelBuffer: CVPixelBuffer) {
        guard let drawable = metalLayer.nextDrawable() else { return }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let orientedImage = ciImage.oriented(orientation)

        let destination = CIRenderDestination(
            width: Int(metalLayer.drawableSize.width),
            height: Int(metalLayer.drawableSize.height),
            pixelFormat: metalLayer.pixelFormat,
            commandBuffer: nil
        ) { () -> MTLTexture in
            return drawable.texture
        }

        let task = try? ciContext.startTask(toRender: orientedImage, to: destination)
        _ = try? task?.waitUntilCompleted()
        drawable.present()
    }
}

@MainActor
final class ScreenRelay: NSObject, SCStreamDelegate {
    private var window: NSWindow?
    private var stream: SCStream?
    private var renderer: RelayRenderer?
    private var targetDisplayID: CGDirectDisplayID?
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let ciContext: CIContext
    private let renderQueue = DispatchQueue(label: "ipad-display.relay.render", qos: .userInteractive)

    static func create() throws -> ScreenRelay {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw RelayError.metalUnavailable
        }
        return ScreenRelay(device: device, commandQueue: commandQueue)
    }

    private init(device: MTLDevice, commandQueue: MTLCommandQueue) {
        self.device = device
        self.commandQueue = commandQueue
        self.ciContext = CIContext(mtlCommandQueue: commandQueue)
        super.init()
    }

    func start(
        sourceDisplayID: CGDirectDisplayID,
        targetDisplayID: CGDirectDisplayID,
        width: Int,
        height: Int,
        refreshRate: Int,
        orientation: CGImagePropertyOrientation
    ) async throws {
        // 1. Verify ScreenCaptureKit access BEFORE creating any window or views
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            throw DisplayError.screenRecordingPermissionRequired
        }

        // 2. Safety invariant: NEVER open relay window on the main screen!
        guard targetDisplayID != CGMainDisplayID() else {
            throw RelayError.targetScreenNotFound
        }

        // 3. Wait for AppKit to recognize the target display in NSScreen.screens
        guard let targetScreen = await Self.findScreen(for: targetDisplayID) else {
            throw RelayError.targetScreenNotFound
        }

        self.targetDisplayID = targetDisplayID

        // 4. Capture source portrait display
        let content = try await SCShareableContent.current
        guard let scDisplay = content.displays.first(where: { $0.displayID == sourceDisplayID }) else {
            throw RelayError.sourceDisplayNotFound
        }

        // 5. Create a borderless window strictly for the target display
        let window = NSWindow(
            contentRect: targetScreen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.setFrame(targetScreen.frame, display: true)
        window.level = .normal
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.ignoresMouseEvents = true
        window.isOpaque = false
        window.backgroundColor = .clear

        let metalView = NSView(frame: window.contentView?.bounds ?? targetScreen.frame)
        metalView.wantsLayer = true
        let metalLayer = CAMetalLayer()
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false
        metalLayer.drawableSize = CGSize(width: width, height: height)
        metalView.layer = metalLayer
        window.contentView = metalView

        self.window = window
        let renderer = RelayRenderer(metalLayer: metalLayer, ciContext: ciContext, orientation: orientation)
        self.renderer = renderer

        // Observe screen changes to immediately hide if display is detached or reconfigured
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        do {
            let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = scDisplay.width
            config.height = scDisplay.height
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(refreshRate))
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = true
            config.queueDepth = 3

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(renderer, type: .screen, sampleHandlerQueue: renderQueue)
            try await stream.startCapture()
            self.stream = stream

            // Reveal window only after capture has started
            window.orderFront(nil)
        } catch {
            stop()
            throw error
        }
    }

    @objc private func screenParametersDidChange() {
        guard let window = self.window, let targetID = self.targetDisplayID else { return }
        guard let currentScreen = window.screen,
              let num = currentScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              CGDirectDisplayID(num.uint32Value) == targetID else {
            NSLog("[ScreenRelay] Relay window is no longer on target display %u. Ordering out to protect main screen.", targetID)
            window.orderOut(nil)
            return
        }
    }

    func stop() {
        NotificationCenter.default.removeObserver(self, name: NSApplication.didChangeScreenParametersNotification, object: nil)
        if let stream = self.stream {
            Task {
                try? await stream.stopCapture()
            }
            self.stream = nil
        }
        window?.orderOut(nil)
        window?.close()
        window = nil
        renderer = nil
        targetDisplayID = nil
    }

    // MARK: - Helper

    private static func findScreen(for displayID: CGDirectDisplayID, timeout: TimeInterval = 4.0) async -> NSScreen? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let screen = NSScreen.screens.first(where: {
                guard let num = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
                return CGDirectDisplayID(num.uint32Value) == displayID
            }) {
                return screen
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return nil
    }
}
