// VirtualDisplayManager.swift
//
// Manages creation, configuration, and destruction of the private-API virtual display.
// Only ONE virtual display is created at any time, named "iPad Display".

import AppKit
import CoreGraphics
import Foundation

enum DisplayError: LocalizedError {
    case unavailable
    case didNotAppear
    case didNotDisappear
    case screenRecordingPermissionRequired

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Virtual display support is not available on this Mac."
        case .didNotAppear:
            return "The virtual display was created but macOS did not bring it online."
        case .didNotDisappear:
            return "macOS did not release the previous virtual display in time."
        case .screenRecordingPermissionRequired:
            return "Screen Recording permission is required. Please enable it in System Settings > Privacy & Security > Screen Recording, then restart ipad-display."
        }
    }
}

final class VirtualDisplayManager {
    private var desktopDisplay: IPDVirtualDisplay?

    /// ID of the single user-facing virtual display, or nil when none exists.
    private(set) var desktopDisplayID: CGDirectDisplayID?

    /// ID of the display captured by Sunshine (same as desktopDisplayID in single-display mode).
    var streamDisplayID: CGDirectDisplayID? {
        return desktopDisplayID
    }

    private static var generation: UInt32 = 0x1000

    /// Clean, monotonically incrementing serial number. Ensures each virtual display has a unique
    /// non-zero identity and product ID that WindowServer immediately recognizes and brings online.
    static func nextSerial() -> UInt32 {
        generation &+= 1
        return generation
    }

    /// Creates a single landscape display. Returns the display ID.
    func createLandscape(width: Int, height: Int, refreshRate: Int, hiDPI: Bool) async throws -> CGDirectDisplayID {
        guard IPDVirtualDisplay.isAvailable() else { throw DisplayError.unavailable }
        try await destroy()
        try? await Task.sleep(nanoseconds: 100_000_000)

        let serial = Self.nextSerial()
        let created = try IPDVirtualDisplay.make(
            name: "iPad Display",
            pixelWidth: UInt(width),
            pixelHeight: UInt(height),
            refreshRate: Double(refreshRate),
            hiDPI: hiDPI,
            serial: serial
        )

        let id = created.displayID
        NSLog("[VirtualDisplayManager] Created landscape display object, displayID = %u", id)
        desktopDisplay = created
        desktopDisplayID = id

        guard await Self.waitAsync(timeout: 15, until: { Self.isDisplayActive(id) }) else {
            NSLog("[VirtualDisplayManager] Timed out waiting for display ID: %u to appear", id)
            try? await destroy()
            throw DisplayError.didNotAppear
        }
        Self.configureDisplayMode(displayID: id, pixelWidth: width, pixelHeight: height, hiDPI: hiDPI)
        NSLog("[VirtualDisplayManager] Display ID %u is online and active", id)
        return id
    }

    /// Creates a single portrait display (e.g. 1536 x 2048). Returns the display ID.
    func createPortrait(
        landscapeWidth: Int,
        landscapeHeight: Int,
        refreshRate: Int,
        hiDPI: Bool
    ) async throws -> CGDirectDisplayID {
        guard IPDVirtualDisplay.isAvailable() else { throw DisplayError.unavailable }
        try await destroy()
        try? await Task.sleep(nanoseconds: 100_000_000)

        let serial = Self.nextSerial()
        let created = try IPDVirtualDisplay.make(
            name: "iPad Display",
            pixelWidth: UInt(landscapeHeight),
            pixelHeight: UInt(landscapeWidth),
            refreshRate: Double(refreshRate),
            hiDPI: hiDPI,
            serial: serial
        )
        let id = created.displayID
        NSLog("[VirtualDisplayManager] Created portrait display object, displayID = %u", id)
        desktopDisplay = created
        desktopDisplayID = id

        guard await Self.waitAsync(timeout: 15, until: { Self.isDisplayActive(id) }) else {
            NSLog("[VirtualDisplayManager] Timed out waiting for portrait display ID: %u to appear", id)
            try? await destroy()
            throw DisplayError.didNotAppear
        }

        Self.configureDisplayMode(displayID: id, pixelWidth: landscapeHeight, pixelHeight: landscapeWidth, hiDPI: hiDPI)
        NSLog("[VirtualDisplayManager] Portrait display ID %u is online and active", id)
        return id
    }

    /// Removes the virtual display (if any) and waits briefly. Safe to call repeatedly.
    func destroy() async throws {
        guard let id = desktopDisplayID, id != 0 else { return }

        NSLog("[VirtualDisplayManager] destroy() called for ID: %u", id)
        desktopDisplay?.destroy()
        desktopDisplay = nil
        desktopDisplayID = nil

        // Brief yield to let WindowServer unregister the display
        try? await Task.sleep(nanoseconds: 250_000_000)
        NSLog("[VirtualDisplayManager] destroy() completed.")
    }

    /// Synchronous version for app termination.
    func destroySync() {
        guard let id = desktopDisplayID, id != 0 else { return }
        NSLog("[VirtualDisplayManager] destroySync() called for ID: %u", id)
        desktopDisplay?.destroy()
        desktopDisplay = nil
        desktopDisplayID = nil
    }

    /// Sets the desktop resolution and HiDPI scaling mode via CoreGraphics.
    private static func configureDisplayMode(displayID: CGDirectDisplayID, pixelWidth: Int, pixelHeight: Int, hiDPI: Bool) {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else {
            NSLog("[VirtualDisplayManager] Could not get modes for display %u", displayID)
            return
        }

        let targetPointsW = hiDPI ? pixelWidth / 2 : pixelWidth
        let targetPointsH = hiDPI ? pixelHeight / 2 : pixelHeight

        var bestMode: CGDisplayMode?
        for mode in modes {
            let pw = mode.pixelWidth
            let ph = mode.pixelHeight
            let w = mode.width
            let h = mode.height

            if pw == pixelWidth && ph == pixelHeight {
                if hiDPI && (w == targetPointsW && h == targetPointsH) {
                    bestMode = mode
                    break
                } else if !hiDPI && (w == pixelWidth && h == pixelHeight) {
                    bestMode = mode
                    break
                } else if bestMode == nil {
                    bestMode = mode
                }
            }
        }

        guard let chosen = bestMode else {
            NSLog("[VirtualDisplayManager] No matching mode for display %u (target %dx%d, hiDPI: %d)",
                  displayID, pixelWidth, pixelHeight, hiDPI ? 1 : 0)
            return
        }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let cfg = config else {
            NSLog("[VirtualDisplayManager] CGBeginDisplayConfiguration failed for display %u", displayID)
            return
        }

        let setErr = CGConfigureDisplayWithDisplayMode(cfg, displayID, chosen, nil)
        if setErr != .success {
            NSLog("[VirtualDisplayManager] CGConfigureDisplayWithDisplayMode failed: %d", setErr.rawValue)
            CGCancelDisplayConfiguration(cfg)
            return
        }

        let completeErr = CGCompleteDisplayConfiguration(cfg, .forSession)
        if completeErr != .success {
            NSLog("[VirtualDisplayManager] CGCompleteDisplayConfiguration failed: %d", completeErr.rawValue)
        } else {
            NSLog("[VirtualDisplayManager] Successfully committed mode for display %u: %dx%d (pt: %dx%d, flags: 0x%x)",
                  displayID, chosen.pixelWidth, chosen.pixelHeight, chosen.width, chosen.height, chosen.ioFlags)
        }
    }

    /// Checks whether the display is reported as active by macOS.
    private static func isDisplayActive(_ id: CGDirectDisplayID) -> Bool {
        return CGDisplayIsActive(id) == 1
    }

    private static func waitAsync(timeout: TimeInterval, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }
}
