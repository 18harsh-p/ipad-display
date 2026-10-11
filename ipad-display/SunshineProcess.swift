// SunshineProcess.swift
//
// Runs the bundled, stripped-down Sunshine as a child process and talks to it.
//
//  * Everything Sunshine writes lives in ~/.config/ipad-display (its own config, state, keys,
//    log), so it never touches an existing Sunshine install in ~/.config/sunshine. The path has
//    no spaces on purpose, because Sunshine's config file does not support quoting.
//  * Sunshine's local HTTPS API (port 47990 by default) is limited to this Mac
//    (origin_web_ui_allowed = pc) and protected with a random password kept in a 0600 file.
//  * State comes from Sunshine's console output: "Configuration UI available" means ready,
//    "CLIENT CONNECTED" / "CLIENT DISCONNECTED" mean the iPad came or went. If a future
//    Sunshine changes those texts, state reporting degrades but streaming still works.
//
// start() and stop() block, so call them from the backend's serial queue.

import CoreGraphics
import Darwin
import Foundation

enum SunshineEvent {
    case ready(port: Int)
    case clientConnected
    case clientDisconnected
    case exited(status: Int32)
}

enum SunshineError: LocalizedError {
    case binaryNotFound
    case credentialSetupFailed
    case startFailed(String)
    case noPendingPairing
    case pairingRejected
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "The streaming engine (sunshine) is missing from the app."
        case .credentialSetupFailed:
            return "Could not set up the streaming engine's local login."
        case .startFailed(let detail):
            return "The streaming engine did not start. \(detail)"
        case .noPendingPairing:
            return "No pairing request found. On the iPad open Moonlight, tap this Mac, wait for the PIN to appear, then try again."
        case .pairingRejected:
            return "Pairing failed. Check the PIN and try again."
        case .http(let code):
            return "The streaming engine answered with error \(code)."
        }
    }
}

struct SunshinePaths {
    let root: URL
    var config: URL { root.appendingPathComponent("sunshine.conf") }
    var state: URL { root.appendingPathComponent("sunshine_state.json") }
    var credentials: URL { root.appendingPathComponent("sunshine_credentials.json") }
    var privateKey: URL { root.appendingPathComponent("cakey.pem") }
    var certificate: URL { root.appendingPathComponent("cacert.pem") }
    var log: URL { root.appendingPathComponent("sunshine.log") }
    var apps: URL { root.appendingPathComponent("apps.json") }
    var apiLogin: URL { root.appendingPathComponent("api-login.json") }
    var pid: URL { root.appendingPathComponent("sunshine.pid") }
}

final class SunshineProcess {
    struct Pairing: Decodable {
        let id: String
        let name: String
        let address: String
    }

    private struct Login: Codable {
        let username: String
        let password: String
    }

    /// Called on a background queue.
    var onEvent: ((SunshineEvent) -> Void)?

    private let paths: SunshinePaths
    private let executable: URL
    private let lock = NSLock()
    private let readySignal = DispatchSemaphore(value: 0)
    private lazy var session = URLSession(configuration: .ephemeral, delegate: LocalTrustDelegate(), delegateQueue: nil)

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
    }

    // MARK: - Start and stop

    /// Writes the config, starts Sunshine for the given display and blocks until it reports ready.
    func start(displayID: CGDirectDisplayID) throws {
        stop()
        reapStaleProcess()

        try writeConfig(displayID: displayID)
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
        guard let child else { return }

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

        for device in devices {
            if let cert = device["cert"] as? String {
                let trimmed = cert.trimmingCharacters(in: .whitespacesAndNewlines)
                if seenCerts.insert(trimmed).inserted {
                    var cleanDevice = device
                    cleanDevice["enabled"] = "true"
                    deduplicated.append(cleanDevice)
                }
            } else {
                deduplicated.append(device)
            }
        }

        if deduplicated.count != devices.count {
            root["named_devices"] = deduplicated
            json["root"] = root
            if let output = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) {
                try? output.write(to: paths.state, options: .atomic)
            }
            return true
        }
        return false
    }

    private func writeConfig(displayID: CGDirectDisplayID) throws {
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)

        let config = """
        sunshine_name = iPad Display
        min_log_level = info
        origin_web_ui_allowed = pc
        system_tray = disabled
        vt_software = allowed
        output_name = \(displayID)
        fps = [30, 60]
        resolutions = [2048x1536, 1536x2048, 1600x1200, 1200x1600, 1024x768, 768x1024]
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
            let password = String((0..<32).map { _ in alphabet.randomElement()! })
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
        lock.unlock()
        for line in lines { handle(line: line) }
    }

    private func handle(line: String) {
        lock.lock()
        recentLines.append(line)
        if recentLines.count > 30 { recentLines.removeFirst() }
        lock.unlock()

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
        struct Response: Decodable { let pairings: [Pairing] }
        let data = try await request(path: "/api/pin", method: "GET", body: nil, timeout: 10)
        return try JSONDecoder().decode(Response.self, from: data).pairings
    }

    /// Blocks (up to about a minute) while Moonlight finishes its side of the handshake.
    func submitPIN(pairingID: String, pin: String, name: String) async throws -> Bool {
        struct Body: Encodable { let pairing_id: String; let pin: String; let name: String }
        struct Response: Decodable { let status: Bool }
        let body = try JSONEncoder().encode(Body(pairing_id: pairingID, pin: pin, name: name))
        let data = try await request(path: "/api/pin", method: "POST", body: body, timeout: 70)
        let success = try JSONDecoder().decode(Response.self, from: data).status
        if success {
            sanitizeStateFile()
        }
        return success
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
private final class LocalTrustDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           space.host == "127.0.0.1",
           let trust = space.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
