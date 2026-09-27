import CoachCore
import Foundation
import Security

/// The OpenAI API key, stored in the iOS Keychain on this device only
/// (never in the app bundle, the shared container or the repository).
enum OpenAIKeyStore {
    private static let service = "com.heloniuminnovation.aigamingcoach.openai"
    private static let account = "apiKey"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        delete()
        var item = baseQuery
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

/// Calls `POST https://api.openai.com/v1/responses`. Retries rate limits and
/// server errors a few times with back-off; a missing quota is not retried.
struct OpenAIHTTPClient: ResponsesClient {
    let apiKey: String
    var endpoint = URL(string: "https://api.openai.com/v1/responses")!
    var maxAttempts = 4

    func send(_ request: ResponsesRequest) async throws -> ResponsesReply {
        var urlRequest = URLRequest(url: endpoint, timeoutInterval: 300)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)

        var attempt = 1
        while true {
            let (data, response) = try await URLSession.shared.data(for: urlRequest)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let reply = try? JSONDecoder().decode(ResponsesReply.self, from: data)
            let message = reply?.error?.message ?? String(decoding: data.prefix(300), as: UTF8.self)

            switch status {
            case 200..<300:
                guard let reply else { throw AnalysisError.malformedAnswer("unreadable response") }
                return reply
            case 401:
                throw AnalysisError.invalidAPIKey
            case 404:
                throw AnalysisError.modelUnavailable(request.model)
            case 400 where message.lowercased().contains("model"):
                throw AnalysisError.modelUnavailable(request.model)
            case 429 where reply?.error?.code == "insufficient_quota" || message.contains("quota"):
                throw AnalysisError.rateLimited(message)
            case 429, 500...599:
                guard attempt < maxAttempts else {
                    throw status == 429 ? AnalysisError.rateLimited(message) : AnalysisError.server(status, message)
                }
                try await Task.sleep(nanoseconds: UInt64(pow(2, Double(attempt)) * 5_000_000_000))
                attempt += 1
            default:
                throw AnalysisError.server(status, message)
            }
        }
    }
}
