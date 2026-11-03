import Foundation
import Security

struct ServerConfig: Equatable {
    var baseURL: URL
    var secret: String
}

enum ServerError: LocalizedError {
    case notConfigured
    case http(Int, String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Server not set up yet."
        case .http(401, _): return "The app secret doesn't match the server."
        case .http(let code, let message): return message.isEmpty ? "Server error \(code)." : message
        case .invalidResponse: return "Unexpected response from the server."
        }
    }
}

/// Talks to the companion server (server/src/api.ts).
struct ServerClient {
    let config: ServerConfig

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    func status() async throws -> ServerStatus {
        try await request("GET", "status", body: nil as [String: String]?)
    }

    @discardableResult
    func request<Body: Encodable, Response: Decodable>(_ method: String, _ path: String, body: Body?) async throws -> Response {
        var req = URLRequest(url: config.baseURL.appending(path: path))
        req.httpMethod = method
        req.setValue("Bearer \(config.secret)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await Self.session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw ServerError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? ""
            throw ServerError.http(http.statusCode, message)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    func send(_ method: String, _ path: String, _ body: [String: AnyEncodable] = [:]) async throws {
        let _: Ignored = try await request(method, path, body: body)
    }

    private struct Ignored: Decodable {}
}

/// Lets us send mixed-type JSON bodies.
struct AnyEncodable: Encodable {
    private let encodeFn: (Encoder) throws -> Void
    init<T: Encodable>(_ value: T) { encodeFn = value.encode }
    func encode(to encoder: Encoder) throws { try encodeFn(encoder) }
}

/// Stores the app secret in the Keychain rather than UserDefaults.
enum Keychain {
    private static let service = "HaleysPancreas"

    static func set(_ value: String, for key: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        // Readable after first unlock so background pushes can still use it.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func delete(_ key: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service,
                       kSecAttrAccount as String: key] as CFDictionary)
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: key,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
