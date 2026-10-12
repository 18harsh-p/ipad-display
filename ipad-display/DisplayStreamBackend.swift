// DisplayStreamBackend.swift
//
// The StreamBackend the menu talks to. It owns the order of operations:
//
//   change requested -> stop Sunshine -> stop relay -> destroy old display(s) -> create new display(s)
//                    -> start relay (if portrait) -> point Sunshine at capture display ID -> start Sunshine
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

    init(sunshine: SunshineProcess) {
        self.sunshine = sunshine
        sunshine.onEvent = { [weak self] event in self?.handle(event) }
    }

    // MARK: - StreamBackend

    func apply(_ settings: DisplaySettings, completion: @escaping (Result<Void, Error>) -> Void) {
        currentTask?.cancel()
        currentTask = Task {
            NSLog("[Backend] apply called: orientation=%@, preset=%@, refreshRate=%d, hiDPI=%d", settings.orientation.rawValue, settings.preset.name, settings.refreshRate, settings.hiDPI ? 1 : 0)
            setState(.starting)
            let result: Result<Void, Error>
            do {
                // Stop Sunshine and previous relay
                sunshine.stop()
                self.relay?.stop()
                self.relay = nil
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

                    // Start hardware-accelerated ScreenRelay
                    NSLog("[Backend] Starting ScreenRelay...")
                    let newRelay = try ScreenRelay.create()
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
                    self.relay?.stop()
                    self.relay = nil
                    try? await displays.destroy()
                    return
                }

                NSLog("[Backend] Starting Sunshine for display ID: %u", captureDisplayID)
                try sunshine.start(displayID: captureDisplayID)
                NSLog("[Backend] Sunshine started successfully")

                setState(.waitingForClient)
                result = .success(())
            } catch {
                NSLog("[Backend] apply failed with error: %@", error.localizedDescription)
                self.relay?.stop()
                self.relay = nil
                try? await displays.destroy()
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

    // MARK: - Events and state

    private func handle(_ event: SunshineEvent) {
        switch event {
        case .ready:
            break  // apply() moves to .waitingForClient once start() returns
        case .clientConnected:
            setState(.streaming(clientName: "iPad"))
        case .clientDisconnected:
            setState(.waitingForClient)
        case .exited(let status):
            if state != .stopped {
                setState(.failed("The streaming engine stopped (code \(status)). Choose Restart display."))
            }
        }
    }

    private func setState(_ new: StreamState) {
        stateLock.lock()
        let changed = (currentState != new)
        currentState = new
        stateLock.unlock()
        guard changed else { return }
        DispatchQueue.main.async { [weak self] in self?.onStateChange?() }
    }
}
