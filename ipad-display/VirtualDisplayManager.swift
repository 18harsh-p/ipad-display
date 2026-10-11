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
            return "Portrait mode requires Screen Recording permission so ipad-display can rotate the video stream for Moonlight without black bars. Please enable it in System Settings > Privacy & Security > Screen Recording."
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
    func createLandscape(width: Int, height: Int, refreshRate: Int, hiDPI: Bool) throws -> CGDirectDisplayID {
        guard IPDVirtualDisplay.isAvailable() else { throw DisplayError.unavailable }
        try destroy()
        Thread.sleep(forTimeInterval: 0.1)

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

        guard Self.wait(timeout: 15, until: { Self.isActive(id) }) else {
            NSLog("[VirtualDisplayManager] Timed out waiting for display ID: %u to appear", id)
            try? destroy()
            throw DisplayError.didNotAppear
        }
        NSLog("[VirtualDisplayManager] Display ID %u is online and active", id)
        return id
    }

    /// Creates a portrait desktop display (for macOS) and a landscape stream display (for Moonlight).
    func createPortrait(
        landscapeWidth: Int,
        landscapeHeight: Int,
        refreshRate: Int,
        hiDPI: Bool
    ) throws -> (desktopID: CGDirectDisplayID, streamID: CGDirectDisplayID) {
        guard IPDVirtualDisplay.isAvailable() else { throw DisplayError.unavailable }
        try destroy()
        Thread.sleep(forTimeInterval: 0.1)

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

        guard Self.wait(timeout: 15, until: { Self.isActive(dID) && Self.isActive(sID) }) else {
            try? destroy()
            throw DisplayError.didNotAppear
        }

        return (desktopID: dID, streamID: sID)
    }

    /// Removes all virtual displays (if any) and waits until macOS no longer lists them. Safe to call twice.
    func destroy() throws {
        let oldIDs = [desktopDisplayID, streamDisplayID].compactMap { $0 }
        guard !oldIDs.isEmpty else { return }

        desktopDisplay = nil
        if relayDisplay != nil {
            Thread.sleep(forTimeInterval: 0.05)
            relayDisplay = nil
        }
        desktopDisplayID = nil
        streamDisplayID = nil

        guard Self.wait(timeout: 10, until: { oldIDs.allSatisfy { !Self.isActive($0) } }) else {
            throw DisplayError.didNotDisappear
        }
    }

    // MARK: - Helpers

    private static func isActive(_ id: CGDirectDisplayID) -> Bool {
        if CGDisplayIsOnline(id) != 0 || CGDisplayIsActive(id) != 0 {
            return true
        }
        var onlineCount: UInt32 = 0
        if CGGetOnlineDisplayList(0, nil, &onlineCount) == .success, onlineCount > 0 {
            var ids = [CGDirectDisplayID](repeating: 0, count: Int(onlineCount))
            if CGGetOnlineDisplayList(onlineCount, &ids, &onlineCount) == .success {
                if ids.prefix(Int(onlineCount)).contains(id) { return true }
            }
        }
        var activeCount: UInt32 = 0
        if CGGetActiveDisplayList(0, nil, &activeCount) == .success, activeCount > 0 {
            var ids = [CGDirectDisplayID](repeating: 0, count: Int(activeCount))
            if CGGetActiveDisplayList(activeCount, &ids, &activeCount) == .success {
                if ids.prefix(Int(activeCount)).contains(id) { return true }
            }
        }
        return false
    }

    private static func wait(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return condition()
    }
}
