import Foundation

private struct VoicePolishStageTimeoutError: Error {}

struct VoicePolishPipeline: Sendable {
    private enum FastValidationScope {
        case document
        case chunk

        var deferredCodes: Set<VoicePolishValidationCode> {
            switch self {
            case .document:
                return []
            case .chunk:
                // “是否原样”和“是否兑现整篇版式”都无法脱离全文判断。
                // 内容事实、安全字符、旧事实和语义关系仍在片级立即拦截。
                return [.unchangedDraft, .layoutRequirementUnmet]
            }
        }
    }

    private static let baselineFirstRequestTimeout: Duration = .seconds(30)
    private static let baselineTotalTimeout: Duration = .seconds(45)
    private static let baselineAnalyzeTimeout: Duration = .seconds(15)
    private static let baselineRenderTimeout: Duration = .seconds(20)
    private static let baselineRepairTimeout: Duration = .seconds(10)
    private static let maximumFirstRequestTimeout: Int64 = 120
    private static let maximumAnalyzeTimeout: Int64 = 60
    private static let maximumRenderTimeout: Int64 = 120
    private static let maximumRepairTimeout: Int64 = 90
    private static let maximumTotalTimeout: Int64 = 240
    private static let maximumOutputTokens = 8_192
    /// 每篇长文只允许对一个失败初始片执行一次二分；每个子片仍沿用 Fast 的
    /// “初稿 + 一次修复”上限，因此额外最多四次 LLM 调用，且不会递归二分。
    private static let fastChunkRecoveryMaximumDepth = 1
    private static let fastChunkRecoveryMaximumAdditionalAttempts = 4
    private static let fastChunkMaximumAttemptsPerRun = 2
    /// 所有片都已成功后，全文门禁只允许一次合并修复。修复稿仍须重新通过
    /// 完整全文校验；失败后直接停止，不能递归修复或重新跑全部分片。
    private static let fastMergedRepairMaximumAttempts = 1
    private static let repairableFastCodes: Set<VoicePolishValidationCode> = [
        .explanationOnly,
        .promptLeakage,
        .missingProtectedFact,
        .supersededFactRetained,
        .excludedSideNoteLeaked,
        .planIntegrityFailure,
        .layoutRequirementUnmet,
        .unchangedDraft,
        .abnormalLength,
    ]
    private static let recoverableFastChunkCodes: Set<VoicePolishValidationCode> = [
        .explanationOnly,
        .missingProtectedFact,
        .abnormalLength,
        .planIntegrityFailure,
        .layoutRequirementUnmet,
        .unchangedDraft,
    ]
    /// 单片正文控制在约 1,800 tokens。真实质量跑测证明 2,600 tokens 左右的
    /// 单片仍可能被模型压缩，随后因事实缺失让整篇长文退回原稿。更小的片段
    /// 给逐项保全和一次局部修复留出余量；它只是内部可靠性策略，不暴露为
    /// 用户模式。
    static let fastChunkSourceTokenLimit = 1_800

    private let client: any LLMClient
    private let config: LLMConfig
    private let totalTimeout: Duration
    private let firstRequestTimeout: Duration
    private let usesAdaptiveTotalTimeout: Bool
    private let usesAdaptiveFirstRequestTimeout: Bool
    private let analyzeTimeout: Duration
    private let renderTimeout: Duration
    private let repairTimeout: Duration
    private let usesAdaptiveAnalyzeTimeout: Bool
    private let usesAdaptiveRenderTimeout: Bool
    private let usesAdaptiveRepairTimeout: Bool
    private let fastChunkTokenLimit: Int
    private let ledgerRoutingEnabled: Bool
    private let ledgerMinimumCharacterCount: Int
    private let onStage: (@Sendable (VoicePolishStage) -> Void)?

    init(
        client: any LLMClient,
        config: LLMConfig,
        totalTimeout: Duration? = nil,
        firstRequestTimeout: Duration? = nil,
        analyzeTimeout: Duration? = nil,
        renderTimeout: Duration? = nil,
        repairTimeout: Duration? = nil,
        fastChunkSourceTokenLimit: Int = VoicePolishPipeline.fastChunkSourceTokenLimit,
        ledgerRoutingEnabled: Bool = true,
        ledgerMinimumCharacterCount: Int = 80,
        onStage: (@Sendable (VoicePolishStage) -> Void)? = nil
    ) {
        self.client = client
        self.config = config
        self.totalTimeout = totalTimeout ?? Self.baselineTotalTimeout
        self.firstRequestTimeout = firstRequestTimeout ?? Self.baselineFirstRequestTimeout
        self.usesAdaptiveTotalTimeout = totalTimeout == nil
        self.usesAdaptiveFirstRequestTimeout = firstRequestTimeout == nil
        self.analyzeTimeout = analyzeTimeout ?? Self.baselineAnalyzeTimeout
        self.renderTimeout = renderTimeout ?? Self.baselineRenderTimeout
        self.repairTimeout = repairTimeout ?? Self.baselineRepairTimeout
        self.usesAdaptiveAnalyzeTimeout = analyzeTimeout == nil
        self.usesAdaptiveRenderTimeout = renderTimeout == nil
        self.usesAdaptiveRepairTimeout = repairTimeout == nil
        self.fastChunkTokenLimit = max(1, fastChunkSourceTokenLimit)
        // 非默认切片阈值只由旧 Fast 分片专项测试注入；它必须继续验证原有
        // 分片实现，不能被日常长文的新 Ledger 编排提前接管。
        self.ledgerRoutingEnabled = ledgerRoutingEnabled
            && fastChunkSourceTokenLimit == Self.fastChunkSourceTokenLimit
        self.ledgerMinimumCharacterCount = max(0, ledgerMinimumCharacterCount)
        self.onStage = onStage
    }

    /// 长内容的成稿通常接近原文长度。固定 2048 tokens 会让 Provider 正常地
    /// 以长度上限结束，随后被事实校验回退成原文。预算按 canonical 正文估算，
    /// 但统一封顶，避免异常输入把单次请求无限放大。
    static func outputTokenBudget(
        for request: VoicePolishRequest,
        task: LLMTask
    ) -> Int {
        let sourceTokens = min(
            EstimatedTokenCounter.count(in: request.fallbackText),
            maximumOutputTokens
        )
        let baseline: Int
        let estimated: Int
        switch task {
        case .voicePolishFast:
            baseline = 2_048
            estimated = sourceTokens * 3 / 2 + 512
        case .voicePolishRender:
            baseline = 3_072
            estimated = sourceTokens * 3 / 2 + 512
        case .voicePolishAnalyze, .voicePolishStructured, .voicePolishRepair:
            baseline = 4_096
            estimated = sourceTokens * 2 + 1_024
        case .generic:
            return 2_048
        }
        return min(maximumOutputTokens, max(baseline, estimated))
    }

    /// 默认预算才随正文增长；测试或特殊调用显式注入的短超时必须原样保留。
    /// 按每秒约 64 个输出 tokens 预留增量，覆盖长文首包、网络波动和完整收尾；
    /// 用户仍可通过 HUD 主动使用原文。
    static func defaultFirstRequestTimeout(for request: VoicePolishRequest) -> Duration {
        let outputTokens = outputTokenBudget(for: request, task: .voicePolishFast)
        let extraTokens = max(0, outputTokens - 2_048)
        let extraSeconds = Int64((extraTokens + 63) / 64)
        return .seconds(min(maximumFirstRequestTimeout, 30 + extraSeconds))
    }

    static func defaultAnalyzeTimeout(for request: VoicePolishRequest) -> Duration {
        adaptiveStageTimeout(
            baselineSeconds: 15,
            maximumSeconds: maximumAnalyzeTimeout,
            outputTokens: outputTokenBudget(for: request, task: .voicePolishAnalyze),
            baselineTokens: 4_096,
            tokensPerSecond: 128
        )
    }

    static func defaultRenderTimeout(for request: VoicePolishRequest) -> Duration {
        adaptiveStageTimeout(
            baselineSeconds: 20,
            maximumSeconds: maximumRenderTimeout,
            outputTokens: outputTokenBudget(for: request, task: .voicePolishRender),
            baselineTokens: 3_072,
            tokensPerSecond: 96
        )
    }

    static func defaultRepairTimeout(for request: VoicePolishRequest) -> Duration {
        adaptiveStageTimeout(
            baselineSeconds: 10,
            maximumSeconds: maximumRepairTimeout,
            outputTokens: outputTokenBudget(for: request, task: .voicePolishRepair),
            baselineTokens: 4_096,
            tokensPerSecond: 96
        )
    }

    static func defaultTotalTimeout(for request: VoicePolishRequest) -> Duration {
        let firstSeconds = defaultFirstRequestTimeout(for: request).components.seconds
        let fastSeconds = firstSeconds + 15
        let stagedSeconds = defaultAnalyzeTimeout(for: request).components.seconds
            + defaultRenderTimeout(for: request).components.seconds
            + defaultRepairTimeout(for: request).components.seconds
            + 15
        let sourceNeedsExpandedBudget = outputTokenBudget(
            for: request,
            task: .voicePolishFast
        ) > 2_048
        let requiredSeconds = sourceNeedsExpandedBudget
            ? max(fastSeconds, stagedSeconds)
            : fastSeconds
        return .seconds(min(maximumTotalTimeout, max(45, requiredSeconds)))
    }

    private static func adaptiveStageTimeout(
        baselineSeconds: Int64,
        maximumSeconds: Int64,
        outputTokens: Int,
        baselineTokens: Int,
        tokensPerSecond: Int
    ) -> Duration {
        let extraTokens = max(0, outputTokens - baselineTokens)
        let extraSeconds = Int64((extraTokens + tokensPerSecond - 1) / tokensPerSecond)
        return .seconds(min(maximumSeconds, baselineSeconds + extraSeconds))
    }

    func process(
        _ request: VoicePolishRequest,
        startedAt suppliedStart: ContinuousClock.Instant? = nil
    ) async -> VoicePolishResult {
        let startedAt = suppliedStart ?? ContinuousClock.now
        let sourceFactSegments = request.context.scene == .code
            ? request.input.segments
            : VoicePolishNumbering.removingContinuousNumberedLineMarkers(
                from: request.input.segments
            )
        let sourceFacts = ProtectedFactExtractor.extract(from: sourceFactSegments)
            + request.resolvedEntities.map {
                SourceFactCandidate(
                    sourceText: $0.surfaceText,
                    canonicalValue: $0.canonical,
                    kind: .lexiconEntity,
                    sourceSegmentIDs: $0.sourceSegmentIDs
                )
            }
        let decision = VoicePolishComplexityRouter.decide(
            request: request,
            factCandidates: sourceFacts
        )
        let executedRoute = VoicePolishComplexityRouter.executedRoute(
            for: decision,
            request: request
        )
        let maximumAttempts: Int
        switch executedRoute {
        case .fast:
            maximumAttempts = 1
        case .structured:
            maximumAttempts = request.qualityMode == .fast ? 1 : 2
        case .deep:
            maximumAttempts = 3
        }

        DebugFileLogger.log(
            "voice polish start route=\(decision.route.rawValue) executed=\(executedRoute.rawValue) quality=\(request.qualityMode.rawValue) input=\(request.fallbackText.count)chars facts=\(sourceFacts.count)"
        )

        if ledgerRoutingEnabled,
           VoicePolishLedgerPipeline.shouldUse(
               for: request,
               minimumCharacterCount: ledgerMinimumCharacterCount
           ) {
            DebugFileLogger.log(
                "voice polish ledger route input=\(request.input.fallbackText.count)chars scene=\(request.context.scene.rawValue)"
            )
            let ledgerResult = await VoicePolishLedgerPipeline(
                client: client,
                config: config,
                onStage: onStage
            // Ledger 的 120 秒预算从实际进入规划时开始。录音停止后的 ASR
            // teardown/词汇解析不应提前吃掉模型预算，否则长口述可能尚未发起
            // Planner 就被判超时。
            ).process(request, startedAt: .now)
            if let text = ledgerResult.text {
                return VoicePolishResult(
                    text: text,
                    detectedRoute: decision.route,
                    executedRoute: .deep,
                    llmAttemptCount: ledgerResult.attempts,
                    validationCodes: ledgerResult.validationCodes,
                    usedFallback: false,
                    failureReason: nil
                )
            }
            DebugFileLogger.log(
                "voice polish ledger unavailable stage=\(ledgerResult.failureStage?.rawValue ?? "unknown") attempts=\(ledgerResult.attempts)"
            )
            return VoicePolishResult(
                text: request.fallbackText,
                detectedRoute: decision.route,
                executedRoute: .deep,
                llmAttemptCount: ledgerResult.attempts,
                validationCodes: ledgerResult.validationCodes,
                usedFallback: true,
                failureReason: ledgerResult.failureReason,
                plannerValidationTrace: ledgerResult.plannerValidationTrace,
                rejectedDraft: ledgerResult.rejectedDraft
            )
        }

        do {
            if executedRoute == .fast {
                let chunks = Self.fastChunkTexts(
                    from: request.fallbackText,
                    maximumSourceTokens: fastChunkTokenLimit,
                    protectedTerms: request.resolvedEntities.map(\.canonical)
                )
                if chunks.count > 1 {
                    return await runChunkedFast(
                        request: request,
                        chunks: chunks,
                        sourceFacts: sourceFacts,
                        detectedRoute: decision.route,
                        startedAt: startedAt
                    )
                }
            }
            let payload = try VoicePolishPrompts.payload(
                for: request,
                sourceFacts: sourceFacts,
                deepDeferred: false
            )
            if executedRoute == .fast {
                return await runFast(
                    request: request,
                    payload: payload,
                    sourceFacts: sourceFacts,
                    detectedRoute: decision.route,
                    startedAt: startedAt,
                    validationScope: .document
                )
            }
            if executedRoute == .deep {
                return await runDeep(
                    request: request,
                    payload: payload,
                    sourceFacts: sourceFacts,
                    detectedRoute: decision.route,
                    startedAt: startedAt
                )
            }
            return await runStructured(
                request: request,
                payload: payload,
                sourceFacts: sourceFacts,
                detectedRoute: decision.route,
                maximumAttempts: maximumAttempts,
                startedAt: startedAt
            )
        } catch {
            return fallback(
                request: request,
                detectedRoute: decision.route,
                executedRoute: executedRoute,
                attempts: 0,
                codes: [.emptyOutput],
                reason: .setupFailed
            )
        }
    }

    /// 将超长正文切成尽量均衡的内部片段。优先在完整句界、换行和分号处分片，
    /// 其次才使用逗号或空白；没有任何边界的低标点口述才按字符安全截断。
    /// 分片不会把紧随其后的显式改口与前文拆开，避免旧事实被局部校验误保留。
    static func fastChunkTexts(
        from source: String,
        maximumSourceTokens: Int = fastChunkSourceTokenLimit,
        protectedTerms: [String] = []
    ) -> [String] {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard maximumSourceTokens > 0,
              EstimatedTokenCounter.count(in: trimmed) > maximumSourceTokens else {
            return [trimmed]
        }

        var remaining = trimmed
        var chunks: [String] = []
        while EstimatedTokenCounter.count(in: remaining) > maximumSourceTokens {
            let remainingTokens = EstimatedTokenCounter.count(in: remaining)
            let remainingChunkCount = max(
                2,
                Int(ceil(Double(remainingTokens) / Double(maximumSourceTokens)))
            )
            let idealTokens = Int(
                ceil(Double(remainingTokens) / Double(remainingChunkCount))
            )
            let boundary = preferredChunkBoundary(
                in: remaining,
                idealTokens: idealTokens,
                maximumTokens: maximumSourceTokens,
                protectedTerms: protectedTerms
            )
            guard boundary > remaining.startIndex, boundary < remaining.endIndex else {
                return [trimmed]
            }
            let chunk = String(remaining[..<boundary])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            remaining = String(remaining[boundary...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !chunk.isEmpty, !remaining.isEmpty else { return [trimmed] }
            chunks.append(chunk)
        }
        chunks.append(remaining)
        return chunks
    }

    private static func preferredChunkBoundary(
        in text: String,
        idealTokens: Int,
        maximumTokens: Int,
        protectedTerms: [String]
    ) -> String.Index {
        struct Candidate {
            let index: String.Index
            let tokens: Int
            let strength: Int
        }

        let minimumTokens = max(1, idealTokens * 3 / 5)
        var candidates: [Candidate] = []
        var safeCandidates: [Candidate] = []
        var hardBoundary: String.Index?
        var index = text.startIndex
        let protectedRanges = protectedChunkRanges(
            in: text,
            additionalTerms: protectedTerms
        )

        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            let prefix = String(text[..<next])
            let tokens = EstimatedTokenCounter.count(in: prefix)
            if tokens <= maximumTokens {
                if !isUnsafeProtectedBoundary(next, ranges: protectedRanges),
                   !isUnsafeCorrectionBoundary(in: text, at: next) {
                    hardBoundary = next
                }
            } else {
                break
            }

            guard let strength = chunkBoundaryStrength(after: character),
                  !isUnsafeCorrectionBoundary(in: text, at: next),
                  !isUnsafeProtectedBoundary(next, ranges: protectedRanges) else {
                index = next
                continue
            }
            let candidate = Candidate(index: next, tokens: tokens, strength: strength)
            safeCandidates.append(candidate)
            if tokens >= minimumTokens {
                candidates.append(candidate)
            }
            index = next
        }

        if let best = candidates.max(by: { left, right in
            if left.strength != right.strength {
                return left.strength < right.strength
            }
            let leftDistance = abs(left.tokens - idealTokens)
            let rightDistance = abs(right.tokens - idealTokens)
            if leftDistance != rightDistance { return leftDistance > rightDistance }
            return left.tokens > right.tokens
        }) {
            return best.index
        }

        // 理想区间内没有安全边界时，优先退回更早的完整句界。不能因为 token
        // 上限直接在“改成 | 4 人”“应该是 | 周五”之间硬切；旧事实与最终值
        // 一旦分到两个请求，局部事实校验会互相冲突并把整篇退回原文。
        if let fallback = safeCandidates.last {
            return fallback.index
        }

        // 纠错短语可能正好横跨上限，且它前后的边界都会因“必须与旧值留在同
        // 一片”而被判不安全。此时允许最多小幅越过预算，向后找到下一个句号
        // 或分号；比在“改成 4 人”中间硬切更安全，默认 2,800-token 片仍远低
        // 于 8,192-token 输出上限。
        let extensionLimit = maximumTokens + min(128, max(16, maximumTokens / 10))
        var extendedIndex = index
        while extendedIndex < text.endIndex {
            let character = text[extendedIndex]
            let next = text.index(after: extendedIndex)
            let tokens = EstimatedTokenCounter.count(in: String(text[..<next]))
            if tokens > extensionLimit { break }
            if let strength = chunkBoundaryStrength(after: character),
               strength >= 1,
               !isUnsafeCorrectionBoundary(in: text, at: next),
               !isUnsafeProtectedBoundary(next, ranges: protectedRanges) {
                return next
            }
            extendedIndex = next
        }

        guard var boundary = hardBoundary else { return text.endIndex }
        // 不把英文单词、数字、路径或代码标识符从中间截断。
        while boundary > text.startIndex, boundary < text.endIndex {
            let previous = text[text.index(before: boundary)]
            let next = text[boundary]
            guard isASCIIWordCharacter(previous), isASCIIWordCharacter(next) else { break }
            boundary = text.index(before: boundary)
        }
        while let protectedRange = protectedRanges.first(where: {
            $0.lowerBound < boundary && boundary < $0.upperBound
        }) {
            boundary = protectedRange.lowerBound
        }
        return boundary == text.startIndex ? (hardBoundary ?? text.endIndex) : boundary
    }

    private static func protectedChunkRanges(
        in text: String,
        additionalTerms: [String]
    ) -> [Range<String.Index>] {
        let segment = RecognitionSegment(
            id: "voice-polish-chunk-boundary",
            text: text,
            startTimeMs: nil,
            endTimeMs: nil,
            confidence: nil,
            isFinal: true
        )
        let facts = ProtectedFactExtractor.extract(from: [segment])
        var ranges = ProtectedFactExtractor.locations(
            of: facts,
            in: [segment]
        ).compactMap { location -> Range<String.Index>? in
            guard location.segmentIndex == 0,
                  location.offset >= 0,
                  location.length > 0,
                  let lower = text.index(
                      text.startIndex,
                      offsetBy: location.offset,
                      limitedBy: text.endIndex
                  ),
                  let upper = text.index(
                      lower,
                      offsetBy: location.length,
                      limitedBy: text.endIndex
                  ) else {
                return nil
            }
            return lower..<upper
        }

        for term in Set(additionalTerms) {
            guard !term.isEmpty else { continue }
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let range = text.range(
                      of: term,
                      range: searchStart..<text.endIndex
                  ) {
                ranges.append(range)
                searchStart = range.upperBound
            }
        }
        return ranges
    }

    private static func isUnsafeProtectedBoundary(
        _ boundary: String.Index,
        ranges: [Range<String.Index>]
    ) -> Bool {
        ranges.contains {
            $0.lowerBound < boundary && boundary < $0.upperBound
        }
    }

    private static func chunkBoundaryStrength(after character: Character) -> Int? {
        if "。！？!?\n".contains(character) { return 2 }
        if "；;".contains(character) { return 1 }
        if "，,、：:\t ".contains(character) { return 0 }
        return nil
    }

    private static func isUnsafeCorrectionBoundary(
        in text: String,
        at boundary: String.Index
    ) -> Bool {
        let trailing = String(text[..<boundary])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // 内部分片可以从“ 不对 / 我说错了 ”开始，因为每片都携带全文只读
        // 上下文，且旧事实按具体 occurrence 映射处理。真正不能切的是纠错动词
        // 与其最终值之间，例如“改成 | 4 人”。
        let trailingSignals = [
            "不对", "不是", "说错了", "我说错了", "我改一下", "改一下",
            "应该是", "准确地说", "改成", "改为", "调整为", "现定为",
        ]
        let punctuation = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "，,、：:；;。！？!?"))
        let normalizedTrailing = trailing.trimmingCharacters(in: punctuation)
        return trailingSignals.contains(where: normalizedTrailing.hasSuffix)
    }

    private static func isASCIIWordCharacter(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first,
              scalar.isASCII else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
            || "_./:-".unicodeScalars.contains(scalar)
    }

    /// 失败片的唯一恢复切分。它只产生两个 canonical 子片，不对任一子片继续
    /// 递归；沿用常规分片的纠错短语和 ASCII 标识符边界保护。
    static func fastChunkRecoveryTexts(
        from source: String,
        protectedTerms: [String] = []
    ) -> [String]? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let totalTokens = EstimatedTokenCounter.count(in: trimmed)
        guard !trimmed.isEmpty, totalTokens >= 2 else { return nil }

        let halfTokens = max(1, Int(ceil(Double(totalTokens) / 2)))
        let boundary = preferredChunkBoundary(
            in: trimmed,
            idealTokens: halfTokens,
            maximumTokens: halfTokens,
            protectedTerms: protectedTerms
        )
        guard boundary > trimmed.startIndex, boundary < trimmed.endIndex else {
            return nil
        }
        let first = String(trimmed[..<boundary])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let second = String(trimmed[boundary...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !first.isEmpty, !second.isEmpty else { return nil }
        return [first, second]
    }

    private struct DocumentListCountDeclaration {
        let count: Int
        let numberText: String
    }

    private struct MergedFastRepairOutcome {
        let text: String?
        let attempts: Int
        let validationCodes: [VoicePolishValidationCode]
        let failureReason: VoicePolishFailureReason?
        let rejectedDraft: String
    }

    /// 与最终列表门禁相同，只认唯一、明确的结构总数声明。这里不依赖整篇被
    /// 分类为 numberedList：长口述常被识别为混合结构，但“下面共 48 项”仍然
    /// 是一个确定的全文契约。
    private static func documentListCountDeclaration(
        in request: VoicePolishRequest
    ) -> DocumentListCountDeclaration? {
        let count = #"([1-9]\d?|[一二两三四五六七八九十]{1,3})"#
        let unit = #"(?:点|条|项|步|部分|方面|件事|个事(?:情|项)?|(?:个)?(?:问题|原因|建议|方案|任务|风险|事项|要点|结论|观点|方法|要求|目标|主题|阶段|选择|选项))"#
        let patterns = [
            #"(?:一共|总共|共计|共有|主要有|主要讲|归纳为|总结成|需要做|要做|包括|包含|分为|分成|列出|整理出|有|共)\s*"#
                + count + #"\s*"# + unit,
            #"(?:^|[。！？!?\n])\s*"# + count + #"\s*"# + unit
                + #"(?:要做|需要做|是|包括|如下|[：:])"#,
        ]
        let source = request.fallbackText
        let fullRange = NSRange(source.startIndex..<source.endIndex, in: source)
        var seenRanges: Set<String> = []
        var declarations: [DocumentListCountDeclaration] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: source, range: fullRange) {
                guard match.numberOfRanges > 1,
                      let numberRange = Range(match.range(at: 1), in: source) else {
                    continue
                }
                let rawNumber = String(source[numberRange])
                guard let canonical = ProtectedFactExtractor.canonicalValue(
                    for: rawNumber,
                    kind: .number
                ), let value = Int(canonical), value >= 2 else {
                    continue
                }
                let rangeKey = "\(match.range(at: 1).location):\(match.range(at: 1).length)"
                if seenRanges.insert(rangeKey).inserted {
                    declarations.append(DocumentListCountDeclaration(
                        count: value,
                        numberText: rawNumber
                    ))
                }
            }
        }
        guard declarations.count == 1 else { return nil }
        return declarations[0]
    }

    /// “共 N 项”描述的是整篇列表，不是包含声明的首片必须逐字复述的局部事实。
    /// 金额、日期、普通数量和没有唯一总数声明的开放列表都不会进入延后集合。
    private static func documentOnlyListCountFactKeys(
        request: VoicePolishRequest,
        sourceFacts: [SourceFactCandidate]
    ) -> Set<String> {
        guard let declaration = documentListCountDeclaration(in: request) else {
            return []
        }
        guard VoicePolishListCountConsistency.canDeferStructuralDeclaredCountFact(
            canonicalSource: request.fallbackText,
            count: declaration.count,
            numberText: declaration.numberText
        ) else {
            return []
        }
        return Set(sourceFacts.compactMap { fact in
            guard fact.kind == .number,
                  fact.canonicalValue == String(declaration.count),
                  fact.sourceText == declaration.numberText else {
                return nil
            }
            return semanticFactIdentity(fact)
        })
    }

    /// 各片由模型独立生成时通常都会从 1 开始编号。只有全文明确要求精确 N 项、
    /// 所有片的顶层编号总数恰好等于 N，且每片自身都是 1...局部项数时，才把
    /// 这些纯版式标记重排成全文 1...N；缺项、乱序或正文数字一律不改。
    private static func continuouslyNumberedChunkOutputs(
        _ outputs: [String],
        request: VoicePolishRequest
    ) -> [String] {
        let expectation = VoicePolishLayoutExpectation.infer(from: request)
        guard expectation.numberingPreference != .chinese,
              let declaration = documentListCountDeclaration(in: request),
              declaration.count >= 2,
              outputs.count > 1 else {
            return outputs
        }
        let expectedCount = declaration.count
        let markerPattern = #"^([1-9]\d{0,2})[.)、）．。][ \t]*"#
        let ordinalsByOutput = outputs.map { output in
            output.components(separatedBy: "\n").compactMap { line -> Int? in
                guard let range = line.range(
                    of: markerPattern,
                    options: .regularExpression
                ) else {
                    return nil
                }
                let marker = String(line[range])
                return Int(marker.prefix { $0.isNumber })
            }
        }
        let flattened = ordinalsByOutput.flatMap { $0 }
        let expectedSequence = Array(1...expectedCount)
        guard flattened.count == expectedCount else { return outputs }
        if flattened == expectedSequence { return outputs }
        guard ordinalsByOutput.allSatisfy({ ordinals in
            ordinals.isEmpty || ordinals == Array(1...ordinals.count)
        }) else {
            return outputs
        }

        var nextOrdinal = 1
        return outputs.map { output in
            var lines = output.components(separatedBy: "\n")
            for index in lines.indices {
                guard let range = lines[index].range(
                    of: markerPattern,
                    options: .regularExpression
                ) else {
                    continue
                }
                lines[index].replaceSubrange(range, with: "\(nextOrdinal). ")
                nextOrdinal += 1
            }
            return lines.joined(separator: "\n")
        }
    }

    private static func startsWithTopLevelNumberedListItem(_ text: String) -> Bool {
        guard let first = text.components(separatedBy: "\n").first(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            return false
        }
        return first.range(
            of: #"^[1-9]\d{0,2}[.)、）．。][ \t]*\S"#,
            options: .regularExpression
        ) != nil
    }

    private static func endsWithTopLevelNumberedListItem(_ text: String) -> Bool {
        guard let last = text.components(separatedBy: "\n").last(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            return false
        }
        return last.range(
            of: #"^[1-9]\d{0,2}[.)、）．。][ \t]*\S"#,
            options: .regularExpression
        ) != nil
    }

    private static func combinedChunkOutput(
        _ outputs: [String],
        sourceChunks: [String],
        canonicalSource: String
    ) -> String {
        guard outputs.count == sourceChunks.count,
              let firstOutput = outputs.first else {
            return outputs.joined(separator: "\n\n")
        }

        var sourceRanges: [Range<String.Index>] = []
        var searchStart = canonicalSource.startIndex
        for chunk in sourceChunks {
            guard let range = canonicalSource.range(
                of: chunk,
                range: searchStart..<canonicalSource.endIndex
            ) else {
                return outputs.joined(separator: "\n\n")
            }
            sourceRanges.append(range)
            searchStart = range.upperBound
        }

        var combined = firstOutput
        for index in 0..<(outputs.count - 1) {
            let currentRange = sourceRanges[index]
            let nextRange = sourceRanges[index + 1]
            let sourceGap = String(
                canonicalSource[currentRange.upperBound..<nextRange.lowerBound]
            )
            let separator: String
            if sourceGap.contains("\n") {
                separator = "\n\n"
            } else if !sourceGap.isEmpty {
                separator = sourceGap
            } else if currentRange.upperBound > canonicalSource.startIndex,
                      let lastCharacter = canonicalSource[..<currentRange.upperBound].last,
                      chunkBoundaryStrength(after: lastCharacter) != nil {
                separator = "\n\n"
            } else if endsWithTopLevelNumberedListItem(outputs[index]),
                      startsWithTopLevelNumberedListItem(outputs[index + 1]) {
                // 硬切是请求边界，普通正文仍连续拼回；但两个已成形的列表片之间
                // 至少需要一个换行，否则“16. ...17. ...”会被粘成同一项。
                separator = "\n"
            } else {
                // 无标点硬切只是请求边界，不是正文段落边界。连续拼回可避免
                // “一百 | 二十三人”一类事实被凭空插入空行后改变含义。
                separator = ""
            }
            combined += separator + outputs[index + 1]
        }
        return combined
    }

    /// 只用于全文 unchangedDraft 探针：按 canonical source 中真实存在的片间
    /// 字符拼回，不把请求边界补成新段落。最终展示文本仍使用上面的语义合并；
    /// 这份副本只回答“模型是否实质改写过整篇”。
    private static func sourceFaithfulChunkOutput(
        _ outputs: [String],
        sourceChunks: [String],
        canonicalSource: String
    ) -> String {
        guard outputs.count == sourceChunks.count,
              let firstOutput = outputs.first else {
            return outputs.joined()
        }

        var sourceRanges: [Range<String.Index>] = []
        var searchStart = canonicalSource.startIndex
        for chunk in sourceChunks {
            guard let range = canonicalSource.range(
                of: chunk,
                range: searchStart..<canonicalSource.endIndex
            ) else {
                return outputs.joined()
            }
            sourceRanges.append(range)
            searchStart = range.upperBound
        }

        var combined = firstOutput
        for index in 0..<(outputs.count - 1) {
            let currentRange = sourceRanges[index]
            let nextRange = sourceRanges[index + 1]
            combined += String(
                canonicalSource[currentRange.upperBound..<nextRange.lowerBound]
            )
            combined += outputs[index + 1]
        }
        return combined
    }

    private func runChunkedFast(
        request: VoicePolishRequest,
        chunks: [String],
        sourceFacts: [SourceFactCandidate],
        detectedRoute: VoicePolishRoute,
        startedAt: ContinuousClock.Instant
    ) async -> VoicePolishResult {
        DebugFileLogger.log(
            "voice polish chunked start chunks=\(chunks.count) input=\(request.fallbackText.count)chars"
        )
        var outputs: [String] = []
        var outputSourceChunks: [String] = []
        var attempts = 0
        var accumulatedCodes: [VoicePolishValidationCode] = []
        var recoveryDepth = 0
        var recoveryAttempts = 0
        let supersededOccurrences = VoicePolishValidator.locallySupersededFactOccurrences(
            request: request,
            sourceFacts: sourceFacts
        )
        let globallyForbiddenSuperseded = VoicePolishValidator
            .unambiguouslySupersededFactIndices(
                request: request,
                sourceFacts: sourceFacts
            )
        let documentOnlyFactKeys = Self.documentOnlyListCountFactKeys(
            request: request,
            sourceFacts: sourceFacts
        )
        let factDispositionsByChunk = Self.factDispositionsByChunk(
            request: request,
            chunks: chunks,
            sourceFacts: sourceFacts,
            supersededOccurrences: supersededOccurrences
        )

        for (index, chunk) in chunks.enumerated() {
            let executionIndex = index + recoveryDepth
            let executionCount = chunks.count + recoveryDepth
            // 第一片继续尊重从停止录音起算的既有时限；后续每片获得独立生成
            // 窗口，避免把多次受控请求重新挤回单次 240 秒的总上限。
            let chunkStartedAt = index == 0 ? startedAt : ContinuousClock.now
            let result = await runFastChunk(
                documentRequest: request,
                text: chunk,
                index: executionIndex,
                count: executionCount,
                sourceFacts: sourceFacts,
                supersededKeys: factDispositionsByChunk[index].superseded,
                documentOnlyFactKeys: documentOnlyFactKeys,
                globallyForbiddenSuperseded: globallyForbiddenSuperseded,
                detectedRoute: detectedRoute,
                startedAt: chunkStartedAt
            )
            attempts += result.llmAttemptCount
            if !result.usedFallback {
                appendUnique(result.validationCodes, to: &accumulatedCodes)
                outputs.append(result.text.trimmingCharacters(in: .whitespacesAndNewlines))
                outputSourceChunks.append(chunk)
                continue
            }

            guard recoveryDepth < Self.fastChunkRecoveryMaximumDepth,
                  Self.shouldRecoverFastChunk(result),
                  let recoveryChunks = Self.fastChunkRecoveryTexts(
                      from: chunk,
                      protectedTerms: request.resolvedEntities.map(\.canonical)
                  ) else {
                appendUnique(result.validationCodes, to: &accumulatedCodes)
                return fallback(
                    request: request,
                    detectedRoute: detectedRoute,
                    executedRoute: .fast,
                    attempts: attempts,
                    codes: accumulatedCodes,
                    reason: result.failureReason ?? .validationFailed,
                    rejectedDraft: result.rejectedDraft
                )
            }

            recoveryDepth += 1
            let expandedChunks = Array(chunks[..<index])
                + recoveryChunks
                + Array(chunks[(index + 1)...])
            let recoveryDispositions = Self.factDispositionsByChunk(
                request: request,
                chunks: expandedChunks,
                sourceFacts: sourceFacts,
                supersededOccurrences: supersededOccurrences
            )
            var recoveredOutputs: [String] = []
            var recoveryFailedResult: VoicePolishResult?

            for (childOffset, recoveryChunk) in recoveryChunks.enumerated() {
                // 为即将运行的子片预留完整的“初稿 + 修复”预算。不能在只剩一次
                // 调用时启动一个可能需要修复的子片，从而突破总调用上限。
                guard recoveryAttempts + Self.fastChunkMaximumAttemptsPerRun
                        <= Self.fastChunkRecoveryMaximumAdditionalAttempts else {
                    recoveryFailedResult = result
                    break
                }
                let expandedIndex = index + childOffset
                let childResult = await runFastChunk(
                    documentRequest: request,
                    text: recoveryChunk,
                    index: expandedIndex,
                    count: expandedChunks.count,
                    sourceFacts: sourceFacts,
                    supersededKeys: recoveryDispositions[expandedIndex].superseded,
                    documentOnlyFactKeys: documentOnlyFactKeys,
                    globallyForbiddenSuperseded: globallyForbiddenSuperseded,
                    detectedRoute: detectedRoute,
                    startedAt: ContinuousClock.now
                )
                attempts += childResult.llmAttemptCount
                recoveryAttempts += childResult.llmAttemptCount
                guard !childResult.usedFallback else {
                    recoveryFailedResult = childResult
                    break
                }
                appendUnique(childResult.validationCodes, to: &accumulatedCodes)
                recoveredOutputs.append(
                    childResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }

            if let recoveryFailedResult {
                appendUnique(result.validationCodes, to: &accumulatedCodes)
                appendUnique(recoveryFailedResult.validationCodes, to: &accumulatedCodes)
                return fallback(
                    request: request,
                    detectedRoute: detectedRoute,
                    executedRoute: .fast,
                    attempts: attempts,
                    codes: accumulatedCodes,
                    reason: recoveryFailedResult.failureReason ?? .validationFailed,
                    rejectedDraft: recoveryFailedResult.rejectedDraft ?? result.rejectedDraft
                )
            }
            guard recoveredOutputs.count == recoveryChunks.count else {
                appendUnique(result.validationCodes, to: &accumulatedCodes)
                return fallback(
                    request: request,
                    detectedRoute: detectedRoute,
                    executedRoute: .fast,
                    attempts: attempts,
                    codes: accumulatedCodes,
                    reason: .validationFailed,
                    rejectedDraft: result.rejectedDraft
                )
            }
            outputs.append(contentsOf: recoveredOutputs)
            outputSourceChunks.append(contentsOf: recoveryChunks)
        }

        let mergeReadyOutputs = Self.continuouslyNumberedChunkOutputs(
            outputs,
            request: request
        )
        let combinedDraft = Self.combinedChunkOutput(
            mergeReadyOutputs,
            sourceChunks: outputSourceChunks,
            canonicalSource: request.fallbackText
        )
        let normalized = normalizedLayoutText(combinedDraft, request: request)
        let finalOutput = VoicePolishValidator.removingDeterministicDraftArtifacts(
            from: normalized,
            request: request
        ) ?? normalized
        let validation = VoicePolishValidator.validateFast(
            output: finalOutput,
            request: request,
            sourceFacts: sourceFacts
        )
        var finalValidationCodes = validation.codes
        let sourceFaithfulDraft = Self.sourceFaithfulChunkOutput(
            mergeReadyOutputs,
            sourceChunks: outputSourceChunks,
            canonicalSource: request.fallbackText
        )
        let unchangedProbe = VoicePolishValidator.validateFast(
            output: sourceFaithfulDraft,
            request: request,
            sourceFacts: sourceFacts
        )
        if unchangedProbe.codes.contains(.unchangedDraft),
           !finalValidationCodes.contains(.unchangedDraft) {
            finalValidationCodes.append(.unchangedDraft)
        }
        if finalValidationCodes.contains(where: \.isHardFailure) {
            let repaired = await repairMergedFastOutput(
                request: request,
                sourceFacts: sourceFacts,
                rejectedDraft: finalOutput,
                validationCodes: finalValidationCodes
            )
            attempts += repaired.attempts
            if let repairedText = repaired.text {
                appendUnique(repaired.validationCodes, to: &accumulatedCodes)
                DebugFileLogger.log(
                    "voice polish chunked merged repair done chunks=\(chunks.count) attempts=\(attempts) output=\(repairedText.count)chars"
                )
                return success(
                    text: repairedText,
                    detectedRoute: detectedRoute,
                    executedRoute: .fast,
                    attempts: attempts,
                    codes: accumulatedCodes
                )
            }
            appendUnique(finalValidationCodes, to: &accumulatedCodes)
            appendUnique(repaired.validationCodes, to: &accumulatedCodes)
            return fallback(
                request: request,
                detectedRoute: detectedRoute,
                executedRoute: .fast,
                attempts: attempts,
                codes: accumulatedCodes,
                reason: repaired.failureReason ?? .validationFailed,
                rejectedDraft: repaired.rejectedDraft
            )
        }
        appendUnique(finalValidationCodes, to: &accumulatedCodes)
        DebugFileLogger.log(
            "voice polish chunked done chunks=\(chunks.count) attempts=\(attempts) output=\(finalOutput.count)chars"
        )
        return success(
            text: finalOutput,
            detectedRoute: detectedRoute,
            executedRoute: .fast,
            attempts: attempts,
            codes: accumulatedCodes
        )
    }

    /// 最终合并稿已经带有所有成功片，只需给模型一次针对全文硬错误的修复机会。
    /// 请求使用完整 canonical source 和事实约束；响应不会再分片或递归，而是
    /// 直接走完整全文 Validator。网络、超时和不可修复安全错误均有限停止。
    private func repairMergedFastOutput(
        request: VoicePolishRequest,
        sourceFacts: [SourceFactCandidate],
        rejectedDraft: String,
        validationCodes: [VoicePolishValidationCode]
    ) async -> MergedFastRepairOutcome {
        let hardCodes = validationCodes.filter(\.isHardFailure)
        guard Self.fastMergedRepairMaximumAttempts > 0,
              !hardCodes.isEmpty,
              hardCodes.allSatisfy(Self.repairableFastCodes.contains) else {
            return MergedFastRepairOutcome(
                text: nil,
                attempts: 0,
                validationCodes: [],
                failureReason: .validationFailed,
                rejectedDraft: rejectedDraft
            )
        }

        let repairPayload: String
        do {
            let originalPayload = try VoicePolishPrompts.payload(
                for: request,
                sourceFacts: sourceFacts,
                deepDeferred: false
            )
            repairPayload = try VoicePolishPrompts.fastRepairPayload(
                originalPayload: originalPayload,
                rawResponse: rejectedDraft,
                validationCodes: hardCodes,
                request: request,
                sourceFacts: sourceFacts
            )
        } catch {
            return MergedFastRepairOutcome(
                text: nil,
                attempts: 0,
                validationCodes: [],
                failureReason: .setupFailed,
                rejectedDraft: rejectedDraft
            )
        }

        do {
            let repairStartedAt = ContinuousClock.now
            let timeout = try availableTimeout(
                stageLimit: effectiveRepairTimeout(for: request),
                startedAt: repairStartedAt,
                request: request
            )
            let repairedRaw = try await generate(
                LLMRequest(
                    context: .processingMode,
                    task: .voicePolishRepair,
                    system: VoicePolishPrompts.fastContentRepair,
                    user: repairPayload,
                    options: LLMGenerationOptions(
                        temperature: 0,
                        maxOutputTokens: Self.outputTokenBudget(
                            for: request,
                            task: .voicePolishRepair
                        ),
                        reasoningPolicy: .disabled,
                        responseFormat: .text
                    )
                ),
                timeout: timeout
            ).text
            guard let repairedDraft = VoicePolishOutputNormalizer.plainText(
                repairedRaw,
                sourceText: request.fallbackText
            ) else {
                return MergedFastRepairOutcome(
                    text: nil,
                    attempts: 1,
                    validationCodes: [.abnormalLength],
                    failureReason: .validationFailed,
                    rejectedDraft: rejectedDraft
                )
            }
            let normalized = normalizedLayoutText(repairedDraft, request: request)
            let repaired = VoicePolishValidator.removingDeterministicDraftArtifacts(
                from: normalized,
                request: request
            ) ?? normalized
            var repairedValidation = VoicePolishValidator.validateFast(
                output: repaired,
                request: request,
                sourceFacts: sourceFacts
            ).codes
            if hardCodes.contains(.unchangedDraft),
               Self.layoutInsensitiveMergedDraft(repaired)
                    == Self.layoutInsensitiveMergedDraft(request.fallbackText),
               !repairedValidation.contains(.unchangedDraft) {
                repairedValidation.append(.unchangedDraft)
            }
            guard !repairedValidation.contains(where: \.isHardFailure) else {
                return MergedFastRepairOutcome(
                    text: nil,
                    attempts: 1,
                    validationCodes: repairedValidation,
                    failureReason: .validationFailed,
                    rejectedDraft: repaired
                )
            }
            return MergedFastRepairOutcome(
                text: repaired,
                attempts: 1,
                validationCodes: repairedValidation,
                failureReason: nil,
                rejectedDraft: repaired
            )
        } catch {
            let sizeRelated = isSizeRelatedGenerationFailure(error)
            return MergedFastRepairOutcome(
                text: nil,
                attempts: 1,
                validationCodes: sizeRelated ? [.abnormalLength] : [],
                failureReason: sizeRelated ? .validationFailed : failureReason(for: error),
                rejectedDraft: rejectedDraft
            )
        }
    }

    private static func layoutInsensitiveMergedDraft(_ text: String) -> String {
        String(text.lowercased().filter {
            !$0.isWhitespace && !$0.isPunctuation && !$0.isSymbol
        })
    }

    private static func shouldRecoverFastChunk(_ result: VoicePolishResult) -> Bool {
        guard result.usedFallback,
              result.failureReason == .validationFailed else {
            return false
        }
        let hardCodes = result.validationCodes.filter(\.isHardFailure)
        guard !hardCodes.isEmpty,
              hardCodes.allSatisfy(recoverableFastChunkCodes.contains) else {
            return false
        }
        if result.llmAttemptCount == fastChunkMaximumAttemptsPerRun { return true }
        // 初次响应已被 Provider 明确截断、超过安全上限，或无法通过长度归一化
        // 时，不存在可供内容 Repair 的完整草稿；直接缩小该片比重复同尺寸请求
        // 更可靠。普通网络/超时仍不会映射为 abnormalLength。
        return result.llmAttemptCount == 1
            && hardCodes.count == 1
            && hardCodes[0] == .abnormalLength
    }

    private func runFastChunk(
        documentRequest: VoicePolishRequest,
        text: String,
        index: Int,
        count: Int,
        sourceFacts: [SourceFactCandidate],
        supersededKeys: Set<String>,
        documentOnlyFactKeys: Set<String>,
        globallyForbiddenSuperseded: Set<Int>,
        detectedRoute: VoicePolishRoute,
        startedAt: ContinuousClock.Instant
    ) async -> VoicePolishResult {
        let chunkRequest = fastChunkRequest(
            from: documentRequest,
            text: text,
            index: index,
            count: count
        )
        let factSegments = chunkRequest.context.scene == .code
            ? chunkRequest.input.segments
            : VoicePolishNumbering.removingContinuousNumberedLineMarkers(
                from: chunkRequest.input.segments
            )
        let chunkFacts = (ProtectedFactExtractor.extract(from: factSegments)
            + chunkRequest.resolvedEntities.map {
                SourceFactCandidate(
                    sourceText: $0.surfaceText,
                    canonicalValue: $0.canonical,
                    kind: .lexiconEntity,
                    sourceSegmentIDs: $0.sourceSegmentIDs
                )
            }).filter {
                let key = Self.semanticFactIdentity($0)
                return !supersededKeys.contains(key)
                    && !documentOnlyFactKeys.contains(key)
            }
        let payload: String
        do {
            payload = try VoicePolishPrompts.chunkPayload(
                for: chunkRequest,
                sourceFacts: chunkFacts,
                documentText: documentRequest.fallbackText,
                documentSourceFacts: sourceFacts,
                supersededFactIndices: globallyForbiddenSuperseded,
                chunkIndex: index + 1,
                chunkCount: count
            )
        } catch {
            return fallback(
                request: chunkRequest,
                detectedRoute: detectedRoute,
                executedRoute: .fast,
                attempts: 0,
                codes: [.emptyOutput],
                reason: .setupFailed
            )
        }
        return await runFast(
            request: chunkRequest,
            payload: payload,
            sourceFacts: chunkFacts,
            detectedRoute: detectedRoute,
            startedAt: startedAt,
            validationScope: .chunk
        )
    }

    private func fastChunkRequest(
        from request: VoicePolishRequest,
        text: String,
        index: Int,
        count: Int
    ) -> VoicePolishRequest {
        let segmentID = "voice-polish-chunk-\(index + 1)"
        let segment = RecognitionSegment(
            id: segmentID,
            text: text,
            startTimeMs: nil,
            endTimeMs: nil,
            confidence: nil,
            isFinal: true
        )
        let entityEdits = request.input.requiredEntityEdits.compactMap { edit -> VoiceTerminologyEdit? in
            guard text.contains(edit.alias) || text.contains(edit.canonical) else { return nil }
            return VoiceTerminologyEdit(
                alias: edit.alias,
                canonical: edit.canonical,
                sourceSegmentIDs: [segmentID]
            )
        }
        let resolvedEntities = request.resolvedEntities.compactMap { entity -> ResolvedEntity? in
            guard text.contains(entity.surfaceText) || text.contains(entity.canonical) else {
                return nil
            }
            return ResolvedEntity(
                surfaceText: entity.surfaceText,
                canonical: entity.canonical,
                sourceSegmentIDs: [segmentID],
                candidateSource: entity.candidateSource,
                confidence: entity.confidence
            )
        }
        return VoicePolishRequest(
            input: VoiceInputEnvelope(
                providerFinalText: text,
                rawSegments: [segment],
                canonicalText: text,
                segments: [segment],
                requiredEntityEdits: entityEdits,
                durationMs: request.input.durationMs / max(1, count),
                detectedLanguage: request.input.detectedLanguage,
                provider: request.input.provider
            ),
            context: request.context,
            preferences: request.preferences,
            qualityMode: request.qualityMode,
            resolvedEntities: resolvedEntities
        )
    }

    private func appendUnique(
        _ codes: [VoicePolishValidationCode],
        to accumulated: inout [VoicePolishValidationCode]
    ) {
        for code in codes where !accumulated.contains(code) {
            accumulated.append(code)
        }
    }

    private static func semanticFactIdentity(_ fact: SourceFactCandidate) -> String {
        "\(fact.kind.rawValue)|\(fact.canonicalValue ?? fact.sourceText)"
    }

    struct ChunkFactDisposition {
        let superseded: Set<String>
    }

    /// 以“事实的具体字符出现位置”映射内部片段，而不是只看 Provider segment。
    /// 因而即使 Provider 把 8K 正文压成单 segment，仍能区分北京仍有效的 3 与
    /// 上海被 4 覆盖的 3。无法精确对齐时返回空放宽集合，宁可进入安全修复，
    /// 也不把同值的有效事实一起删掉。
    static func factDispositionsByChunk(
        request: VoicePolishRequest,
        chunks: [String],
        sourceFacts: [SourceFactCandidate],
        supersededOccurrences: Set<VoicePolishValidator.SupersededFactOccurrence>
    ) -> [ChunkFactDisposition] {
        guard !chunks.isEmpty else { return [] }

        let resolvedSegmentTexts = request.input.segments.map { segment in
            let relevantEntities = request.resolvedEntities.filter {
                $0.sourceSegmentIDs.contains(segment.id)
            }
            return EntityResolver.applying(relevantEntities, to: segment.text)
        }
        let document = request.fallbackText
        let conservative = Array(
            repeating: ChunkFactDisposition(superseded: []),
            count: chunks.count
        )
        let resolvedDocument = resolvedSegmentTexts.joined()
        let trimSet = CharacterSet.whitespacesAndNewlines
        let trimmedResolvedDocument = resolvedDocument.trimmingCharacters(in: trimSet)
        guard trimmedResolvedDocument == document else {
            return conservative
        }
        let leadingTrimCount: Int
        if let firstContent = resolvedDocument.rangeOfCharacter(from: trimSet.inverted)?.lowerBound {
            leadingTrimCount = resolvedDocument.distance(
                from: resolvedDocument.startIndex,
                to: firstContent
            )
        } else {
            leadingTrimCount = 0
        }

        var segmentOffsets: [Int] = []
        var nextSegmentOffset = 0
        for text in resolvedSegmentTexts {
            segmentOffsets.append(nextSegmentOffset)
            nextSegmentOffset += text.count
        }

        var searchStart = document.startIndex
        var chunkRanges: [(lower: Int, upper: Int)] = []
        for chunk in chunks {
            guard let range = document.range(
                of: chunk,
                options: [],
                range: searchStart..<document.endIndex
            ) else {
                return conservative
            }
            let lower = document.distance(from: document.startIndex, to: range.lowerBound)
            let upper = document.distance(from: document.startIndex, to: range.upperBound)
            chunkRanges.append((lower, upper))
            searchStart = range.upperBound
        }

        struct LocatedEvidence {
            let key: String
            let lower: Int
            let upper: Int
            let isSuperseded: Bool
        }
        let evidence = ProtectedFactExtractor.locations(
            of: sourceFacts.filter { $0.kind != .lexiconEntity },
            in: request.input.segments
        ).compactMap { location -> LocatedEvidence? in
            guard let factIndex = sourceFacts.firstIndex(where: {
                $0.kind == location.candidate.kind
                    && $0.canonicalValue == location.candidate.canonicalValue
                    && $0.sourceSegmentIDs == location.candidate.sourceSegmentIDs
            }), segmentOffsets.indices.contains(location.segmentIndex) else {
                return nil
            }
            let segment = request.input.segments[location.segmentIndex]
            let relevantEntities = request.resolvedEntities.filter {
                $0.sourceSegmentIDs.contains(segment.id)
            }
            let prefixEnd = segment.text.index(
                segment.text.startIndex,
                offsetBy: location.offset
            )
            let factEnd = segment.text.index(
                prefixEnd,
                offsetBy: location.length
            )
            // 实体纠错可能改变前文长度（Type less → Typeless）。用同一套已确认
            // 替换分别投影“事实前缀”和“事实结尾”，得到 canonical 正文中的
            // 精确位置；不能因任意实体替换就退回保守空映射。
            let resolvedPrefix = EntityResolver.applying(
                relevantEntities,
                to: String(segment.text[..<prefixEnd])
            )
            let resolvedThroughFact = EntityResolver.applying(
                relevantEntities,
                to: String(segment.text[..<factEnd])
            )
            let lower = segmentOffsets[location.segmentIndex] + resolvedPrefix.count - leadingTrimCount
            let upper = segmentOffsets[location.segmentIndex] + resolvedThroughFact.count - leadingTrimCount
            return LocatedEvidence(
                key: semanticFactIdentity(sourceFacts[factIndex]),
                lower: lower,
                upper: upper,
                isSuperseded: supersededOccurrences.contains {
                    $0.factIndex == factIndex
                        && $0.segmentIndex == location.segmentIndex
                        && $0.offset == location.offset
                        && $0.length == location.length
                }
            )
        }

        return chunkRanges.map { chunkRange in
            let overlapping = evidence.filter {
                $0.lower < chunkRange.upper && chunkRange.lower < $0.upper
            }
            let active = Set(overlapping.filter { !$0.isSuperseded }.map(\.key))
            let superseded = Set(overlapping.filter { $0.isSuperseded }.map(\.key))
                .subtracting(active)
            return ChunkFactDisposition(superseded: superseded)
        }
    }

    private func runDeep(
        request: VoicePolishRequest,
        payload: String,
        sourceFacts: [SourceFactCandidate],
        detectedRoute: VoicePolishRoute,
        startedAt: ContinuousClock.Instant
    ) async -> VoicePolishResult {
        var attempts = 0
        let analyzerRaw: String
        do {
            let timeout = try availableTimeout(
                stageLimit: effectiveAnalyzeTimeout(for: request),
                startedAt: startedAt,
                request: request
            )
            attempts += 1
            analyzerRaw = try await generate(
                LLMRequest(
                    context: .processingMode,
                    task: .voicePolishAnalyze,
                    system: VoicePolishPrompts.analyzer,
                    user: payload,
                    options: LLMGenerationOptions(
                        temperature: 0,
                        maxOutputTokens: Self.outputTokenBudget(
                            for: request,
                            task: .voicePolishAnalyze
                        ),
                        reasoningPolicy: .low,
                        responseFormat: .jsonObject
                    )
                ),
                timeout: timeout
            ).text
        } catch {
            return fallback(
                request: request,
                detectedRoute: detectedRoute,
                executedRoute: .deep,
                attempts: attempts,
                codes: [.invalidStructuredResponse],
                reason: failureReason(for: error)
            )
        }

        var plan: VoicePolishPlan
        do {
            plan = try StructuredLLMDecoder.decode(VoicePolishPlan.self, from: analyzerRaw)
        } catch {
            let decodeCode = validationCode(for: error)
            guard analyzerRaw.utf8.count <= VoicePolishOutputNormalizer.maximumResponseBytes else {
                return fallback(
                    request: request,
                    detectedRoute: detectedRoute,
                    executedRoute: .deep,
                    attempts: attempts,
                    codes: [decodeCode]
                )
            }
            do {
                let timeout = try availableTimeout(
                    stageLimit: effectiveRepairTimeout(for: request),
                    startedAt: startedAt,
                    request: request
                )
                attempts += 1
                let repairPayload = try VoicePolishPrompts.repairPayload(
                    originalPayload: payload,
                    rawResponse: analyzerRaw,
                    validationCodes: [decodeCode]
                )
                let repairedRaw = try await generate(
                    LLMRequest(
                        context: .processingMode,
                        task: .voicePolishRepair,
                        system: VoicePolishPrompts.planFormatRepair,
                        user: repairPayload,
                        options: LLMGenerationOptions(
                            temperature: 0,
                            maxOutputTokens: Self.outputTokenBudget(
                                for: request,
                                task: .voicePolishRepair
                            ),
                            reasoningPolicy: .disabled,
                            responseFormat: .jsonObject
                        )
                    ),
                    timeout: timeout
                ).text
                plan = try StructuredLLMDecoder.decode(VoicePolishPlan.self, from: repairedRaw)
            } catch {
                return fallback(
                    request: request,
                    detectedRoute: detectedRoute,
                    executedRoute: .deep,
                    attempts: attempts,
                    codes: [validationCode(for: error)],
                    reason: failureReason(for: error)
                )
            }
        }
        plan = normalizedPlanLayout(plan, request: request)

        let planValidation = VoicePolishValidator.validatePlan(
            plan,
            request: request,
            sourceFacts: sourceFacts
        )
        guard !planValidation.hasHardFailure else {
            return fallback(
                request: request,
                detectedRoute: detectedRoute,
                executedRoute: .deep,
                attempts: attempts,
                codes: planValidation.codes
            )
        }

        let renderPayload: String
        let renderRaw: String
        do {
            let timeout = try availableTimeout(
                stageLimit: effectiveRenderTimeout(for: request),
                startedAt: startedAt,
                request: request
            )
            attempts += 1
            renderPayload = try VoicePolishPrompts.renderPayload(
                for: request,
                plan: plan
            )
            renderRaw = try await generate(
                LLMRequest(
                    context: .processingMode,
                    task: .voicePolishRender,
                    system: VoicePolishPrompts.renderer,
                    user: renderPayload,
                    options: LLMGenerationOptions(
                        temperature: 0.2,
                        maxOutputTokens: Self.outputTokenBudget(
                            for: request,
                            task: .voicePolishRender
                        ),
                        reasoningPolicy: .disabled,
                        responseFormat: .text
                    )
                ),
                timeout: timeout
            ).text
        } catch {
            return fallback(
                request: request,
                detectedRoute: detectedRoute,
                executedRoute: .deep,
                attempts: attempts,
                codes: [.emptyOutput],
                reason: failureReason(for: error)
            )
        }

        guard let renderedDraft = VoicePolishOutputNormalizer.plainText(
            renderRaw,
            sourceText: request.fallbackText
        ) else {
            return fallback(
                request: request,
                detectedRoute: detectedRoute,
                executedRoute: .deep,
                attempts: attempts,
                codes: [.abnormalLength]
            )
        }
        let rendered = normalizedLayoutText(renderedDraft, request: request)
        let validation = VoicePolishValidator.validateStructured(
            response: StructuredVoicePolishResponse(plan: plan, finalText: rendered),
            request: request,
            sourceFacts: sourceFacts
        )
        guard validation.hasHardFailure else {
            return success(
                text: rendered,
                detectedRoute: detectedRoute,
                executedRoute: .deep,
                attempts: attempts,
                codes: validation.codes
            )
        }

        // Analyzer 曾使用格式修复时已消耗三次预算，Renderer 失败直接回退。
        guard attempts < 3 else {
            return fallback(
                request: request,
                detectedRoute: detectedRoute,
                executedRoute: .deep,
                attempts: attempts,
                codes: validation.codes
            )
        }
        do {
            let timeout = try availableTimeout(
                stageLimit: effectiveRepairTimeout(for: request),
                startedAt: startedAt,
                request: request
            )
            attempts += 1
            let repairPayload = try VoicePolishPrompts.renderRepairPayload(
                validatedRenderPayload: renderPayload,
                rawResponse: renderRaw,
                validationCodes: validation.codes.filter(\.isHardFailure)
            )
            let repairedRaw = try await generate(
                LLMRequest(
                    context: .processingMode,
                    task: .voicePolishRepair,
                    system: VoicePolishPrompts.renderRepair,
                    user: repairPayload,
                    options: LLMGenerationOptions(
                        temperature: 0,
                        maxOutputTokens: Self.outputTokenBudget(
                            for: request,
                            task: .voicePolishRepair
                        ),
                        reasoningPolicy: .disabled,
                        responseFormat: .text
                    )
                ),
                timeout: timeout
            ).text
            guard let repairedDraft = VoicePolishOutputNormalizer.plainText(
                repairedRaw,
                sourceText: request.fallbackText
            ) else {
                throw StructuredLLMDecoderError.invalidJSON
            }
            let repaired = normalizedLayoutText(repairedDraft, request: request)
            let repairedValidation = VoicePolishValidator.validateStructured(
                response: StructuredVoicePolishResponse(plan: plan, finalText: repaired),
                request: request,
                sourceFacts: sourceFacts
            )
            guard !repairedValidation.hasHardFailure else {
                return fallback(
                    request: request,
                    detectedRoute: detectedRoute,
                    executedRoute: .deep,
                    attempts: attempts,
                    codes: repairedValidation.codes
                )
            }
            return success(
                text: repaired,
                detectedRoute: detectedRoute,
                executedRoute: .deep,
                attempts: attempts,
                codes: repairedValidation.codes
            )
        } catch {
            return fallback(
                request: request,
                detectedRoute: detectedRoute,
                executedRoute: .deep,
                attempts: attempts,
                codes: [validationCode(for: error)],
                reason: failureReason(for: error)
            )
        }
    }

    private func fastValidation(
        output: String,
        request: VoicePolishRequest,
        sourceFacts: [SourceFactCandidate],
        scope: FastValidationScope
    ) -> VoicePolishValidationResult {
        let validation = VoicePolishValidator.validateFast(
            output: output,
            request: request,
            sourceFacts: sourceFacts
        )
        let deferred = scope.deferredCodes
        guard !deferred.isEmpty else { return validation }
        return VoicePolishValidationResult(
            codes: validation.codes.filter { !deferred.contains($0) }
        )
    }

    private func runFast(
        request: VoicePolishRequest,
        payload: String,
        sourceFacts: [SourceFactCandidate],
        detectedRoute: VoicePolishRoute,
        startedAt: ContinuousClock.Instant,
        validationScope: FastValidationScope
    ) async -> VoicePolishResult {
        var attempts = 0
        do {
            let timeout = try availableTimeout(
                stageLimit: effectiveFirstRequestTimeout(for: request),
                startedAt: startedAt,
                request: request
            )
            attempts = 1
            let response = try await generate(
                LLMRequest(
                    context: .processingMode,
                    task: .voicePolishFast,
                    system: VoicePolishPrompts.fast,
                    user: payload,
                    options: LLMGenerationOptions(
                        // 语音成稿追求同输入稳定收敛，创意随机性只会放大漏约束、
                        // 旧改口残留和幕后指令泄漏的概率。
                        temperature: 0,
                        maxOutputTokens: Self.outputTokenBudget(
                            for: request,
                            task: .voicePolishFast
                        ),
                        reasoningPolicy: .disabled,
                        responseFormat: .text
                    )
                ),
                timeout: timeout
            )
            guard let outputDraft = VoicePolishOutputNormalizer.plainText(
                response.text,
                sourceText: request.fallbackText
            ) else {
                return fallback(
                    request: request,
                    detectedRoute: detectedRoute,
                    executedRoute: .fast,
                    attempts: attempts,
                    codes: [.abnormalLength]
                )
            }
            let output = normalizedLayoutText(outputDraft, request: request)
            var finalOutput = VoicePolishValidator.removingDeterministicDraftArtifacts(
                from: output,
                request: request
            ) ?? output
            var validation = fastValidation(
                output: finalOutput,
                request: request,
                sourceFacts: sourceFacts,
                scope: validationScope
            )
            if validation.codes.contains(.supersededFactRetained),
               let cleaned = VoicePolishValidator.removingParentheticalSupersededFacts(
                   from: finalOutput,
                   request: request,
                   sourceFacts: sourceFacts
               ) {
                let cleanedValidation = fastValidation(
                    output: cleaned,
                    request: request,
                    sourceFacts: sourceFacts,
                    scope: validationScope
                )
                if !cleanedValidation.hasHardFailure {
                    finalOutput = cleaned
                    validation = cleanedValidation
                }
            }
            let hardCodes = validation.codes.filter(\.isHardFailure)
            if !hardCodes.isEmpty,
               hardCodes.allSatisfy(Self.repairableFastCodes.contains) {
                do {
                    let timeout = try availableTimeout(
                        stageLimit: effectiveRepairTimeout(for: request),
                        startedAt: startedAt,
                        request: request
                    )
                    attempts += 1
                    let repairPayload = try VoicePolishPrompts.fastRepairPayload(
                        originalPayload: payload,
                        rawResponse: finalOutput,
                        validationCodes: validation.codes.filter(\.isHardFailure),
                        request: request,
                        sourceFacts: sourceFacts
                    )
                    let repairedRaw = try await generate(
                        LLMRequest(
                            context: .processingMode,
                            task: .voicePolishRepair,
                            system: VoicePolishPrompts.fastContentRepair,
                            user: repairPayload,
                            options: LLMGenerationOptions(
                                temperature: 0,
                                maxOutputTokens: Self.outputTokenBudget(
                                    for: request,
                                    task: .voicePolishRepair
                                ),
                                reasoningPolicy: .disabled,
                                responseFormat: .text
                            )
                        ),
                        timeout: timeout
                    ).text
                    guard let repairedDraft = VoicePolishOutputNormalizer.plainText(
                        repairedRaw,
                        sourceText: request.fallbackText
                    ) else {
                        throw StructuredLLMDecoderError.invalidJSON
                    }
                    let repaired = normalizedLayoutText(repairedDraft, request: request)
                    let repairedValidation = fastValidation(
                        output: repaired,
                        request: request,
                        sourceFacts: sourceFacts,
                        scope: validationScope
                    )
                    guard !repairedValidation.hasHardFailure else {
                        return fallback(
                            request: request,
                            detectedRoute: detectedRoute,
                            executedRoute: .fast,
                            attempts: attempts,
                            codes: repairedValidation.codes,
                            rejectedDraft: repaired
                        )
                    }
                    return success(
                        text: repaired,
                        detectedRoute: detectedRoute,
                        executedRoute: .fast,
                        attempts: attempts,
                        codes: repairedValidation.codes
                    )
                } catch {
                    if isSizeRelatedGenerationFailure(error) {
                        var codes = validation.codes
                        appendUnique([.abnormalLength], to: &codes)
                        return fallback(
                            request: request,
                            detectedRoute: detectedRoute,
                            executedRoute: .fast,
                            attempts: attempts,
                            codes: codes,
                            reason: .validationFailed,
                            rejectedDraft: finalOutput
                        )
                    }
                    return fallback(
                        request: request,
                        detectedRoute: detectedRoute,
                        executedRoute: .fast,
                        attempts: attempts,
                        codes: validation.codes,
                        reason: failureReason(for: error),
                        rejectedDraft: finalOutput
                    )
                }
            }
            guard !validation.hasHardFailure else {
                return fallback(
                    request: request,
                    detectedRoute: detectedRoute,
                    executedRoute: .fast,
                    attempts: attempts,
                    codes: validation.codes,
                    rejectedDraft: finalOutput
                )
            }
            return success(
                text: finalOutput,
                detectedRoute: detectedRoute,
                executedRoute: .fast,
                attempts: attempts,
                codes: validation.codes
            )
        } catch {
            if isSizeRelatedGenerationFailure(error) {
                return fallback(
                    request: request,
                    detectedRoute: detectedRoute,
                    executedRoute: .fast,
                    attempts: attempts,
                    codes: [.abnormalLength],
                    reason: .validationFailed
                )
            }
            return fallback(
                request: request,
                detectedRoute: detectedRoute,
                executedRoute: .fast,
                attempts: attempts,
                codes: [.emptyOutput],
                reason: failureReason(for: error)
            )
        }
    }

    private func runStructured(
        request: VoicePolishRequest,
        payload: String,
        sourceFacts: [SourceFactCandidate],
        detectedRoute: VoicePolishRoute,
        maximumAttempts: Int,
        startedAt: ContinuousClock.Instant
    ) async -> VoicePolishResult {
        var attempts = 0
        let firstRaw: String
        do {
            let timeout = try availableTimeout(
                stageLimit: effectiveFirstRequestTimeout(for: request),
                startedAt: startedAt,
                request: request
            )
            attempts += 1
            firstRaw = try await generate(
                LLMRequest(
                    context: .processingMode,
                    task: .voicePolishStructured,
                    system: VoicePolishPrompts.structured,
                    user: payload,
                    options: LLMGenerationOptions(
                        temperature: 0.1,
                        maxOutputTokens: Self.outputTokenBudget(
                            for: request,
                            task: .voicePolishStructured
                        ),
                        reasoningPolicy: .disabled,
                        responseFormat: .jsonObject
                    )
                ),
                timeout: timeout
            ).text
        } catch {
            return fallback(
                request: request,
                detectedRoute: detectedRoute,
                executedRoute: .structured,
                attempts: attempts,
                codes: [.invalidStructuredResponse],
                reason: failureReason(for: error)
            )
        }

        let decoded: StructuredVoicePolishResponse
        do {
            decoded = try StructuredLLMDecoder.decode(
                StructuredVoicePolishResponse.self,
                from: firstRaw
            )
        } catch {
            let decodeCode = validationCode(for: error)
            guard attempts < maximumAttempts,
                  firstRaw.utf8.count <= VoicePolishOutputNormalizer.maximumResponseBytes else {
                return fallback(
                    request: request,
                    detectedRoute: detectedRoute,
                    executedRoute: .structured,
                    attempts: attempts,
                    codes: [decodeCode]
                )
            }
            do {
                let timeout = try availableTimeout(
                    stageLimit: effectiveRepairTimeout(for: request),
                    startedAt: startedAt,
                    request: request
                )
                attempts += 1
                let repairPayload = try VoicePolishPrompts.repairPayload(
                    originalPayload: payload,
                    rawResponse: firstRaw,
                    validationCodes: [decodeCode]
                )
                let repairedRaw = try await generate(
                    LLMRequest(
                        context: .processingMode,
                        task: .voicePolishRepair,
                        system: VoicePolishPrompts.formatRepair,
                        user: repairPayload,
                        options: LLMGenerationOptions(
                            temperature: 0,
                            maxOutputTokens: Self.outputTokenBudget(
                                for: request,
                                task: .voicePolishRepair
                            ),
                            reasoningPolicy: .disabled,
                            responseFormat: .jsonObject
                        )
                    ),
                    timeout: timeout
                ).text
                let repairedDraft = try StructuredLLMDecoder.decode(
                    StructuredVoicePolishResponse.self,
                    from: repairedRaw
                )
                let repaired = normalizedStructuredResponse(repairedDraft, request: request)
                let validation = VoicePolishValidator.validateStructured(
                    response: repaired,
                    request: request,
                    sourceFacts: sourceFacts
                )
                guard !validation.hasHardFailure else {
                    return fallback(
                        request: request,
                        detectedRoute: detectedRoute,
                        executedRoute: .structured,
                        attempts: attempts,
                        codes: validation.codes
                    )
                }
                return success(
                    text: repaired.finalText,
                    detectedRoute: detectedRoute,
                    executedRoute: .structured,
                    attempts: attempts,
                    codes: validation.codes
                )
            } catch {
                return fallback(
                    request: request,
                    detectedRoute: detectedRoute,
                    executedRoute: .structured,
                    attempts: attempts,
                    codes: [validationCode(for: error)],
                    reason: failureReason(for: error)
                )
            }
        }

        let normalizedDecoded = normalizedStructuredResponse(decoded, request: request)
        let validation = VoicePolishValidator.validateStructured(
            response: normalizedDecoded,
            request: request,
            sourceFacts: sourceFacts
        )
        guard validation.hasHardFailure else {
            return success(
                text: normalizedDecoded.finalText,
                detectedRoute: detectedRoute,
                executedRoute: .structured,
                attempts: attempts,
                codes: validation.codes
            )
        }
        guard attempts < maximumAttempts else {
            return fallback(
                request: request,
                detectedRoute: detectedRoute,
                executedRoute: .structured,
                attempts: attempts,
                codes: validation.codes
            )
        }

        // 内容 Repair 与格式 Repair 共享最后一次预算；当前分支只在首次 JSON
        // 已有效时进入，因此不会出现“格式修复后再内容修复”的第三次调用。
        do {
            let timeout = try availableTimeout(
                stageLimit: effectiveRepairTimeout(for: request),
                startedAt: startedAt,
                request: request
            )
            attempts += 1
            let repairPayload = try VoicePolishPrompts.repairPayload(
                originalPayload: payload,
                rawResponse: firstRaw,
                validationCodes: validation.codes.filter(\.isHardFailure)
            )
            let repairedRaw = try await generate(
                LLMRequest(
                    context: .processingMode,
                    task: .voicePolishRepair,
                    system: VoicePolishPrompts.contentRepair,
                    user: repairPayload,
                    options: LLMGenerationOptions(
                        temperature: 0,
                        maxOutputTokens: Self.outputTokenBudget(
                            for: request,
                            task: .voicePolishRepair
                        ),
                        reasoningPolicy: .disabled,
                        responseFormat: .jsonObject
                    )
                ),
                timeout: timeout
            ).text
            let repairedDraft = try StructuredLLMDecoder.decode(
                StructuredVoicePolishResponse.self,
                from: repairedRaw
            )
            let repaired = normalizedStructuredResponse(repairedDraft, request: request)
            let repairedValidation = VoicePolishValidator.validateStructured(
                response: repaired,
                request: request,
                sourceFacts: sourceFacts
            )
            guard !repairedValidation.hasHardFailure else {
                return fallback(
                    request: request,
                    detectedRoute: detectedRoute,
                    executedRoute: .structured,
                    attempts: attempts,
                    codes: repairedValidation.codes
                )
            }
            return success(
                text: repaired.finalText,
                detectedRoute: detectedRoute,
                executedRoute: .structured,
                attempts: attempts,
                codes: repairedValidation.codes
            )
        } catch {
            return fallback(
                request: request,
                detectedRoute: detectedRoute,
                executedRoute: .structured,
                attempts: attempts,
                codes: [validationCode(for: error)],
                reason: failureReason(for: error)
            )
        }
    }

    private func generate(
        _ request: LLMRequest,
        timeout: Duration
    ) async throws -> LLMResponse {
        try Task.checkCancellation()
        onStage?(stage(for: request.task))
        let startedAt = ContinuousClock.now
        do {
            let response = try await AsyncTimeout.throwingValue(
                timeout,
                timeoutError: VoicePolishStageTimeoutError()
            ) {
                try await client.generate(request, config: config)
            }
            DebugFileLogger.log(
                "voice polish stage task=\(request.task.rawValue) elapsed_ms=\(milliseconds(ContinuousClock.now - startedAt)) outcome=success"
            )
            return response
        } catch {
            DebugFileLogger.log(
                "voice polish stage task=\(request.task.rawValue) elapsed_ms=\(milliseconds(ContinuousClock.now - startedAt)) outcome=failure"
            )
            throw error
        }
    }

    /// 在事实校验前执行可逆、确定性的纯版式整理。只有成稿自身已经存在明确的
    /// 句界、分号边界或连续列表边界时才补换行；代码场景不按分号拆分，避免破坏
    /// 语法。用户明确要求中文编号时保留中文样式。
    private func normalizedLayoutText(
        _ text: String,
        request: VoicePolishRequest
    ) -> String {
        let expectation = VoicePolishLayoutExpectation.infer(from: request)
        if request.context.scene == .code {
            return text
        }
        let punctuationRepaired = VoicePolishPunctuationRepair.normalize(text)
        let formatted = VoicePolishFallbackFormatter.formatCandidate(
            punctuationRepaired,
            expectation: expectation
        )
        let candidate: String
        if expectation.numberingPreference == .chinese {
            candidate = formatted
        } else {
            candidate = VoicePolishNumbering.normalizeExistingList(
                in: formatted,
                as: expectation.kind
            )
        }
        // 编号归一也属于本地改写，必须与 Formatter 一起包在最终安全门内。
        // 无法证明只改变空白和完整列表标记时，保留模型原成稿并交给 Validator。
        guard VoicePolishFallbackFormatter.isStrictlySafeTransformation(
            source: punctuationRepaired,
            candidate: candidate,
            expectation: expectation
        ) else {
            return punctuationRepaired
        }
        // 总数同步是独立于通用纯版式门禁的窄规则：仅当本地能证明
        // “原 N 项 + 明确新增 1 项 = 连续 N+1 项”时，定点修正唯一声明数字。
        return VoicePolishListCountConsistency
            .synchronizeDeclaredCountForProvenTrailingAddition(
                in: candidate,
                canonicalSource: request.fallbackText
            )
    }

    private func normalizedStructuredResponse(
        _ response: StructuredVoicePolishResponse,
        request: VoicePolishRequest
    ) -> StructuredVoicePolishResponse {
        StructuredVoicePolishResponse(
            plan: normalizedPlanLayout(response.plan, request: request),
            finalText: normalizedLayoutText(response.finalText, request: request)
        )
    }

    /// output_format 是本地版式契约的镜像，不属于模型需要自主判断的事实。
    /// 统一覆盖它可以避免 Analyzer/Structured 仅因自报格式错误浪费一次请求；
    /// 最终正文仍由独立 Validator 按真实换行与列表项逐项验收。
    private func normalizedPlanLayout(
        _ plan: VoicePolishPlan,
        request: VoicePolishRequest
    ) -> VoicePolishPlan {
        let expectation = VoicePolishLayoutExpectation.infer(from: request)
        let expectedListCount: Int?
        switch expectation.kind {
        case .numberedList, .bulletList:
            if let exact = expectation.expectedListItemCount {
                expectedListCount = exact
            } else {
                // minimum-only 契约不能把模型猜测的数量升级成硬约束，否则
                // Structured/Deep 会比 Fast 多出无依据的精确项数要求。
                expectedListCount = nil
            }
        case .sentence, .paragraphs:
            expectedListCount = nil
        }

        return VoicePolishPlan(
            version: plan.version,
            language: plan.language,
            scene: plan.scene,
            finalIntent: plan.finalIntent,
            orderedBlocks: plan.orderedBlocks,
            discardedFragments: plan.discardedFragments,
            corrections: plan.corrections,
            sideNotes: plan.sideNotes,
            facts: plan.facts,
            uncertainEntities: plan.uncertainEntities,
            outputFormat: VoiceOutputFormat(
                kind: expectation.kind,
                expectedListCount: expectedListCount
            ),
            confidence: plan.confidence
        )
    }

    private func stage(for task: LLMTask) -> VoicePolishStage {
        switch task {
        case .voicePolishAnalyze:
            return .analyzing
        case .voicePolishRender:
            return .rendering
        case .voicePolishRepair:
            return .repairing
        case .voicePolishFast, .voicePolishStructured:
            return .polishing
        default:
            return .polishing
        }
    }

    private func milliseconds(_ duration: Duration) -> Int64 {
        duration.components.seconds * 1_000
            + Int64(duration.components.attoseconds / 1_000_000_000_000_000)
    }

    private func effectiveFirstRequestTimeout(for request: VoicePolishRequest) -> Duration {
        usesAdaptiveFirstRequestTimeout
            ? Self.defaultFirstRequestTimeout(for: request)
            : firstRequestTimeout
    }

    private func effectiveTotalTimeout(for request: VoicePolishRequest) -> Duration {
        usesAdaptiveTotalTimeout
            ? Self.defaultTotalTimeout(for: request)
            : totalTimeout
    }

    private func effectiveAnalyzeTimeout(for request: VoicePolishRequest) -> Duration {
        usesAdaptiveAnalyzeTimeout ? Self.defaultAnalyzeTimeout(for: request) : analyzeTimeout
    }

    private func effectiveRenderTimeout(for request: VoicePolishRequest) -> Duration {
        usesAdaptiveRenderTimeout ? Self.defaultRenderTimeout(for: request) : renderTimeout
    }

    private func effectiveRepairTimeout(for request: VoicePolishRequest) -> Duration {
        usesAdaptiveRepairTimeout ? Self.defaultRepairTimeout(for: request) : repairTimeout
    }

    private func availableTimeout(
        stageLimit: Duration,
        startedAt: ContinuousClock.Instant,
        request: VoicePolishRequest
    ) throws -> Duration {
        let elapsed = ContinuousClock.now - startedAt
        let remaining = effectiveTotalTimeout(for: request) - elapsed
        guard remaining >= .seconds(2) else {
            throw VoicePolishStageTimeoutError()
        }
        return min(stageLimit, remaining)
    }

    private func validationCode(for error: Error) -> VoicePolishValidationCode {
        if let decoderError = error as? StructuredLLMDecoderError {
            switch decoderError {
            case .ambiguousJSONObjects:
                return .ambiguousStructuredResponse
            case .responseTooLarge:
                return .abnormalLength
            case .noJSONObject, .invalidJSON:
                return .invalidStructuredResponse
            }
        }
        return .invalidStructuredResponse
    }

    private func failureReason(for error: Error) -> VoicePolishFailureReason {
        if error is VoicePolishStageTimeoutError || error is CancellationError {
            return .timeout
        }
        if error is StructuredLLMDecoderError {
            return .validationFailed
        }
        return .requestFailed
    }

    private func isSizeRelatedGenerationFailure(_ error: Error) -> Bool {
        guard let llmError = error as? LLMError else { return false }
        switch llmError {
        case .truncatedResponse, .responseTooLarge:
            return true
        default:
            return false
        }
    }

    private func success(
        text: String,
        detectedRoute: VoicePolishRoute,
        executedRoute: VoicePolishRoute,
        attempts: Int,
        codes: [VoicePolishValidationCode]
    ) -> VoicePolishResult {
        DebugFileLogger.log(
            "voice polish done route=\(detectedRoute.rawValue) executed=\(executedRoute.rawValue) attempts=\(attempts) output=\(text.count)chars codes=\(codes.map(\.rawValue).joined(separator: ",")) fallback=false"
        )
        return VoicePolishResult(
            text: text,
            detectedRoute: detectedRoute,
            executedRoute: executedRoute,
            llmAttemptCount: attempts,
            validationCodes: codes,
            usedFallback: false,
            failureReason: nil
        )
    }

    private func fallback(
        request: VoicePolishRequest,
        detectedRoute: VoicePolishRoute,
        executedRoute: VoicePolishRoute,
        attempts: Int,
        codes: [VoicePolishValidationCode],
        reason: VoicePolishFailureReason = .validationFailed,
        rejectedDraft: String? = nil
    ) -> VoicePolishResult {
        // 回退仍以 canonical transcript 为唯一内容来源；先只移除可证明错误的
        // ASR 标点/空白，再在字符与顺序不变的前提下补段落或列表结构，避免
        // 校验失败后重新退回错误断句或一坨文字。
        let expectation = VoicePolishLayoutExpectation.infer(from: request)
        let fallbackText: String
        if request.context.scene == .code {
            fallbackText = request.fallbackText
        } else {
            let punctuationRepaired = VoicePolishPunctuationRepair.normalize(
                request.fallbackText
            )
            let fallbackCandidate = VoicePolishFallbackFormatter.formatCandidate(
                punctuationRepaired,
                expectation: expectation
            )
            if VoicePolishFallbackFormatter.isStrictlySafeTransformation(
                source: punctuationRepaired,
                candidate: fallbackCandidate,
                expectation: expectation
            ) {
                fallbackText = VoicePolishListCountConsistency
                    .synchronizeDeclaredCountForProvenTrailingAddition(
                        in: fallbackCandidate,
                        canonicalSource: request.fallbackText
                    )
            } else {
                fallbackText = punctuationRepaired
            }
        }
        DebugFileLogger.log(
            "voice polish done route=\(detectedRoute.rawValue) executed=\(executedRoute.rawValue) attempts=\(attempts) output=\(fallbackText.count)chars codes=\(codes.map(\.rawValue).joined(separator: ",")) fallback=true"
        )
        return VoicePolishResult(
            text: fallbackText,
            detectedRoute: detectedRoute,
            executedRoute: executedRoute,
            llmAttemptCount: attempts,
            validationCodes: codes,
            usedFallback: true,
            failureReason: reason,
            rejectedDraft: rejectedDraft
        )
    }
}
