// SPDX-License-Identifier: GPL-3.0-or-later
import UIKit
import BackgroundTasks
import Observation
import Darwin
import CryptoKit

/// Local authenticated client for the local iCTRL v1 protocol. Credentials stay in
/// this app's device-only keychain; no remote endpoint or automatic approval.
@MainActor private enum LocalDeviceControlClient {
    private static let root = URL(string: "http://127.0.0.1:8200")!
    private static let keyService = "com.louis.actell.local-control-acceptance"
    nonisolated private static func mac(_ key: Data, _ data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }
    nonisolated private static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    nonisolated private static func unhex(_ text: String) throws -> Data {
        guard text.count % 2 == 0 else { throw fault(1) }
        let chars = Array(text); var bytes = Data()
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let byte = UInt8(String(chars[i...i+1]), radix: 16) else { throw fault(1) }
            bytes.append(byte)
        }
        return bytes
    }
    nonisolated private static func fault(_ code: Int) -> NSError { NSError(domain: "LocalControlProbe", code: code) }
    nonisolated private static func xor(_ data: Data, key: Data, nonce: Data) -> Data {
        guard !data.isEmpty else { return Data() }
        let signingKey = SymmetricKey(data: key)
        var material = nonce + Data(repeating: 0, count: 4)
        var output = Data(count: data.count)
        output.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) in
            data.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                var offset = 0
                var counter: UInt32 = 0
                while offset < data.count {
                    material.withUnsafeMutableBytes { (block: UnsafeMutableRawBufferPointer) in
                        let base = nonce.count
                        block[base] = UInt8(truncatingIfNeeded: counter >> 24)
                        block[base + 1] = UInt8(truncatingIfNeeded: counter >> 16)
                        block[base + 2] = UInt8(truncatingIfNeeded: counter >> 8)
                        block[base + 3] = UInt8(truncatingIfNeeded: counter)
                    }
                    let pad = HMAC<SHA256>.authenticationCode(for: material, using: signingKey)
                    let count = min(32, data.count - offset)
                    pad.withUnsafeBytes { (mask: UnsafeRawBufferPointer) in
                        for index in 0..<count { destination[offset + index] = source[offset + index] ^ mask[index] }
                    }
                    offset += count; counter &+= 1
                }
            }
        }
        return output
    }
    static func request(_ path: String, body: [String: Any]? = nil, timeout: TimeInterval? = nil) async throws -> [String: Any] {
        var req = URLRequest(url: root.appendingPathComponent(path)); req.timeoutInterval = timeout ?? (path == "pair" ? 110 : 20)
        if let body {
            req.httpMethod = "POST"; req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw fault((response as? HTTPURLResponse)?.statusCode ?? 2) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw fault(3) }
        return json
    }
    static func savedKey() -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keyService, kSecAttrAccount as String: "local-runner"]
        var found: CFTypeRef?
        if SecItemCopyMatching(query.merging([kSecReturnData as String: true]) { _, b in b } as CFDictionary, &found) == errSecSuccess,
           let data = found as? Data, data.count == 32 { return data }
        return nil
    }
    static func key() async throws -> Data {
        if let data = savedKey() { return data }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keyService, kSecAttrAccount as String: "local-runner"]
        let response = try await request("pair", body: ["client_name": "Louis on this iPhone", "plain": true])
        guard let token = response["token"] as? String else { throw fault(4) }
        let data = try unhex(token); guard data.count == 32 else { throw fault(4) }
        var item = query; item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw fault(Int(status)) }
        return data
    }
    static func rpc(_ method: String, _ params: [String: Any] = [:], key: Data) async throws -> [String: Any] {
        var nonceBytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, 16, &nonceBytes) == errSecSuccess else { throw fault(5) }
        let nonce = Data(nonceBytes), tok = Data(SHA256.hash(data: key)).prefix(4)
        let ts = UInt64(Date().timeIntervalSince1970); var be = ts.bigEndian
        let payload = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method, "params": params])
        let cipher = xor(payload, key: mac(key, Data("ictrl-v1|enc-req".utf8) + nonce), nonce: nonce)
        let kMac = mac(key, Data("ictrl-v1|mac".utf8) + nonce)
        let signed = Data("v1".utf8) + tok + Data(bytes: &be, count: 8) + nonce + cipher
        let response = try await request("rpc", body: ["v": 1, "tok": hex(tok), "ts": ts, "nonce": hex(nonce), "ct": cipher.base64EncodedString(), "tag": hex(mac(kMac, signed))])
        guard let text = response["ct"] as? String, let bytes = Data(base64Encoded: text), let tagText = response["tag"] as? String else { throw fault(6) }
        let tag = try unhex(tagText)
        // Large screenshot decryption must not block the UI actor.
        let plain = try await Task.detached(priority: .userInitiated) {
            guard HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: Data("resp".utf8) + nonce + bytes, using: SymmetricKey(data: kMac)) else { throw fault(7) }
            return xor(bytes, key: mac(key, Data("ictrl-v1|enc-resp".utf8) + nonce), nonce: nonce)
        }.value
        try Task.checkCancellation()
        guard let json = try JSONSerialization.jsonObject(with: plain) as? [String: Any] else { throw fault(8) }
        guard json["error"] == nil, let result = json["result"] as? [String: Any] else { throw NSError(domain: "LocalControlRPC", code: (json["error"] as? [String: Any])?["code"] as? Int ?? 9) }
        return result
    }
    #if DEBUG
    static func run() async {
        let file = URL.documentsDirectory.appending(path: "local-xctest-acceptance.txt")
        var lines: [String] = []
        func record(_ line: String) {
            lines.append("\(Date().ISO8601Format()) \(line)")
            try? lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        }
        record("start endpoint=127.0.0.1:8200")
        do {
            _ = try await request("whoami"); record("local HTTP reachable; waiting for on-device pairing approval if needed")
            let credential = try await key(); record("paired; key retained only in device keychain")
            _ = try await rpc("device_info", key: credential); record("device_info succeeded")
            for i in 0..<12 {
                try Task.checkCancellation()
                let before = ContinuousClock.now
                let frame = try await rpc("screenshot", ["scale": 0.5, "format": "jpeg", "quality": 0.5], key: credential)
                guard let encoded = frame["data"] as? String, let bytes = Data(base64Encoded: encoded), let image = UIImage(data: bytes), let cg = image.cgImage else { throw fault(10) }
                if i == 0 || i == 11 { try bytes.write(to: URL.documentsDirectory.appending(path: "local-xctest-frame-\(i).jpg")) }
                record("frame=\(i) \(cg.width)x\(cg.height) bytes=\(bytes.count) elapsed=\(before.duration(to: .now)) background=\(UIApplication.shared.applicationState == .background)")
                try await Task.sleep(for: .seconds(10))
            }
            record("complete")
        } catch { let e = error as NSError; record("failed domain=\(e.domain) code=\(e.code)") }
    }
    #endif
}

/// Adapts the authenticated on-device runner to the same session and action gates
/// as CoreDevice. A failed mutation is never retried: its effect may be unknown.
/// Development-build restoration after XCTest returns focus to SpringBoard.
/// This only opens our own app; it never restores/replays a device input.
@MainActor private enum LocalClientActivation {
    static func restore() async {
        guard UIApplication.shared.isProtectedDataAvailable else { return }
        try? await Task.sleep(for: .milliseconds(350))
        if UIApplication.shared.applicationState == .active { return }
        let opened: Bool = {
            guard let type = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type,
                  let workspace = type.perform(NSSelectorFromString("defaultWorkspace"))?.takeUnretainedValue() as? NSObject else { return false }
            let selector = NSSelectorFromString("openApplicationWithBundleID:")
            guard workspace.responds(to: selector), let implementation = workspace.method(for: selector),
                  let bundle = Bundle.main.bundleIdentifier else { return false }
            typealias Open = @convention(c) (AnyObject, Selector, NSString) -> Bool
            return unsafeBitCast(implementation, to: Open.self)(workspace, selector, bundle as NSString)
        }()
        BackgroundExecutionTrace.record("control.clientRestore requested=\(opened)")
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while UIApplication.shared.applicationState != .active, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        BackgroundExecutionTrace.record("control.clientRestore active=\(UIApplication.shared.applicationState == .active)")
    }
}

@MainActor final class PhoneControlServices {
    private let native = NativeDeveloperServices()
    private var credential: Data?
    private var epoch = UUID()
    private var localGeometryToken: String?
    private var localScreenshotScale = 3.0
    private var restoreClientAfterStop = false
    var capturedVideoGeometryToken: String? { credential == nil ? native.capturedVideoGeometryToken : localGeometryToken }
    var usesLocalRunner: Bool { credential != nil }
    var videoSnapshotDiagnostics: String? { credential == nil ? native.videoSnapshotDiagnostics : nil }
    func close(stopRunner: Bool = false) {
        if stopRunner, let key = credential, pendingStop == nil {
            let restore = restoreClientAfterStop
            pendingStop = Task { try? await Self.stopRunner(key: key, restoreClient: restore) }
        }
        epoch = UUID(); credential = nil; localGeometryToken = nil; native.close()
    }
    private var pendingStop: Task<Void, Never>?
    private static func stopRunner(key: Data, restoreClient: Bool = false) async throws {
        // Never pair just to stop a service, and never retry a stop mutation.
        guard (try? await LocalDeviceControlClient.request("whoami", timeout: 1)) != nil else { return }
        _ = try await LocalDeviceControlClient.rpc("config", ["stop_server": true], key: key)
        for _ in 0..<15 {
            try await Task.sleep(for: .milliseconds(200))
            if (try? await LocalDeviceControlClient.request("whoami", timeout: 1)) == nil {
                if restoreClient { await LocalClientActivation.restore() }
                return
            }
        }
        throw NativeBackendError.protocolFailure(stage: 12, cause: 2)
    }
    func stopIdleLocalRunner() {
        guard pendingStop == nil, let key = LocalDeviceControlClient.savedKey() else { return }
        pendingStop = Task { try? await Self.stopRunner(key: key) }
    }
    func connectLocalXCTest() async throws {
        await pendingStop?.value; pendingStop = nil
        let current = epoch
        let wasForeground = UIApplication.shared.applicationState != .background
        var launched = false
        defer { if launched && credential == nil { stopIdleLocalRunner() } }
        if (try? await LocalDeviceControlClient.request("whoami", timeout: 1)) == nil {
            guard let url = URL(string: "louislocalcontrol://start"), await UIApplication.shared.open(url) else {
                throw CoreDeviceControlError.unavailable(String(localized: "Open Louis to start phone control, then retry the task."))
            }
            launched = true
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            while (try? await LocalDeviceControlClient.request("whoami", timeout: 1)) == nil {
                try Task.checkCancellation()
                guard epoch == current, ContinuousClock.now < deadline else { throw NativeBackendError.closed }
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        let key = try await LocalDeviceControlClient.key()
        let geometry = try await LocalDeviceControlClient.rpc("louis_geometry", key: key)
        if let scale = geometry["scale"] as? Double, scale.isFinite, scale >= 1, scale <= 3 { localScreenshotScale = scale }
        try Task.checkCancellation()
        guard current == epoch else { throw NativeBackendError.closed }
        credential = key
        restoreClientAfterStop = wasForeground
        if launched && wasForeground {
            // Opening the service temporarily leaves Louis. Return once, using
            // the now authenticated service; this never replays task input.
            _ = try await call("launch_app", ["bundle_id": Bundle.main.bundleIdentifier!, "fast": true, "settle": false], mutation: true)
            let foregroundDeadline = ContinuousClock.now.advanced(by: .seconds(3))
            while UIApplication.shared.applicationState != .active, ContinuousClock.now < foregroundDeadline {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }
    func connectLocalVPN(identity: AuthorizedRemoteIdentity, authorization: ExistingSessionAuthorization,
                         pairingPort: UInt16, configuration: VPNLoopbackConfiguration) async throws {
        try await native.connectLocalVPN(identity: identity, authorization: authorization, pairingPort: pairingPort, configuration: configuration)
    }
    func connect(identity: AuthorizedRemoteIdentity, authorization: ExistingSessionAuthorization,
                 discovery: DiagnosticReply, endpoint: DiagnosticReply.Endpoint) async throws {
        try await native.connect(identity: identity, authorization: authorization, discovery: discovery, endpoint: endpoint)
    }
    private func call(_ method: String, _ params: [String: Any] = [:], mutation: Bool = false) async throws -> [String: Any] {
        guard let credential else { throw NativeBackendError.closed }
        try Task.checkCancellation()
        let current = epoch
        let timingStart = DispatchTime.now().uptimeNanoseconds, timingID = UUID()
        var timingOK = false
        defer { LLMDiagnostics.timing("local." + method, attempt: timingID, started: timingStart, succeeded: timingOK) }
        do {
            let result = try await LocalDeviceControlClient.rpc(method, params, key: credential)
            timingOK = true
            guard current == epoch else { throw NativeBackendError.closed }
            return result
        } catch {
            // The runner checks the display token before submitting an event.
            if (error as NSError).domain == "LocalControlRPC", (error as NSError).code == -32091 {
                throw NativeInputGeometryError(.generationChanged)
            }
            if mutation { throw NativeBackendError.protocolFailure(stage: 11, cause: 7) }
            throw error
        }
    }
    func checkDeveloperReadiness() async throws {
        if credential != nil { _ = try await call("louis_geometry") }
        else { try await native.checkDeveloperReadiness() }
    }
    func startTouchMedia() async throws { if credential == nil { try await native.startTouchMedia() } }
    func stopTouchMedia() async throws {
        if let credential { try await Self.stopRunner(key: credential, restoreClient: restoreClientAfterStop) }
        else { try await native.stopTouchMedia() }
    }
    func cryptexInstalled() async throws -> [String: Any] { try await native.cryptexInstalled() }
    func installDeveloperCryptex(directory: String) async throws { try await native.installDeveloperCryptex(directory: directory) }
    #if DEBUG
    func videoDiagnosticKeyframe() async -> Data? { credential == nil ? await native.videoDiagnosticKeyframe() : nil }
    #endif
    private func token(_ remote: String) -> String { "\(epoch.uuidString)|\(remote)" }
    private func geometry() async throws -> (token: String, width: Double, height: Double) {
        let value = try await call("louis_geometry")
        guard let remote = value["token"] as? String, !remote.isEmpty,
              let w = value["width"] as? Double, let h = value["height"] as? Double,
              w.isFinite, h.isFinite, w > 1, h > 1 else { throw NativeInputGeometryError(.metadataInvalid) }
        return (token(remote), w, h)
    }
    func inputDisplayGeometry() async throws -> String {
        if credential == nil { return try await native.inputDisplayGeometry() }
        return try await geometry().token
    }
    func validateVideoGeometry(_ expected: String) async throws {
        if credential == nil { try await native.validateVideoGeometry(expected); return }
        guard try await geometry().token == expected else { throw NativeInputGeometryError(.generationChanged) }
    }
    func captureVideoJPEG() async throws -> Data {
        if credential == nil { return try await native.captureVideoJPEG() }
        localGeometryToken = nil
        let frame = try await call("screenshot", ["scale": localScreenshotScale, "format": "jpeg", "quality": 0.9])
        guard let encoded = frame["data"] as? String, let bytes = Data(base64Encoded: encoded),
              UIImage(data: bytes) != nil, let remote = frame["louis_geometry"] as? String else {
            throw NativeBackendError.screenshotFailure(stage: 9, cause: 1)
        }
        // The runner atomically checks orientation and bounds around capture.
        // Input validates this same token again at dispatch; another read-only
        // RPC here adds latency without making a screenshot more current.
        localGeometryToken = token(remote)
        return bytes
    }
    private func inputGeometry(_ expected: String?) async throws -> (remote: String, width: Double, height: Double) {
        if let expected {
            let prefix = epoch.uuidString + "|"
            guard expected.hasPrefix(prefix) else { throw NativeInputGeometryError(.generationChanged) }
            let remote = String(expected.dropFirst(prefix.count))
            let fields = remote.split(separator: ":")
            guard fields.count == 4, UUID(uuidString: String(fields[0])) != nil,
                  let w = Double(fields[2]), let h = Double(fields[3]),
                  w.isFinite, h.isFinite, w > 1, h > 1, w <= 16384, h <= 16384 else {
                throw NativeInputGeometryError(.invalidToken)
            }
            // The runner compares the entire token immediately before an event.
            return (remote, w, h)
        }
        let g = try await geometry()
        guard let separator = g.token.firstIndex(of: "|") else { throw NativeInputGeometryError(.invalidToken) }
        return (String(g.token[g.token.index(after: separator)...]), g.width, g.height)
    }
    private func point(_ normalized: UInt16, _ extent: Double) -> Double {
        min(extent - 1, Double(normalized) / 65535 * extent)
    }
    func tapDelivery(x: UInt16, y: UInt16, geometryToken: String? = nil) async throws -> InputDelivery {
        if credential == nil { return try await native.tapDelivery(x: x, y: y, geometryToken: geometryToken) }
        let g = try await inputGeometry(geometryToken)
        _ = try await call("tap", ["x": point(x, g.width), "y": point(y, g.height), "fast": true, "settle": false,
                                    "louis_geometry": g.remote], mutation: true)
        return .reportsWrittenVisualEffectUnverified
    }
    func dragDelivery(fromX: UInt16, fromY: UInt16, toX: UInt16, toY: UInt16, durationMS: UInt16,
                      geometryToken: String? = nil) async throws -> InputDelivery {
        if credential == nil { return try await native.dragDelivery(fromX: fromX, fromY: fromY, toX: toX, toY: toY, durationMS: durationMS, geometryToken: geometryToken) }
        let g = try await inputGeometry(geometryToken)
        _ = try await call("drag", ["from_x": point(fromX, g.width), "from_y": point(fromY, g.height),
            "to_x": point(toX, g.width), "to_y": point(toY, g.height), "duration": Double(durationMS) / 1000,
            "fast": true, "settle": false, "louis_geometry": g.remote], mutation: true)
        return .reportsWrittenVisualEffectUnverified
    }
    func home() async throws {
        if credential == nil { try await native.home(); return }
        _ = try await call("home", ["settle": false], mutation: true)
    }
    func typeText(_ text: String) async throws {
        if credential == nil { try await native.typeText(text); return }
        _ = try await call("type", ["text": text, "settle": false], mutation: true)
    }
    func launchApplication(bundleID: String, arguments: [String]) async throws {
        if credential == nil { try await native.launchApplication(bundleID: bundleID, arguments: arguments); return }
        guard arguments.isEmpty else { throw NativeBackendError.protocolFailure(stage: 21, cause: 3) }
        _ = try await call("launch_app", ["bundle_id": bundleID, "settle": false], mutation: true)
    }
    func installedApplications() async throws -> Data {
        if credential == nil { return try await native.installedApplications() }
        let result = try await call("list_apps", ["element_type": "all"])
        guard let apps = result["apps"] as? [[String: Any]] else { throw NativeBackendError.applicationQueryFailure(stage: 21, cause: 1) }
        return try JSONSerialization.data(withJSONObject: apps)
    }
}


enum CoreDeviceControlError: Error { case unavailable(String), stopped }

/// Downloads and caches the on-device cryptex DDI bundle (~17 MB total) used by
/// `Session::install_developer_cryptex`. Source: doronz88/DeveloperDiskImage —
/// the same file set StikDebug uses for its on-device DDI step. One-time
/// download; cached under Documents/DDI. Lives in this file (not its own) so it
/// stays inside the Xcode target without project-file edits.
struct DDICryptexStore {
    static let shared = DDICryptexStore()

    private var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DDI", isDirectory: true)
    }

    private static let files: [(name: String, urlString: String)] = [
        ("BuildManifest.plist", "https://raw.githubusercontent.com/doronz88/DeveloperDiskImage/main/PersonalizedImages/Xcode_iOS_DDI_Cryptex/BuildManifest.plist"),
        ("Image.dmg", "https://raw.githubusercontent.com/doronz88/DeveloperDiskImage/main/PersonalizedImages/Xcode_iOS_DDI_Cryptex/Image.dmg"),
        ("Image.dmg.trustcache", "https://raw.githubusercontent.com/doronz88/DeveloperDiskImage/main/PersonalizedImages/Xcode_iOS_DDI_Cryptex/Image.dmg.trustcache"),
        ("Image.dmg.cryptex_info", "https://raw.githubusercontent.com/doronz88/DeveloperDiskImage/main/PersonalizedImages/Xcode_iOS_DDI_Cryptex/Image.dmg.cryptex_info"),
        ("Image.dmg.root_hash", "https://raw.githubusercontent.com/doronz88/DeveloperDiskImage/main/PersonalizedImages/Xcode_iOS_DDI_Cryptex/Image.dmg.root_hash"),
    ]

    /// Ensures all five DDI files exist locally, downloading missing ones with
    /// one retry per file (GitHub raw connections can be flaky). Returns the
    /// directory path to hand to the cryptex installer.
    func ensureFiles() async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in Self.files {
            let destination = directory.appendingPathComponent(file.name)
            if FileManager.default.fileExists(atPath: destination.path) { continue }
            var lastError: Error?
            for _ in 0..<2 {
                do {
                    try await download(file.urlString, to: destination)
                    lastError = nil
                    break
                } catch { lastError = error }
            }
            if let lastError { throw lastError }
        }
        return directory
    }

    private func download(_ urlString: String, to destination: URL) async throws {
        guard let url = URL(string: urlString) else {
            throw CoreDeviceControlError.unavailable("DDI download URL is invalid.")
        }
        let (temp, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CoreDeviceControlError.unavailable(
                "DDI download failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)).")
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temp, to: destination)
    }
}

/// Coordinates pairing, connection ownership and media lifetime across VPN and NCM routes.
@MainActor @Observable final class DeviceControlCoordinator: NSObject, @preconcurrency NetServiceDelegate {
    static let shared = DeviceControlCoordinator()
    static let taskID = (Bundle.main.bundleIdentifier ?? "com.ja1chen.PhoneAgent") + ".pairing"
    private let pairing = RemotePairingSession()
    private let backend = PhoneControlServices()
    private let client = NCMDiagnosticClient()
    private let localDiscovery = LocalVPNDiscovery()
    private(set) var route: DeviceControlRoute
    private let defaults: UserDefaults
    private static let vpnConfigurationKey = "vpnLoopbackConfiguration"
    private(set) var vpnConfiguration: VPNLoopbackConfiguration
    func saveVPNConfiguration(localAddress: String, peerAddress: String) throws {
        guard canChangeRoute else { throw CoreDeviceControlError.unavailable(String(localized: "Stop the current control task before changing the connection settings")) }
        let configuration = try VPNLoopbackConfiguration(localAddress: localAddress, peerAddress: peerAddress)
        guard configuration != vpnConfiguration else { return }
        cancel()
        vpnConfiguration = configuration
        defaults.set(["localAddress": configuration.localAddress, "peerAddress": configuration.peerAddress], forKey: Self.vpnConfigurationKey)
        lastFailure = nil
        message = String(localized: "Settings saved. Reconnect to use them.")
    }
    var canChangeRoute: Bool { !running && !agentReserved && connectionUsers.isEmpty && !mediaLifetime.stopping }
    @discardableResult func selectRoute(_ selected: DeviceControlRoute) -> Bool {
        guard selected != .localCaptureUSB, canChangeRoute else { return false }
        guard selected != route else { return true }
        cancel()
        route = selected
        hasRecord = store.exists || route == .onDeviceXCTest
        defaults.set(selected.rawValue, forKey: DeviceControlRoute.defaultsKey)
        lastFailure = nil
        message = hasRecord ? String(localized: "Connection method changed. Connect to verify it.") : String(localized: "Complete system pairing first")
        return true
    }
    private let store: RemotePairRecordStore
    private var service: NetService?
    private var generation = UUID()
    private(set) var connectionStopID: UUID? = UUID()
    private(set) var controlSessionID = UUID()
    private var agentOwner: UUID?
    private var connectionUsers: Set<UUID> = []
    private var agentRuns: Set<UUID> = []
    private var agentQueue: [UUID] = []
    private(set) var isBackground = false
    var agentReserved: Bool { !agentRuns.isEmpty || agentOwner != nil }
    private var registeredBackgroundTask = false
    private var mediaStarted = false
    private var mediaUseOwners: Set<UUID> = []
    var mediaStopping: Bool { mediaLifetime.stopping }
    private(set) var mediaRetentionGeneration: UUID? = UUID()
    private let mediaLifetime: ControlMediaLifetime
    private let startMedia: @MainActor (PhoneControlServices) async throws -> Void
    private let stopMedia: @MainActor (PhoneControlServices) async throws -> Void
    private var job: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var heartbeatEpoch = UUID()
    private var maintenanceBusy = false
    private var backgroundTask: BGTask?
    private var operationLease: ExecutionTransitionLease?
    private(set) var capturing = false
    var running = false
    var pairingActive = false
    var lastFailure: String?
    var ready = false
    var hasRecord = false
    var pin: String?
    var message = String(localized: "Complete system pairing first")
    var image: UIImage?
    private(set) var screenshotData: Data?
    var statusText: String {
        if pairingActive { return message }
        if running { return ready ? String(localized: "Processing") : String(localized: "Connecting to \(route.connectionName)") }
        if ready {
            if lastFailure != nil { return String(localized: "The last action did not succeed") }
            return image == nil ? String(localized: "Screenshots and tapping are available") : String(localized: "Screenshot received")
        }
        if hasRecord { return lastFailure == nil ? String(localized: "Paired. You can connect to \(route.connectionName).") : String(localized: "Connection failed. If you revoked permission in Settings, pair again.") }
        return message
    }
    override convenience init() {
        self.init(store: RemotePairRecordStore(url: URL.applicationSupportDirectory.appending(path: "RemotePairing/identity.plist")))
    }
    init(store: RemotePairRecordStore, defaults: UserDefaults = .standard,
         mediaLifetime: ControlMediaLifetime = ControlMediaLifetime(),
         startMedia: @escaping @MainActor (PhoneControlServices) async throws -> Void = { try await $0.startTouchMedia() },
         stopMedia: @escaping @MainActor (PhoneControlServices) async throws -> Void = { try await $0.stopTouchMedia() }) {
        self.mediaLifetime = mediaLifetime; self.startMedia = startMedia; self.stopMedia = stopMedia
        self.store = store; self.defaults = defaults; route = DeviceControlRoute.load(from: defaults)
        let saved = defaults.dictionary(forKey: Self.vpnConfigurationKey) as? [String: String]
        vpnConfiguration = (try? VPNLoopbackConfiguration(localAddress: saved?["localAddress"] ?? VPNLoopbackConfiguration.defaults.localAddress,
            peerAddress: saved?["peerAddress"] ?? VPNLoopbackConfiguration.defaults.peerAddress)) ?? .defaults
        super.init(); hasRecord = store.exists || route == .onDeviceXCTest
    }

    /// User explicitly requests new system authorization, even if a local identity remains.
    func resetPairing() {
        guard !running, !agentReserved else { return }
        cancel()
        do {
            try store.remove(); hasRecord = false; lastFailure = nil; pin = nil
            message = String(localized: "Complete system pairing first")
        } catch {
            hasRecord = store.exists || route == .onDeviceXCTest; message = String(localized: "Could not clear the saved pairing identity. Try again."); lastFailure = message
        }
    }
    func pairAgain() {
        guard !running, !agentReserved else { return }
        resetPairing()
        if !hasRecord { startPairing() }
    }

    func registerBackgroundTask() {
        guard !registeredBackgroundTask else { return }
        if #available(iOS 26.0, *) {
            registeredBackgroundTask = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskID, using: .main) { task in
                Task { @MainActor in
                    guard let continued = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
                    Self.shared.begin(continued)
                }
            }
        }
    }
    func startPairing() {
        guard !running else { return }
        hasRecord = store.exists || route == .onDeviceXCTest
        guard !hasRecord else { message = String(localized: "Connect to \(route.connectionName)"); return }
        guard registeredBackgroundTask else { message = String(localized: "The system pairing task was not registered. Reopen the app."); return }
        guard #available(iOS 26.0, *) else { message = String(localized: "Interactive system pairing needs continued background tasks on iOS 26 or later"); return }
        generation = UUID(); running = true; pairingActive = true; message = String(localized: "Requesting a background task for pairing. Please wait.")
        let request = BGContinuedProcessingTaskRequest(identifier: Self.taskID, title: String(localized: "\(AppIdentity.displayName) pairing"), subtitle: String(localized: "Complete authorization in system Settings"))
        request.strategy = .fail
        do { try BGTaskScheduler.shared.submit(request) }
        catch { running = false; pairingActive = false; message = String(localized: "The system did not allow the background task. Keep the app open and try again.") }
    }
    @available(iOS 26.0, *) private func begin(_ continued: BGContinuedProcessingTask) {
        guard pairingActive, running, job == nil else { continued.setTaskCompleted(success: false); return }
        let epoch = generation
        backgroundTask = continued
        continued.progress.totalUnitCount = 4; continued.progress.completedUnitCount = 1
        continued.expirationHandler = { Task { @MainActor in
            guard Self.shared.generation == epoch else { return }
            Self.shared.cancel()
        } }
        job = Task { @MainActor in
            var success = false
            defer { if generation == epoch { finishPairing(success: success) } }
            do {
                try await pairing.pair(authorized: true, persist: { record in
                    guard self.generation == epoch else { throw CancellationError() }
                    try self.store.save(record); self.hasRecord = true
                }, update: { update in
                    guard self.generation == epoch else { throw CancellationError() }
                    switch update {
                    case .listening(let advertisement):
                        let service = NetService(domain: "local.", type: "_remotepairing-pairable-host._tcp.", name: advertisement.identifier, port: Int32(advertisement.port))
                        service.delegate = self
                        guard service.setTXTRecord(NetService.data(fromTXTRecord: advertisement.txt.mapValues { Data($0.utf8) })) else { throw NativeBackendError.malformedEvent }
                        self.service = service; service.publish()
                        self.message = String(localized: "Preparing system pairing")
                    case .code(let value): self.pin = value; self.message = String(localized: "Enter this PIN on the system pairing page"); continued.progress.completedUnitCount = 2
                    case .persisted(let committed): self.message = committed ? String(localized: "Confirming pairing") : String(localized: "Completing pairing"); continued.progress.completedUnitCount = 3
                    case .completed: self.message = String(localized: "Pairing succeeded. Return to the app and verify the \(route.connectionName) connection."); continued.progress.completedUnitCount = 4
                    }
                })
                success = true
            } catch is CancellationError { guard generation == epoch else { return }; message = String(localized: "Pairing stopped") }
            catch { guard generation == epoch else { return }; message = String(localized: "Pairing did not finish. Check local network access and the system pairing page.") }
        }
    }
    func netServiceDidPublish(_ sender: NetService) {
        guard service === sender else { return }
        message = String(localized: "Open Settings → Privacy & Security → Developer Mode and choose to pair with the app")
    }
    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        guard service === sender else { return }
        cancel(); message = String(localized: "Could not prepare pairing. Check local network access and try again.")
    }
    private func finishPairing(success: Bool) {
        service?.stop(); service = nil; pairing.close(); pin = nil
        backgroundTask?.setTaskCompleted(success: success); backgroundTask = nil
        running = false; pairingActive = false; job = nil; hasRecord = store.exists || route == .onDeviceXCTest
    }
    func cancel() {
        connectionStopID = UUID()
        mediaLifetime.revoke(); mediaUseOwners.removeAll()
        operationLease?.complete(success: false); operationLease = nil
        stopHeartbeat()
        generation = UUID(); controlSessionID = UUID(); agentOwner = nil; agentRuns.removeAll(); agentQueue.removeAll()
        job?.cancel(); pairing.close(); service?.stop(); service = nil
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskID)
        if pairingActive { finishPairing(success: false) }
        backend.close(stopRunner: route == .onDeviceXCTest); client.cancel(); localDiscovery.cancel(); ready = false; mediaStarted = false; image = nil; screenshotData = nil; running = false; capturing = false; job = nil
        message = String(localized: "Stopped")
    }
    func background() {
        isBackground = true
        // App visibility does not revoke an authenticated device session.
        // Active runs own their system execution leases; settings operations
        // own a finite transition lease. Explicit stop/expiry/transport loss
        // still closes the session, without replaying input after reconnect.
    }
    func resume() {
        let wasBackground = isBackground
        isBackground = false
        // Cancelling an in-flight native readiness request closes its transport.
        // Scene transitions may wake an idle heartbeat, never cancel active I/O.
        if ready, wasBackground, !maintenanceBusy { startHeartbeat(immediate: true) }
        restoreConnection()
    }
    func restoreConnection() {
        hasRecord = store.exists || route == .onDeviceXCTest
        if route == .onDeviceXCTest {
            // Foreground transitions must not restart an explicitly stopped runner.
            if !running, !ready, !agentReserved, connectionUsers.isEmpty { backend.stopIdleLocalRunner() }
            return
        }
        if hasRecord, !pairingActive, !running, !ready { verify() }
    }
    /// Called only by a device tool or App startup, never by normal chat.
    /// Concurrent waiters share the same verification job.
    func connectIfNeeded() throws {
        hasRecord = store.exists || route == .onDeviceXCTest
        if ready || pairingActive { return }
        guard hasRecord else { throw CoreDeviceControlError.unavailable(String(localized: "Complete system pairing in Settings → Phone control → Connection and verification first")) }
        if !running && !agentReserved { verify() }
    }
    func verify() {
        guard !running, !agentReserved, store.exists || route == .onDeviceXCTest else { return }
        let previousMaintenance = heartbeatTask
        stopHeartbeat()
        mediaLifetime.revoke()
        generation = UUID(); controlSessionID = UUID(); let epoch = generation
        running = true; ready = false; mediaStarted = false; image = nil; screenshotData = nil; lastFailure = nil; backend.close()
        beginOperationLease(epoch: epoch)
        job = Task { @MainActor in
            defer { if generation == epoch { finishOperationLease(); running = false; job = nil } }
            do {
                await previousMaintenance?.value
                try Task.checkCancellation()
                guard generation == epoch else { return }
                if route == .onDeviceXCTest {
                    message = String(localized: "Connecting to local phone control")
                    try await backend.connectLocalXCTest()
                } else {
                    var identity = try store.load().identity(); defer { identity.clearSeed() }
                    let authorization = ExistingSessionAuthorization(verifyExistingIdentity: true, screen: true, screenVideoStream: true, input: true)
                    if route == .vpnLoopback {
                        message = String(localized: "Finding this phone's RemotePairing service. Keep the VPN loopback connection on.")
                        let configuration = vpnConfiguration
                        let port = try await NativePerformanceTrace.measure(.discovery) { try await localDiscovery.discoverPort(configuration: configuration) }
                        try Task.checkCancellation(); guard generation == epoch else { return }
                        message = String(localized: "Verifying identity and opening the CoreDevice tunnel through VPN loopback")
                        try await backend.connectLocalVPN(identity: identity, authorization: authorization, pairingPort: port, configuration: configuration)
                    } else {
                        message = String(localized: "Finding the phone's RemotePairing service through ESP32")
                        let discovery = try await NativePerformanceTrace.measure(.discovery) {
                            var discovery = try await client.request(.discoverIPv4)
                            if discovery.endpoints?.contains(where: { $0.service == "remotepairing" }) != true {
                                discovery = try await client.request(.discoverIPv6)
                            }
                            return discovery
                        }
                        try Task.checkCancellation(); guard generation == epoch else { return }
                        guard let endpoint = discovery.endpoints?.first(where: { $0.service == "remotepairing" }) else {
                            throw CoreDeviceControlError.unavailable(String(localized: "Phone service not found. Check the ESP32 connection."))
                        }
                        message = String(localized: "Verifying identity and opening the developer tunnel through ESP32")
                        try await backend.connect(identity: identity, authorization: authorization, discovery: discovery, endpoint: endpoint)
                    }
                    do {
                        try await NativePerformanceTrace.measure(.developerReadiness) { try await backend.checkDeveloperReadiness() }
                    } catch {
                        // DDI missing (e.g. after a reboot): auto-install the cryptex
                        // DDI on-device — no computer involved. iOS 26.4+ cryptex path.
                        try await recoverDeveloperImage(backend)
                        try await NativePerformanceTrace.measure(.developerReadiness) { try await backend.checkDeveloperReadiness() }
                    }
                }
                try Task.checkCancellation(); guard generation == epoch else { return }
                ready = true; startHeartbeat(); message = route == .onDeviceXCTest
                    ? String(localized: "Local phone control is ready. You can take screenshots and send input.")
                    : String(localized: "\(route.connectionName) authentication, tunnel, and service checks succeeded. You can test screenshots and input.")
            } catch {
                guard generation == epoch else { return }
                let category = error as NSError
                BackgroundExecutionTrace.record("control.connect.failed domain=\(category.domain) code=\(category.code)")
                backend.close(stopRunner: route == .onDeviceXCTest); message = failure(error); lastFailure = message
            }
        }
    }
    /// DDI cryptex auto-recovery. Downloads the ~17 MB bundle once (cached),
    /// personalizes and installs it over the loopback tunnel. A read-only
    /// cryptexd query runs first so unrelated readiness failures never trigger
    /// downloads. Requires Developer Mode enabled on this phone.
    private func recoverDeveloperImage(_ backend: PhoneControlServices) async throws {
        message = String(localized: "Developer services unavailable. Checking the on-device DDI cryptex...")
        guard let status = try? await backend.cryptexInstalled() else {
            throw CoreDeviceControlError.unavailable(String(localized: "Developer image check failed. Verify Developer Mode is on and the VPN loopback connection is up."))
        }
        if (status["installed"] as? Bool) == true {
            message = String(localized: "Developer image cryptex present; retrying service checks.")
            return
        }
        message = String(localized: "Developer image missing. Downloading the cryptex DDI (~17 MB, one-time)...")
        let directory = try await DDICryptexStore.shared.ensureFiles()
        message = String(localized: "Personalizing and installing the developer image cryptex. Apple signs the ticket; this can take up to a minute.")
        try await backend.installDeveloperCryptex(directory: directory.path)
        message = String(localized: "Developer image cryptex installed.")
    }
    #if DEBUG
    func videoDiagnosticKeyframe() async -> Data? { await backend.videoDiagnosticKeyframe() }
    #endif
    func capture() { operation(capturing: true) {
        try await self.prepareAgentInput(self.backend)
        let png = try await self.backend.captureVideoJPEG()
        try Task.checkCancellation()
        guard let image = UIImage(data: png) else { throw NativeBackendError.malformedEvent }
        self.screenshotData = png; self.image = image; self.message = String(localized: "Phone screenshot received")
    } }
    func tapCenter() { operation {
        try await self.prepareAgentInput(self.backend)
        _ = try await self.backend.tapDelivery(x: 32768, y: 32768)
        try Task.checkCancellation()
        self.message = String(localized: "A tap was sent to the screen center. Check your phone to confirm the result.")
    } }
    private func operation(capturing: Bool = false, _ action: @escaping @MainActor () async throws -> Void) {
        guard ready, !running, !agentReserved else { return }
        mediaLifetime.clearIdle()
        generation = UUID(); let epoch = generation
        running = true; self.capturing = capturing
        beginOperationLease(epoch: epoch)
        job = Task { @MainActor in
            defer {
                if generation == epoch {
                    running = false; self.capturing = false; job = nil
                    finishControlMediaIfIdle()
                    if !mediaLifetime.stopping { finishOperationLease() }
                }
            }
            do {
                // User requests queue behind an in-flight keepalive; the UI only
                // becomes busy after a user operation, never for maintenance.
                while maintenanceBusy {
                    try await Task.sleep(for: .milliseconds(10))
                    guard generation == epoch else { return }
                }
                try Task.checkCancellation()
                guard generation == epoch, ready else { return }
                try await action()
                lastFailure = nil
            }
            catch {
                guard generation == epoch else { return }
                if case NativeBackendError.touchPreparationFailure = error {
                    mediaStarted = false
                    message = String(localized: "\(failure(error)). No tap was sent.")
                    lastFailure = message
                } else if case NativeBackendError.screenshotFailure(let stage, let cause) = error {
                    BackgroundExecutionTrace.record("screenshot.failed stage=\(stage) cause=\(cause) connectionRetained=true")
                    message = failure(error)
                    lastFailure = message
                } else {
                    stopHeartbeat(); ready = false; mediaStarted = false; backend.close(stopRunner: route == .onDeviceXCTest)
                    message = String(localized: "\(failure(error)); reconnect to \(route.connectionName)"); lastFailure = message
                }
            }
        }
    }
    /// A task pins one authenticated session. Reconnect never silently substitutes
    /// another generation; diagnostics and task traffic share the operation gate.
    func agentOperation<T>(owner: UUID, session: UUID, action: (PhoneControlServices) async throws -> T) async throws -> T {
        guard ready, controlSessionID == session else { throw CoreDeviceControlError.unavailable(String(localized: "Phone control is not connected. Connect in Settings → Phone control → Connection and verification.")) }
        if agentOwner != owner {
            if !agentQueue.contains(owner) { agentQueue.append(owner) }
            defer { agentQueue.removeAll { $0 == owner } }
            while running || agentOwner != nil || agentQueue.first != owner {
                try Task.checkCancellation()
                guard ready, controlSessionID == session, agentRuns.contains(owner) else { throw CoreDeviceControlError.stopped }
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        try Task.checkCancellation()
        guard ready, controlSessionID == session, agentRuns.contains(owner) else { throw CoreDeviceControlError.stopped }
        agentOwner = owner
        running = true
        defer { if controlSessionID == session { running = false } }
        do {
            while maintenanceBusy {
                try await Task.sleep(for: .milliseconds(10))
                guard ready, controlSessionID == session, agentOwner == owner else { throw CoreDeviceControlError.stopped }
            }
            try Task.checkCancellation()
            guard ready, controlSessionID == session, agentOwner == owner else { throw CoreDeviceControlError.stopped }
            let value = try await action(backend)
            try Task.checkCancellation()
            guard ready, controlSessionID == session, agentOwner == owner else { throw CoreDeviceControlError.stopped }
            lastFailure = nil
            return value
        } catch {
            guard controlSessionID == session else { throw CoreDeviceControlError.stopped }
            if let geometry = error as? NativeInputGeometryError {
                BackgroundExecutionTrace.record("input.geometry.failed reason=\(geometry.reason.rawValue) stage=\(geometry.stage) cause=\(geometry.cause) connectionRetained=true")
                message = String(localized: "Could not verify the current screen layout. No input was sent.")
                lastFailure = message
                throw geometry
            }
            if case NativeBackendError.touchPreparationFailure = error {
                mediaStarted = false; message = String(localized: "\(failure(error)). No input was sent."); lastFailure = message
                throw CoreDeviceControlError.unavailable(message)
            }
            if case NativeBackendError.screenshotFailure(let stage, let cause) = error {
                BackgroundExecutionTrace.record("screenshot.failed stage=\(stage) cause=\(cause) connectionRetained=true")
                message = failure(error)
                lastFailure = message
                throw CoreDeviceControlError.unavailable(message)
            }
            if case NativeBackendError.applicationQueryFailure(let stage, let cause) = error {
                BackgroundExecutionTrace.record("apps.query.failed stage=\(stage) cause=\(cause)")
                throw CoreDeviceControlError.unavailable(String(localized: "Could not list installed apps. Try again later."))
            }
            if error is CancellationError || (error as? CoreDeviceControlError) != nil {
                cancel(); throw CoreDeviceControlError.stopped
            }
            if case NativeBackendError.protocolFailure(_, let cause) = error, cause == 7 {
                // Delivery-uncertain (e.g. a lost launch receipt) does NOT break
                // the authenticated tunnel. Keep the session alive and hand the
                // model an actionable next step instead of tearing the
                // connection down — the old path closed the backend here and
                // ended the whole run on a recoverable outcome.
                BackgroundExecutionTrace.record("control.operation.uncertain cause=\(cause) connectionRetained=true")
                let message = String(localized: "\(failure(error)). The action may have taken effect. Take a screenshot to observe the real state, then decide; do not blindly retry and do not reconnect.")
                lastFailure = message
                throw CoreDeviceControlError.unavailable(message)
            }
            if case NativeBackendError.protocolFailure(let stage, let cause) = error {
                BackgroundExecutionTrace.record("control.operation.failed stage=\(stage) cause=\(cause) connectionRetained=false")
            } else if case NativeBackendError.closed = error {
                BackgroundExecutionTrace.record("control.operation.failed reason=closed connectionRetained=false")
            }
            message = String(localized: "\(failure(error)); reconnect to \(route.connectionName)"); lastFailure = message
            stopHeartbeat(); ready = false; mediaStarted = false; backend.close(stopRunner: route == .onDeviceXCTest)
            invalidateAgentSession(); running = false
            throw CoreDeviceControlError.unavailable(message)
        }
    }
    func prepareAgentInput(_ services: PhoneControlServices) async throws {
        mediaLifetime.suspendIdle()
        if let agentOwner { mediaUseOwners.insert(agentOwner) }
        if mediaStarted { BackgroundExecutionTrace.record("control.mediaReused") }
        if !mediaStarted {
            try await NativePerformanceTrace.measure(.mediaStart) { try await self.startMedia(services) }
            try Task.checkCancellation()
            mediaStarted = true
            mediaLifetime.didOpen()
        }
    }
    private func invalidateAgentSession() {
        mediaLifetime.revoke(); mediaUseOwners.removeAll()
        controlSessionID = UUID(); agentOwner = nil
        agentRuns.removeAll(); agentQueue.removeAll()
    }
    func mediaLifetimeWait() async { await mediaLifetime.wait() }
    func canActivateApplication(owner: UUID, session: UUID) -> Bool {
        ready && controlSessionID == session && !running &&
            (agentOwner == owner || (agentOwner == nil && agentQueue.isEmpty))
    }
    func retainConnection(owner: UUID) {
        if route == .onDeviceXCTest, ready, !running, !agentReserved, connectionUsers.isEmpty {
            // Each new run performs a fresh readiness check. A volume-button
            // stop must not leave the next task trusting a stale ready flag.
            ready = false; stopHeartbeat(); backend.close()
        }
        connectionUsers.insert(owner)
    }
    func releaseConnection(owner: UUID) {
        connectionUsers.remove(owner)
        if route == .onDeviceXCTest {
            finishControlMediaIfIdle()
            if !ready, !running, !agentReserved, connectionUsers.isEmpty { backend.stopIdleLocalRunner() }
        }
    }
    func registerAgent(owner: UUID, session: UUID) {
        guard ready, controlSessionID == session else { return }
        mediaLifetime.suspendIdle()
        agentRuns.insert(owner)
    }
    func releaseAgent(owner: UUID, session: UUID) {
        releaseAgent(owner: owner, session: session, retainingMedia: false)
    }
    func finishRemoteAgent(owner: UUID, session: UUID, retentionGeneration: UUID?) {
        releaseAgent(owner: owner, session: session, retainingMedia: route != .onDeviceXCTest && retentionGeneration == mediaRetentionGeneration)
    }
    private func releaseAgent(owner: UUID, session: UUID, retainingMedia: Bool) {
        guard controlSessionID == session, agentRuns.contains(owner) else { return }
        let usedMedia = mediaUseOwners.remove(owner) != nil
        if retainingMedia {
            if usedMedia && mediaStarted { mediaLifetime.refreshMuseIdle() }
        } else { mediaLifetime.clearIdle() }
        agentRuns.remove(owner); agentQueue.removeAll { $0 == owner }
        guard agentOwner == owner else {
            finishControlMediaIfIdle()
            return
        }
        // Partial/cancelled operations remain fatal. Completed runs release media
        // only after the final registered controller finishes; queued runs share it.
        if running { cancel() } else {
            agentOwner = nil
            finishControlMediaIfIdle()
        }
    }
    func revokeMuseMediaRetention() {
        mediaRetentionGeneration = UUID()
        releaseIdleMuseMedia()
    }
    /// Only drops the optional Muse cache, never an owner, queued run or input.
    @discardableResult func releaseIdleMuseMedia() -> Bool {
        guard ready, !running, !agentReserved, agentQueue.isEmpty,
              !capturing, !pairingActive, !mediaLifetime.stopping,
              mediaLifetime.idleUntil != nil, mediaStarted else { return false }
        mediaLifetime.clearIdle()
        finishControlMediaIfIdle()
        return mediaLifetime.stopping
    }
    func releaseIdleMuseMediaAndWait() async -> Bool {
        let session = controlSessionID
        guard releaseIdleMuseMedia() else { return false }
        await mediaLifetime.wait()
        return controlSessionID == session && !mediaStarted
    }
    private func finishControlMediaIfIdle() {
        if route == .onDeviceXCTest, ready, !running, !agentReserved, agentQueue.isEmpty, !mediaStarted {
            mediaStarted = true; mediaLifetime.didOpen()
        }
        guard ready, !running, mediaStarted, !agentReserved, agentQueue.isEmpty else { return }
        if route != .onDeviceXCTest, mediaLifetime.idleUntil != nil {
            finishOperationLease()
            BackgroundExecutionTrace.record("control.mediaIdle timeoutSeconds=600")
            mediaLifetime.scheduleIdle { [weak self] in self?.releaseIdleMuseMedia() }
            return
        }
        let session = controlSessionID
        let accepted = mediaLifetime.finishIfIdle(hasUsers: !agentRuns.isEmpty || agentOwner != nil,
            stop: { [weak self] in
                guard let self else { throw CancellationError() }
                while self.maintenanceBusy {
                    try await Task.sleep(for: .milliseconds(10))
                    guard self.controlSessionID == session else { throw CancellationError() }
                }
                guard self.controlSessionID == session, self.ready else { throw CancellationError() }
                BackgroundExecutionTrace.record("control.mediaStopRequested scoped=true")
                try await self.stopMedia(self.backend)
            }, completed: { [weak self] success in
                guard let self, self.controlSessionID == session else { return }
                self.running = false; self.mediaStarted = false
                self.finishOperationLease()
                if success {
                    BackgroundExecutionTrace.record("control.mediaReleased peerConfirmed=true connectionRetained=true")
                    if self.route == .onDeviceXCTest {
                        self.stopHeartbeat(); self.backend.close(); self.ready = false
                        self.controlSessionID = UUID()
                        self.message = String(localized: "Phone control stopped. It will start automatically for the next task.")
                    } else { self.message = String(localized: "Screen control ended") }
                } else {
                    self.cancel()
                    self.message = String(localized: "Could not end screen control. Reconnect.")
                    self.lastFailure = self.message
                }
            })
        if accepted { running = true }
    }
    /// Termination notification is best-effort; synchronous native handle close
    /// revokes all App-owned transports without waiting for an async stop reply.
    func applicationWillTerminate() { cancel() }
    private func beginOperationLease(epoch: UUID) {
        finishOperationLease()
        let lease = ExecutionTransitionLease()
        lease.expirationHandler = { [weak self] in
            guard let self, self.generation == epoch else { return }
            self.cancel()
            self.message = String(localized: "Background execution expired. The action was stopped.")
            self.lastFailure = self.message
        }
        lease.begin(); operationLease = lease
    }
    private func finishOperationLease() {
        operationLease?.complete(success: true); operationLease = nil
    }
    private func stopHeartbeat() {
        heartbeatEpoch = UUID(); heartbeatTask?.cancel(); heartbeatTask = nil; maintenanceBusy = false
    }
    /// Read-only service traffic checks connection readiness on both routes and
    /// keeps the ESP32 relay's idle lease alive when using NCM.
    /// Shares the operation gate; never overlaps a screenshot or touch request.
    private func startHeartbeat(immediate: Bool = false) {
        stopHeartbeat(); let epoch = heartbeatEpoch
        heartbeatTask = Task { @MainActor [weak self] in
            var delay: Duration = immediate ? .zero : .seconds(20)
            while !Task.isCancelled {
                do { try await Task.sleep(for: delay) } catch { return }
                delay = .seconds(20)
                guard let self, self.heartbeatEpoch == epoch, self.ready else { return }
                if self.running { continue }
                self.maintenanceBusy = true
                do {
                    try await self.backend.checkDeveloperReadiness()
                    guard self.heartbeatEpoch == epoch else { return }
                    self.maintenanceBusy = false
                } catch {
                    guard self.heartbeatEpoch == epoch else { return }
                    self.maintenanceBusy = false; self.ready = false; self.mediaStarted = false; self.running = false
                    self.backend.close(stopRunner: self.route == .onDeviceXCTest); self.invalidateAgentSession()
                    self.message = String(localized: "Connection keep-alive failed: \(self.failure(error)); reconnect to \(route.connectionName)")
                    self.lastFailure = self.message
                    return
                }
            }
        }
    }
    private func failure(_ error: Error) -> String {
        if case CoreDeviceControlError.unavailable(let message) = error { return message }
        if let vpnError = error as? LocalVPNError {
            switch vpnError {
            case .inactive: return String(localized: "VPN interface \(vpnConfiguration.localAddress) was not found. Check that VPN is on and its addresses are correct.")
            case .ambiguousInterface: return String(localized: "Multiple matching VPN interfaces were found. Check your connection settings.")
            case .serviceNotFound: return String(localized: "This phone's RemotePairing service was not found. Check Developer Mode, system pairing, and local network access.")
            case .ambiguousService: return String(localized: "Multiple local RemotePairing ports were found. Reconnect and try again.")
            case .invalidConfiguration: return String(localized: "Enter two different, valid IPv4 interface and peer addresses")
            case .discoveryDenied: return String(localized: "Local service discovery failed. Allow local network access.")
            }
        }

        if case NativeBackendError.screenshotFailure(let stage, let cause) = error {
            return failure(NativeBackendError.protocolFailure(stage: stage, cause: cause))
        }

        if case NativeBackendError.touchPreparationFailure(let stage, let cause) = error {
            let labels: [UInt32: String] = [10:String(localized: "Video service availability"), 11:String(localized: "Touch service availability"), 13:String(localized: "Video receive port"), 14:String(localized: "Video service connection"), 15:String(localized: "Video session request"), 16:String(localized: "Video negotiation response"), 17:String(localized: "Valid video packet reception"), 18:String(localized: "Touch service connection")]
            let reasons: [UInt32: String] = [1:String(localized: "Protocol error"), 2:String(localized: "Timed out"), 3:String(localized: "Invalid parameter"), 4:String(localized: "Service missing"), 5:String(localized: "Not ready")]
            return String(localized: "Could not prepare touch input: \(labels[stage] ?? String(localized: "Video preparation")), \(reasons[cause] ?? String(localized: "Reason \(cause)"))")
        }
        if case NativeBackendError.protocolFailure(let stage, let cause) = error {
            if stage == 2 {
                switch cause {
                case 8: return String(localized: "The phone refused the local control connection. Keep the loopback VPN connected and retry.")
                case 9: return String(localized: "There is no route to the local control service. Check the loopback VPN after changing networks.")
                case 10: return String(localized: "The VPN interface changed or is unavailable. Reconnect the loopback VPN and retry.")
                case 11: return String(localized: "iOS denied the local control connection. Check VPN and local network permissions.")
                case 12: return String(localized: "The local control connection was reset. Reconnect after changing networks.")
                case 13: return String(localized: "The local control socket failed before phone authentication. Check the loopback VPN.")
                default: break
                }
            }
            if stage == 19 || stage == 20 {
                let reasons: [UInt32: String] = [1:String(localized: "Protocol error"), 2:String(localized: "Timed out"), 3:String(localized: "Invalid parameter"), 4:String(localized: "Service missing"), 5:String(localized: "Not ready"), 8:String(localized: "Timed out without receiving video data"), 9:String(localized: "Timed out without receiving a matching video packet"), 10:String(localized: "Timed out before a complete video frame was received"), 11:String(localized: "Timed out before video image integrity could be confirmed"), 12:String(localized: "Timed out because the video image exceeded the receive limit"), 13:String(localized: "Video decoding session is no longer valid"), 14:String(localized: "Video decoding failed")]
                return String(localized: "Screenshot \(stage == 19 ? String(localized: "connection") : String(localized: "request and reception")) failed (\(reasons[cause] ?? String(localized: "Reason \(cause)")))")
            }
            let labels: [UInt32: String] = [1:String(localized: "Pairing identity"), 2:String(localized: "\(route.connectionName) connection"), 3:String(localized: "Phone authentication"), 4:String(localized: "Dynamic tunnel discovery"), 5:String(localized: "Tunnel TLS"), 6:String(localized: "Remote service list"), 7:String(localized: "Developer Mode"), 8:String(localized: "Developer image"), 9:String(localized: "Screenshot"), 10:String(localized: "Screen video session"), 11:String(localized: "Input delivery"), 12:String(localized: "Session close"), 21:String(localized: "App service")]
            let reasons: [UInt32: String] = [1:String(localized: "Protocol error"), 2:String(localized: "Timed out"), 3:String(localized: "Invalid parameter"), 4:String(localized: "Service missing"), 5:String(localized: "Not ready"), 6:String(localized: "Screen session is no longer valid"), 7:String(localized: "Delivery result unknown")]
            return String(localized: "\(labels[stage] ?? String(localized: "Protocol")) failed (\(reasons[cause] ?? String(localized: "Reason \(cause)")))")
        }
        if error is CancellationError { return String(localized: "Stopped") }
        if route == .onDeviceXCTest { return String(localized: "Open Louis Local Control, then return here and connect. If it cannot start, reconnect the phone to Xcode to prepare developer services.") }
        return route == .vpnLoopback
            ? String(localized: "Connection failed. Check VPN loopback settings, Developer Mode, and local network access.")
            : String(localized: "Connection failed. Check ESP32 firmware, the NCM interface, and local network access.")
    }
    #if DEBUG
    private var backgroundProbeStarted = false
    /// Opt-in real-device acceptance probe. Uses the production bridge and
    /// scheduler; logs state/dimensions. The additional input-probe flag saves
    /// three local verification images for the reversible Home-screen swipe.
    func runBackgroundProbeIfRequested(pip: StatusPiPController? = nil) async {
        if ProcessInfo.processInfo.arguments.contains("--local-control-lifecycle-probe") {
            let file = URL.documentsDirectory.appending(path: "local-control-lifecycle.log")
            var lines: [String] = []
            func record(_ value: String) {
                lines.append(Date().ISO8601Format() + " " + value)
                try? lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
            }
            record("start route=\(route.rawValue)")
            for cycle in 1...3 {
                let visibleDeadline = ContinuousClock.now.advanced(by: .seconds(3))
                while UIApplication.shared.applicationState != .active, ContinuousClock.now < visibleDeadline {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                record("cycle=\(cycle) foreground=\(UIApplication.shared.applicationState == .active)")
                var bridge: CoreDeviceBridge?
                do {
                    let control = try CoreDeviceBridge(flow: self); bridge = control
                    let frame = try await control.screenshot()
                    record("cycle=\(cycle) screenshot=\(frame.width)x\(frame.height) ready=\(ready)")
                    await control.stop(); bridge = nil
                    try await Task.sleep(for: .seconds(2))
                    let reachable = (try? await LocalDeviceControlClient.request("whoami", timeout: 1)) != nil
                    record("cycle=\(cycle) stopped=\(!ready && !reachable) ready=\(ready) reachable=\(reachable)")
                    guard !ready, !reachable else { throw NSError(domain: "LocalLifecycle", code: 1) }
                } catch {
                    if let bridge { await bridge.stop() }
                    let e = error as NSError
                    record("FAIL cycle=\(cycle) domain=\(e.domain) code=\(e.code) detail=\(lastFailure ?? message)")
                    return
                }
            }
            record("PASS three automatic start/screenshot/stop cycles")
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--local-xctest-probe") {
            await LocalDeviceControlClient.run(); return
        }
        if ProcessInfo.processInfo.arguments.contains("--export-loopback-config") {
            let file = URL.documentsDirectory.appending(path: "Louis-Local-Loopback.json")
            if FileManager.default.fileExists(atPath: file.path),
               let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
               var presenter = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController {
                while let shown = presenter.presentedViewController { presenter = shown }
                presenter.present(UIDocumentPickerViewController(forExporting: [file], asCopy: true), animated: true)
            }
            return
        }
        guard (ProcessInfo.processInfo.arguments.contains("--coredevice-background-probe") || pip != nil), !backgroundProbeStarted else { return }
        backgroundProbeStarted = true
        let url = URL.documentsDirectory.appending(path: "coredevice-background-probe.txt")
        var lines: [String] = []
        func record(_ value: String) {
            lines.append("\(Date().ISO8601Format()) \(value)")
            try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        record("start paired=\(hasRecord)")
        // Opt-in local diagnostics: inventory VPN IPv4 addresses only. Never
        // include cellular addresses, link-layer addresses or pairing material.
        var interfaceHead: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&interfaceHead) == 0 {
            var cursor = interfaceHead
            while let entry = cursor {
                defer { cursor = entry.pointee.ifa_next }
                let row = entry.pointee
                let name = String(cString: row.ifa_name)
                guard name.hasPrefix("utun"), let address = row.ifa_addr,
                      address.pointee.sa_family == UInt8(AF_INET) else { continue }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(address.pointee.sa_len), &host,
                               socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    record("vpn_interface name=\(name) index=\(if_nametoindex(row.ifa_name)) ipv4=\(String(cString: host)) flags=\(row.ifa_flags)")
                }
            }
            freeifaddrs(interfaceHead)
        }
        if !ready && !running { verify() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while !ready && running && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard ready else { record("connect failed: \(message)"); return }
        let systemScheduler = ContinuedProcessingScheduler()
        systemScheduler.diagnostic = { record($0) }
        let scheduler: any RunBackgroundScheduler = pip == nil
            ? systemScheduler : CompositeRunScheduler(allowed: { [.pictureInPicture] })
        let identifier = (Bundle.main.bundleIdentifier ?? "com.ja1chen.PhoneAgent") + ".backgroundRun." + UUID().uuidString
        var lease: (any RunBackgroundLease)?
        var expired = false
        var activeBridge: CoreDeviceBridge?
        do {
            try scheduler.submit(identifier: identifier, launched: { grant in
                lease = grant
                grant.expirationHandler = { expired = true; activeBridge?.cancelTransport(); record("execution expired") }
            })
            if pip != nil { record("PiP-only acceptance active=\(pip?.active == true); combined lease=\(lease != nil); no system execution lease requested") }
            let bridge = try CoreDeviceBridge(flow: self)
            activeBridge = bridge
            defer { lease?.complete(success: !expired); scheduler.cancel(identifier: identifier) }
            do {
                let frame = try await bridge.screenshot()
                record("foreground capture \(frame.width)x\(frame.height) bytes=\(frame.png.count); background switch window=15s")
                UIApplication.shared.perform(NSSelectorFromString("suspend"))
                for step in 1...3 {
                    try await Task.sleep(for: .seconds(15))
                    guard !expired else { throw AppError.stopped }
                    record("readiness \(step) start background=\(isBackground) pip=\(pip?.active == true)")
                    while maintenanceBusy { try await Task.sleep(for: .milliseconds(10)) }
                    running = true
                    do { try await backend.checkDeveloperReadiness(); running = false }
                    catch { running = false; throw error }
                    record("readiness \(step) ok")
                    let start = ContinuousClock.now
                    let frame = try await bridge.screenshot()
                    record("capture \(step) background=\(isBackground) ready=\(ready) \(frame.width)x\(frame.height) bytes=\(frame.png.count) elapsed=\(start.duration(to: .now))")
                    lease?.report(completed: step, subtitle: String(localized: "Background screenshot verification \(step)/3"))
                    if step == 1 && ProcessInfo.processInfo.arguments.contains("--coredevice-background-input-probe") {
                        try frame.png.write(to: URL.documentsDirectory.appending(path: "coredevice-input-before.png"))
                        try await bridge.authorizeTaskInput(imageID: frame.id)
                        try await bridge.drag(fromX: 52428, fromY: 32768, toX: 13107, toY: 32768, durationMS: 300, imageID: frame.id)
                        record("background swipe-left reports written")
                        lease?.report(completed: step + 1, subtitle: String(localized: "Background swipe sent. Checking the screen."))
                        try await Task.sleep(for: .seconds(1))
                        let changed = try await bridge.screenshot()
                        try changed.png.write(to: URL.documentsDirectory.appending(path: "coredevice-input-after.png"))
                        lease?.report(completed: step + 2, subtitle: String(localized: "Screenshot received after swiping. Restoring the Home Screen."))
                        try await bridge.authorizeTaskInput(imageID: changed.id)
                        try await bridge.drag(fromX: 13107, fromY: 32768, toX: 52428, toY: 32768, durationMS: 300, imageID: changed.id)
                        record("background swipe-right reports written")
                        lease?.report(completed: step + 3, subtitle: String(localized: "Restore swipe sent. Checking the Home Screen."))
                        try await Task.sleep(for: .seconds(1))
                        let restored = try await bridge.screenshot()
                        try restored.png.write(to: URL.documentsDirectory.appending(path: "coredevice-input-restored.png"))
                        record("background swipe verification images saved")
                        record("complete"); break
                    }
                }
                record("complete")
            } catch { record("capture failed background=\(isBackground): \(message); \(error)") }
            await bridge.stop()
        } catch { record("probe failed: \(error)") }
    }
    #endif
}
