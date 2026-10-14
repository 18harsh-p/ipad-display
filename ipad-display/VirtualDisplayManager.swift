// VirtualDisplayManager.swift
//
// Owns the virtual display(s). Create and destroy are blocking calls meant to run on the
// backend's queue, never on the main thread.
//
// In Landscape: creates one virtual display matching the iPad's aspect ratio.
// In Portrait: creates two virtual displays:
//   1. A portrait display (desktop) for the macOS user to interact with.
//   2. A landscape display (stream) that receives the hardware-rotated frames for Moonlight.

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
            return "This version of macOS no longer provides virtual displays to apps."
        case .didNotAppear:
            return "The virtual display was created but macOS did not bring it online."
        case .didNotDisappear:
            return "The old virtual display did not go away. Quit and reopen the app."
        case .screenRecordingPermissionRequired:
            return "Screen Recording permission is required so ipad-display and Sunshine can capture the display for Moonlight. Please enable it in System Settings > Privacy & Security > Screen Recording for both ipad-display and Sunshine."
        }
    }
}

final class VirtualDisplayManager {
    private var desktopDisplay: IPDVirtualDisplay?
    private var relayDisplay: IPDVirtualDisplay?

    /// ID of the user-facing desktop display, or nil when none exists.
    private(set) var desktopDisplayID: CGDirectDisplayID?

    /// ID of the stream display captured by Sunshine, or nil when none exists.
    private(set) var streamDisplayID: CGDirectDisplayID?

    private static var generation: UInt32 = 0

    /// Combines display characteristics with an incrementing generation counter so WindowServer
    /// never confuses a newly created display with an old one that was recently torn down.
    static func serial(width: Int, height: Int, refreshRate: Int, hiDPI: Bool) -> UInt32 {
        generation &+= 1
        let gen = generation & 0xFF
        let w = UInt32(min(max(width, 1), 4095))
        let h = UInt32(min(max(height, 1), 4095))
        let rate: UInt32 = refreshRate >= 60 ? 1 : 0
        let dpi: UInt32 = hiDPI ? 1 : 0
        return (gen << 24) | (dpi << 23) | (rate << 22) | ((h & 0x7FF) << 11) | (w & 0x7FF)
    }

    /// Creates a single landscape display. Returns the display ID.
    func createLandscape(width: Int, height: Int, refreshRate: Int, hiDPI: Bool) async throws -> CGDirectDisplayID {
        guard IPDVirtualDisplay.isAvailable() else { throw DisplayError.unavailable }
        try await destroy()
        try? await Task.sleep(nanoseconds: 100_000_000)

        let serial = Self.serial(width: width, height: height, refreshRate: refreshRate, hiDPI: hiDPI)
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
        streamDisplayID = id

        guard await Self.waitAsync(timeout: 15, until: { Self.isDisplayActive(id) }) else {
            NSLog("[VirtualDisplayManager] Timed out waiting for display ID: %u to appear", id)
            try? await destroy()
            throw DisplayError.didNotAppear
        }
        Self.configureDisplayMode(displayID: id, pixelWidth: width, pixelHeight: height, hiDPI: hiDPI)
        NSLog("[VirtualDisplayManager] Display ID %u is online and active", id)
        return id
    }

    /// Creates a portrait desktop display (for macOS) and a landscape stream display (for Moonlight).
    func createPortrait(
        landscapeWidth: Int,
        landscapeHeight: Int,
        refreshRate: Int,
        hiDPI: Bool
    ) async throws -> (desktopID: CGDirectDisplayID, streamID: CGDirectDisplayID) {
        guard IPDVirtualDisplay.isAvailable() else { throw DisplayError.unavailable }
        try await destroy()
        try? await Task.sleep(nanoseconds: 100_000_000)

        // 1. User's portrait desktop (e.g. 1536 x 2048)
        let desktopSerial = Self.serial(width: landscapeHeight, height: landscapeWidth, refreshRate: refreshRate, hiDPI: hiDPI)
        let desktop = try IPDVirtualDisplay.make(
            name: "iPad Desktop",
            pixelWidth: UInt(landscapeHeight),
            pixelHeight: UInt(landscapeWidth),
            refreshRate: Double(refreshRate),
            hiDPI: hiDPI,
            serial: desktopSerial
        )
        let dID = desktop.displayID
        desktopDisplay = desktop
        desktopDisplayID = dID

        // 2. Stream display for Moonlight (e.g. 2048 x 1536, 1x)
        let streamSerial = Self.serial(width: landscapeWidth, height: landscapeHeight, refreshRate: refreshRate, hiDPI: false) ^ 0x00F00000
        let relay = try IPDVirtualDisplay.make(
            name: "iPad Stream",
            pixelWidth: UInt(landscapeWidth),
            pixelHeight: UInt(landscapeHeight),
            refreshRate: Double(refreshRate),
            hiDPI: false,
            serial: streamSerial
        )
        let sID = relay.displayID
        relayDisplay = relay
        streamDisplayID = sID

        guard await Self.waitAsync(timeout: 15, until: { Self.isDisplayActive(dID) && Self.isDisplayActive(sID) }) else {
            try? await destroy()
            throw DisplayError.didNotAppear
        }

        Self.configureDisplayMode(displayID: dID, pixelWidth: landscapeHeight, pixelHeight: landscapeWidth, hiDPI: hiDPI)
        Self.configureDisplayMode(displayID: sID, pixelWidth: landscapeWidth, pixelHeight: landscapeHeight, hiDPI: false)

        return (desktopID: dID, streamID: sID)
    }

    /// Removes all virtual displays (if any) and waits until macOS no longer lists them. Safe to call twice.
    func destroy() async throws {
        let oldIDs = Set([desktopDisplayID, streamDisplayID].compactMap { $0 }.filter { $0 != 0 })
        guard !oldIDs.isEmpty else { return }

        NSLog("[VirtualDisplayManager] destroy() called for IDs: %@", oldIDs.map(String.init).joined(separator: ", "))
        desktopDisplay?.destroy()
        desktopDisplay = nil
        if let relay = relayDisplay {
            relay.destroy()
            try? await Task.sleep(nanoseconds: 50_000_000)
            relayDisplay = nil
        }
        desktopDisplayID = nil
        streamDisplayID = nil

        let disappeared = await Self.waitAsync(timeout: 10, until: { oldIDs.allSatisfy { !Self.isDisplayPresent($0) } })
        if !disappeared {
            let lingering = oldIDs.filter { Self.isDisplayPresent($0) }
            NSLog("[VirtualDisplayManager] destroy() timed out. Still present IDs: %@", lingering.map(String.init).joined(separator: ", "))
            throw DisplayError.didNotDisappear
        }
        NSLog("[VirtualDisplayManager] destroy() completed. All old IDs are gone.")
    }

    /// Synchronous version for app termination.
    func destroySync() {
        let oldIDs = Set([desktopDisplayID, streamDisplayID].compactMap { $0 }.filter { $0 != 0 })
        guard !oldIDs.isEmpty else { return }

        NSLog("[VirtualDisplayManager] destroySync() called for IDs: %@", oldIDs.map(String.init).joined(separator: ", "))
        desktopDisplay?.destroy()
        desktopDisplay = nil
        if let relay = relayDisplay {
            relay.destroy()
            Thread.sleep(forTimeInterval: 0.05)
            relayDisplay = nil
        }
        desktopDisplayID = nil
        streamDisplayID = nil

        _ = Self.waitSync(timeout: 3, until: { oldIDs.allSatisfy { !Self.isDisplayPresent($0) } })
    }

    // MARK: - Helpers

    /// Configures the display mode to ensure the requested resolution and HiDPI scaling are active.
    static func configureDisplayMode(displayID: CGDirectDisplayID, pixelWidth: Int, pixelHeight: Int, hiDPI: Bool) {
        let targetPointWidth = hiDPI ? pixelWidth / 2 : pixelWidth
        let targetPointHeight = hiDPI ? pixelHeight / 2 : pixelHeight

        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else {
            NSLog("[VirtualDisplayManager] Could not get modes for display %u", displayID)
            return
        }

        // 1. Look for the exact mode matching pixel dimensions and target point dimensions
        for mode in modes {
            if mode.pixelWidth == pixelWidth && mode.pixelHeight == pixelHeight &&
               mode.width == targetPointWidth && mode.height == targetPointHeight {
                NSLog("[VirtualDisplayManager] Setting display %u mode to %dx%d (pt: %dx%d, flags: 0x%x)",
                      displayID, mode.pixelWidth, mode.pixelHeight, mode.width, mode.height, mode.ioFlags)
                let err = CGDisplaySetDisplayMode(displayID, mode, nil)
                if err != .success {
                    NSLog("[VirtualDisplayManager] Failed to set display mode: %d", err.rawValue)
                }
                return
            }
        }

        // 2. Fallback: match pixel dimensions
        for mode in modes {
            if mode.pixelWidth == pixelWidth && mode.pixelHeight == pixelHeight {
                NSLog("[VirtualDisplayManager] Setting display %u fallback mode to %dx%d (pt: %dx%d)",
                      displayID, mode.pixelWidth, mode.pixelHeight, mode.width, mode.height)
                let err = CGDisplaySetDisplayMode(displayID, mode, nil)
                if err != .success {
                    NSLog("[VirtualDisplayManager] Failed to set fallback display mode: %d", err.rawValue)
                }
                return
            }
        }
    }

    /// Verifies that the display is not only online but actively published in macOS active displays list,
    /// ensuring Sunshine/encoders can successfully open and stream it.
    private static func isDisplayActive(_ id: CGDirectDisplayID) -> Bool {
        guard id != 0 else { return false }
        guard CGDisplayIsActive(id) == 1 else { return false }
        var activeCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &activeCount) == .success, activeCount > 0 else { return false }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(activeCount))
        guard CGGetActiveDisplayList(activeCount, &ids, &activeCount) == .success else { return false }
        return ids.prefix(Int(activeCount)).contains(id)
    }

    /// Checks whether the display is still reported as online or active by macOS.
    private static func isDisplayPresent(_ id: CGDirectDisplayID) -> Bool {
        guard id != 0 else { return false }
        if CGDisplayIsOnline(id) == 1 || CGDisplayIsActive(id) == 1 {
            return true
        }
        var onlineCount: UInt32 = 0
        if CGGetOnlineDisplayList(0, nil, &onlineCount) == .success, onlineCount > 0 {
            var ids = [CGDirectDisplayID](repeating: 0, count: Int(onlineCount))
            if CGGetOnlineDisplayList(onlineCount, &ids, &onlineCount) == .success {
                if ids.prefix(Int(onlineCount)).contains(id) { return true }
            }
        }
        return false
    }

    private static func waitAsync(timeout: TimeInterval, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    private static func waitSync(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            if Thread.isMainThread {
                _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
            } else {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        return condition()
    }
}
