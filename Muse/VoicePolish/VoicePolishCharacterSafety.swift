import Foundation

enum VoicePolishCharacterSafety {

    static func normalizedLineEndings(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    static func containsUnsafeCharacters(_ text: String) -> Bool {
        normalizedLineEndings(text).unicodeScalars.contains(where: isUnsafe)
    }

    static func sanitizedFallback(_ text: String) -> String {
        let normalized = normalizedLineEndings(text)
        let scalars = normalized.unicodeScalars.filter { !isUnsafe($0) }
        return String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isUnsafe(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if value == 0x09 || value == 0x0A { return false }
        if value <= 0x1F { return true }
        if value == 0x7F || (0x80...0x9F).contains(value) { return true }
        if (0xFDD0...0xFDEF).contains(value) { return true }
        return value & 0xFFFF == 0xFFFE || value & 0xFFFF == 0xFFFF
    }
}

enum VoicePolishOutputNormalizer {

    static let maximumResponseBytes = 1_048_576

    static func plainText(_ response: String, sourceText: String) -> String? {
        guard response.utf8.count <= maximumResponseBytes else { return nil }
        var normalized = VoicePolishCharacterSafety.normalizedLineEndings(
            response.strippingThinkTags()
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        let prefixes = ["最终文本：", "最终文本:", "润色后：", "润色后:",
                        "Final text:", "Polished text:"]
        for prefix in prefixes where normalized.hasPrefix(prefix) && !sourceText.hasPrefix(prefix) {
            normalized.removeFirst(prefix.count)
            normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        return normalized
    }
}
