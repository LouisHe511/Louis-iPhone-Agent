import XCTest
import UIKit
import SwiftAgentKit
import ProviderCore
@testable import PhoneAgent

private actor SpyBridge: DeviceBridge {
    private(set) var taps = 0
    private(set) var drags = 0
    private(set) var stopped = false
    private(set) var systemActions: [String] = []
    private(set) var insertedText = ""
    private(set) var launchArguments: [String] = []
    let tapError: AppError?
    let capturedAt: Date
    init(tapError: AppError? = nil, capturedAt: Date = Date()) { self.tapError = tapError; self.capturedAt = capturedAt }
    func screenshot() async throws -> FrameImage { FrameImage(id: "fresh", png: Data(), width: 390, height: 844, capturedAt: capturedAt, isDemo: true) }
    func tap(x: Int, y: Int, imageID: String) async throws { taps += 1; if let tapError { throw tapError } }
    func drag(fromX: Int, fromY: Int, toX: Int, toY: Int, durationMS: Int, imageID: String) async throws { drags += 1 }
    func systemActionContext() async throws -> String { "synthetic-system-session" }
    func authorizeSystemAction(authorizationID: String, taskScoped: Bool) async throws {}
    func installedApplications() async throws -> Data { Data("[{\"name\":\"Fixture\",\"bundle_id\":\"example.fixture\",\"path\":\"PRIVATE_PATH\"}]".utf8) }
    func systemAction(name: String, text: String, arguments: [String], imageID: String) async throws {
        systemActions.append(name); insertedText = text; launchArguments = arguments
    }
    func stop() async { stopped = true }
}
final class SafetyTests: XCTestCase {
    func testSystemActionsForwardExactTextAndArgumentsWithoutScreenshotDependency() async throws {
        let bridge = SpyBridge()
        let coordinator = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { _ in true }, onImage: { _, _ in }, onReceipt: { _ in })
        _ = try await coordinator.execute(name: "type_text", parameters: ["text": "你好 ESP32 🌟\n ", "purpose": "insert requested whitespace"], callID: "text")
        let text = await bridge.insertedText; XCTAssertEqual(text, "你好 ESP32 🌟\n ")
        _ = try await coordinator.execute(name: "home", parameters: ["purpose": "home"], callID: "home-no-frame")
        _ = try await coordinator.execute(name: "launch_app", parameters: ["bundle_id": "example.fixture", "arguments": ["--test", "值"], "purpose": "open fixture"], callID: "launch")
        let arguments = await bridge.launchArguments, actions = await bridge.systemActions
        XCTAssertEqual(arguments, ["--test", "值"]); XCTAssertEqual(actions, ["type_text", "home", "launch_app"])
    }
    func testInvalidTextFailsBeforeApprovalAndKeepsSessionUsable() async throws {
        for text in ["a\0b", String(repeating: "a", count: 8193)] {
            let bridge = SpyBridge()
            let coordinator = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { _ in true }, onImage: { _, _ in }, onReceipt: { _ in })
            _ = try await coordinator.execute(name: "screenshot", parameters: [:], callID: "image")
            let actions = ToolActions()
            let tool = DeviceTool(name: "type_text", coordinator: coordinator)
            let result = try await tool.execute(context: ToolContext(callId: "invalid", toolName: "type_text", parameters: ["text": text, "purpose": "unsupported fixture"], state: AgentState(), actions: actions))
            XCTAssertTrue(result.isError); XCTAssertFalse(actions.shouldStop)
            let dispatched = await bridge.systemActions; XCTAssertTrue(dispatched.isEmpty)
            _ = try await coordinator.execute(name: "screenshot", parameters: [:], callID: "fresh-after-error")
            _ = try await coordinator.execute(name: "type_text", parameters: ["text": "valid", "purpose": "fixture"], callID: "valid")
            let inserted = await bridge.insertedText; XCTAssertEqual(inserted, "valid")
            await coordinator.stop()
        }
    }
    func testAppQueryNeedsNoScreenshotAndDoesNotExposePrivatePaths() async throws {
        let coordinator = ActionCoordinator(bridge: SpyBridge(), limits: AgentLimits(), approve: { _ in XCTFail("read query requested input approval"); return false }, onImage: { _, _ in }, onReceipt: { _ in })
        let result = try await coordinator.execute(name: "list_apps", parameters: [:], callID: "apps")
        XCTAssertFalse(result.isError); XCTAssertTrue(result.result.contains("example.fixture"))
        XCTAssertFalse(result.result.contains("PRIVATE_PATH"))
    }
    func testInputSchemasRequireCoordinatesScreenshotReferenceAndPurpose() {
        let coordinator = ActionCoordinator(bridge: SpyBridge(), limits: AgentLimits(), approve: { _ in true }, onImage: { _, _ in }, onReceipt: { _ in })
        for (name, keys) in [("tap", ["x", "y", "image_id", "purpose"]),
                             ("drag", ["from_x", "from_y", "to_x", "to_y", "duration_ms", "image_id", "purpose"])] {
            let schema = DeviceTool(name: name, coordinator: coordinator).parameters
            XCTAssertEqual(Set(schema.properties.keys), Set(keys))
            XCTAssertEqual(Set(schema.required), Set(keys))
        }
    }
    func testExplicitReferenceStillRequiresPerActionApproval() async throws {
        let bridge = SpyBridge(capturedAt: Date().addingTimeInterval(-3_600))
        let coordinator = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { request in
            XCTAssertGreaterThan(request.expiresAt.timeIntervalSinceNow, 40, "Request timeout must not be based on capture time")
            return true
        }, onImage: { _, _ in }, onReceipt: { _ in })
        _ = try await coordinator.execute(name: "screenshot", parameters: [:], callID: "s1")
        _ = try await coordinator.execute(name: "tap", parameters: ["image_id": "fresh", "x": 100, "y": 100, "purpose": "fixture tap"], callID: "t")
        _ = try await coordinator.execute(name: "screenshot", parameters: [:], callID: "s2")
        _ = try await coordinator.execute(name: "drag", parameters: ["image_id": "fresh", "from_x": 100, "from_y": 100, "to_x": 120, "to_y": 120, "duration_ms": 200, "purpose": "fixture drag"], callID: "d")
        _ = try await coordinator.execute(name: "screenshot", parameters: [:], callID: "s3")
        _ = try await coordinator.execute(name: "finish", parameters: ["summary": "fixture finished"], callID: "f")
        let taps = await bridge.taps, drags = await bridge.drags
        XCTAssertEqual(taps, 1); XCTAssertEqual(drags, 1)
    }
    func testToolValidationErrorReturnsNormallyAndAllowsCorrectedCall() async throws {
        let c = ActionCoordinator(bridge: SpyBridge(), limits: AgentLimits(), approve: { _ in true }, onImage: { _, _ in }, onReceipt: { _ in })
        let actions = ToolActions()
        let tool = DeviceTool(name: "wait", coordinator: c)
        let failed = try await tool.execute(context: ToolContext(callId: "bad", toolName: "wait", parameters: ["duration_ms": 0], state: AgentState(), actions: actions))
        XCTAssertTrue(failed.isError)
        XCTAssertEqual(failed.result, String(localized: "Wait duration must be 1–10,000 milliseconds"))
        XCTAssertEqual(failed.toolCallId, "bad")
        XCTAssertFalse(actions.shouldStop)
        let corrected = try await tool.execute(context: ToolContext(callId: "corrected", toolName: "wait", parameters: ["duration_ms": 1], state: AgentState(), actions: actions))
        XCTAssertFalse(corrected.isError)
        XCTAssertFalse(actions.shouldStop)
    }
    func testUncertainInputReturnsErrorThenAllowsObservedNextActionWithoutReplay() async throws {
        let bridge = SpyBridge(tapError: .unknownOutcome)
        let c = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { _ in true }, onImage: { _, _ in }, onReceipt: { _ in })
        let actions = ToolActions()
        _ = try await c.execute(name: "screenshot", parameters: [:], callID: "s")
        let failed = try await DeviceTool(name: "tap", coordinator: c).execute(context:
            ToolContext(callId: "t", toolName: "tap", parameters: ["image_id": "fresh", "x": 100, "y": 100, "purpose": "test"], state: AgentState(), actions: actions))
        XCTAssertTrue(failed.isError)
        XCTAssertTrue(failed.result.contains("动作结果未知"))
        XCTAssertTrue(failed.result.contains("未自动重发"))
        XCTAssertFalse(failed.result.contains("截图"))
        XCTAssertFalse(actions.shouldStop)
        do {
            _ = try await c.execute(name: "tap", parameters: ["image_id": "fresh", "x": 100, "y": 100, "purpose": "no old frame"], callID: "no-frame")
            XCTFail("An unknown action must consume its old image")
        } catch { XCTAssertTrue(error is AppError) }
        for name in ["drag", "home", "launch_app", "type_text"] {
            _ = try await c.execute(name: "screenshot", parameters: [:], callID: "s-" + name)
            let result = try await DeviceTool(name: name, coordinator: c).execute(context:
                ToolContext(callId: "next-" + name, toolName: name, parameters: ["image_id": "fresh", "from_x": 100, "from_y": 100, "to_x": 120, "to_y": 120, "duration_ms": 200, "purpose": "observed next step", "bundle_id": "example.fixture", "text": "fixture"], state: AgentState(), actions: actions))
            XCTAssertFalse(result.isError)
            XCTAssertFalse(actions.shouldStop)
        }
        let taps = await bridge.taps, drags = await bridge.drags
        XCTAssertEqual(taps, 1, "The unknown tap is never resent automatically")
        XCTAssertEqual(drags, 1)
    }
    func testExplicitStopStillEndsToolExecution() async throws {
        let c = ActionCoordinator(bridge: SpyBridge(), limits: AgentLimits(), approve: { _ in true }, onImage: { _, _ in }, onReceipt: { _ in })
        await c.stop()
        let actions = ToolActions()
        do {
            _ = try await DeviceTool(name: "screenshot", coordinator: c).execute(context: ToolContext(callId: "s", toolName: "screenshot", parameters: [:], state: AgentState(), actions: actions))
            XCTFail("An explicit stop must not become a recoverable tool result")
        } catch { XCTAssertEqual(error as? AppError, .stopped) }
        XCTAssertTrue(actions.shouldStop)
    }
    func testApprovalDeniedNeverSendsInput() async throws {
        let bridge = SpyBridge()
        let c = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { _ in false }, onImage: { _, _ in }, onReceipt: { _ in })
        _ = try await c.execute(name: "screenshot", parameters: [:], callID: "s")
        do {
            _ = try await c.execute(name: "tap", parameters: ["image_id": "fresh", "x": 100, "y": 100, "purpose": "test"], callID: "t")
            XCTFail("Denied input must not run")
        } catch {}
        let count = await bridge.taps; XCTAssertEqual(count, 0)
    }
    func testTaskAuthorizationCannotGrantAnUnsupportedBridgeInputPermission() async throws {
        let bridge = SpyBridge()
        let c = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { _ in true },
                                  onImage: { _, _ in }, onReceipt: { _ in }, authorizationMode: .task)
        _ = try await c.execute(name: "screenshot", parameters: [:], callID: "s")
        do {
            _ = try await c.execute(name: "tap", parameters: ["image_id": "fresh", "x": 100, "y": 100, "purpose": "fixture"], callID: "t")
            XCTFail("Task authorization must be explicitly supported by the input bridge")
        } catch { XCTAssertTrue(error.localizedDescription.contains("不支持任务内自动授权")) }
        let count = await bridge.taps; XCTAssertEqual(count, 0)
    }
    func testCoordinateReferencePersistsButEachInputStillNeedsApproval() async throws {
        let bridge = SpyBridge()
        let c = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { $0.callID != "denied" }, onImage: { _, _ in }, onReceipt: { _ in })
        _ = try await c.execute(name: "screenshot", parameters: [:], callID: "s")
        let p: [String: Any] = ["image_id": "fresh", "x": 100, "y": 100, "purpose": "test"]
        _ = try await c.execute(name: "tap", parameters: p, callID: "t1")
        _ = try await c.execute(name: "tap", parameters: p, callID: "t2")
        do { _ = try await c.execute(name: "tap", parameters: p, callID: "denied"); XCTFail("Retained reference cannot bypass approval") }
        catch { XCTAssertEqual(error as? AppError, .stopped) }
        let count = await bridge.taps; XCTAssertEqual(count, 2)
    }
    func testStopFencesLaterTools() async throws {
        let bridge = SpyBridge()
        let c = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { _ in true }, onImage: { _, _ in }, onReceipt: { _ in })
        await c.stop()
        do { _ = try await c.execute(name: "screenshot", parameters: [:], callID: "s"); XCTFail("Stopped session must fail") } catch {}
        let value = await bridge.stopped; XCTAssertTrue(value)
    }
    func testLegacyFinishCanEndWithoutAnExtraObservation() async throws {
        let c = ActionCoordinator(bridge: SpyBridge(), limits: AgentLimits(), approve: { _ in true }, onImage: { _, _ in }, onReceipt: { _ in })
        _ = try await c.execute(name: "finish", parameters: ["summary": "done"], callID: "f")
        let summary = await c.finishSummary; XCTAssertEqual(summary, "done")
    }
    func testBooleansCannotBecomePixelCoordinates() async throws {
        let bridge = SpyBridge()
        let c = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { _ in true }, onImage: { _, _ in }, onReceipt: { _ in })
        _ = try await c.execute(name: "screenshot", parameters: [:], callID: "s")
        do { _ = try await c.execute(name: "tap", parameters: ["x": true, "y": 0, "purpose": "bad"], callID: "t"); XCTFail("Boolean must fail") } catch {}
        let count = await bridge.taps; XCTAssertEqual(count, 0)
    }
    func testOpenAIToolImagesUseAdjacentUserMessage() throws {
        let settings = ProviderSettings(baseURL: "https://example.com/v1", model: "vision")
        let provider = try PrivateVisionProvider(settings: settings, apiKey: "test-only-not-a-real-key", limits: AgentLimits())
        defer { provider.cancel() }
        let image = ModelImage(data: Data([1,2,3]))
        let request = ModelRequest(model: "vision", messages: [
            .assistant(content: "", toolCalls: [ModelToolCall(id: "call", name: "screenshot", arguments: "{}")]),
            ModelMessage(role: .tool, content: "screen", images: [image], toolCallId: "call")
        ])
        let body = try XCTUnwrap(try provider.prepareRequest(request, stream: false).httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["assistant", "tool", "user"])
        XCTAssertTrue(messages[1]["content"] is String)
        XCTAssertTrue(messages[2]["content"] is [[String: Any]])
        XCTAssertEqual(object["parallel_tool_calls"] as? Bool, true)
    }
}

private actor OCRRecoveryBridge: DeviceBridge {
    let bytes: Data
    private(set) var captures = 0
    private(set) var taps = 0
    private(set) var stopped = false
    init(bytes: Data) { self.bytes = bytes }
    func screenshot() async throws -> FrameImage {
        captures += 1
        return FrameImage(id: "frame-\(captures)", png: bytes, width: 402, height: 874, capturedAt: Date(), isDemo: true)
    }
    func tap(x: Int, y: Int, imageID: String) async throws { taps += 1 }
    func drag(fromX: Int, fromY: Int, toX: Int, toY: Int, durationMS: Int, imageID: String) async throws {}
    func stop() async { stopped = true }
}

@MainActor final class OCRRegressionTests: XCTestCase {
    private func image() -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 3
        return UIGraphicsImageRenderer(size: CGSize(width: 402, height: 874), format: format).jpegData(withCompressionQuality: 0.9) { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 402, height: 874))
            ("提交（不限次）" as NSString).draw(at: CGPoint(x: 80, y: 800), withAttributes: [.font: UIFont.systemFont(ofSize: 17), .foregroundColor: UIColor.black])
        }
    }
    func testCloudImagePixelLimitDoesNotDependOnDisplayScale() throws {
        let source = image()
        XCTAssertEqual(UIImage(data: source)?.cgImage?.height, 2622)
        let cloud = try XCTUnwrap(ActionCoordinator.griddedPNG(source))
        let cg = try XCTUnwrap(UIImage(data: cloud)?.cgImage)
        XCTAssertLessThanOrEqual(max(cg.width, cg.height), 900)
        XCTAssertLessThan(cloud.count, 250_000)
    }
    func testLowConfidenceChineseLabelRequiresMatchingCropAtSameLocation() async throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 3
        let bytes = UIGraphicsImageRenderer(size: CGSize(width: 402, height: 874), format: format).jpegData(withCompressionQuality: 0.9) { ctx in
            UIColor.systemBlue.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 402, height: 874))
            ("提交（不限次）" as NSString).draw(at: CGPoint(x: 110, y: 730), withAttributes: [.font: UIFont.systemFont(ofSize: 20, weight: .semibold), .foregroundColor: UIColor.white])
        }
        let hits = try await ScreenTextOCR.locate(in: bytes, target: "提交（不限次）")
        let found = try XCTUnwrap(hits.first)
        let low = OCRTextHit(text: found.text, confidence: 0.30, x: found.x, y: found.y, top: found.top, left: found.left, boundingBox: found.boundingBox)
        let verified = try await ScreenTextOCR.verifyIfNeeded(in: bytes, target: "提交（不限次）", hit: low)
        XCTAssertTrue(verified.verifiedByCrop)
        XCTAssertEqual(verified.x, found.x); XCTAssertEqual(verified.y, found.y)
        let wrongLabel = try await ScreenTextOCR.verifyIfNeeded(in: bytes, target: "不存在", hit: low)
        XCTAssertFalse(wrongLabel.verifiedByCrop)
        let misplaced = OCRTextHit(text: found.text, confidence: 0.30, x: 100, y: 100, top: 0.1, left: 0.1, boundingBox: CGRect(x: 0.05, y: 0.8, width: 0.3, height: 0.04))
        let wrongLocation = try await ScreenTextOCR.verifyIfNeeded(in: bytes, target: "提交（不限次）", hit: misplaced)
        XCTAssertFalse(wrongLocation.verifiedByCrop)
    }
    func testNormalizedSubstringMapsBackToOriginalChinesePunctuationAndWhitespace() {
        let text = "左侧 提 交（不 限 次） 右侧"
        let ranges = ScreenTextOCR.matchingRanges(of: "提交 (不限次)", in: text)
        XCTAssertEqual(ranges.map { String(text[$0]) }, ["提 交（不 限 次）"])
        XCTAssertTrue(ScreenTextOCR.matchingRanges(of: "不存在", in: text).isEmpty)
        XCTAssertTrue(ScreenTextOCR.matchingRanges(of: "  ", in: text).isEmpty)
    }
    func testOCRFailureReturnsFreshFrameAndShorterLabelCanRecoverWithoutLosingImage() async throws {
        let bridge = OCRRecoveryBridge(bytes: image())
        let coordinator = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { _ in true }, onImage: { _, _ in }, onReceipt: { _ in }, locateText: { _, target in
            target == "提交" ? [OCRTextHit(text: target, confidence: 0.95, x: 500, y: 950, top: 0.9, left: 0.3)] : []
        })
        _ = try await coordinator.execute(name: "screenshot", parameters: [:], callID: "initial")
        let tool = DeviceTool(name: "tap_text", coordinator: coordinator)
        let failed = try await tool.execute(context: ToolContext(callId: "lookup", toolName: "tap_text", parameters: ["image_id": "frame-1", "text": "提交（不限次）", "purpose": "fixture"], state: AgentState(), actions: ToolActions()))
        XCTAssertTrue(failed.isError)
        XCTAssertTrue(failed.result.contains("frame-2"))
        XCTAssertEqual(failed.images.count, 1)
        let noTaps = await bridge.taps; XCTAssertEqual(noTaps, 0)
        let recovered = try await tool.execute(context: ToolContext(callId: "shorter", toolName: "tap_text", parameters: ["image_id": "frame-2", "text": "提交", "purpose": "fixture"], state: AgentState(), actions: ToolActions()))
        XCTAssertFalse(recovered.isError)
        let taps = await bridge.taps; XCTAssertEqual(taps, 1)
        let captures = await bridge.captures; XCTAssertEqual(captures, 4)
        await coordinator.stop()
    }
    func testTwoOCRFailuresStopTaskWithoutAnyTapAndReadToolsDoNotResetFailures() async throws {
        let bridge = OCRRecoveryBridge(bytes: image())
        let coordinator = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { _ in true }, onImage: { _, _ in }, onReceipt: { _ in }, locateText: { _, _ in [] })
        _ = try await coordinator.execute(name: "screenshot", parameters: [:], callID: "initial")
        let tool = DeviceTool(name: "tap_text", coordinator: coordinator)
        let firstActions = ToolActions()
        _ = try await tool.execute(context: ToolContext(callId: "first", toolName: "tap_text", parameters: ["image_id": "frame-1", "text": "absent", "purpose": "fixture"], state: AgentState(), actions: firstActions))
        XCTAssertFalse(firstActions.shouldStop)
        _ = try await coordinator.execute(name: "screenshot", parameters: [:], callID: "observe-again")
        let secondActions = ToolActions()
        let second = try await tool.execute(context: ToolContext(callId: "second", toolName: "tap_text", parameters: ["image_id": "frame-3", "text": "absent", "purpose": "fixture"], state: AgentState(), actions: secondActions))
        XCTAssertTrue(second.isError); XCTAssertTrue(secondActions.shouldStop)
        let taps = await bridge.taps, stopped = await bridge.stopped
        XCTAssertEqual(taps, 0); XCTAssertTrue(stopped)
    }
    func testKeyboardIconCanRecoverAfterLabelMissUsingCurrentFrame() async throws {
        let bridge = OCRRecoveryBridge(bytes: image())
        let coordinator = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { _ in true }, onImage: { _, _ in }, onReceipt: { _ in }, locateText: { _, _ in [] })
        _ = try await coordinator.execute(name: "screenshot", parameters: [:], callID: "initial")
        let tool = DeviceTool(name: "dismiss_keyboard", coordinator: coordinator)
        let failed = try await tool.execute(context: ToolContext(callId: "label-miss", toolName: "dismiss_keyboard", parameters: [:], state: AgentState(), actions: ToolActions()))
        XCTAssertTrue(failed.isError); XCTAssertTrue(failed.result.contains("frame-2")); XCTAssertEqual(failed.images.count, 1)
        let actions = ToolActions()
        let recovered = try await tool.execute(context: ToolContext(callId: "visible-icon", toolName: "dismiss_keyboard", parameters: ["image_id": "frame-2", "x": 900, "y": 580], state: AgentState(), actions: actions))
        XCTAssertFalse(recovered.isError); XCTAssertFalse(actions.shouldStop)
        XCTAssertTrue(recovered.result.contains("frame-3")); XCTAssertEqual(recovered.images.count, 1)
        let taps = await bridge.taps; XCTAssertEqual(taps, 1)
        do {
            _ = try await coordinator.execute(name: "dismiss_keyboard", parameters: ["image_id": "frame-2", "x": 900, "y": 580], callID: "stale")
            XCTFail("Consumed visual reference must not dispatch another tap")
        } catch {}
        let after = await bridge.taps; XCTAssertEqual(after, 1)
        await coordinator.stop()
    }
    func testKeyboardIconNeedsBothCoordinatesCurrentFrameAndApproval() async throws {
        for parameters: [String: Any] in [["x": 900], ["x": 900, "y": 580], ["x": 900, "y": 580, "image_id": "other-run"], ["x": true, "y": 580, "image_id": "frame-1"]] {
            let bridge = OCRRecoveryBridge(bytes: image())
            let coordinator = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { _ in XCTFail("Malformed target must fail before approval"); return true }, onImage: { _, _ in }, onReceipt: { _ in })
            _ = try await coordinator.execute(name: "screenshot", parameters: [:], callID: "initial")
            do { _ = try await coordinator.execute(name: "dismiss_keyboard", parameters: parameters, callID: "invalid"); XCTFail("Invalid visual reference") } catch {}
            let taps = await bridge.taps; XCTAssertEqual(taps, 0)
            await coordinator.stop()
        }
        let bridge = OCRRecoveryBridge(bytes: image())
        let coordinator = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { _ in false }, onImage: { _, _ in }, onReceipt: { _ in })
        _ = try await coordinator.execute(name: "screenshot", parameters: [:], callID: "initial")
        do { _ = try await coordinator.execute(name: "dismiss_keyboard", parameters: ["image_id": "frame-1", "x": 900, "y": 580], callID: "denied"); XCTFail("No input without approval") } catch {}
        let taps = await bridge.taps; XCTAssertEqual(taps, 0)
        await coordinator.stop()
    }
    func testForeignImageReferenceAndUnidentifiedKeyboardNeverDispatch() async throws {
        let bridge = OCRRecoveryBridge(bytes: image())
        let coordinator = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { _ in true }, onImage: { _, _ in }, onReceipt: { _ in }, locateText: { _, _ in [] })
        _ = try await coordinator.execute(name: "screenshot", parameters: [:], callID: "initial")
        do {
            _ = try await coordinator.execute(name: "tap_text", parameters: ["image_id": "other-run", "text": "提交", "purpose": "fixture"], callID: "foreign")
            XCTFail("Foreign references cannot authorize a fresh text tap")
        } catch {}
        do {
            _ = try await coordinator.execute(name: "dismiss_keyboard", parameters: [:], callID: "keyboard")
            XCTFail("Missing close label must not fall back to guessed coordinates")
        } catch is TextTargetError {}
        let taps = await bridge.taps; XCTAssertEqual(taps, 0)
        await coordinator.stop()
    }
}
