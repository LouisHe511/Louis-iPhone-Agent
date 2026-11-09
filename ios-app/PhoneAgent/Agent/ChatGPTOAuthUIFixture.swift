#if DEBUG
import Foundation
import CryptoKit

/// Test-only issuer transport. Production JWS verification still runs; there is
/// no "skip verification" path. Its keys are generated afresh and never persisted.
final class ChatGPTOAuthUIFixture: ChatGPTHTTPClient, @unchecked Sendable {
    private static let lock = NSLock()
    private static var nonce = ""
    private let key = P256.Signing.PrivateKey()
    static func open(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), url.host == "auth.openai.com" else { return }
        let values = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        lock.withLock { nonce = values["nonce"] ?? "" }
        if ProcessInfo.processInfo.arguments.contains("--ui-test-chatgpt-auth-wait") { return }
        guard let redirect = values["redirect_uri"], let base = URL(string: redirect), base.host == "127.0.0.1", base.scheme == "http", base.path == "/auth/callback" else { return }
        var callback = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        callback.queryItems = [.init(name: "code", value: "local_fixture"), .init(name: "state", value: values["state"]), .init(name: "client_id", value: values["client_id"] == "dynamic_agent_client" ? "oaiapp_actell_fixture" : values["client_id"])]
        Task {
            let c = URLSessionConfiguration.ephemeral; c.httpCookieStorage = nil
            let session = URLSession(configuration: c); defer { session.invalidateAndCancel() }
            _ = try? await session.data(from: callback.url!)
        }
    }
    func data(_ request: URLRequest) async throws -> (Data, Int) {
        let result: [String: Any]
        switch request.url {
        case ChatGPTSubscriptionPolicy.token:
            let invalid = ProcessInfo.processInfo.arguments.contains("--ui-test-chatgpt-auth-invalid")
            let now = Date().timeIntervalSince1970
            let publicKey = key.publicKey.x963Representation
            let header: [String: Any] = ["alg": "ES256", "kid": "local-test"]
            let claims: [String: Any] = ["iss": ChatGPTIDTokenVerifier.issuer, "sub": "local-ui-subject", "email": "local-fixture@example.invalid", "aud": "oaiapp_actell_fixture", "nonce": Self.lock.withLock { Self.nonce }, "iat": now - 1, "exp": now + 3600]
            let signed = Self.base64(try JSONSerialization.data(withJSONObject: header)) + "." + Self.base64(try JSONSerialization.data(withJSONObject: claims))
            let signature = try key.signature(for: Data(signed.utf8)).rawRepresentation
            result = ["access_token": "local_fixture_access", "refresh_token": "local_fixture_refresh", "token_type": "Bearer", "expires_in": 3600, "id_token": signed + "." + Self.base64(invalid ? Data(repeating: 0, count: 64) : signature), "scope": "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"]
            _ = publicKey
        case ChatGPTIDTokenVerifier.jwksURL:
            let bytes = key.publicKey.x963Representation
            result = ["keys": [["kid": "local-test", "alg": "ES256", "use": "sig", "kty": "EC", "crv": "P-256", "x": Self.base64(bytes.subdata(in: 1..<33)), "y": Self.base64(bytes.subdata(in: 33..<65))]]]
        case ChatGPTSubscriptionPolicy.resource.appendingPathComponent("models"):
            result = ["models": [["slug": "fixture-vision", "display_name": "Local subscription model", "visibility": "list", "supported_reasoning_efforts": ["low", "high"], "default_reasoning_effort": "low"]]]
        case ChatGPTAccountManager.discoveryURL:
            result = ["issuer": ChatGPTIDTokenVerifier.issuer, "revocation_endpoint": "https://auth.openai.com/api/accounts/local-fixture-revoke"]
        default:
            guard request.url?.path == "/api/accounts/local-fixture-revoke" else { throw ChatGPTAuthError.network }
            return (Data(), 200)
        }
        return (try JSONSerialization.data(withJSONObject: result), 200)
    }
    private static func base64(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}
#endif
