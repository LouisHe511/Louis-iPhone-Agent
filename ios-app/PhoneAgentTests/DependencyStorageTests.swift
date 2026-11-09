import Foundation
import SwiftAgentKit
import XCTest

final class DependencyStorageTests: XCTestCase {
    func testDefaultStoresUseWritableApplicationSupportOnIOS() throws {
        let name = "phoneagent-test-\(UUID().uuidString)"
        let base = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
            .appendingPathComponent(".\(name)")
        defer { try? FileManager.default.removeItem(at: base) }

        let memory = FileAgentMemoryStore.defaultStore(named: name)
        let skills = FileAgentSkillStore.defaultStore(named: name)
        let goals = FileAgentGoalStore.defaultStore(named: name)
        XCTAssertEqual(memory.directory.standardizedFileURL.path, base.standardizedFileURL.path)
        XCTAssertEqual(skills.directory.standardizedFileURL.path, base.appendingPathComponent("skills").standardizedFileURL.path)
        XCTAssertEqual(goals.directory.standardizedFileURL.path, base.appendingPathComponent("goals").standardizedFileURL.path)

        for directory in [memory.directory, skills.directory, goals.directory] {
            let file = directory.appendingPathComponent("write-probe.txt")
            let content = Data("sandbox storage".utf8)
            try content.write(to: file, options: .atomic)
            XCTAssertEqual(try Data(contentsOf: file), content)
        }
    }
}
