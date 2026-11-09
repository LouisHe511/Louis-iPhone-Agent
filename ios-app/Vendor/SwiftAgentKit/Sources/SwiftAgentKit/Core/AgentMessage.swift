//
//  AgentMessage.swift
//  SwiftAgentKit
//
//  Created by SwiftAgentKit — generalized from production app agent patterns.
//

import Foundation
import ProviderCore

/// A single message in an agent conversation.
///
/// Extends ProviderCore's `ModelMessage` with agent-specific fields:
/// tool calls (assistant requesting tool execution) and tool results
/// (user/system feeding tool output back to the model).
///
/// This is the universal message type that flows through every agent loop,
/// every memory store, and every LLM call in SwiftAgentKit.
///
public struct AgentMessage: Identifiable, @unchecked Sendable, Codable {

    public let id: UUID
    public var role: AgentMessageRole
    public var content: String
    public var images: [ModelImage]
    public var replayState: ScopedChatReplayState?
    public var toolCalls: [AgentToolCall]?
    public var toolResults: [AgentToolResult]?
    public let timestamp: Date

    // MARK: - Init

    public init(
        id: UUID = UUID(),
        role: AgentMessageRole,
        content: String,
        images: [ModelImage] = [],
        toolCalls: [AgentToolCall]? = nil,
        toolResults: [AgentToolResult]? = nil,
        timestamp: Date = Date(),
        replayState: ScopedChatReplayState? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.images = images
        self.toolCalls = toolCalls
        self.toolResults = toolResults
        self.timestamp = timestamp
        self.replayState = replayState
    }

    // MARK: - Factories

    /// Create a system message.
    public static func system(_ content: String) -> AgentMessage {
        AgentMessage(role: .system, content: content)
    }

    /// Create a user message (text only).
    public static func user(_ content: String) -> AgentMessage {
        AgentMessage(role: .user, content: content)
    }

    /// Create a user message with images (for vision-capable models).
    public static func user(_ content: String, images: [ModelImage]) -> AgentMessage {
        AgentMessage(role: .user, content: content, images: images)
    }

    /// Create an assistant message (model response).
    public static func assistant(_ content: String, replayState: ScopedChatReplayState? = nil) -> AgentMessage {
        AgentMessage(role: .assistant, content: content, replayState: replayState)
    }

    /// Create an assistant message with tool calls.
    public static func assistant(content: String = "", toolCalls: [AgentToolCall], replayState: ScopedChatReplayState? = nil) -> AgentMessage {
        AgentMessage(role: .assistant, content: content, toolCalls: toolCalls, replayState: replayState)
    }

    /// Create a tool-result message (fed back to the model after tool execution).
    public static func tool(results: [AgentToolResult]) -> AgentMessage {
        AgentMessage(role: .tool, content: "", toolResults: results)
    }

    // MARK: - Conversion to ProviderCore

    /// Convert to one or more `ModelMessage` values for the LLM provider layer.
    ///
    /// Most agent messages map to exactly one provider message. Tool-result
    /// messages are the exception: strict providers require one provider message
    /// per original tool call ID, so a single `.tool(results:)` agent message fans
    /// out into multiple `ModelMessage.tool` messages.
    public func toModelMessages() -> [ModelMessage] {
        switch role {
        case .tool:
            guard let toolResults, !toolResults.isEmpty else {
                return [.user(content)]
            }

            return toolResults.map { result in
                let status = result.isError ? "ERROR" : "OK"
                let toolName = result.toolName ?? "unknown"
                let content = "[Tool: \(toolName)] \(status)\n\(result.result)"
                return ModelMessage(role: .tool, content: content, images: result.images, toolCallId: result.toolCallId)
            }

        default:
            return [toModelMessage()]
        }
    }

    /// Convert to a single `ModelMessage` for the LLM provider layer.
    ///
    /// Prefer `toModelMessages()` when building provider requests from conversation
    /// history because tool-result messages may need to fan out. This method is
    /// kept for source compatibility and for contexts that explicitly require a
    /// single provider message.
    public func toModelMessage() -> ModelMessage {
        switch role {
        case .system:
            return .system(content)

        case .user:
            if images.isEmpty {
                return .user(content)
            }
            return .user(content, images: images)

        case .assistant:
            if let toolCalls, !toolCalls.isEmpty {
                // Convert AgentToolCall to ModelToolCall so the provider
                // can serialize them for the model to correlate results
                let llmToolCalls = toolCalls.map { call in
                    // Serialize parameters to JSON string
                    let paramsData = try? JSONEncoder().encode(call.parameters)
                    let argsString = paramsData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    return ModelToolCall(
                        id: call.id,
                        name: call.name,
                        arguments: argsString,
                        providerMetadata: call.providerMetadata
                    )
                }
                return .assistant(content: content, toolCalls: llmToolCalls, replayState: replayState)
            }
            return .assistant(content, replayState: replayState)

        case .tool:
            if let first = toModelMessages().first {
                return first
            }
            return .user(content)
        }
    }
}

// MARK: - Message Role

public enum AgentMessageRole: String, Sendable, Codable, Equatable, CaseIterable {
    case system
    case user
    case assistant
    case tool
}

// MARK: - Tool Call

/// A request from the model to execute a tool.
///
/// When the LLM returns tool calls, each call is parsed into this type.
/// The agent loop dispatches it to the registered `AgentTool` by name.
///
public struct AgentToolCall: Identifiable, Codable, @unchecked Sendable {

    public let id: String
    public var name: String
    public var parameters: [String: AnyCodable]
    public var providerMetadata: [String: String]

    public init(
        id: String = UUID().uuidString,
        name: String,
        parameters: [String: AnyCodable] = [:],
        providerMetadata: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.parameters = parameters
        self.providerMetadata = providerMetadata
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case parameters
        case providerMetadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        parameters = try container.decode([String: AnyCodable].self, forKey: .parameters)
        providerMetadata = try container.decodeIfPresent([String: String].self, forKey: .providerMetadata) ?? [:]
    }

    /// A stable deduplication key (name + sorted parameters).
    public var deduplicationKey: String {
        let sortedParams = parameters
            .sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.value)" }
            .joined(separator: ",")
        return "\(name)|\(sortedParams)"
    }
}

// MARK: - Tool Result

/// The result of executing a tool call.
///
/// Fed back to the model as a `tool` message so the loop can continue.
///
public struct AgentToolResult: Sendable, Identifiable, Equatable, Codable {

    public let id: String
    public let toolCallId: String
    public let toolName: String?
    public let result: String
    public let isError: Bool
    /// Images the tool returned (e.g. a screenshot), for vision-capable models.
    public let images: [ModelImage]

    public init(
        id: String = UUID().uuidString,
        toolCallId: String,
        toolName: String? = nil,
        result: String,
        isError: Bool = false,
        images: [ModelImage] = []
    ) {
        self.id = id
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.result = result
        self.isError = isError
        self.images = images
    }

    /// Create a successful result.
    public static func success(toolCallId: String, toolName: String?, result: String, images: [ModelImage] = []) -> AgentToolResult {
        AgentToolResult(toolCallId: toolCallId, toolName: toolName, result: result, isError: false, images: images)
    }

    /// Create an error result.
    public static func error(toolCallId: String, toolName: String?, message: String, images: [ModelImage] = []) -> AgentToolResult {
        AgentToolResult(toolCallId: toolCallId, toolName: toolName, result: message, isError: true, images: images)
    }
}

// MARK: - AnyCodable

/// A type-erased Codable wrapper for heterogeneous JSON values.
///
/// Tool parameters come back from LLMs as arbitrary JSON (bool/int/double/string/array/dict/null).
/// `AnyCodable` safely decodes and re-encodes any JSON value without losing type information.
///
/// This mirrors a production-proven pattern for heterogeneous JSON values.
///
public struct AnyCodable: @unchecked Sendable, Codable {

    public let value: Any

    // MARK: - Equatable (custom, since Any is not Equatable)

    public static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        // Compare by JSON-encoded string for robust equality
        let lhsData = try? JSONSerialization.data(withJSONObject: lhs.value, options: [.sortedKeys])
        let rhsData = try? JSONSerialization.data(withJSONObject: rhs.value, options: [.sortedKeys])
        return lhsData == rhsData
    }

    public init(_ value: Any) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self.value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            self.value = bool
        } else if let int = try? container.decode(Int.self) {
            self.value = int
        } else if let double = try? container.decode(Double.self) {
            self.value = double
        } else if let string = try? container.decode(String.self) {
            self.value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            self.value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            self.value = dict.mapValues { $0.value }
        } else {
            self.value = NSNull()
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            try container.encodeNil()
        }
    }

    // MARK: - Convenience accessors

    public var stringValue: String? { value as? String }
    public var intValue: Int? { value as? Int }
    public var doubleValue: Double? { value as? Double }
    public var boolValue: Bool? { value as? Bool }
    public var arrayValue: [Any]? { value as? [Any] }
    public var dictValue: [String: Any]? { value as? [String: Any] }

    /// Convert to a plain `[String: Any]` dictionary (for tool execution).
    public func toDictionary() -> [String: Any] {
        (value as? [String: Any]) ?? [:]
    }
}
