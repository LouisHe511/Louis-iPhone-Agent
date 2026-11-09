import Foundation
import ProviderCore

/// Narrow transport because MacPaw 0.5.2's streaming client creates a .default
/// session and does not provide a public factory for the privacy delegate.
/// Request/output codecs remain MacPaw-backed; no SDK source is vendored.
public final class ResponsesTransport: @unchecked Sendable {
    private let delegate: NoRedirectDelegate
    public let session: URLSession
    public init(protocolClasses: [AnyClass]? = nil) {
        delegate = NoRedirectDelegate()
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 300; config.timeoutIntervalForResource = 1800
        config.protocolClasses = protocolClasses
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }
    public func cancel() { session.invalidateAndCancel() }
    deinit { session.invalidateAndCancel() }
    public func complete(_ request: URLRequest) async throws -> Data {
        let cancellation = TransportCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let (bytes, response) = try await session.bytes(for: request)
            cancellation.install(bytes.task)
            defer { cancellation.cancel() }
            try Task.checkCancellation(); try Self.verify(response)
            var data = Data()
            for try await byte in bytes { try Task.checkCancellation(); guard data.count < 4 * 1024 * 1024 else { throw ModelError.protocolViolation("Response exceeds 4 MiB") }; data.append(byte) }
            try Task.checkCancellation(); return data
        } onCancel: { cancellation.cancel() }
    }
    /// A per-operation data task is cancelled on parser failure, consumer stop,
    /// HTTP error or EOF. It never logs request/response payloads.
    public func payloads(_ request: URLRequest) -> AsyncThrowingStream<String, Error> {
        // Pull one frame per consumer request. A fast model must not fail just
        // because parsing/tool validation temporarily consumes frames more slowly.
        let cursor = SSEPayloadCursor(session: session, request: request)
        return AsyncThrowingStream(unfolding: { try await cursor.next() })
    }
    fileprivate static func verify(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw ModelError.networkError("Non-HTTP response") }
        guard (200..<300).contains(http.statusCode) else { throw ModelError.httpError(http.statusCode, nil) }
    }
}
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

private final class TransportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false
    func install(_ task: URLSessionTask) { lock.withLock { if cancelled { task.cancel() } else { self.task = task } } }
    func cancel() { lock.withLock { cancelled = true; task?.cancel(); task = nil } }
}

/// AsyncThrowingStream's unfolding iterator calls next serially; only cancellation
/// crosses threads. Retaining no producer task/queue also cancels on early break.
private final class SSEPayloadCursor: @unchecked Sendable {
    private let session: URLSession
    private let request: URLRequest
    private let cancellation = TransportCancellation()
    private var iterator: URLSession.AsyncBytes.Iterator?
    private var decoder = SSEFrameDecoder()
    private var finished = false
    init(session: URLSession, request: URLRequest) { self.session = session; self.request = request }
    deinit { cancellation.cancel() }
    func next() async throws -> String? {
        try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                guard !finished else { return nil }
                if iterator == nil {
                    let (bytes, response) = try await session.bytes(for: request)
                    cancellation.install(bytes.task)
                    try Task.checkCancellation()
                    try ResponsesTransport.verify(response)
                    iterator = bytes.makeAsyncIterator()
                }
                while let byte = try await iterator!.next() {
                    try Task.checkCancellation()
                    if let frame = try decoder.consume(byte) { return frame }
                }
                try decoder.finish()
                finished = true; cancellation.cancel()
                return nil
            } catch {
                finished = true; cancellation.cancel()
                throw Task.isCancelled ? CancellationError() : error
            }
        } onCancel: { cancellation.cancel() }
    }
}
