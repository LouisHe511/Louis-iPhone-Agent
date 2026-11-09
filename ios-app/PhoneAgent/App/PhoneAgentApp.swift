import SwiftUI
import AppIntents
import SwiftAgentKit
import Darwin
import Network

@main @MainActor struct PhoneAgentApp: App {
    @StateObject private var background = BackgroundExecutionCoordinator.shared
    @StateObject private var settings = BackgroundSettingsStore.shared
    @StateObject private var model = PhoneAgentRuntime.shared.model
    @StateObject private var statusPiP = BackgroundExecutionCoordinator.shared.media!
    @Environment(\.scenePhase) private var scenePhase
    init() {
        _ = BackgroundSettingsStore.shared // Migrate before runtime/history creation or any UI binding.
        PhoneAgentShortcuts.updateAppShortcutParameters()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--keep-awake") { UIApplication.shared.isIdleTimerDisabled = true }
        if ProcessInfo.processInfo.arguments.contains("--ocr-fix-probe") || ProcessInfo.processInfo.arguments.contains("--local-control-integrated-probe") || ProcessInfo.processInfo.arguments.contains("--local-control-lifecycle-probe") {
            _ = DeviceControlCoordinator.shared.selectRoute(.onDeviceXCTest)
        }
        if ProcessInfo.processInfo.arguments.contains("--local-vpn-probe") {
            _ = DeviceControlCoordinator.shared.selectRoute(.vpnLoopback)
        }
        #endif
        DeviceControlCoordinator.shared.registerBackgroundTask()
    }
    var body: some Scene {
        WindowGroup {
            ContentView(model: model, statusPiP: statusPiP, commands: PhoneAgentRuntime.shared.commands)
                .overlay {
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--ocr-fix-probe") { OCRFixProbeView() }
                    else if ProcessInfo.processInfo.arguments.contains("--local-control-integrated-probe") { LocalControlProbeView() }
                    else if ProcessInfo.processInfo.arguments.contains("--local-vpn-probe") { LocalVPNProbeView() }
                    else if ProcessInfo.processInfo.arguments.contains("--coredevice-video-geometry-probe") { CoreDeviceVideoGeometryProbeView(statusPiP: statusPiP) }
                    else if ProcessInfo.processInfo.arguments.contains("--coredevice-tools-probe") { CoreDeviceToolsProbeView(statusPiP: statusPiP) }
                    #endif
                }
                .onAppIntentExecution(PrepareAgentTaskIntent.self) { _ in
                    // SwiftUI receives the scene handoff; perform() alone owns task submission.
                    model.usbDiagnostics.record("siri.sceneHandoff received=true")
                }
                .preferredColorScheme(testColorScheme)
                // A covered backing layer supplies AVKit without occupying the UI.
                .background(alignment: .bottom) {
                    StatusSampleBufferView(displayLayer: statusPiP.displayLayer)
                        .frame(width: 320, height: 180)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
                .task {
                    let streamProbe = ProcessInfo.processInfo.arguments.contains("--task-pip-probe") && ProcessInfo.processInfo.arguments.contains("--background-stream-probe")
                    if !streamProbe { DeviceControlCoordinator.shared.restoreConnection() }
                    model.liveActivities.setBackgroundResident(settings.reservesStandbyActivity)
                    statusPiP.observeTasks(in: model)
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--task-pip-probe") {
                        if streamProbe { background.applySelection([.audio]) }
                        model.start()
                        let startCPU = processCPUSecondsForProbe(), startTime = Date()
                        for step in 0..<(streamProbe ? 10 : 5) {
                            try? await Task.sleep(for: .seconds(10))
                            statusPiP.recordTaskProbe(step: step, running: model.hasBusySessions,
                                liveActivities: model.liveActivities.activeCountForProbe)
                            if streamProbe {
                                BackgroundExecutionTrace.record("streamProbe.cpu wall=\(Date().timeIntervalSince(startTime)) cpu=\(processCPUSecondsForProbe()-startCPU) running=\(model.hasBusySessions)")
                            }
                            if step == 0 { UIApplication.shared.perform(NSSelectorFromString("suspend")) }
                        }
                    } else { await DeviceControlCoordinator.shared.runBackgroundProbeIfRequested() }
                    #endif
                }
                .onChange(of: settings.reservesStandbyActivity) { _, enabled in
                    model.liveActivities.setBackgroundResident(enabled)
                }
                .alert(String(localized: "Enable location for background execution?"), isPresented: Binding(get: { background.locationExplanation && !background.locationExplanationInSettings }, set: { _ in })) {
                    Button(String(localized: "Not now"), role: .cancel) { background.dismissLocationExplanation() }
                    Button(String(localized: "Continue to permission")) { background.acceptLocationExplanation() }
                } message: { Text(BackgroundExecutionCoordinator.locationPurpose) }
                .onChange(of: model.approval?.id) { _, id in
                    #if DEBUG
                    if id != nil { Task { await PhoneAgentRuntime.shared.invokeSiriFixtureIfNeeded(busy: true) } }
                    #endif
                }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    // Return run leases to foreground before stopping PiP revokes its background receipt.
                    model.setScene(phase == .active ? .active : phase == .background ? .background : .inactive)
                    background.setForeground(phase == .active, transitioning: phase == .inactive)
                    if phase == .background { DeviceControlCoordinator.shared.background() }
                    else if phase == .active { DeviceControlCoordinator.shared.resume() }
                    model.setProtectedDataAvailable(UIApplication.shared.isProtectedDataAvailable)
                    PhoneAgentRuntime.shared.museConnection.setScene(active: phase == .active, background: phase == .background)
                    if phase == .active { PhoneAgentRuntime.shared.commands.resumePendingExecutions() }
                    // Inactive is a transition, not a request to show PiP.

                    #if DEBUG
                    if phase == .background { PhoneAgentRuntime.shared.completeBackgroundUIFixtureIfNeeded() }
                    if phase == .active { PhoneAgentRuntime.shared.finishForegroundUIFixtureIfNeeded() }
                    if phase == .active { Task { await PhoneAgentRuntime.shared.invokeSiriFixtureIfNeeded(busy: false) } }
                    #endif
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
                    PhoneAgentRuntime.shared.remoteTools.stop()
                    DeviceControlCoordinator.shared.applicationWillTerminate()
                    background.shutdown()
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
                    PhoneAgentRuntime.shared.remoteTools.stop()
                    DeviceControlCoordinator.shared.cancel()
                    background.setProtectedData(false)
                    model.setProtectedDataAvailable(false)
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in
                    background.setProtectedData(true)
                    model.setProtectedDataAvailable(true)
                    PhoneAgentRuntime.shared.museConnection.resumeIfEnabled()
                    PhoneAgentRuntime.shared.commands.resumePendingExecutions()
                }
                .onChange(of: model.hasBusySessions) { _, busy in
                    if !busy { PhoneAgentRuntime.shared.museConnection.resumeIfEnabled() }
                }
        }
    }
    private var testColorScheme: ColorScheme? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-testing"), arguments.contains("--ui-test-dark") { return .dark }
        if arguments.contains("--ui-testing"), arguments.contains("--ui-test-light") { return .light }
        #endif
        return nil
    }
}

#if DEBUG
/// Opt-in acceptance touches only this fixture and uses the real local runner.
private struct OCRFixProbeView: View {
    @State private var touches = 0
    @State private var status = String(localized: "Connecting")
    @State private var started = false
    var body: some View {
        VStack(spacing: 20) {
            Text(String(localized: "On-device control")).font(.title2)
            Text(String(localized: "Actual touches: \(touches)")).font(.largeTitle)
            Spacer()
            Button { touches += 1 } label: {
                Text(String(localized: "Submit (unlimited)"))
                    .font(.system(size: 15)).foregroundStyle(.white)
                    .frame(width: 180, height: 44).background(.blue, in: RoundedRectangle(cornerRadius: 4))
            }.buttonStyle(.plain)
            Text(status).font(.footnote)
        }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemBackground).ignoresSafeArea())
            .task { await run() }
    }
    @MainActor private func run() async {
        guard !started else { return }; started = true
        let idleDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        let lease = UIApplication.shared.beginBackgroundTask(withName: "OCR fix acceptance")
        defer {
            UIApplication.shared.isIdleTimerDisabled = idleDisabled
            if lease != .invalid { UIApplication.shared.endBackgroundTask(lease) }
        }
        let log = URL.documentsDirectory.appending(path: "ocr-fix-acceptance.log")
        var lines: [String] = []
        func record(_ message: String) {
            lines.append(Date().ISO8601Format() + " " + message)
            try? lines.joined(separator: "\n").write(to: log, atomically: true, encoding: .utf8)
        }
        var cleanup: ActionCoordinator?
        record("start")
        do {
            let coordinator = ActionCoordinator(bridge: try CoreDeviceBridge(), limits: AgentLimits(), approve: { _ in true }, onImage: { frame, call in
                let name = ["fixture-start", "fixture-miss", "fixture-tap"].contains(call) ? call : "other"
                try? frame.png.write(to: URL.documentsDirectory.appending(path: "ocr-fixture-" + name + ".jpg"))
            }, onReceipt: { _ in }, authorizationMode: .task)
            cleanup = coordinator
            let start = ContinuousClock.now
            _ = try await coordinator.execute(name: "screenshot", parameters: [:], callID: "fixture-start")
            guard let original = await coordinator.frameForAcceptanceProbe() else { throw NSError(domain: "OCRProbe", code: 1) }
            record("first_frame \(original.width)x\(original.height) bytes=\(original.png.count) elapsed=\(start.duration(to: .now))")
            guard original.width >= 1000 else { throw NSError(domain: "OCRProbe", code: 2) }
            let modelBytes = ActionCoordinator.griddedPNG(original.png)!
            let cloud = UIImage(data: modelBytes)!.cgImage!
            record("cloud_frame \(cloud.width)x\(cloud.height) bytes=\(modelBytes.count)")
            guard max(cloud.width, cloud.height) <= 900 else { throw NSError(domain: "OCRProbe", code: 3) }
            let tool = DeviceTool(name: "tap_text", coordinator: coordinator)
            let miss = try await tool.execute(context: ToolContext(callId: "fixture-miss", toolName: "tap_text", parameters: ["image_id": original.id, "text": "__absent_fixture_92E6__", "purpose": "fixture"], state: AgentState(), actions: ToolActions()))
            guard miss.isError, miss.images.count == 1, touches == 0,
                  let recovery = await coordinator.frameForAcceptanceProbe() else { throw NSError(domain: "OCRProbe", code: 4) }
            record("OCR rejection returned image; recovery_reference_present=true; touches=\(touches)")
            let beforeTap = ContinuousClock.now
            let tap = try await tool.execute(context: ToolContext(callId: "fixture-tap", toolName: "tap_text", parameters: ["image_id": recovery.id, "text": String(localized: "Submit (unlimited)"), "purpose": "fixture"], state: AgentState(), actions: ToolActions()))
            record("text_tap error=\(tap.isError) touches=\(touches) elapsed=\(beforeTap.duration(to: .now)) detail=\(tap.result)")
            guard !tap.isError, touches == 1 else { throw NSError(domain: "OCRProbe", code: 5) }
            if let frame = await coordinator.frameForAcceptanceProbe() {
                try frame.png.write(to: URL.documentsDirectory.appending(path: "ocr-fix-after.jpg"))
            }
            await coordinator.stop(); cleanup = nil
            // A second task proves a fresh auto-start and the real breaker.
            let breaker = ActionCoordinator(bridge: try CoreDeviceBridge(), limits: AgentLimits(), approve: { _ in true }, onImage: { _, _ in }, onReceipt: { _ in }, authorizationMode: .task)
            cleanup = breaker
            _ = try await breaker.execute(name: "screenshot", parameters: [:], callID: "breaker-start")
            let keyboard = try await DeviceTool(name: "dismiss_keyboard", coordinator: breaker).execute(context: ToolContext(callId: "no-keyboard", toolName: "dismiss_keyboard", parameters: [:], state: AgentState(), actions: ToolActions()))
            guard keyboard.isError, touches == 1, let frame = await breaker.frameForAcceptanceProbe() else { throw NSError(domain: "OCRProbe", code: 6) }
            let actions = ToolActions()
            let second = try await DeviceTool(name: "tap_text", coordinator: breaker).execute(context: ToolContext(callId: "second-miss", toolName: "tap_text", parameters: ["image_id": frame.id, "text": "__absent_fixture_92E6__", "purpose": "fixture"], state: AgentState(), actions: actions))
            record("two_failures stopped=\(actions.shouldStop) touches=\(touches) error=\(second.isError)")
            guard actions.shouldStop, second.isError, touches == 1 else { throw NSError(domain: "OCRProbe", code: 7) }
            cleanup = nil
            record("PASS high_resolution + cloud_limit + fresh_OCR + failure_recovery + real_tap + no_keyboard_guess + two_failure_stop")
            status = String(localized: "Screen control ended")
        } catch {
            if let cleanup { await cleanup.stop() }
            let e = error as NSError
            record("FAIL domain=\(e.domain) code=\(e.code) detail=\(error.localizedDescription)")
            status = String(localized: "The last action did not succeed")
        }
    }
}


/// Explicit acceptance fixture: touches only an app-local counter, then Home.
/// The normal bridge owns session, geometry and action authorization throughout.
private struct LocalControlProbeView: View {
    @State private var count = 0
    @State private var target = CGRect.zero
    @State private var status = String(localized: "Connecting")
    @State private var started = false
    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            Button { count += 1 } label: {
                VStack {
                    Text(String(localized: "Verify tap"))
                    Text(String(localized: "Actual touches: \(count)")).font(.largeTitle)
                }.frame(width: 270, height: 160)
            }.buttonStyle(.borderedProminent)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { target = $0 }
            VStack {
                Text(String(localized: "On-device control")).font(.title2)
                Spacer()
                Text(status).font(.footnote).multilineTextAlignment(.center)
            }.padding()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .task { await run() }
    }
    @MainActor private func run() async {
        guard !started else { return }; started = true
        let flow = DeviceControlCoordinator.shared
        let file = URL.documentsDirectory.appending(path: "local-control-integrated.log")
        var lines: [String] = []
        func record(_ value: String) {
            lines.append(Date().ISO8601Format() + " " + value)
            try? lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        }
        record("start route=\(flow.route.rawValue)")
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        if !flow.ready && !flow.running { flow.verify() }
        while flow.running && !flow.ready && ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        }
        guard flow.ready else { record("connection failed: \(flow.lastFailure ?? flow.message)"); return }
        record("production coordinator connected")
        let delay = min(180, max(0, Int(ProcessInfo.processInfo.environment["LOUIS_PROBE_DELAY_SECONDS"] ?? "0") ?? 0))
        status = String(localized: "Connected")
        record("waiting \(delay) seconds before input")
        var control: CoreDeviceBridge?
        let background = UIApplication.shared.beginBackgroundTask(withName: "Local control acceptance")
        defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
        do {
            try await Task.sleep(for: .seconds(delay))
            let path: (Bool, Bool) = await withCheckedContinuation { continuation in
                let monitor = NWPathMonitor()
                monitor.pathUpdateHandler = { path in
                    monitor.pathUpdateHandler = nil; monitor.cancel()
                    continuation.resume(returning: (path.usesInterfaceType(.cellular), path.usesInterfaceType(.wifi)))
                }
                monitor.start(queue: DispatchQueue(label: "local-control.acceptance.path"))
            }
            record("default network cellular=\(path.0) wifi=\(path.1)")
            let (_, internet) = try await URLSession.shared.data(from: URL(string: "https://www.apple.com/library/test/success.html")!)
            record("internet HTTP=\((internet as? HTTPURLResponse)?.statusCode ?? 0)")
            let bridge = try CoreDeviceBridge(flow: flow); control = bridge
            let before = try await bridge.screenshot()
            try before.png.write(to: URL.documentsDirectory.appending(path: "local-control-before.jpg"))
            record("screenshot \(before.width)x\(before.height) bytes=\(before.png.count)")
            guard !target.isEmpty, let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
                throw AppError.invalid(String(localized: "The tap target has not been laid out"))
            }
            let baseline = count
            let bounds = scene.screen.bounds
            try await bridge.authorizeTaskInput(imageID: before.id)
            try await bridge.tap(x: Int((target.midX / bounds.width * 65535).rounded()),
                                 y: Int((target.midY / bounds.height * 65535).rounded()), imageID: before.id)
            try await Task.sleep(for: .seconds(0.5))
            record("tap counter \(baseline)->\(count)")
            guard count == baseline + 1 else { throw NSError(domain: "LocalAcceptance", code: 1) }
            let after = try await bridge.screenshot()
            try after.png.write(to: URL.documentsDirectory.appending(path: "local-control-after.jpg"))
            let authorization = UUID().uuidString
            try await bridge.authorizeSystemAction(authorizationID: authorization, taskScoped: true)
            try await bridge.systemAction(name: "home", text: "", arguments: [], imageID: authorization)
            record("home delivered")
            try await Task.sleep(for: .seconds(1))
            let home = try await bridge.screenshot()
            try home.png.write(to: URL.documentsDirectory.appending(path: "local-control-home.jpg"))
            record("home screenshot \(home.width)x\(home.height) background=\(UIApplication.shared.applicationState == .background)")
            let launch = UUID().uuidString
            try await bridge.authorizeSystemAction(authorizationID: launch, taskScoped: true)
            try await bridge.systemAction(name: "launch_app", text: Bundle.main.bundleIdentifier!, arguments: [], imageID: launch)
            record("returned to Louis")
            await bridge.stop(); control = nil
            record("PASS screenshot + actual tap + Home + background screenshot + app launch; ready=\(flow.ready)")
            status = String(localized: "Connected")
        } catch {
            if let control { await control.stop() }
            let e = error as NSError
            record("FAIL domain=\(e.domain) code=\(e.code) detail=\(flow.lastFailure ?? flow.message)")
            status = String(localized: "The last action did not succeed")
        }
    }
}


/// Explicit on-device acceptance: one screenshot, one tap on this harmless
/// counter, then another screenshot. No user history or external app is touched.
private struct LocalVPNProbeView: View {
    @State private var count = 0
    @State private var target = CGRect.zero
    @State private var status = String(localized: "Verifying VPN loopback")
    @State private var started = false
    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            Button { count += 1 } label: {
                VStack { Text(String(localized: "VPN loopback tap target")); Text(String(localized: "Actual touches: \(count)")).font(.largeTitle) }
                    .frame(width: 270, height: 160)
            }.buttonStyle(.borderedProminent)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { target = $0 }
            VStack { Text(String(localized: "Device verification without ESP32")).font(.title2); Spacer(); Text(status).font(.footnote).multilineTextAlignment(.center) }.padding()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await run() }
    }
    @MainActor private func run() async {
        guard !started else { return }; started = true
        let flow = DeviceControlCoordinator.shared
        let url = URL.documentsDirectory.appending(path: "local-vpn-probe.log")
        var records: [String] = []
        func record(_ line: String) {
            records.append(Date().ISO8601Format() + " " + line)
            try? records.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            status = line
        }
        record("start route=\(flow.route.rawValue) paired=\(flow.hasRecord)")
        let deadline = ContinuousClock.now.advanced(by: .seconds(90))
        if !flow.ready && !flow.running { flow.verify() }
        while flow.running && !flow.ready && ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        }
        guard flow.ready else { record("connection failed: \(flow.lastFailure ?? flow.message)"); return }
        record("authenticated CoreDevice ready")
        var control: CoreDeviceBridge?
        do {
            let bridge = try CoreDeviceBridge(flow: flow); control = bridge
            let frame = try await bridge.screenshot()
            try frame.png.write(to: URL.documentsDirectory.appending(path: "local-vpn-before.jpg"))
            record("screenshot \(frame.width)x\(frame.height) bytes=\(frame.png.count)")
            guard !target.isEmpty, let screen = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first?.screen else {
                throw AppError.invalid(String(localized: "The tap target has not been laid out"))
            }
            let x = Int((target.midX / screen.bounds.width * 65535).rounded())
            let y = Int((target.midY / screen.bounds.height * 65535).rounded())
            let baseline = count
            try await bridge.authorizeTaskInput(imageID: frame.id)
            try await bridge.tap(x: x, y: y, imageID: frame.id)
            try await Task.sleep(for: .seconds(1))
            record("tap delivered; actual counter \(baseline)->\(count)")
            let after = try await bridge.screenshot()
            try after.png.write(to: URL.documentsDirectory.appending(path: "local-vpn-after.jpg"))
            await bridge.stop(); control = nil
            let released = flow.ready && !flow.running && flow.lastFailure == nil && flow.message == String(localized: "Screen control ended")
            record("media release confirmed=\(released)")
            record(count == baseline + 1 && released ? "PASS screenshot + actual touch + media release" : "FAIL touch or media release not confirmed; input will not replay")
        } catch {
            if let control { await control.stop() }
            record("failed: \(String(describing: error)); \(flow.lastFailure ?? flow.message)")
        }
    }
}

private func processCPUSecondsForProbe() -> Double {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return -1 }
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
}

/// Explicit read-only screenshot probe. Raw media is saved only for this launch flag.
private struct CoreDeviceVideoGeometryProbeView: View {
    let statusPiP: StatusPiPController
    @State private var status = String(localized: "Video screenshot diagnostics")
    var body: some View {
        VStack(spacing: 20) { Text(String(localized: "Video screenshot diagnostics")).font(.title); Text(status) }
            .padding().frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(uiColor: .systemBackground))
            .task { await run() }
    }
    @MainActor private func run() async {
        let directory = URL.documentsDirectory
        let log = directory.appending(path: "coredevice-video-geometry-probe.log")
        var lines: [String] = []
        func record(_ value: String) {
            lines.append(Date().ISO8601Format() + " " + value)
            try? lines.joined(separator: "\n").write(to: log, atomically: true, encoding: .utf8)
            NSLog("CoreDevice video probe %@", value)
        }
        let flow = DeviceControlCoordinator.shared
        let backgroundProbe = ProcessInfo.processInfo.arguments.contains("--coredevice-video-background-probe")
        let repeatedProbe = backgroundProbe || ProcessInfo.processInfo.arguments.contains("--coredevice-video-repeat-probe")
        if backgroundProbe {
            BackgroundExecutionCoordinator.shared.applySelection([.audio])
            statusPiP.setControlProbeRunning(true)
        }
        defer { if backgroundProbe { statusPiP.setControlProbeRunning(false) } }
        record("started backgroundProbe=\(backgroundProbe)")
        if !flow.ready && !flow.running { flow.verify() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while !flow.ready && flow.running && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        guard flow.ready else { status = String(localized: "Connection is not ready"); record(flow.lastFailure ?? flow.statusText); return }
        var bridge: CoreDeviceBridge?
        do {
            let control = try CoreDeviceBridge(flow: flow); bridge = control
            for index in 0..<(repeatedProbe ? 7 : 3) {
                let frame = try await control.screenshot()
                try frame.png.write(to: directory.appending(path: "coredevice-video-probe-\(index).jpg"))
                if let keyframe = await flow.videoDiagnosticKeyframe() {
                    try keyframe.write(to: directory.appending(path: "coredevice-video-probe.hevc"))
                }
                record("screenshot \(index) \(frame.width)x\(frame.height) appState=\(UIApplication.shared.applicationState.rawValue)")
                status = String(localized: "Captured \(index+1)/\(repeatedProbe ? 7 : 3): \(frame.width) × \(frame.height)")
                if backgroundProbe && index == 0 {
                    try await Task.sleep(for: .seconds(3))
                    UIApplication.shared.perform(NSSelectorFromString("suspend"))
                }
                if backgroundProbe && ProcessInfo.processInfo.arguments.contains("--coredevice-static-screen-probe") && (index == 1 || index == 5) {
                    let context = try await control.systemActionContext()
                    try await control.authorizeSystemAction(authorizationID: context, taskScoped: false)
                    try await control.systemAction(name: "launch_app", text: index == 1 ? "com.apple.calculator" : "com.apple.Preferences", arguments: [], imageID: context)
                    record("visible change receiverState=\(UIApplication.shared.applicationState.rawValue)")
                }
                try await Task.sleep(for: .milliseconds(repeatedProbe ? 6000 : 1200))
            }
            record("completed")
        } catch { record("failed \(String(describing: error))"); status = String(localized: "Diagnostics did not finish") }
        if let bridge { await bridge.stop() }
    }
}

/// Explicit real-device fixture, no provider calls or user conversation writes.
private struct CoreDeviceToolsProbeView: View {
    let statusPiP: StatusPiPController
    @State private var status = String(localized: "Preparing verification")
    var body: some View {
        VStack(spacing: 24) {
            Text(String(localized: "ESP32 tool verification")).font(.title)
            Text(status)
        }.padding().frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(uiColor: .systemBackground))
        .task { await run() }
    }
    @MainActor private func run() async {
        let url = URL.documentsDirectory.appending(path: "coredevice-tools-probe.log")
        var records: [String] = []
        func record(_ value: String) { records.append(Date().ISO8601Format() + " " + value); try? records.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8) }
        let flow = DeviceControlCoordinator.shared
        statusPiP.setControlProbeRunning(true)
        let scheduler = CompositeRunScheduler(primary: ContinuedProcessingScheduler(), allowed: { [.audio, .systemTask] })
        let identifier = (Bundle.main.bundleIdentifier ?? "com.ja1chen.PhoneAgent") + ".backgroundRun." + UUID().uuidString
        var lease: (any RunBackgroundLease)?
        defer { lease?.complete(success: true); scheduler.cancel(identifier: identifier); statusPiP.setControlProbeRunning(false) }
        var expired = false
        do {
            try scheduler.submit(identifier: identifier, launched: { incoming in
                lease = incoming
                incoming.expirationHandler = { expired = true; record("execution expired") }
            })
        } catch { record("execution unavailable"); return }
        record("start")
        if !flow.ready && !flow.running { flow.verify() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while !flow.ready && flow.running && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        guard flow.ready else { record("connection not ready"); status = String(localized: "Connection is not ready"); return }
        statusPiP.setControlProbeRunning(true)
        do {
            let bridge = try CoreDeviceBridge(flow: flow)
            defer { Task { await bridge.stop() } }
            let data = try await bridge.installedApplications()
            let apps = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
            record("apps count=\(apps.count) notes=\(apps.contains { $0["bundle_id"] as? String == "com.apple.mobilenotes" })")
            var frame = try await bridge.screenshot()
            try await bridge.authorizeTaskInput(imageID: frame.id)
            try await bridge.systemAction(name: "home", text: "", arguments: [], imageID: frame.id)
            record("Home delivery acknowledged")
            try await Task.sleep(for: .seconds(1))
            frame = try await bridge.screenshot()
            try frame.png.write(to: URL.documentsDirectory.appending(path: "coredevice-tools-home.png"))
            guard !expired else { throw AppError.stopped }
            try await bridge.authorizeTaskInput(imageID: frame.id)
            try await bridge.systemAction(name: "launch_app", text: "com.apple.mobilenotes", arguments: [], imageID: frame.id)
            record("Notes launch acknowledged")
            try await Task.sleep(for: .seconds(1))
            frame = try await bridge.screenshot()
            let screenURL = URL.documentsDirectory.appending(path: "coredevice-tools-screen.png")
            try frame.png.write(to: screenURL)
            record("Notes screenshot ready \(frame.width)x\(frame.height)")
            lease?.report(completed: 3, subtitle: String(localized: "Home, app discovery, and Notes launch returned. Waiting for test actions."))
            // Explicit debug-only command fixture. Never read task history,
            // arbitrary typed text, identities or paths from this command file.
            let commandURL = URL.documentsDirectory.appending(path: "coredevice-tools-command.json")
            try? FileManager.default.removeItem(at: commandURL)
            var lastID = 0
            let testDeadline = ContinuousClock.now.advanced(by: .seconds(600))
            while ContinuousClock.now < testDeadline && !expired {
                try await Task.sleep(for: .milliseconds(200))
                guard let data = try? Data(contentsOf: commandURL), data.count < 4096,
                      let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let id = command["id"] as? Int, id > lastID,
                      let action = command["action"] as? String else { continue }
                // Commit consumption before dispatch; lost receipts never replay.
                lastID = id
                if action == "finish" { record("finished"); break }
                if action != "screenshot" {
                    try await bridge.authorizeTaskInput(imageID: frame.id)
                    if action == "tap" {
                        guard let x = command["x"] as? Int, let y = command["y"] as? Int else { throw AppError.invalid(String(localized: "Test coordinates are missing")) }
                        try await bridge.tap(x: x, y: y, imageID: frame.id)
                    } else if action == "type_text" {
                        try await bridge.systemAction(name: action, text: "ESP32 direct input", arguments: [], imageID: frame.id)
                    } else { throw AppError.invalid(String(localized: "Unsupported test action")) }
                    try await Task.sleep(for: .seconds(1))
                }
                frame = try await bridge.screenshot()
                try frame.png.write(to: screenURL)
                record("command id=\(id) action=\(action) delivered and screenshot received")
                lease?.report(completed: id + 3, subtitle: String(localized: "Notes verification returned a screenshot"))
            }
            status = String(localized: "Verification complete")
        } catch { status = String(localized: "Verification did not finish"); record("failed: " + String(describing: error)) }
    }
}
#endif
