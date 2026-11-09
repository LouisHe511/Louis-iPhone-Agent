import XCTest
import SwiftAgentKit
import ProviderCore
@testable import PhoneAgent

@MainActor final class SkillTests: XCTestCase {
    private let document = "---\nname: Synthetic Guide\ndescription: Read synthetic fixtures\nversion: 1\n---\nBODY_NOT_A_SUMMARY\nSee [reference](references/guide.md)."
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("skills-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    func testBuiltinIsAvailableByMetadataAndExactRevisionWithoutPersistingIt() throws {
        let store = SkillStore(inMemory: true)
        let builtin = try XCTUnwrap(store.builtinPackages.first)
        XCTAssertEqual(builtin.id, SkillStore.builtinID)
        XCTAssertFalse(builtin.name.isEmpty)
        XCTAssertTrue(store.packages.isEmpty)
        let catalog = SkillCatalog(packages: store.enabledSnapshot)
        let metadata = AgentViewModel.systemPrompt(skills: store.enabledSnapshot)
        XCTAssertTrue(metadata.contains(builtin.name))
        XCTAssertTrue(metadata.contains("revision"))
        let body = try catalog.result(name: "load_skill", parameters: ["id": builtin.id.uuidString, "revision": builtin.revision])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        XCTAssertEqual(object["content"] as? String, builtin.documents["SKILL.md"])
        XCTAssertThrowsError(try store.remove(builtin.id))
    }
    func testImportVersionsDuplicateDisableDeleteAndRestart() throws {
        let root = try directory(), store = SkillStore(directory: root)
        let first = try store.add(documents: ["SKILL.md": document])
        XCTAssertEqual(try store.add(documents: ["SKILL.md": document]).id, first.id)
        let next = try store.add(documents: ["SKILL.md": document + "\nUpdated"])
        XCTAssertNotEqual(first.id, next.id); XCTAssertNotEqual(first.revision, next.revision)
        try store.setEnabled(false, id: first.id)
        XCTAssertEqual(store.enabledSnapshot.filter { $0.id != SkillStore.builtinID }.map(\.id), [next.id])
        let restored = SkillStore(directory: root)
        XCTAssertEqual(restored.packages, store.packages)
        try restored.remove(next.id); XCTAssertEqual(restored.packages.count, 1)
        XCTAssertTrue(restored.enabledSnapshot.filter { $0.id != SkillStore.builtinID }.isEmpty)
    }
    func testNativePackageCopyRetainsReferencesAndRejectsScriptsSymlinksAndBadPaths() throws {
        let root = try directory(), bundle = root.appendingPathComponent("bundle")
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("references"), withIntermediateDirectories: true)
        try Data(document.utf8).write(to: bundle.appendingPathComponent("SKILL.md"))
        try Data("REFERENCE_BODY".utf8).write(to: bundle.appendingPathComponent("references/guide.md"))
        let store = SkillStore(inMemory: true), imported = try store.importPackage(bundle)
        XCTAssertEqual(imported.documents["references/guide.md"], "REFERENCE_BODY")
        try Data("echo must-not-run".utf8).write(to: bundle.appendingPathComponent("run.sh"))
        XCTAssertThrowsError(try store.importPackage(bundle))
        try FileManager.default.removeItem(at: bundle.appendingPathComponent("run.sh"))
        try FileManager.default.createSymbolicLink(at: bundle.appendingPathComponent("outside.md"), withDestinationURL: root.appendingPathComponent("private.md"))
        XCTAssertThrowsError(try store.importPackage(bundle))
        for path in ["../escape.md", "/tmp/private.md", "refs/../../secret.md", "refs\\private.md", "https://x/file.md", "refs//x.md"] {
            XCTAssertThrowsError(try store.add(documents: ["SKILL.md": document, path: "invalid"]))
        }
        XCTAssertEqual(store.packages.count, 1)
    }
    func testMetadataFormatLimitsAndCorruptArchivePreserveOriginal() throws {
        let store = SkillStore(inMemory: true)
        for body in ["# No metadata", "---\nname: x\n---\nmissing description", "---\nname: x\nname: y\ndescription: d\n---", String(repeating: "a", count: 64 * 1024 + 1)] {
            XCTAssertThrowsError(try store.add(documents: ["SKILL.md": body]))
        }
        let multi = try store.add(documents: ["SKILL.md": "---\nname: 'multi'\ndescription: >\n  first line\n  second line\n---\nBody"])
        XCTAssertEqual(multi.summary, "first line second line")
        let root = try directory(), file = root.appendingPathComponent("skills-v1.json"), bytes = Data("unreadable".utf8)
        try bytes.write(to: file)
        let broken = SkillStore(directory: root)
        XCTAssertNotNil(broken.warning); XCTAssertThrowsError(try broken.add(documents: ["SKILL.md": document]))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
    func testCatalogOnlyLoadsChosenVersionAndResourceWithoutDumpingBodyInListing() throws {
        let store = SkillStore(inMemory: true)
        let item = try store.add(documents: ["SKILL.md": document, "references/guide.md": "REFERENCE_BODY"])
        let catalog = SkillCatalog(packages: store.enabledSnapshot)
        let metadata = AgentViewModel.systemPrompt(skills: store.enabledSnapshot)
        XCTAssertTrue(metadata.contains(item.name))
        XCTAssertTrue(metadata.contains("BODY_NOT_A_SUMMARY"))
        XCTAssertFalse(metadata.contains("REFERENCE_BODY"))
        let arguments = ["id": item.id.uuidString, "revision": item.revision]
        XCTAssertTrue(try catalog.result(name: "load_skill", parameters: arguments).contains("BODY_NOT_A_SUMMARY"))
        XCTAssertFalse(try catalog.result(name: "load_skill", parameters: arguments).contains("REFERENCE_BODY"))
        XCTAssertTrue(try catalog.result(name: "load_skill", parameters: arguments.merging(["resource": "references/guide.md"]) { _, b in b }).contains("REFERENCE_BODY"))
        for extra in [["revision": "wrong"], ["id": UUID().uuidString], ["resource": "../private.md"], ["resource": "missing.md"]] {
            XCTAssertThrowsError(try catalog.result(name: "load_skill", parameters: arguments.merging(extra) { _, b in b }))
        }
        try store.setEnabled(false, id: item.id)
        XCTAssertThrowsError(try SkillCatalog(packages: store.enabledSnapshot).result(name: "load_skill", parameters: arguments))
        XCTAssertTrue(try catalog.result(name: "load_skill", parameters: arguments).contains("BODY_NOT_A_SUMMARY")) // frozen old run
    }
    func testPromptOnlyIncludesEnabledMetadataAndDiscoveryToolsAreRejected() throws {
        let store = SkillStore(inMemory: true)
        let item = try store.add(documents: ["SKILL.md": document])
        var disabled = item
        disabled.enabled = false
        let prompt = AgentViewModel.systemPrompt(skills: [disabled])
        XCTAssertFalse(prompt.contains(item.name))
        XCTAssertFalse(prompt.contains(item.summary))
        let enabledPrompt = AgentViewModel.systemPrompt(skills: [item])
        XCTAssertTrue(enabledPrompt.contains(item.id.uuidString))
        XCTAssertTrue(enabledPrompt.contains(item.revision))
        XCTAssertTrue(enabledPrompt.contains("BODY_NOT_A_SUMMARY"))
        XCTAssertFalse(enabledPrompt.contains("REFERENCE_BODY"))
        XCTAssertThrowsError(try SkillCatalog(packages: [item]).result(name: "list_skills", parameters: [:]))
        XCTAssertThrowsError(try SkillCatalog(packages: [item]).result(name: "search_skills", parameters: ["query": "synthetic"]))
    }
    func testCancelledImportAndStaleToolContextNeverRead() async throws {
        let store = SkillStore(inMemory: true), body = document
        let task = Task { try store.add(documents: ["SKILL.md": body]) }; task.cancel()
        do { _ = try await task.value; XCTFail() } catch {}
        XCTAssertTrue(store.packages.isEmpty)
        let item = try store.add(documents: ["SKILL.md": body])
        let tool = SkillTool(name: "load_skill", catalog: SkillCatalog(packages: [item]), canRead: { false })
        let context = ToolContext(callId: "stale", toolName: "load_skill", parameters: ["id": item.id.uuidString, "revision": item.revision], state: AgentState())
        do { _ = try await tool.execute(context: context); XCTFail() } catch { XCTAssertEqual(error as? AppError, .stopped) }
    }
    func testLongSkillCanBeReadExactlyThroughVersionedPages() throws {
        let body = document + String(repeating: "A", count: 51_000)
        let item = try SkillPackage.make(documents: ["SKILL.md": body]), catalog = SkillCatalog(packages: [item])
        var offset = 0, restored = ""
        while true {
            let response = try catalog.result(name: "load_skill", parameters: ["id": item.id.uuidString, "revision": item.revision, "offset": offset])
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
            let page = try XCTUnwrap(object["content"] as? String)
            XCTAssertLessThanOrEqual(page.count, 50_000); restored += page
            guard let next = object["next_offset"] as? Int else { break }
            XCTAssertGreaterThan(next, offset); offset = next
        }
        XCTAssertEqual(restored, body)
        for invalid in [-1, true, 0.5, body.count + 1] as [Any] {
            XCTAssertThrowsError(try catalog.result(name: "load_skill", parameters: ["id": item.id.uuidString, "revision": item.revision, "offset": invalid]))
        }
    }
    func testActualAgentDiscoversAndLoadsSkillReferenceAndProjectsNamedIcon() async throws {
        let store = SkillStore(inMemory: true)
        _ = try store.add(documents: ["SKILL.md": document, "references/guide.md": "REFERENCE_BODY"])
        let provider = SkillRoundTripProvider()
        let model = AgentViewModel(sessions: ConversationStore(inMemory: true), loadPersistentState: false,
            runServices: AgentRunServices(provider: provider, bridge: UnavailableBridge()), skills: store)
        let id = model.createConversation(mode: .live)
        defer { model.stop() }
        XCTAssertTrue(model.send("Use the synthetic guide", in: id, cloudConsent: true))
        for _ in 0..<150 where model.running { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertFalse(model.running)
        XCTAssertEqual(model.sessions.conversation(id)?.phase, .completed)
        let tools = model.sessions.conversation(id)?.messages.compactMap(\.tool) ?? []
        XCTAssertEqual(tools.map(\.name), ["load_skill", "load_skill"])
        XCTAssertTrue(tools.allSatisfy { $0.state == .succeeded })
        XCTAssertEqual(tools.last?.skillName, "Synthetic Guide")
        XCTAssertEqual(tools.last?.symbol, "book.closed")
        XCTAssertTrue(tools.contains { $0.result.contains("BODY_NOT_A_SUMMARY") })
        XCTAssertTrue(tools.contains { $0.result.contains("REFERENCE_BODY") })
    }
}

private struct SkillRoundTripProvider: ModelProvider {
    static let name = "skill-roundtrip-fixture"
    let configuration = ProviderConfiguration(name: name, baseURL: URL(string: "https://invalid.invalid")!, defaultModel: "fixture")
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            do {
                let response = try respond(request)
                for call in response.toolCalls { continuation.yield(.toolCall(call)) }
                if !response.text.isEmpty { continuation.yield(.text(response.text)) }
                continuation.yield(.finish(reason: response.finishReason, usage: nil)); continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
    }
    func complete(_ request: ModelRequest) async throws -> ModelResponse { try respond(request) }
    private func respond(_ request: ModelRequest) throws -> ModelResponse {
        let system = request.messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n")
        XCTAssertTrue(system.contains("Synthetic Guide"))
        XCTAssertTrue(system.contains("Read synthetic fixtures"))
        XCTAssertTrue(system.contains("Skill metadata"))
        XCTAssertFalse(system.contains("search_skills"))
        XCTAssertFalse(system.contains("list_skills"))
        XCTAssertTrue(request.messages.filter { $0.role == .system }.contains { $0.content.contains("BODY_NOT_A_SUMMARY") })
        let results = request.messages.filter { $0.role == .tool }, stage = results.count
        let name: String, arguments: [String: String]
        if stage < 2 {
            // The SDK may append system instructions after the catalog. Read
            // the complete JSON array rather than requiring an otherwise empty line.
            let start = try XCTUnwrap(system.range(of: "[{")) .lowerBound
            var depth = 0, quoted = false, escaped = false, end: String.Index?
            for index in system[start...].indices {
                let character = system[index]
                if quoted {
                    if escaped { escaped = false }
                    else if character == "\\" { escaped = true }
                    else if character == "\"" { quoted = false }
                } else if character == "\"" { quoted = true }
                else if character == "[" { depth += 1 }
                else if character == "]" {
                    depth -= 1
                    if depth == 0 { end = system.index(after: index); break }
                }
            }
            let metadata = system[start..<((try XCTUnwrap(end)))]
            let skills = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(metadata.utf8)) as? [[String: String]])
            let skill = try XCTUnwrap(skills.first(where: { $0["name"] == "Synthetic Guide" }))
            name = "load_skill"; arguments = ["id": skill["id"]!, "revision": skill["revision"]!, "resource": stage == 0 ? "SKILL.md" : "references/guide.md"]
        } else {
            XCTAssertTrue(results.contains { $0.content.contains("BODY_NOT_A_SUMMARY") })
            XCTAssertTrue(results.contains { $0.content.contains("REFERENCE_BODY") })
            return ModelResponse(text: "合成技能与参考已读取。", finishReason: .stop, request: request, providerName: Self.name)
        }
        return ModelResponse(text: "", finishReason: .toolCalls, toolCalls: [.init(id: "skill-\(stage)", name: name,
            arguments: String(decoding: try JSONEncoder().encode(arguments), as: UTF8.self))], request: request, providerName: Self.name)
    }
}
