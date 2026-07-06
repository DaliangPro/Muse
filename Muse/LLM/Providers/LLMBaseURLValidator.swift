import Foundation

enum LLMBaseURLValidator {
    static func normalizedURL(rawValue: String, defaultValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlString = value.isEmpty ? defaultValue : value
        guard let components = URLComponents(string: urlString),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil
        else { return nil }

        if scheme == "https" {
            return urlString
        }
        if scheme == "http", isLoopbackHost(host) {
            return urlString
        }
        return nil
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        host == "localhost"
            || host == "::1"
            || host == "0.0.0.0"
            || host.hasPrefix("127.")
    }
}
