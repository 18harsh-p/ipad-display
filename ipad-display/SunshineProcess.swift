// SunshineProcess.swift
//
// Manages the Sunshine background process. Owns its configuration file, API credentials,
// and the loopback HTTP client used for PIN pairing.
//
// Lifecycle:
//   - init() finds the binary (in app bundle or Homebrew) and prepares ~/.config/ipad-display.
//   - start(displayID:) writes sunshine.conf with the given display number, launches the
//     process, and waits for the API to report ready.
//   - stop() sends SIGTERM, waits up to 4s, and sends SIGKILL if it is still alive.
//   - submitPIN() talks to Sunshine's local REST API to accept a client that has connected.

import Foundation
import SystemConfiguration

nonisolated enum SunshineError: LocalizedError, Sendable {
    case binaryNotFound
    case credentialSetupFailed
    case startFailed(String)
    case noPendingPairing
    case pairingRejected
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "Sunshine was not found. Install it with 'brew install sunshine' or copy Sunshine.app to /Applications."
        case .credentialSetupFailed:
            return "Could not initialize Sunshine's credentials."
        case .startFailed(let details):
            return "Sunshine failed to start: \(details)"
        case .noPendingPairing:
            return "No iPad is currently trying to pair. Open Moonlight on the iPad, tap this Mac, and enter the PIN shown there."
        case .pairingRejected:
            return "Sunshine rejected the PIN. Check that it matches what Moonlight is displaying."
        case .http(let code):
            return "Sunshine's local API returned HTTP \(code)."
        }
    }
}

nonisolated enum SunshineEvent: Sendable {
    case ready(port: Int)
    case clientConnected
    case clientDisconnected
    case exited(status: Int32)
}

nonisolated struct Pairing: Decodable, Sendable {
    let id: String
    let name: String
}

private nonisolated struct Login: Codable, Sendable {
    let username: String
    let password: String
}

nonisolated final class SunshineProcess: @unchecked Sendable {
    struct SunshinePaths: Sendable {
        let root: URL
        var config: URL { root.appendingPathComponent("sunshine.conf") }
        var state: URL { root.appendingPathComponent("sunshine_state.json") }
        var credentials: URL { root.appendingPathComponent("sunshine_credentials.json") }
        var apiLogin: URL { root.appendingPathComponent("api-login.json") }
        var privateKey: URL { root.appendingPathComponent("cakey.pem") }
        var certificate: URL { root.appendingPathComponent("cacert.pem") }
        var log: URL { root.appendingPathComponent("sunshine.log") }
        var apps: URL { root.appendingPathComponent("apps.json") }
        var pid: URL { root.appendingPathComponent("sunshine.pid") }
    }

    var onEvent: (@Sendable (SunshineEvent) -> Void)?

    private let paths: SunshinePaths
    private let executable: URL
    private let lock = NSLock()
    private let readySignal = DispatchSemaphore(value: 0)
    private let session = URLSession(configuration: .ephemeral, delegate: LocalTrustDelegate(), delegateQueue: nil)

    // Guarded by `lock`.
    private var process: Process?
    private var lineBuffer = Data()
    private var recentLines: [String] = []
    private var isReady = false
    private var exitStatus: Int32?
    private var apiPort = 47990
    private var cachedLogin: Login?

    init(supportDirectory: URL, executable: URL? = nil) throws {
        paths = SunshinePaths(root: supportDirectory)
        if let executable {
            self.executable = executable
        } else if let override = ProcessInfo.processInfo.environment["SUNSHINE_BINARY"] {
            self.executable = URL(fileURLWithPath: override)  // handy while developing in Xcode
        } else if let bundled = Bundle.main.url(forAuxiliaryExecutable: "sunshine") {
            self.executable = bundled
        } else if let patched = Self.preparePatchedSunshine(in: supportDirectory) {
            self.executable = patched
        } else if let installed = [
            "/Applications/Sunshine.app/Contents/MacOS/Sunshine",
            "/Applications/Sunshine.app/Contents/MacOS/sunshine",
            "/opt/homebrew/bin/sunshine",
            "/usr/local/bin/sunshine"
        ].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            self.executable = URL(fileURLWithPath: installed)
        } else {
            throw SunshineError.binaryNotFound
        }
        guard FileManager.default.isExecutableFile(atPath: self.executable.path) else {
            throw SunshineError.binaryNotFound
        }
        reapStaleProcess()

        // Import existing Sunshine credentials if available so paired iPads are retained
        if !FileManager.default.fileExists(atPath: paths.certificate.path) {
            let userSunshine = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/sunshine", isDirectory: true)
            let userCert = userSunshine.appendingPathComponent("credentials/cacert.pem")
            let userKey = userSunshine.appendingPathComponent("credentials/cakey.pem")
            let userState = userSunshine.appendingPathComponent("sunshine_state.json")
            if FileManager.default.fileExists(atPath: userCert.path),
               FileManager.default.fileExists(atPath: userKey.path) {
                try? FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
                try? FileManager.default.copyItem(at: userCert, to: paths.certificate)
                try? FileManager.default.copyItem(at: userKey, to: paths.privateKey)
                if FileManager.default.fileExists(atPath: userState.path),
                   !FileManager.default.fileExists(atPath: paths.state.path) {
                    try? FileManager.default.copyItem(at: userState, to: paths.state)
                }
            }
        }
    }

    // MARK: - Start and stop

    /// Writes the config, starts Sunshine for the given display and blocks until it reports ready.
    func start(displayID: CGDirectDisplayID, streamAudio: Bool = false) throws {
        stop()
        reapStaleProcess()

        try writeConfig(displayID: displayID, streamAudio: streamAudio)
        sanitizeStateFile()
        _ = try ensureLogin()

        lock.lock()
        lineBuffer.removeAll()
        recentLines.removeAll()
        isReady = false
        exitStatus = nil
        lock.unlock()
        while readySignal.wait(timeout: .now()) == .success {}  // drop leftover signals

        let child = Process()
        child.executableURL = executable
        child.arguments = [paths.config.path]
        let output = Pipe()
        child.standardOutput = output
        child.standardError = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.consume(data)
        }
        child.terminationHandler = { [weak self] finished in
            self?.didExit(finished)
        }

        // Assigned before run() so an instant crash is still noticed by didExit.
        lock.lock(); process = child; lock.unlock()
        do {
            try child.run()
        } catch {
            lock.lock(); process = nil; lock.unlock()
            throw SunshineError.startFailed(error.localizedDescription)
        }
        try? "\(child.processIdentifier)".write(to: paths.pid, atomically: true, encoding: .utf8)

        let result = readySignal.wait(timeout: .now() + 15)

        lock.lock()
        let status = exitStatus
        let ready = isReady
        let tail = recentLines.suffix(3).joined(separator: " | ")
        lock.unlock()

        if let status {
            throw SunshineError.startFailed("It stopped right away (code \(status)). \(tail)")
        }
        if result == .timedOut || !ready {
            stop()
            throw SunshineError.startFailed("It did not become ready in time. \(tail)")
        }
    }

    /// Stops Sunshine if it is running. Safe to call twice.
    func stop() {
        lock.lock()
        let child = process
        process = nil  // cleared first so the termination handler knows this exit is expected
        lock.unlock()

        if let child {
            if child.isRunning {
                child.terminate()  // SIGTERM: Sunshine shuts down cleanly
                for _ in 0..<80 where child.isRunning {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if child.isRunning {
                    kill(child.processIdentifier, SIGKILL)
                    child.waitUntilExit()
                }
            }
        }
        reapStaleProcess()
        try? FileManager.default.removeItem(at: paths.pid)
    }

    /// If the app was killed (for example by Xcode's Stop button) the old Sunshine can survive
    /// and keep the ports busy. Only a process whose name matches our binary is touched.
    private func reapStaleProcess() {
        guard let text = try? String(contentsOf: paths.pid, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 1
        else { return }

        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        let name = length > 0 ? URL(fileURLWithPath: String(cString: buffer)).lastPathComponent : ""
        if name.caseInsensitiveCompare(executable.lastPathComponent) == .orderedSame {
            kill(pid, SIGTERM)
            for _ in 0..<60 where kill(pid, 0) == 0 {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
        try? FileManager.default.removeItem(at: paths.pid)
    }

    // MARK: - Config and login

    /// Removes duplicate paired device certificates from `sunshine_state.json`.
    /// Sunshine's `is_client_enabled` fails with "Client certificate identity is not enabled"
    /// if more than one entry in `named_devices` has the exact same certificate.
    @discardableResult
    func sanitizeStateFile() -> Bool {
        guard FileManager.default.fileExists(atPath: paths.state.path),
              let data = try? Data(contentsOf: paths.state),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var root = json["root"] as? [String: Any],
              let devices = root["named_devices"] as? [[String: Any]]
        else { return false }

        var seenCerts = Set<String>()
        var deduplicated: [[String: Any]] = []
        var modified = false

        for device in devices {
            if let cert = device["cert"] as? String {
                let trimmed = cert.trimmingCharacters(in: .whitespacesAndNewlines)
                if seenCerts.insert(trimmed).inserted {
                    var cleanDevice = device
                    // Sunshine's C++ state serializer expects "enabled" as a boolean (bool enabled = true)
                    let isEnabled = (cleanDevice["enabled"] as? Bool == true) ||
                                    (cleanDevice["enabled"] as? String == "true") ||
                                    (cleanDevice["enabled"] == nil)
                    if cleanDevice["enabled"] as? Bool != isEnabled {
                        cleanDevice["enabled"] = isEnabled
                        modified = true
                    }
                    deduplicated.append(cleanDevice)
                } else {
                    modified = true
                }
            } else {
                deduplicated.append(device)
            }
        }

        if modified || deduplicated.count != devices.count {
            root["named_devices"] = deduplicated
            json["root"] = root
            if let output = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) {
                try? output.write(to: paths.state, options: .atomic)
            }
            return true
        }
        return false
    }

    private func writeConfig(displayID: CGDirectDisplayID, streamAudio: Bool) throws {
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)

        let audioSetting = streamAudio ? "enabled" : "disabled"
        let config = """
        output_name = \(displayID)
        min_log_level = info
        origin_web_ui_allowed = pc
        platform = macos
        system_tray = disabled
        resolutions = [2048x1536, 1536x2048, 1600x1200, 1200x1600, 1024x768, 768x1024]
        fps = [30, 60]
        vt_software = allowed
        stream_audio = \(audioSetting)

        file_state = \(paths.state.path)
        credentials_file = \(paths.credentials.path)
        pkey = \(paths.privateKey.path)
        cert = \(paths.certificate.path)
        log_path = \(paths.log.path)
        file_apps = \(paths.apps.path)

        """
        try config.write(to: paths.config, atomically: true, encoding: .utf8)

        if !FileManager.default.fileExists(atPath: paths.apps.path) {
            let apps = #"{"env":{},"apps":[{"name":"Desktop"}]}"#
            try apps.write(to: paths.apps, atomically: true, encoding: .utf8)
        }
    }

    /// Loads (or creates) the random API login and makes sure Sunshine knows it.
    private func ensureLogin() throws -> Login {
        lock.lock()
        if let cachedLogin, FileManager.default.fileExists(atPath: paths.credentials.path) {
            lock.unlock()
            return cachedLogin
        }
        lock.unlock()

        let login: Login
        var created = false
        if let data = try? Data(contentsOf: paths.apiLogin),
           let existing = try? JSONDecoder().decode(Login.self, from: data) {
            login = existing
        } else {
            let alphabet = Array("abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
            let password = String((0..<32).map { _ in alphabet.randomElement()! } )
            login = Login(username: "ipad-display", password: password)
            let data = try JSONEncoder().encode(login)
            // Created with owner-only permissions from the start.
            guard FileManager.default.createFile(atPath: paths.apiLogin.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw SunshineError.credentialSetupFailed
            }
            created = true
        }

        if created || !FileManager.default.fileExists(atPath: paths.credentials.path) {
            let tool = Process()
            tool.executableURL = executable
            tool.arguments = [paths.config.path, "--creds", login.username, login.password]
            tool.standardOutput = FileHandle.nullDevice
            tool.standardError = FileHandle.nullDevice
            do {
                try tool.run()
                tool.waitUntilExit()
            } catch {
                throw SunshineError.credentialSetupFailed
            }
            guard tool.terminationStatus == 0, FileManager.default.fileExists(atPath: paths.credentials.path) else {
                throw SunshineError.credentialSetupFailed
            }
        }

        lock.lock(); cachedLogin = login; lock.unlock()
        return login
    }

    // MARK: - Reading Sunshine's output

    private func consume(_ data: Data) {
        var lines: [String] = []
        lock.lock()
        lineBuffer.append(data)
        while let newline = lineBuffer.firstIndex(of: 0x0A) {
            lines.append(String(decoding: lineBuffer[lineBuffer.startIndex..<newline], as: UTF8.self))
            lineBuffer.removeSubrange(lineBuffer.startIndex...newline)
        }
        recentLines.append(contentsOf: lines)
        if recentLines.count > 30 {
            recentLines.removeFirst(recentLines.count - 30)
        }
        lock.unlock()

        for line in lines {
            handleLine(line)
        }
    }

    private func handleLine(_ line: String) {
        if line.contains("Configuration UI available") {
            var port = 47990
            if let range = line.range(of: #":(\d{2,5})\]"#, options: .regularExpression),
               let parsed = Int(line[range].dropFirst().dropLast()) {
                port = parsed
            }
            lock.lock(); apiPort = port; isReady = true; lock.unlock()
            readySignal.signal()
            onEvent?(.ready(port: port))
        } else if line.contains("CLIENT DISCONNECTED") {
            onEvent?(.clientDisconnected)
        } else if line.contains("CLIENT CONNECTED") {
            onEvent?(.clientConnected)
        }
    }

    private func didExit(_ finished: Process) {
        lock.lock()
        let unexpected = (process === finished)
        if unexpected {
            process = nil
            exitStatus = finished.terminationStatus
        }
        lock.unlock()
        guard unexpected else { return }  // stop() already cleared `process`
        readySignal.signal()  // unblocks start() if it was still waiting
        onEvent?(.exited(status: finished.terminationStatus))
    }

    // MARK: - Pairing through Sunshine's local API

    func pendingPairings() async throws -> [Pairing] {
        nonisolated struct Response: Decodable { let pairings: [Pairing] }
        let data = try await request(path: "/api/pin", method: "GET", body: nil, timeout: 10)
        return try JSONDecoder().decode(Response.self, from: data).pairings
    }

    /// Blocks (up to about a minute) while Moonlight finishes its side of the handshake.
    func submitPIN(pairingID: String, pin: String, name: String) async throws -> Bool {
        nonisolated struct Body: Encodable { let pairing_id: String; let pin: String; let name: String }
        nonisolated struct Response: Decodable { let status: Bool }
        let body = try JSONEncoder().encode(Body(pairing_id: pairingID, pin: pin, name: name))
        let data = try await request(path: "/api/pin", method: "POST", body: body, timeout: 70)
        let success = try JSONDecoder().decode(Response.self, from: data).status
        if success {
            sanitizeStateFile()
        }
        return success
    }

    func unpairAll() async throws {
        _ = try? await request(path: "/api/clients/unpair-all", method: "POST", body: nil, timeout: 5)
        // Ensure state file on disk is completely wiped of paired clients
        if FileManager.default.fileExists(atPath: paths.state.path),
           let data = try? Data(contentsOf: paths.state),
           var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           var root = json["root"] as? [String: Any] {
            root["named_devices"] = []
            json["root"] = root
            if let output = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) {
                try? output.write(to: paths.state, options: .atomic)
            }
        }
    }

    private static func preparePatchedSunshine(in supportDirectory: URL) -> URL? {
        let appBundle = supportDirectory.appendingPathComponent("Sunshine.app")
        let binary = appBundle.appendingPathComponent("Contents/MacOS/Sunshine")
        let fileManager = FileManager.default

        if !fileManager.fileExists(atPath: binary.path) {
            guard let sourceApp = [
                "/Applications/Sunshine.app",
                fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Sunshine.app").path
            ].first(where: { fileManager.fileExists(atPath: $0) }) else {
                return nil
            }
            try? fileManager.removeItem(at: appBundle)
            do {
                try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
                try fileManager.copyItem(at: URL(fileURLWithPath: sourceApp), to: appBundle)
                let xattr = Process()
                xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
                xattr.arguments = ["-cr", appBundle.path]
                try? xattr.run()
                xattr.waitUntilExit()
            } catch {
                return nil
            }
        }

        // Apply dual-audio unmuting patches to ensure host Mac speakers are never muted when streaming
        if let handle = try? FileHandle(forUpdating: binary) {
            defer { try? handle.close() }
            var modified = false
            let patches: [(offset: UInt64, original: [UInt8], patched: [UInt8])] = [
                // nvhttp::make_launch_session: force host_audio = true (mov w22, #1)
                (0x7064c, [0xf6, 0x03, 0x00, 0xaa], [0x22, 0x00, 0x80, 0x52]),
                // createSystemTapDescriptionForChannels: nop out cbz to muted tap branch
                (0x1ad1b0, [0x80, 0x05, 0x00, 0x34], [0x1f, 0x20, 0x03, 0xd5]),
                // createSystemTapDescriptionForChannels: force CATapUnmuted (0) instead of CATapMutedWhenTapped (1)
                (0x1ad264, [0x22, 0x00, 0x80, 0x52], [0x02, 0x00, 0x80, 0x52])
            ]
            for patch in patches {
                try? handle.seek(toOffset: patch.offset)
                if let current = try? handle.read(upToCount: patch.original.count), current == Data(patch.original) {
                    try? handle.seek(toOffset: patch.offset)
                    try? handle.write(contentsOf: patch.patched)
                    modified = true
                }
            }
            if modified {
                try? handle.synchronize()
                let codesign = Process()
                codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
                codesign.arguments = ["--force", "-s", "-", binary.path]
                try? codesign.run()
                codesign.waitUntilExit()
            }
        }

        return fileManager.isExecutableFile(atPath: binary.path) ? binary : nil
    }

    private func request(path: String, method: String, body: Data?, timeout: TimeInterval) async throws -> Data {
        let (running, port) = lock.withLock {
            (process != nil, apiPort)
        }
        guard running else { throw SunshineError.startFailed("It is not running.") }
        let login = try ensureLogin()

        var request = URLRequest(url: URL(string: "https://127.0.0.1:\(port)\(path)")!, timeoutInterval: timeout)
        request.httpMethod = method
        let token = Data("\(login.username):\(login.password)".utf8).base64EncodedString()
        request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SunshineError.http(0) }
        guard (200..<300).contains(http.statusCode) else { throw SunshineError.http(http.statusCode) }
        return data
    }
}

/// Sunshine's API uses a self-signed certificate. Trust is granted only for this Mac's own
/// loopback address, never for any other host.
private final class LocalTrustDelegate: NSObject, URLSessionDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust,
           challenge.protectionSpace.host == "127.0.0.1" {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
