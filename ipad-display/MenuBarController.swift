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
import Darwin
import ServiceManagement
import SystemConfiguration

// MARK: - Model
struct NetworkAddress: Sendable {
    let interface: String
    let ip: String

    var displayName: String {
        if ip.hasPrefix("169.254.") {
            return "USB Cable (\(interface)): \(ip)"
        } else if interface == "en0" {
            return "Wi-Fi (\(interface)): \(ip)"
        } else if interface.hasPrefix("en") {
            return "Ethernet (\(interface)): \(ip)"
        } else if interface.hasPrefix("utun") {
            return "VPN (\(interface)): \(ip)"
        } else {
            return "\(interface): \(ip)"
        }
    }
}


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
    case portDown
    case portUp

    var title: String {
        switch self {
        case .portDown: return "Portrait (Cable at Bottom)"
        case .portUp: return "Portrait (Cable at Top)"
        }
    }

    var exifOrientation: CGImagePropertyOrientation {
        switch self {
        case .portDown: return .left  // 270° CW / 90° CCW: top of screen at top of iPad when cable is at bottom
        case .portUp: return .right   // 90° CW: top of screen at top of iPad when cable is at top
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

struct DisplaySettings: Codable, Equatable, Sendable {
    var orientation: Orientation = .portrait
    var portraitRotation: PortraitRotation = .portDown
    var sizeIndex: Int = 0
    var refreshRate: Int = 60
    var hiDPI: Bool = true   // "Retina": text is drawn at double density, so a 2048x1536 iPad looks like 1024x768
    var streamAudio: Bool = false // false = Mac only (blocked); true = Mac + iPad (dual audio)

    enum CodingKeys: String, CodingKey {
        case orientation, portraitRotation, sizeIndex, refreshRate, hiDPI, streamAudio
    }

    init(
        orientation: Orientation = .portrait,
        portraitRotation: PortraitRotation = .portDown,
        sizeIndex: Int = 0,
        refreshRate: Int = 60,
        hiDPI: Bool = true,
        streamAudio: Bool = false
    ) {
        self.orientation = orientation
        self.portraitRotation = portraitRotation
        self.sizeIndex = sizeIndex
        self.refreshRate = refreshRate
        self.hiDPI = hiDPI
        self.streamAudio = streamAudio
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.orientation = try container.decodeIfPresent(Orientation.self, forKey: .orientation) ?? .portrait
        self.portraitRotation = try container.decodeIfPresent(PortraitRotation.self, forKey: .portraitRotation) ?? .portDown
        self.sizeIndex = try container.decodeIfPresent(Int.self, forKey: .sizeIndex) ?? 0
        self.refreshRate = try container.decodeIfPresent(Int.self, forKey: .refreshRate) ?? 60
        self.hiDPI = try container.decodeIfPresent(Bool.self, forKey: .hiDPI) ?? true
        self.streamAudio = try container.decodeIfPresent(Bool.self, forKey: .streamAudio) ?? false
    }

    var preset: SizePreset { SizePreset.all[min(max(sizeIndex, 0), SizePreset.all.count - 1)] }

    /// Pixel size handed to the user-facing virtual display.
    var pixelSize: (width: Int, height: Int) {
        let p = preset
        switch orientation {
        case .landscape: return (p.landscapeWidth, p.landscapeHeight)
        case .portrait: return (p.landscapeHeight, p.landscapeWidth)
        }
    }

    private static let key = "displaySettings.v5"

    static func load() -> DisplaySettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(DisplaySettings.self, from: data)
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

    static func getIPv4Addresses() -> [NetworkAddress] {
        var results: [NetworkAddress] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING),
                  (flags & IFF_LOOPBACK) == 0,
                  let addr = ptr.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET)
            else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(
                addr,
                socklen_t(addr.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 {
                let ifName = String(cString: ptr.pointee.ifa_name)
                let ip = String(cString: hostname)
                if !ip.isEmpty && !ip.hasPrefix("127.") && !ip.hasPrefix("192.0.0.") {
                    results.append(NetworkAddress(interface: ifName, ip: ip))
                }
            }
        }

        return results.sorted { a, b in
            let aScore = score(for: a)
            let bScore = score(for: b)
            if aScore != bScore { return aScore < bScore }
            return a.interface < b.interface
        }
    }

    static var localHostName: String {
        if let scName = SCDynamicStoreCopyLocalHostName(nil) as String? {
            let trimmed = scName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return "\(trimmed).local"
            }
        }
        let raw = ProcessInfo.processInfo.hostName
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix(".local") {
            return trimmed
        }
        return "\(trimmed).local"
    }

    private static func score(for addr: NetworkAddress) -> Int {
        if addr.interface == "en0" { return 1 }
        if addr.ip.hasPrefix("169.254.") { return 2 }
        if addr.interface.hasPrefix("en") { return 3 }
        if addr.interface.hasPrefix("utun") { return 10 }
        return 20
    }

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

        let hostName = Self.localHostName
        let hostItem = NSMenuItem(title: "Host: \(hostName)  (Click to copy)", action: #selector(copyHostName), keyEquivalent: "")
        hostItem.target = self
        hostItem.toolTip = "Copy \(hostName) to clipboard. Enter this in Moonlight on iPad to avoid retyping IP after restarts."
        menu.addItem(hostItem)

        let addresses = Self.getIPv4Addresses()
        if let primary = addresses.first {
            let ipItem = NSMenuItem(title: "IP: \(primary.ip)  (Click to copy)", action: #selector(copyPrimaryIP), keyEquivalent: "")
            ipItem.target = self
            ipItem.toolTip = "Copy \(primary.ip) to clipboard"
            menu.addItem(ipItem)

            if addresses.count > 1 {
                let subMenu = NSMenu()
                for addr in addresses {
                    let subItem = NSMenuItem(title: "\(addr.displayName)  (Click to copy)", action: #selector(copySelectedIP(_:)), keyEquivalent: "")
                    subItem.representedObject = addr.ip
                    subItem.target = self
                    subItem.toolTip = "Copy \(addr.ip) to clipboard"
                    subMenu.addItem(subItem)
                }
                let allIPsItem = NSMenuItem(title: "All Network IPs", action: nil, keyEquivalent: "")
                allIPsItem.submenu = subMenu
                menu.addItem(allIPsItem)
            }
        }
        menu.addItem(.separator())

        // Orientation: the must-have control.
        let orientationItem = NSMenuItem(title: "Orientation", action: nil, keyEquivalent: "")
        let orientationMenu = NSMenu()

        let portraitItem = NSMenuItem(title: "Portrait", action: #selector(pickOrientationPortrait), keyEquivalent: "")
        portraitItem.target = self
        portraitItem.state = settings.orientation == .portrait ? .on : .off
        portraitItem.isEnabled = !isApplying
        orientationMenu.addItem(portraitItem)

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

        // Stream audio toggle
        let audio = NSMenuItem(
            title: "Dual Audio (Mac + iPad)",
            action: #selector(toggleAudio),
            keyEquivalent: ""
        )
        audio.target = self
        audio.state = settings.streamAudio ? .on : .off
        audio.isEnabled = !isApplying
        menu.addItem(audio)

        menu.addItem(.separator())

        let restart = NSMenuItem(title: "Restart display", action: #selector(restartDisplay), keyEquivalent: "r")
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

        statusItem.button?.title = ""
        let hostOrIP = Self.localHostName
        statusItem.button?.toolTip = "\(backend.state.menuText) • \(hostOrIP)"
        rebuildMenu()
    }

    // MARK: Actions

    @objc private func pickOrientationPortrait() {
        change { $0.orientation = .portrait }
    }

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
        let index = sender.tag
        guard index >= 0 && index < SizePreset.all.count else { return }
        change { $0.sizeIndex = index }
    }

    @objc private func pickRate(_ sender: NSMenuItem) {
        let rate = sender.tag
        guard rate == 30 || rate == 60 else { return }
        change { $0.refreshRate = rate }
    }

    @objc private func toggleHiDPI() {
        change { $0.hiDPI.toggle() }
    }

    @objc private func toggleAudio() {
        change { $0.streamAudio.toggle() }
    }

    @objc private func restartDisplay() {
        apply(settings)
    }

    @objc private func pairDevice() {
        let alert = NSAlert()
        alert.messageText = "Pair new iPad"
        let deviceName = Host.current().localizedName ?? "Mac"
        alert.informativeText = "Open Moonlight on your iPad. Tap '\(deviceName)' (or tap '+' and enter '\(Self.localHostName)'), then enter the 4-digit PIN shown on the iPad:"
        alert.alertStyle = .informational

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
        input.placeholderString = "0000"
        alert.accessoryView = input
        alert.addButton(withTitle: "Pair")
        alert.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let pin = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pin.isEmpty else { return }
            backend.pair(pin: pin, deviceName: "iPad") { result in
                switch result {
                case .success:
                    let ok = NSAlert()
                    ok.messageText = "Paired!"
                    ok.informativeText = "The iPad is now paired. Tap the display on the iPad to start streaming."
                    ok.runModal()
                case .failure(let err):
                    let fail = NSAlert()
                    fail.alertStyle = .warning
                    fail.messageText = "Pairing failed"
                    fail.informativeText = err.localizedDescription
                    fail.runModal()
                }
            }
        }
    }

    @objc private func unpairAllDevices() {
        let alert = NSAlert()
        alert.messageText = "Unpair all iPads?"
        alert.informativeText = "This will remove all paired Moonlight clients. You will need to enter a PIN again next time."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Unpair all")
        alert.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            backend.unpairAll { result in
                switch result {
                case .success:
                    let ok = NSAlert()
                    ok.messageText = "Unpaired"
                    ok.informativeText = "All clients have been unpaired."
                    ok.runModal()
                case .failure(let err):
                    let fail = NSAlert()
                    fail.alertStyle = .warning
                    fail.messageText = "Failed to unpair"
                    fail.informativeText = err.localizedDescription
                    fail.runModal()
                }
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
            rebuildMenu()
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Login item change failed"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func quitApp() {
        backend.stop()
        NSApp.terminate(nil)
    }

    @objc private func copyHostName() {
        copyToPasteboard(Self.localHostName)
    }

    @objc private func copyPrimaryIP() {
        if let ip = Self.getIPv4Addresses().first?.ip {
            copyToPasteboard(ip)
        }
    }

    @objc private func copySelectedIP(_ sender: NSMenuItem) {
        if let ip = sender.representedObject as? String {
            copyToPasteboard(ip)
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func change(_ mutate: (inout DisplaySettings) -> Void) {
        var copy = settings
        mutate(&copy)
        guard copy != settings else { return }
        settings = copy
        settings.save()
        apply(settings)
    }

    private func apply(_ new: DisplaySettings) {
        isApplying = true
        rebuildMenu()
        backend.apply(new) { [weak self] result in
            guard let self = self else { return }
            self.isApplying = false
            switch result {
            case .success:
                new.save()
            case .failure(let error):
                self.showError("Could not apply the change: \(error.localizedDescription)")
            }
            self.rebuildMenu()
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
}
