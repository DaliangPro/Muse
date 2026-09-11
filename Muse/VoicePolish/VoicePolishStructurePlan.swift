import Foundation

enum VoicePolishStructurePlanError: Error, Equatable {
    case invalidSource, invalidSegments, invalidLayout, outputTooLong
}

/// 结构阶段只安排真实片段；模型没有提供自由正文、标题或删除片段的入口。
enum VoicePolishStructurePlan {
    struct Segment: Codable, Equatable, Sendable {
        let id: String
        let text: String
    }

    enum Style: String, Codable, Sendable {
        case paragraph, bullet, numbered
    }

    struct Block: Encodable, Equatable, Sendable {
        let style: Style
        let segmentIDs: [String]

        enum CodingKeys: String, CodingKey {
            case style
            case segmentIDs = "segment_ids"
        }
    }

    static let maximumSegments = 128
    static let maximumOutputBytes = VoicePolishOutputNormalizer.maximumResponseBytes

    /// 按完整修正稿的明确句末切分，逗号和裸换行不切分；所有原始字节仍由片段保留。
    static func segments(in draft: String) throws -> [Segment] {
        guard validSource(draft) else { throw VoicePolishStructurePlanError.invalidSource }
        let text = Array(draft)
        let bracketClosers: [Character: Character] = [
            "(": ")", "[": "]", "{": "}", "（": "）", "【": "】", "《": "》", "〈": "〉"
        ]
        let quoteClosers: [Character: Character] = ["“": "”", "‘": "’", "「": "」", "『": "』", "\"": "\"", "'": "'"]
        var brackets: [Character] = []
        var quote: Character?
        var codeDelimiter: Character?
        var codeDelimiterCount = 0
        var indentedCodeLine = false
        var parts: [String] = []
        var start = 0
        var index = 0
        while index < text.count && parts.count < maximumSegments - 1 {
            let character = text[index]
            if index == 0 || text[index - 1].isNewline {
                indentedCodeLine = isIndentedCodeLine(text[index...])
            }
            if character == "`" || character == "~" {
                var end = index + 1
                while end < text.count && text[end] == character { end += 1 }
                let count = end - index
                if let delimiter = codeDelimiter {
                    if delimiter == character && (codeDelimiterCount >= 3 ? count >= codeDelimiterCount : count == codeDelimiterCount) {
                        codeDelimiter = nil
                        codeDelimiterCount = 0
                    }
                } else if character == "`" || count >= 3 {
                    codeDelimiter = character
                    codeDelimiterCount = count
                }
                index = end
                continue
            }
            if codeDelimiter != nil || indentedCodeLine {
                index += 1
                continue
            }
            if let closer = quote {
                if character == closer && !isEscaped(text, at: index) { quote = nil }
                index += 1
                continue
            }
            if let closer = quoteClosers[character], !isEscaped(text, at: index),
               !(character == "'" && index > 0 && index + 1 < text.count && text[index - 1].isLetter && text[index + 1].isLetter) {
                quote = closer
                index += 1
                continue
            }
            if character == brackets.last {
                brackets.removeLast()
            } else if let closer = bracketClosers[character] {
                brackets.append(closer)
            }
            if brackets.isEmpty && isSentenceEnd(text, at: index) {
                var end = index + 1
                // 连续问叹号属于同一句，避免产生只有标点的布局片段。
                while end < text.count && "。！？!?".contains(text[end]) { end += 1 }
                parts.append(String(text[start..<end]))
                start = end
                index = end
            } else {
                index += 1
            }
        }
        if start < text.count {
            let tail = String(text[start...])
            if !parts.isEmpty && tail.allSatisfy(\.isWhitespace) {
                parts[parts.count - 1] += tail
            } else {
                parts.append(tail)
            }
        }
        return parts.enumerated().map { Segment(id: "c\($0.offset + 1)", text: $0.element) }
    }

    /// object 是响应中的 layout 数组；每项仅允许样式和真实片段 ID。
    static func decodeLayout(from object: Any, segments: [Segment]) throws -> [Block] {
        try validateSegments(segments)
        guard let items = object as? [[String: Any]], !items.isEmpty,
              items.count <= maximumSegments else { throw VoicePolishStructurePlanError.invalidLayout }
        let blocks = try items.map { item -> Block in
            guard Set(item.keys) == ["style", "segment_ids"],
                  let rawStyle = item["style"] as? String, let style = Style(rawValue: rawStyle),
                  let ids = item["segment_ids"] as? [String], !ids.isEmpty,
                  ids.count <= maximumSegments else { throw VoicePolishStructurePlanError.invalidLayout }
            return Block(style: style, segmentIDs: ids)
        }
        try validateBlocks(blocks, segments: segments)
        return blocks
    }

    /// 即使调用方绕过 JSON 解码，也必须重新通过完整覆盖检查；不 trim 正文或代码缩进。
    static func render(_ blocks: [Block], segments: [Segment], includesMarkers: Bool = true) throws -> String {
        try validateSegments(segments)
        try validateBlocks(blocks, segments: segments)
        let byID = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0.text) })
        var number = 0
        var previousBody: String?
        var output = ""
        for block in blocks {
            let body = block.segmentIDs.map { byID[$0]! }.joined()
            if let previousBody {
                output += paragraphSeparator(previousBody, body)
            }
            let marker: String
            switch block.style {
            case .paragraph:
                number = 0
                marker = ""
            case .bullet:
                number = 0
                marker = "- "
            case .numbered:
                number += 1
                marker = "\(number). "
            }
            output += includesMarkers ? inserting(marker, afterLeadingWhitespaceIn: body) : body
            previousBody = body
        }
        guard output.utf8.count <= maximumOutputBytes else { throw VoicePolishStructurePlanError.outputTooLong }
        return output
    }

    /// 标记紧贴正文，前导空白仍逐字保留，避免编号单独占一行。
    private static func inserting(_ marker: String, afterLeadingWhitespaceIn body: String) -> String {
        guard !marker.isEmpty else { return body }
        let position = body.firstIndex(where: { !$0.isWhitespace }) ?? body.endIndex
        return String(body[..<position]) + marker + String(body[position...])
    }

    /// 原有空白不折叠，只补足组间换行；在拼合后计数以处理跨边界的 CRLF。
    private static func paragraphSeparator(_ previous: String, _ next: String) -> String {
        let trailing = String(previous.reversed().prefix(while: \.isWhitespace).reversed())
        let leading = String(next.prefix(while: \.isWhitespace))
        for count in 0...2 {
            let separator = String(repeating: "\n", count: count)
            let newlineCount = (trailing + separator + leading).reduce(0) { $0 + ($1.isNewline ? 1 : 0) }
            if newlineCount >= 2 { return separator }
        }
        return "\n\n"
    }

    private static func validSource(_ source: String) -> Bool {
        !source.isEmpty && source.utf8.count <= maximumOutputBytes
            && source.contains(where: { !$0.isWhitespace })
            && !VoicePolishCharacterSafety.containsUnsafeCharacters(source)
    }

    private static func validateSegments(_ segments: [Segment]) throws {
        guard !segments.isEmpty, segments.count <= maximumSegments,
              segments.enumerated().allSatisfy({ $0.element.id == "c\($0.offset + 1)" && !$0.element.text.isEmpty }) else {
            throw VoicePolishStructurePlanError.invalidSegments
        }
        var byteCount = 0
        var hasContent = false
        for segment in segments {
            let size = segment.text.utf8.count
            guard size <= maximumOutputBytes - byteCount,
                  !VoicePolishCharacterSafety.containsUnsafeCharacters(segment.text) else {
                throw VoicePolishStructurePlanError.invalidSegments
            }
            byteCount += size
            hasContent = hasContent || segment.text.contains(where: { !$0.isWhitespace })
        }
        guard hasContent else { throw VoicePolishStructurePlanError.invalidSegments }
    }

    private static func validateBlocks(_ blocks: [Block], segments: [Segment]) throws {
        guard !blocks.isEmpty, blocks.count <= maximumSegments else { throw VoicePolishStructurePlanError.invalidLayout }
        let known = Set(segments.map(\.id))
        let codeBlocks = Set(segments.filter { containsCodeBlock($0.text) }.map(\.id))
        var seen: Set<String> = []
        for block in blocks {
            let hasCode = block.segmentIDs.contains(where: codeBlocks.contains)
            guard !block.segmentIDs.isEmpty, block.segmentIDs.count <= maximumSegments,
                  !hasCode || (block.style == .paragraph && block.segmentIDs.count == 1) else {
                throw VoicePolishStructurePlanError.invalidLayout
            }
            for id in block.segmentIDs {
                guard known.contains(id), seen.insert(id).inserted else { throw VoicePolishStructurePlanError.invalidLayout }
            }
        }
        guard seen == known else { throw VoicePolishStructurePlanError.invalidLayout }
    }

    /// 围栏和已识别的缩进代码独占段落；普通行内代码不受此限制。
    private static func containsCodeBlock(_ text: String) -> Bool {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).contains { line in
            if isIndentedCodeLine(line) { return true }
            let content = line.drop(while: { $0 == " " || $0 == "\t" })
            return content.hasPrefix("```") || content.hasPrefix("~~~")
        }
    }

    /// 分段器与布局校验共享同一个行首定义，不根据写作场景猜测代码。
    private static func isIndentedCodeLine<Characters: Sequence>(_ line: Characters) -> Bool where Characters.Element == Character {
        var spaces = 0
        for character in line {
            if character == "\t" { return true }
            guard character == " " else { break }
            spaces += 1
        }
        return spaces >= 4
    }

    private static func isEscaped(_ text: [Character], at index: Int) -> Bool {
        var cursor = index
        var slashes = 0
        while cursor > 0 && text[cursor - 1] == "\\" {
            slashes += 1
            cursor -= 1
        }
        return !slashes.isMultiple(of: 2)
    }

    private static func isSentenceEnd(_ text: [Character], at index: Int) -> Bool {
        let character = text[index]
        if "。！？".contains(character) { return true }
        guard ".!?".contains(character), index > 0, !text[index - 1].isWhitespace,
              index + 1 == text.count || text[index + 1].isWhitespace else { return false }
        var tokenStart = index
        while tokenStart > 0 && !text[tokenStart - 1].isWhitespace { tokenStart -= 1 }
        let token = String(text[tokenStart..<index])
        // 路径、域名、小数、缩写与运算符不能因一个 ASCII 标点被拆开。
        if token.contains(where: { ".:/\\_=@#<>|&*+{}[]".contains($0) }) { return false }
        if character == "." {
            let abbreviations: Set<String> = ["mr", "mrs", "ms", "dr", "prof", "sr", "jr", "vs", "etc", "st", "no"]
            if token.count == 1 || abbreviations.contains(token.lowercased()) { return false }
        }
        // 裸 ASCII 问叹号之后若仍是小写标识符，保守保留可能的代码表达式。
        if character != ".", index + 1 < text.count {
            var next = index + 1
            while next < text.count && text[next].isWhitespace { next += 1 }
            if next < text.count && text[next].isASCII && text[next].isLowercase { return false }
        }
        return true
    }
}
