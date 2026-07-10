import Foundation
import Compression

// MARK: - Result Types

struct VolcUtterance: Sendable, Equatable {
    let text: String
    let definite: Bool
}

struct VolcASRResult: Sendable, Equatable {
    let text: String
    let utterances: [VolcUtterance]
}

struct VolcServerResponse: Sendable, Equatable {
    let header: VolcHeader
    let result: VolcASRResult
}

// MARK: - Protocol Functions

enum VolcProtocol: Sendable {

    // MARK: - Build Client Request JSON

    static func buildClientRequest(
        uid: String,
        format: String = "pcm",
        codec: String = "raw",
        rate: Int = 16000,
        bits: Int = 16,
        channel: Int = 1,
        showUtterances: Bool = true,
        resultType: String = "full",
        options: ASRRequestOptions = ASRRequestOptions()
    ) -> Data {
        var requestDict: [String: Any] = [
            "model_name": "bigmodel",
            "enable_punc": options.enablePunc,
            "enable_ddc": true,
            "enable_nonstream": true,
            "show_utterances": showUtterances,
            "result_type": resultType,
            "end_window_size": 3000,
            "force_to_speech_time": 1000,
        ]

        if let contextString = buildContextString(
            hotwords: options.hotwords,
            userHotwordCount: options.userHotwordCount,
            correctionWords: options.correctionWords
        ) {
            requestDict["context"] = contextString
        }

        var corpus: [String: Any] = [:]
        if let boostingTableID = sanitized(options.boostingTableID) {
            corpus["boosting_table_id"] = boostingTableID
        }
        if !corpus.isEmpty {
            requestDict["corpus"] = corpus
        }

        if options.contextHistoryLength > 0 {
            requestDict["context_history_length"] = options.contextHistoryLength
        }

        let payload: [String: Any] = [
            "user": ["uid": uid],
            "audio": [
                "format": format,
                "codec": codec,
                "rate": rate,
                "bits": bits,
                "channel": channel,
            ],
            "request": requestDict,
        ]
        // Force-try is safe here: dictionary of known-serializable types
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    private static func buildContextString(
        hotwords: [String],
        userHotwordCount: Int,
        correctionWords: [String: String]
    ) -> String? {
        var contextObject: [String: Any] = [:]

        var seenHotwords = Set<String>()
        var cleanedUserHotwordCount = 0
        let cleanedHotwords = hotwords.enumerated().compactMap { index, word -> String? in
            let cleaned = word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return nil }
            let key = cleaned.lowercased()
            guard seenHotwords.insert(key).inserted else { return nil }
            if index < max(userHotwordCount, 0) {
                cleanedUserHotwordCount += 1
            }
            return cleaned
        }
        if !cleanedHotwords.isEmpty {
            // 火山请求级热词的官方格式只声明 word。此前附带的 scale 无文档背书，
            // 可能导致服务端忽略所谓权重；用户词优先级由上游顺序保持。
            contextObject["hotwords"] = cleanedHotwords.map { word in
                ["word": word] as [String: Any]
            }
        }

        let userHotwords = Array(cleanedHotwords.prefix(cleanedUserHotwordCount))
        var effectiveCorrections = automaticCorrectionWords(for: userHotwords)
        // 用户手工配置的错词纠正优先于自动格式变体。
        for (trigger, replacement) in correctionWords {
            let cleanedTrigger = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanedReplacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanedTrigger.isEmpty, !cleanedReplacement.isEmpty else { continue }
            effectiveCorrections[cleanedTrigger] = cleanedReplacement
        }
        if !effectiveCorrections.isEmpty {
            contextObject["correct_words"] = effectiveCorrections
        }

        guard !contextObject.isEmpty,
              let contextData = try? JSONSerialization.data(withJSONObject: contextObject),
              let contextString = String(data: contextData, encoding: .utf8)
        else {
            return nil
        }
        return contextString
    }

    /// 用户只输入正确词，后台自动补常见的英文大小写、CamelCase 分词与扩展名口语形式。
    /// 中文同音错词无法可靠猜测，仍由「错词纠正」让用户明确指定，避免误替换。
    private static func automaticCorrectionWords(for hotwords: [String]) -> [String: String] {
        var corrections: [String: String] = [:]

        for canonical in hotwords {
            var variants: [String] = []
            func appendVariant(_ value: String) {
                let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty, cleaned != canonical, !variants.contains(cleaned) else { return }
                variants.append(cleaned)
            }

            appendVariant(canonical.lowercased())

            let camelSpaced = splitCamelCase(canonical)
            appendVariant(camelSpaced)
            appendVariant(camelSpaced.lowercased())

            if canonical.contains(".") {
                let spaceVariant = canonical.replacingOccurrences(of: ".", with: " ")
                appendVariant(spaceVariant)
                appendVariant(spaceVariant.lowercased())

                let chineseDotVariant = canonical.replacingOccurrences(of: ".", with: "点")
                appendVariant(chineseDotVariant)
                appendVariant(chineseDotVariant.lowercased())
            }

            for variant in variants where corrections[variant] == nil {
                corrections[variant] = canonical
            }
        }

        return corrections
    }

    private static func splitCamelCase(_ value: String) -> String {
        var result = ""
        var previous: Character?
        for character in value {
            if let previous,
               character.isUppercase,
               previous.isLowercase || previous.isNumber {
                result.append(" ")
            }
            result.append(character)
            previous = character
        }
        return result
    }

    private static func sanitized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }

    // MARK: - Encode Full Binary Message

    static func encodeMessage(
        header: VolcHeader,
        payload: Data,
        sequenceNumber: Int32? = nil
    ) -> Data {
        var message = header.encode()

        // Append sequence number if flagged
        if let seq = sequenceNumber {
            var seqBig = seq.bigEndian
            message.append(Data(bytes: &seqBig, count: 4))
        }

        // Append payload size (4 bytes big-endian) + payload
        var size = UInt32(payload.count).bigEndian
        message.append(Data(bytes: &size, count: 4))
        message.append(payload)

        return message
    }

    // MARK: - Encode Audio Packet

    static func encodeAudioPacket(
        audioData: Data,
        isLast: Bool
    ) -> Data {
        let flags: VolcMessageFlags = isLast ? .lastPacketNoSequence : .noSequence
        let header = VolcHeader(
            messageType: .audioOnlyRequest,
            flags: flags,
            serialization: .none,
            compression: .none
        )
        return encodeMessage(header: header, payload: audioData)
    }

    // MARK: - Decode Server Message

    static func decodeServerResponse(_ data: Data) throws -> VolcServerResponse {
        let header = try VolcHeader.decode(from: data)
        let headerBytes = Int(header.headerSize) * 4
        var offset = headerBytes

        // Skip sequence number if present
        if header.flags == .positiveSequence || header.flags == .negativeSequenceLast {
            offset += 4
        }

        guard data.count >= offset + 4 else {
            throw VolcProtocolError.invalidPayload
        }

        // Read payload size
        let sizeBytes = data[data.startIndex + offset ..< data.startIndex + offset + 4]
        let payloadSize = Int(UInt32(bigEndian: sizeBytes.withUnsafeBytes { $0.load(as: UInt32.self) }))
        offset += 4

        guard data.count >= offset + payloadSize else {
            throw VolcProtocolError.invalidPayload
        }

        var payload = data[data.startIndex + offset ..< data.startIndex + offset + payloadSize]

        // Handle server error
        if header.messageType == .serverError {
            // Error payload may also be compressed/JSON
            if header.compression == .gzip {
                payload = try gzipDecompress(Data(payload))
            }
            if header.serialization == .json, !payload.isEmpty {
                if let json = try? JSONSerialization.jsonObject(with: Data(payload)) as? [String: Any] {
                    let code = json["code"] as? Int
                    let message = json["message"] as? String
                    throw VolcProtocolError.serverError(code: code, message: message)
                }
            }
            throw VolcProtocolError.serverError(code: nil, message: nil)
        }

        // Decompress if needed
        if header.compression == .gzip {
            payload = try gzipDecompress(Data(payload))
        }

        // Parse JSON
        guard header.serialization == .json else {
            throw VolcProtocolError.invalidPayload
        }

        guard let json = try JSONSerialization.jsonObject(with: Data(payload)) as? [String: Any] else {
            throw VolcProtocolError.invalidPayload
        }

        // Response format: {"result": {"text": "...", "utterances": [...]}, "audio_info": {...}}
        let resultObj = json["result"] as? [String: Any]
        let text = resultObj?["text"] as? String ?? json["text"] as? String ?? ""
        var utterances: [VolcUtterance] = []

        let uttsSource = resultObj?["utterances"] as? [[String: Any]]
            ?? json["utterances"] as? [[String: Any]]
        if let utts = uttsSource {
            utterances = utts.map { u in
                VolcUtterance(
                    text: u["text"] as? String ?? "",
                    definite: u["definite"] as? Bool ?? false
                )
            }
        }

        return VolcServerResponse(
            header: header,
            result: VolcASRResult(text: text, utterances: utterances)
        )
    }

    // MARK: - Gzip

    private static func processStream(
        operation: compression_stream_operation,
        source: Data
    ) -> Data? {
        let pageSize = 16384
        let dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: pageSize)
        defer { dstBuffer.deallocate() }

        let streamPtr = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPtr.deallocate() }

        let initStatus = compression_stream_init(streamPtr, operation, COMPRESSION_ZLIB)
        guard initStatus == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(streamPtr) }

        return source.withUnsafeBytes { (srcPointer: UnsafeRawBufferPointer) -> Data? in
            guard let srcBase = srcPointer.baseAddress else { return nil }

            streamPtr.pointee.src_ptr = srcBase.assumingMemoryBound(to: UInt8.self)
            streamPtr.pointee.src_size = source.count

            var output = Data()

            repeat {
                streamPtr.pointee.dst_ptr = dstBuffer
                streamPtr.pointee.dst_size = pageSize

                let status = compression_stream_process(streamPtr, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))

                let produced = pageSize - streamPtr.pointee.dst_size
                if produced > 0 {
                    output.append(dstBuffer, count: produced)
                }

                if status == COMPRESSION_STATUS_END {
                    break
                }
                if status == COMPRESSION_STATUS_ERROR {
                    return nil
                }
            } while true

            return output
        }
    }

    static func gzipDecompress(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return Data() }
        guard let result = processStream(operation: COMPRESSION_STREAM_DECODE, source: data) else {
            throw VolcProtocolError.decompressionFailed
        }
        return result
    }
}
