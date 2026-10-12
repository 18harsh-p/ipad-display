// MenuBarController.swift
//
// Menu-bar UI for the combined FluffyDisplay + Sunshine app.
// AppKit only, macOS 13+.
//
// Design rules:
//  * The menu never talks to Sunshine or CoreGraphics directly. It edits
//    `DisplaySettings` and hands them to a `StreamBackend`..
//  * Changing orientation, size or refresh rate DESTROYS and RECREATES the virtual
//    display instead of switching modes. Switching the mode of a live private-API
//    virtual display can leave it impossible to remove.
//  * The display ID changes on every recreate, so the backend must also write the
//    new ID into Sunshine's `output_name` and restart Sunshine.

import AppKit
import CoreGraphics
import ServiceManagement

// MARK: - Model

enum Orientation: String, Codable, CaseIterable {
    case portrait
    case landscape

    var title: String {
        switch self {
        case .portrait: return "Portrait"
        case .landscape: return "Landscape"
        }
    }
}

enum PortraitRotation: String, Codable, CaseIterable {
    case portUp
    case portDown

    var title: String {
        switch self {
        case .portUp: return "Portrait (Port Up)"
        case .portDown: return "Portrait (Port Down)"
        }
    }

    var exifOrientation: CGImagePropertyOrientation {
        switch self {
        case .portUp: return .right    // 90° CW: holding iPad upright with port at top presents upright screen
        case .portDown: return .left   // 270° CCW: holding iPad upright with port at bottom presents upright screen
        }
    }
}

/// Sizes are stored in landscape form (iPad Air 1st gen is 2048x1536) and swapped for portrait.
struct SizePreset: Codable, Equatable {
    let name: String
    let landscapeWidth: Int
    let landscapeHeight: Int

    static let all: [SizePreset] = [
        SizePreset(name: "Full iPad (2048×1536)", landscapeWidth: 2048, landscapeHeight: 1536),
        SizePreset(name: "Balanced (1600×1200)", landscapeWidth: 1600, landscapeHeight: 1200),
        SizePreset(name: "Light (1024×768)", landscapeWidth: 1024, landscapeHeight: 768),
    ]
}

struct DisplaySettings: Codable, Equatable {
    var orientation: Orientation = .portrait
    var portraitRotation: PortraitRotation = .portUp
    var sizeIndex: Int = 0
    var refreshRate: Int = 60
    var hiDPI: Bool = true   // "Retina": text is drawn at double density, so a 2048x1536 iPad looks like 1024x768

    var preset: SizePreset { SizePreset.all[min(max(sizeIndex, 0), SizePreset.all.count - 1)] }

    /// Pixel size handed to the user-facing virtual display.
    var pixelSize: (width: Int, height: Int) {
        let p = preset
        switch orientation {
        case .landscape: return (p.landscapeWidth, p.landscapeHeight)
        case .portrait: return (p.landscapeHeight, p.landscapeWidth)
        }
    }

    private static let key = "displaySettings.v3"

    static func load() -> DisplaySettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              var decoded = try? JSONDecoder().decode(DisplaySettings.self, from: data)
        else { return DisplaySettings() }
        return decoded
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

enum StreamState: Equatable {
    case stopped
    case starting
    case waitingForClient          // display is up, Sunshine is listening, no iPad yet
    case streaming(clientName: String)
    case failed(String)

    var menuText: String {
        switch self {
        case .stopped: return "Display off"
        case .starting: return "Starting…"
        case .waitingForClient: return "Ready: open Moonlight on the iPad"
        case .streaming(let name): return "Streaming to \(name)"
        case .failed(let reason): return "Problem: \(reason)"
        }
    }
}

// MARK: - Backend contract

/// Implemented by the part of the app that owns the virtual display and the Sunshine process.
protocol StreamBackend: AnyObject {
    var state: StreamState { get }

    /// Called whenever `state` changes so the menu can refresh. Delivered on the main queue.
    var onStateChange: (() -> Void)? { get set }

    /// Create (or recreate) the virtual display with these settings, point Sunshine at it
    /// and (re)start streaming. Completion runs on the main queue.
    func apply(_ settings: DisplaySettings, completion: @escaping (Result<Void, Error>) -> Void)

    /// Remove the virtual display and stop Sunshine. Must be safe to call twice.
    func stop()

    /// Finish pairing a Moonlight client with the PIN it is showing.
    func pair(pin: String, deviceName: String, completion: @escaping (Result<Void, Error>) -> Void)

    /// Removes all paired clients and certificates from Sunshine.
    func unpairAll(completion: @escaping (Result<Void, Error>) -> Void)
}

// MARK: - Menu

final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let backend: StreamBackend
    private var settings = DisplaySettings.load()
    private var isApplying = false

    init(backend: StreamBackend) {
        self.backend = backend
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "ipad", accessibilityDescription: "iPad display")
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        backend.onStateChange = { [weak self] in self?.refreshIcon() }
        rebuildMenu()
        refreshIcon()
    }

    /// Call once at launch to bring the display up with the saved settings.
    func start() { apply(settings) }

    // MARK: Building the menu

    func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu() }

    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        let status = NSMenuItem(title: isApplying ? "Applying…" : backend.state.menuText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        // Orientation: the must-have control.
        let orientationItem = NSMenuItem(title: "Orientation", action: nil, keyEquivalent: "")
        let orientationMenu = NSMenu()

        for rotation in PortraitRotation.allCases {
            let item = NSMenuItem(title: rotation.title, action: #selector(pickPortraitRotation(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = rotation.rawValue
            item.state = (settings.orientation == .portrait && settings.portraitRotation == rotation) ? .on : .off
            item.isEnabled = !isApplying
            orientationMenu.addItem(item)
        }

        orientationMenu.addItem(.separator())

        let landscapeItem = NSMenuItem(title: "Landscape", action: #selector(pickOrientationLandscape), keyEquivalent: "")
        landscapeItem.target = self
        landscapeItem.state = settings.orientation == .landscape ? .on : .off
        landscapeItem.isEnabled = !isApplying
        orientationMenu.addItem(landscapeItem)

        orientationItem.submenu = orientationMenu
        menu.addItem(orientationItem)

        // Preset sizes
        let sizeItem = NSMenuItem(title: "Resolution", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        for (index, preset) in SizePreset.all.enumerated() {
            let item = NSMenuItem(title: preset.name, action: #selector(pickSize(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = settings.sizeIndex == index ? .on : .off
            item.isEnabled = !isApplying
            sizeMenu.addItem(item)
        }
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        // Refresh rate
        let rateItem = NSMenuItem(title: "Refresh Rate", action: nil, keyEquivalent: "")
        let rateMenu = NSMenu()
        for rate in [60, 30] {
            let item = NSMenuItem(title: "\(rate) Hz", action: #selector(pickRate(_:)), keyEquivalent: "")
            item.target = self
            item.tag = rate
            item.state = settings.refreshRate == rate ? .on : .off
            item.isEnabled = !isApplying
            rateMenu.addItem(item)
        }
        rateItem.submenu = rateMenu
        menu.addItem(rateItem)

        // HiDPI toggle
        let sharp = NSMenuItem(title: "Retina (2×)", action: #selector(toggleHiDPI), keyEquivalent: "")
        sharp.target = self
        sharp.state = settings.hiDPI ? .on : .off
        sharp.isEnabled = !isApplying
        menu.addItem(sharp)

        menu.addItem(.separator())

        // Moonlight Host IPs (shows active network addresses for easy connection)
        let ips = Self.activeIPAddresses()
        if !ips.isEmpty {
            let hostItem = NSMenuItem(title: "Moonlight Host IP", action: nil, keyEquivalent: "")
            let hostMenu = NSMenu()
            for (label, ip) in ips {
                let item = NSMenuItem(title: "\(label): \(ip)", action: #selector(copyIPAddress(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = ip
                item.toolTip = "Click to copy IP address"
                hostMenu.addItem(item)
            }
            hostItem.submenu = hostMenu
            menu.addItem(hostItem)
        }

        let restart = NSMenuItem(title: "Restart display", action: #selector(restartDisplay), keyEquivalent: "")
        restart.target = self
        restart.isEnabled = !isApplying
        menu.addItem(restart)

        let pair = NSMenuItem(title: "Pair new iPad…", action: #selector(pairDevice), keyEquivalent: "")
        pair.target = self
        menu.addItem(pair)

        let unpair = NSMenuItem(title: "Unpair all iPads…", action: #selector(unpairAllDevices), keyEquivalent: "")
        unpair.target = self
        menu.addItem(unpair)

        menu.addItem(.separator())

        let login = NSMenuItem(title: "Open at login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        let quit = NSMenuItem(title: "Quit and remove display", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func refreshIcon() {
        let symbol: String
        switch settings.orientation {
        case .landscape: symbol = "ipad.landscape"
        case .portrait: symbol = "ipad"
        }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "iPad display")
        statusItem.button?.toolTip = backend.state.menuText
        rebuildMenu()
    }

    // MARK: Actions

    @objc private func pickOrientationLandscape() {
        change { $0.orientation = .landscape }
    }

    @objc private func pickPortraitRotation(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let rotation = PortraitRotation(rawValue: raw) else { return }
        change {
            $0.orientation = .portrait
            $0.portraitRotation = rotation
        }
    }

    @objc private func toggleOrientation() {
        change {
            if $0.orientation == .portrait {
                $0.orientation = .landscape
            } else {
                $0.orientation = .portrait
            }
        }
    }

    @objc private func pickSize(_ sender: NSMenuItem) {
        change { $0.sizeIndex = sender.tag }
    }

    @objc private func pickRate(_ sender: NSMenuItem) {
        change { $0.refreshRate = sender.tag }
    }

    @objc private func toggleHiDPI() {
        change { $0.hiDPI.toggle() }
    }

    @objc private func restartDisplay() {
        apply(settings)
    }

    @objc private func copyIPAddress(_ sender: NSMenuItem) {
        guard let ip = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ip, forType: .string)
    }

    @objc private func pairDevice() {
        let alert = NSAlert()
        alert.messageText = "Pair new iPad"
        alert.informativeText = "Open Moonlight on the iPad, pick this Mac, and type the 4-digit PIN it shows."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
        field.placeholderString = "PIN"
        alert.accessoryView = field
        alert.addButton(withTitle: "Pair")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let pin = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard pin.count == 4, pin.allSatisfy(\.isNumber) else {
            showError("The PIN is 4 digits.")
            return
        }
        backend.pair(pin: pin, deviceName: "iPad") { [weak self] result in
            if case .failure(let error) = result { self?.showError("Pairing failed: \(error.localizedDescription)") }
        }
    }

    @objc private func unpairAllDevices() {
        let alert = NSAlert()
        alert.messageText = "Unpair all iPads?"
        alert.informativeText = "This removes all saved pairing credentials. You will need to delete this Mac from Moonlight on your iPad and pair again with a new PIN."
        alert.addButton(withTitle: "Unpair")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        backend.unpairAll { [weak self] result in
            switch result {
            case .success:
                let done = NSAlert()
                done.messageText = "Unpaired successfully"
                done.informativeText = "On your iPad, delete this Mac from Moonlight, tap it again to get a new PIN, and click 'Pair new iPad…' here."
                NSApp.activate(ignoringOtherApps: true)
                done.runModal()
            case .failure(let error):
                self?.showError("Failed to unpair: \(error.localizedDescription)")
            }
        }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showError("Could not change the login setting: \(error.localizedDescription)")
        }
        rebuildMenu()
    }

    @objc private func quitApp() {
        backend.stop()
        NSApp.terminate(nil)
    }

    // MARK: Applying changes

    /// Edit settings, save them and recreate the display. Ignored while a change is already running,
    /// because overlapping create/destroy calls are a likely cause of stuck displays.
    private func change(_ edit: (inout DisplaySettings) -> Void) {
        guard !isApplying else { return }
        var updated = settings
        edit(&updated)
        guard updated != settings else { return }
        apply(updated)
    }

    private func apply(_ new: DisplaySettings) {
        guard !isApplying else { return }
        isApplying = true
        rebuildMenu()

        backend.apply(new) { [weak self] result in
            guard let self else { return }
            self.isApplying = false
            switch result {
            case .success:
                self.settings = new
                new.save()
            case .failure(let error):
                // Keep the previously saved settings; the backend reports its own state.
                self.showError("Could not apply the change: \(error.localizedDescription)")
            }
            self.refreshIcon()
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        if message.contains("Screen Recording") {
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            }
        } else {
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    // MARK: - Helpers

    static func activeIPAddresses() -> [(label: String, ip: String)] {
        var results: [(String, String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return results }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            let flags = Int32(current.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            if isUp && !isLoopback, let addr = current.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let name = String(cString: current.pointee.ifa_name)
                    let ip = String(cString: hostname)
                    let label: String
                    if ip.hasPrefix("169.254.") {
                        label = "USB Cable (\(name))"
                    } else {
                        label = "Wi-Fi (\(name))"
                    }
                    results.append((label, ip))
                }
            }
            ptr = current.pointee.ifa_next
        }
        return results
    }
}
