import Foundation

enum StructuredLLMDecoderError: Error, Equatable {
    case responseTooLarge
    case noJSONObject
    case ambiguousJSONObjects
    case invalidJSON
}

enum StructuredLLMDecoder {

    static func decode<T: Decodable>(
        _ type: T.Type,
        from response: String,
        maximumBytes: Int = VoicePolishOutputNormalizer.maximumResponseBytes
    ) throws -> T {
        guard response.utf8.count <= maximumBytes else {
            throw StructuredLLMDecoderError.responseTooLarge
        }
        let normalized = VoicePolishCharacterSafety.normalizedLineEndings(
            response.strippingThinkTags()
        )
        let objects = topLevelJSONObjects(in: normalized)
        guard !objects.isEmpty else {
            throw StructuredLLMDecoderError.noJSONObject
        }
        guard objects.count == 1 else {
            throw StructuredLLMDecoderError.ambiguousJSONObjects
        }

        let safeJSON = removingSafeTrailingCommas(objects[0])
        guard let data = safeJSON.data(using: .utf8) else {
            throw StructuredLLMDecoderError.invalidJSON
        }
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(type, from: data)
        } catch {
            throw StructuredLLMDecoderError.invalidJSON
        }
    }

    private static func topLevelJSONObjects(in text: String) -> [String] {
        var results: [String] = []
        var start: String.Index?
        var depth = 0
        var inString = false
        var escaping = false
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaping {
                    escaping = false
                } else if character == "\\" {
                    escaping = true
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                if depth == 0 { start = index }
                depth += 1
            } else if character == "}", depth > 0 {
                depth -= 1
                if depth == 0, let objectStart = start {
                    let end = text.index(after: index)
                    results.append(String(text[objectStart..<end]))
                    start = nil
                }
            }
            index = text.index(after: index)
        }
        return results
    }

    private static func removingSafeTrailingCommas(_ json: String) -> String {
        var result = ""
        var inString = false
        var escaping = false
        var index = json.startIndex

        while index < json.endIndex {
            let character = json[index]
            if inString {
                result.append(character)
                if escaping {
                    escaping = false
                } else if character == "\\" {
                    escaping = true
                } else if character == "\"" {
                    inString = false
                }
                index = json.index(after: index)
                continue
            }
            if character == "\"" {
                inString = true
                result.append(character)
                index = json.index(after: index)
                continue
            }
            if character == "," {
                var lookahead = json.index(after: index)
                while lookahead < json.endIndex, json[lookahead].isWhitespace {
                    lookahead = json.index(after: lookahead)
                }
                if lookahead < json.endIndex,
                   json[lookahead] == "}" || json[lookahead] == "]" {
                    index = json.index(after: index)
                    continue
                }
            }
            result.append(character)
            index = json.index(after: index)
        }
        return result
    }
}
