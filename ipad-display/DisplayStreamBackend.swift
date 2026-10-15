// DisplayStreamBackend.swift
//
// The StreamBackend the menu talks to. It owns the order of operations:
//
//   change requested -> stop Sunshine -> destroy old display -> create new display
//                    -> point Sunshine at capture display ID -> start Sunshine
//
// All work runs in a managed task sequence on a private serial queue / task context.

import CoreGraphics
import Foundation

final class DisplayStreamBackend: StreamBackend {
    var onStateChange: (() -> Void)?

    var state: StreamState {
        stateLock.lock(); defer { stateLock.unlock() }
        return currentState
    }

    private let sunshine: SunshineProcess
    private let displays = VirtualDisplayManager()
    private var relay: ScreenRelay?
    private let stateLock = NSLock()
    private var currentState: StreamState = .stopped
    private var currentTask: Task<Void, Never>?
    private var appliedSettings: DisplaySettings?
    private var activeCaptureDisplayID: CGDirectDisplayID?

    init(sunshine: SunshineProcess) {
        self.sunshine = sunshine
        sunshine.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event)
            }
        }
    }

    // MARK: - StreamBackend

    func apply(_ settings: DisplaySettings, completion: @escaping (Result<Void, Error>) -> Void) {
        currentTask?.cancel()
        currentTask = Task {
            NSLog("[Backend] apply called: orientation=%@, rotation=%@, preset=%@, refreshRate=%d, hiDPI=%d, streamAudio=%d",
                  settings.orientation.rawValue, settings.portraitRotation.rawValue, settings.preset.name, settings.refreshRate, settings.hiDPI ? 1 : 0, settings.streamAudio ? 1 : 0)

            // Fast path: if only streamAudio changed and displays are already up, simply restart Sunshine
            let canFastRestartSunshine: Bool = {
                guard let currentID = self.activeCaptureDisplayID,
                      let prev = self.appliedSettings else { return false }
                let isCurrentStateActive: Bool
                switch self.state {
                case .waitingForClient, .streaming:
                    isCurrentStateActive = true
                default:
                    isCurrentStateActive = false
                }
                guard isCurrentStateActive else { return false }
                return prev.orientation == settings.orientation &&
                       prev.portraitRotation == settings.portraitRotation &&
                       prev.sizeIndex == settings.sizeIndex &&
                       prev.refreshRate == settings.refreshRate &&
                       prev.hiDPI == settings.hiDPI &&
                       prev.streamAudio != settings.streamAudio
            }()

            if canFastRestartSunshine, let currentID = self.activeCaptureDisplayID {
                NSLog("[Backend] Fast restart: only streamAudio changed. Restarting Sunshine (streamAudio=%d)...", settings.streamAudio ? 1 : 0)
                setState(.starting)
                do {
                    self.sunshine.stop()
                    try self.sunshine.start(displayID: currentID, streamAudio: settings.streamAudio)
                    self.appliedSettings = settings
                    self.setState(.waitingForClient)
                    await MainActor.run { completion(.success(())) }
                    return
                } catch {
                    NSLog("[Backend] Fast audio restart failed (%@), falling back to full display recreate", error.localizedDescription)
                }
            }

            setState(.starting)
            let result: Result<Void, Error>
            do {
                // Stop Sunshine and previous relay
                sunshine.stop()
                if Thread.isMainThread {
                    MainActor.assumeIsolated {
                        self.relay?.stop()
                        self.relay = nil
                    }
                } else {
                    await MainActor.run {
                        self.relay?.stop()
                        self.relay = nil
                    }
                }
                try await displays.destroy()

                guard !Task.isCancelled else { return }

                let p = settings.preset
                let captureDisplayID: CGDirectDisplayID

                switch settings.orientation {
                case .landscape:
                    NSLog("[Backend] Creating landscape display (%dx%d)", p.landscapeWidth, p.landscapeHeight)
                    let id = try await displays.createLandscape(
                        width: p.landscapeWidth,
                        height: p.landscapeHeight,
                        refreshRate: settings.refreshRate,
                        hiDPI: settings.hiDPI
                    )
                    captureDisplayID = id
                    NSLog("[Backend] Created landscape display ID: %u", id)

                case .portrait:
                    NSLog("[Backend] Creating portrait displays (%dx%d)", p.landscapeWidth, p.landscapeHeight)
                    let pair = try await displays.createPortrait(
                        landscapeWidth: p.landscapeWidth,
                        landscapeHeight: p.landscapeHeight,
                        refreshRate: settings.refreshRate,
                        hiDPI: settings.hiDPI
                    )
                    NSLog("[Backend] Created portrait pair: desktop=%u, stream=%u", pair.desktopID, pair.streamID)

                    guard !Task.isCancelled else {
                        try? await displays.destroy()
                        return
                    }

                    // Start hardware-accelerated ScreenRelay with cursor guard
                    NSLog("[Backend] Starting ScreenRelay with rotation: %@", settings.portraitRotation.title)
                    let newRelay = try await MainActor.run { () throws -> ScreenRelay in
                        return try ScreenRelay.create()
                    }
                    self.relay = newRelay
                    try await newRelay.start(
                        sourceDisplayID: pair.desktopID,
                        targetDisplayID: pair.streamID,
                        width: p.landscapeWidth,
                        height: p.landscapeHeight,
                        refreshRate: settings.refreshRate,
                        orientation: settings.portraitRotation.exifOrientation
                    )
                    NSLog("[Backend] ScreenRelay started successfully")
                    captureDisplayID = pair.streamID
                }

                guard !Task.isCancelled else {
                    await MainActor.run {
                        self.relay?.stop()
                        self.relay = nil
                    }
                    try? await displays.destroy()
                    return
                }

                NSLog("[Backend] Starting Sunshine for display ID: %u, streamAudio: %d", captureDisplayID, settings.streamAudio ? 1 : 0)
                try sunshine.start(displayID: captureDisplayID, streamAudio: settings.streamAudio)
                NSLog("[Backend] Sunshine started successfully")

                activeCaptureDisplayID = captureDisplayID
                appliedSettings = settings
                setState(.waitingForClient)
                result = .success(())
            } catch {
                NSLog("[Backend] apply failed with error: %@", error.localizedDescription)
                await MainActor.run {
                    self.relay?.stop()
                    self.relay = nil
                }
                try? await displays.destroy()
                activeCaptureDisplayID = nil
                appliedSettings = nil
                setState(.failed(error.localizedDescription))
                result = .failure(error)
            }
            await MainActor.run { completion(result) }
        }
    }

    func stop() {
        currentTask?.cancel()
        currentTask = nil

        sunshine.stop()
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                self.relay?.stop()
                self.relay = nil
            }
        } else {
            DispatchQueue.main.sync {
                self.relay?.stop()
                self.relay = nil
            }
        }
        activeCaptureDisplayID = nil
        appliedSettings = nil
        displays.destroySync()
        setState(.stopped)
    }

    func pair(pin: String, deviceName: String, completion: @escaping (Result<Void, Error>) -> Void) {
        Task {
            let result: Result<Void, Error>
            do {
                let pending = try await sunshine.pendingPairings()
                guard let target = pending.last else { throw SunshineError.noPendingPairing }
                let name = target.name.isEmpty ? deviceName : target.name
                guard try await sunshine.submitPIN(pairingID: target.id, pin: pin, name: name) else {
                    throw SunshineError.pairingRejected
                }
                result = .success(())
            } catch {
                result = .failure(error)
            }
            await MainActor.run { completion(result) }
        }
    }

    func unpairAll(completion: @escaping (Result<Void, Error>) -> Void) {
        Task {
            let result: Result<Void, Error>
            do {
                try await sunshine.unpairAll()
                result = .success(())
            } catch {
                result = .failure(error)
            }
            await MainActor.run { completion(result) }
        }
    }

    // MARK: - Internals

    private func setState(_ next: StreamState) {
        stateLock.lock()
        let changed = currentState != next
        currentState = next
        stateLock.unlock()

        if changed {
            NSLog("[Backend] State -> %@", next.menuText)
            DispatchQueue.main.async { [weak self] in
                self?.onStateChange?()
            }
        }
    }

    private func handle(_ event: SunshineEvent) {
        switch event {
        case .ready:
            break
        case .clientConnected:
            setState(.streaming(clientName: "iPad"))
        case .clientDisconnected:
            setState(.waitingForClient)
        case .exited(let status):
            if state != .stopped {
                setState(.failed("Sunshine process exited unexpectedly (code \(status))"))
            }
        }
    }
}
