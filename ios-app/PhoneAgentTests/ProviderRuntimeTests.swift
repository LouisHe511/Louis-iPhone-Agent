import XCTest
import SwiftAgentKit
import ProviderCore
@testable import PhoneAgent

private actor ProviderSideEffects {
    var count = 0
    func execute() { count += 1 }
}
private struct CountedDeviceTool: AgentTool {
    let name = "tap", description = "Synthetic device side effect only"
    let parameters = ToolParameters.empty
    let effects: ProviderSideEffects
    func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        await effects.execute()
        return .success(toolCallId: "", toolName: name, result: "receipt:already-executed")
    }
}
private final class RuntimeFixtureProvider: ModelProvider, @unchecked Sendable {
    enum Behavior { case roundTrip, repeatCall, partialTool, onlyToolSignal, resultSubmissionFailure, failure, incomplete }
    static let name = "native-runtime-fixture"
    let configuration = ProviderConfiguration(name: name, baseURL: URL(string: "https://invalid.invalid")!, defaultModel: "fixture")
    let behavior: Behavior
    private let lock = NSLock()
    private var requests: [ModelRequest] = []
    private var completes = 0
    init(_ behavior: Behavior) { self.behavior = behavior }
    var counts: (Int, Int) { lock.withLock { (requests.count, completes) } }
    func complete(_ request: ModelRequest) async throws -> ModelResponse { lock.withLock { completes += 1 }; throw ModelError.interrupted }
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        let index = lock.withLock { requests.append(request); return requests.count }
        return AsyncThrowingStream { c in
            if behavior == .failure || (behavior == .resultSubmissionFailure && index > 1) { c.finish(throwing: ModelError.interrupted); return }
            let call = ModelToolCall(id: "stable-call", itemID: "separate-item", name: "tap", arguments: "{}", status: .completed)
            if behavior == .partialTool { c.yield(.toolCall(call)); c.finish(); return }
            if behavior == .onlyToolSignal { c.yield(.finish(reason: .toolCalls, usage: nil)); c.finish(); return }
            if behavior == .incomplete {
                c.yield(.terminal(.init(id: "r", model: "fixture", status: .incomplete, output: [.functionCall(call)], request: request, providerName: Self.name))); c.finish(); return
            }
            if index == 1 || behavior == .repeatCall {
                c.yield(.terminal(.init(id: "r\(index)", model: "fixture", status: .completed, output: [.functionCall(call)], request: request, providerName: Self.name)))
            } else {
                XCTAssertEqual(request.messages.filter { $0.role == .tool }.map(\.toolCallId), ["stable-call"])
                XCTAssertTrue(request.messages.contains { $0.content.contains("receipt:already-executed") })
                c.yield(.terminal(.init(id: "r\(index)", model: "fixture", status: .completed, output: [.message(.init(id: "m", content: [.text("done", annotations: [])]))], request: request, providerName: Self.name)))
            }
            c.finish()
        }
    }
}
final class ProviderRuntimeTests: XCTestCase {
    private func run(_ behavior: RuntimeFixtureProvider.Behavior) async throws -> (RuntimeFixtureProvider, ProviderSideEffects) {
        let p = RuntimeFixtureProvider(behavior), e = ProviderSideEffects()
        let agent = Agent(config: AgentConfig(provider: p, enableRepairRetry: false, tools: [CountedDeviceTool(effects: e)], loopDetection: nil, parallelToolCalls: false))
        do {
            for try await _ in agent.runStreamingTagged("synthetic") {}
            if behavior != .roundTrip { XCTFail("Expected failure") }
        } catch { if behavior == .roundTrip { throw error } }
        return (p, e)
    }
    func testNativeToolsRoundTripAndRepeatedCallsNeverRepeatDeviceSideEffect() async throws {
        for behavior in [RuntimeFixtureProvider.Behavior.roundTrip, .repeatCall, .resultSubmissionFailure] {
            let (p, e) = try await run(behavior)
            let count = await e.count; XCTAssertEqual(count, 1); XCTAssertEqual(p.counts.0, 2); XCTAssertEqual(p.counts.1, 0)
        }
    }
    func testIncompleteOrPartialToolStreamsAndUncertainErrorsDoNotRegenerateOrDispatch() async throws {
        for behavior in [RuntimeFixtureProvider.Behavior.partialTool, .onlyToolSignal, .failure, .incomplete] {
            let (p, e) = try await run(behavior)
            let count = await e.count; XCTAssertEqual(count, 0); XCTAssertEqual(p.counts.0, 1); XCTAssertEqual(p.counts.1, 0)
        }
    }
}
