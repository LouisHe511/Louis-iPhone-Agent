import CryptoKit
import Foundation

/// App-sandbox authority, deliberately not shared with the Widget. Only this
/// process owns continuations; every launch invalidates unfinished records.
/// All compare-and-transition operations are synchronous on MainActor and are
/// persisted atomically BEFORE their callers may release an approval.
@MainActor final class ApprovalRecordStore {
    enum State: String, Codable { case pending, accepted, executing, finished, denied, cancelled, expired, interrupted }
    struct Record: Codable, Equatable {
        let id: UUID
        let sessionID: UUID
        let runID: UUID
        let callID: String
        let digest: String
        let version: Int
        let expiresAt: Date
        // Optional to decode existing archives. Missing means legacy per-action.
        var authorizationMode: InputAuthorizationMode?
        var state: State
    }
    enum Failure: Error { case unavailable, invalid, expired }
    private struct Archive: Codable { var version = 1; var records: [Record] }
    private(set) var records: [Record] = []
    private var file: URL?
    private var writable = true

    init(directory: URL? = nil, inMemory: Bool = false) {
        guard !inMemory else { return }
        do {
            let folder = try directory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("PhoneAgent", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var excluded = folder; var values = URLResourceValues(); values.isExcludedFromBackup = true
            try excluded.setResourceValues(values)
            let file = folder.appendingPathComponent("approvals-v1.json"); self.file = file
            if FileManager.default.fileExists(atPath: file.path) {
                let data = try Data(contentsOf: file)
                guard data.count < 1_048_576 else { throw Failure.invalid }
                let archive = try JSONDecoder().decode(Archive.self, from: data)
                guard archive.version == 1 else { throw Failure.invalid }
                records = archive.records
            }
            var restored = records
            for index in restored.indices where Self.openStates.contains(restored[index].state) { restored[index].state = .interrupted }
            try commit(restored)
        } catch { writable = false }
    }
    private static let openStates: Set<State> = [.pending, .accepted, .executing]
    nonisolated static func digest(tool: String, parameters: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["tool": tool, "parameters": parameters], options: [.sortedKeys])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    func register(_ request: Approval, run: RunIdentity, now: Date = Date(), authorizationMode: InputAuthorizationMode = .perAction) throws {
        guard request.expiresAt > now, request.version == 1, !request.parametersDigest.isEmpty,
              let callID = request.callID, !records.contains(where: { $0.id == request.id || ($0.runID == run.runID && $0.callID == callID) }) else { throw Failure.invalid }
        var updated = records
        updated.append(Record(id: request.id, sessionID: run.conversationID, runID: run.runID, callID: callID,
                              digest: request.parametersDigest, version: request.version, expiresAt: request.expiresAt,
                              authorizationMode: authorizationMode, state: .pending))
        try commit(Array(updated.suffix(256)))
    }
    func isPending(_ request: Approval, run: RunIdentity, now: Date = Date()) -> Bool {
        writable && records.contains { matches($0, request, run) && $0.state == .pending && now < $0.expiresAt }
    }
    func resolve(_ request: Approval, run: RunIdentity, approved: Bool, now: Date = Date()) throws {
        guard let index = records.firstIndex(where: { matches($0, request, run) && $0.state == .pending }) else { throw Failure.invalid }
        var updated = records
        guard now < updated[index].expiresAt else {
            updated[index].state = .expired; try commit(updated); throw Failure.expired
        }
        updated[index].state = approved ? .accepted : .denied
        try commit(updated)
    }
    func claimExecution(callID: String, run: RunIdentity, now: Date = Date()) throws {
        guard let index = records.firstIndex(where: { $0.sessionID == run.conversationID && $0.runID == run.runID && $0.callID == callID && $0.state == .accepted }),
              now < records[index].expiresAt else { throw Failure.invalid }
        var updated = records; updated[index].state = .executing; try commit(updated)
    }
    func finish(callID: String, run: RunIdentity) throws {
        guard records.contains(where: { $0.sessionID == run.conversationID && $0.runID == run.runID && $0.callID == callID && Self.openStates.contains($0.state) }) else { return }
        var updated = records
        for index in updated.indices where updated[index].runID == run.runID && updated[index].callID == callID && Self.openStates.contains(updated[index].state) { updated[index].state = .finished }
        try commit(updated)
    }
    func invalidate(run: RunIdentity) throws {
        var updated = records
        for index in updated.indices where updated[index].runID == run.runID && Self.openStates.contains(updated[index].state) { updated[index].state = .cancelled }
        try commit(updated)
    }
    func record(id: UUID) -> Record? { records.first { $0.id == id } }
    private func matches(_ record: Record, _ request: Approval, _ run: RunIdentity) -> Bool {
        record.id == request.id && record.sessionID == run.conversationID && record.runID == run.runID &&
        record.callID == request.callID && record.digest == request.parametersDigest && record.version == request.version && record.expiresAt == request.expiresAt
    }
    private func commit(_ updated: [Record]) throws {
        guard writable else { throw Failure.unavailable }
        if let file {
            do { try JSONEncoder().encode(Archive(records: updated)).write(to: file, options: [.atomic, .completeFileProtection]) }
            catch { writable = false; throw Failure.unavailable }
        }
        records = updated
    }
}
