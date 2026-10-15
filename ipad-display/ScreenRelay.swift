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
        var orientedImage = ciImage.oriented(orientation)

        // Normalize origin so the image coordinates start at (0, 0)
        if orientedImage.extent.origin != .zero {
            orientedImage = orientedImage.transformed(by: CGAffineTransform(
                translationX: -orientedImage.extent.origin.x,
                y: -orientedImage.extent.origin.y
            ))
        }

        // Guarantee that the oriented image scales exactly to fill the destination drawable,
        // avoiding any 1/4 area or partial black screen issues if buffer dimensions differ.
        let targetWidth = metalLayer.drawableSize.width
        let targetHeight = metalLayer.drawableSize.height
        if orientedImage.extent.width > 0 && orientedImage.extent.height > 0 {
            let scaleX = targetWidth / orientedImage.extent.width
            let scaleY = targetHeight / orientedImage.extent.height
            if scaleX != 1.0 || scaleY != 1.0 {
                orientedImage = orientedImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            }
        }

        let destination = CIRenderDestination(
            width: Int(targetWidth),
            height: Int(targetHeight),
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

final class CursorGuard {
    private var monitor: Any?
    private let streamDisplayID: CGDirectDisplayID
    private let desktopDisplayID: CGDirectDisplayID

    init(streamDisplayID: CGDirectDisplayID, desktopDisplayID: CGDirectDisplayID) {
        self.streamDisplayID = streamDisplayID
        self.desktopDisplayID = desktopDisplayID

        self.monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        ) { [weak self] _ in
            self?.checkAndDeflect()
        }
    }

    private func checkAndDeflect() {
        let mouseLoc = NSEvent.mouseLocation
        guard let streamScreen = NSScreen.screens.first(where: {
            (($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0) == streamDisplayID
        }) else { return }

        if streamScreen.frame.contains(mouseLoc) {
            if let desktopScreen = NSScreen.screens.first(where: {
                (($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0) == desktopDisplayID
            }) {
                let targetX = min(max(mouseLoc.x, desktopScreen.frame.minX + 20), desktopScreen.frame.maxX - 20)
                let targetY = min(max(mouseLoc.y, desktopScreen.frame.minY + 20), desktopScreen.frame.maxY - 20)
                let primaryHeight = NSScreen.screens.first?.frame.height ?? 1000
                let cgPoint = CGPoint(x: targetX, y: primaryHeight - targetY)
                CGWarpMouseCursorPosition(cgPoint)
            }
        }
    }

    func stop() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }
}

@MainActor
final class ScreenRelay: NSObject, SCStreamDelegate {
    private var window: NSWindow?
    private var stream: SCStream?
    private var renderer: RelayRenderer?
    private var targetDisplayID: CGDirectDisplayID?
    private var cursorGuard: CursorGuard?
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
        do {
            _ = try await SCShareableContent.current
        } catch {
            if !CGPreflightScreenCaptureAccess() {
                CGRequestScreenCaptureAccess()
            }
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
        guard let scDisplay = await Self.findSCDisplay(for: sourceDisplayID) else {
            throw RelayError.sourceDisplayNotFound
        }

        // 5. Create a borderless window strictly for the target display.
        // Use .screenSaver level so that the window covers the target display's menu bar
        // and is never hidden when applications are minimized or "Show Desktop" is invoked.
        let window = NSWindow(
            contentRect: targetScreen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.setFrame(targetScreen.frame, display: true)
        window.level = .screenSaver
        window.canHide = false
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false

        let metalView = NSView(frame: window.contentView?.bounds ?? NSRect(origin: .zero, size: targetScreen.frame.size))
        metalView.autoresizingMask = [.width, .height]
        metalView.wantsLayer = true

        let metalLayer = CAMetalLayer()
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false
        metalLayer.contentsScale = targetScreen.backingScaleFactor
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.drawableSize = CGSize(width: width, height: height)
        metalLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        metalView.layer = metalLayer
        window.contentView = metalView

        self.window = window
        let renderer = RelayRenderer(metalLayer: metalLayer, ciContext: ciContext, orientation: orientation)
        self.renderer = renderer

        // Observe screen changes to handle resolution or display origin updates
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        do {
            let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
            let config = SCStreamConfiguration()

            // Query actual physical pixel dimensions from CGDisplayMode rather than
            // CGDisplayPixelsWide/High which return point dimensions on Retina/HiDPI displays.
            let sourceMode = CGDisplayCopyDisplayMode(sourceDisplayID)
            let sourcePixelWidth = (sourceMode?.pixelWidth ?? 0) > 0 ? sourceMode!.pixelWidth : height
            let sourcePixelHeight = (sourceMode?.pixelHeight ?? 0) > 0 ? sourceMode!.pixelHeight : width

            config.width = sourcePixelWidth
            config.height = sourcePixelHeight
            config.captureResolution = .best
            config.scalesToFit = false
            config.colorSpaceName = CGColorSpace.sRGB
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(refreshRate))
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = true
            config.queueDepth = 3

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(renderer, type: .screen, sampleHandlerQueue: renderQueue)
            try await stream.startCapture()
            self.stream = stream

            // Reveal window only after capture has started
            window.orderFrontRegardless()

            // Guard against cursor wandering into the relay display
            cursorGuard = CursorGuard(streamDisplayID: targetDisplayID, desktopDisplayID: sourceDisplayID)
        } catch {
            stop()
            throw error
        }
    }

    @objc private func screenParametersDidChange() {
        guard let window = self.window, let targetID = self.targetDisplayID else { return }
        Task { @MainActor in
            if let targetScreen = await Self.findScreen(for: targetID, timeout: 1.0) {
                window.setFrame(targetScreen.frame, display: true)
                window.orderFrontRegardless()
            } else {
                NSLog("[ScreenRelay] Target display %u is no longer present. Ordering out.", targetID)
                window.orderOut(nil)
            }
        }
    }

    func stop() {
        NotificationCenter.default.removeObserver(self, name: NSApplication.didChangeScreenParametersNotification, object: nil)
        cursorGuard?.stop()
        cursorGuard = nil
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

    private static func findSCDisplay(for displayID: CGDirectDisplayID, timeout: TimeInterval = 10.0) async -> SCDisplay? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let content = try? await SCShareableContent.current,
               let scDisplay = content.displays.first(where: { $0.displayID == displayID }) {
                return scDisplay
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return nil
    }

    private static func findScreen(for displayID: CGDirectDisplayID, timeout: TimeInterval = 10.0) async -> NSScreen? {
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
