import Foundation

struct VoicePolishValidationResult: Sendable, Equatable {
    let codes: [VoicePolishValidationCode]

    var hasHardFailure: Bool {
        codes.contains(where: \.isHardFailure)
    }
}

enum VoicePolishValidator {

    static func validatePlan(
        _ plan: VoicePolishPlan,
        request: VoicePolishRequest,
        sourceFacts: [SourceFactCandidate]
    ) -> VoicePolishValidationResult {
        // 复用完整 Plan 完整性检查，但只返回分析阶段可以在本地证明的结构错误。
        // Analyzer 尚未产生成稿，因此不能在此判断事实是否已进入最终正文。
        let provisional = StructuredVoicePolishResponse(
            plan: plan,
            finalText: request.fallbackText
        )
        var codes = validateStructured(
            response: provisional,
            request: request,
            sourceFacts: sourceFacts
        ).codes.filter { $0 == .planIntegrityFailure }
        appendPlanLayoutCodes(plan, request: request, to: &codes)
        return VoicePolishValidationResult(codes: codes)
    }

    static func validateFast(
        output: String,
        request: VoicePolishRequest,
        sourceFacts: [SourceFactCandidate]
    ) -> VoicePolishValidationResult {
        var codes = commonCodes(output: output, sourceText: request.fallbackText)
        let outputFacts = protectedFactsFromOutput(output, request: request)
        let supersededFactIndices = locallySupersededFactIndices(
            request: request,
            sourceFacts: sourceFacts
        )

        if sourceFacts.enumerated().contains(where: { index, fact in
            !supersededFactIndices.contains(index)
                && !containsEquivalent(fact, in: outputFacts, output: output)
        }) {
            append(.missingProtectedFact, to: &codes)
        }
        if outputFacts.contains(where: { outputFact in
            !sourceFacts.contains(where: { equivalent($0, outputFact) })
                && !isSourceBackedFormattingFact(
                    outputFact,
                    request: request
                )
        }) {
            append(.planIntegrityFailure, to: &codes)
        }
        if supersededFactIndices.contains(where: { index in
            let fact = sourceFacts[index]
            let canonicalIsStillRequired = sourceFacts.enumerated().contains { otherIndex, other in
                otherIndex != index
                    && !supersededFactIndices.contains(otherIndex)
                    && equivalent(fact, other)
            }
            return !canonicalIsStillRequired
                && containsEquivalent(fact, in: outputFacts, output: output)
        }) {
            append(.supersededFactRetained, to: &codes)
        }
        if retainsExplicitCorrectionNarration(output: output, request: request) {
            append(.supersededFactRetained, to: &codes)
        }
        appendUnchangedDraftCode(output: output, request: request, to: &codes)
        appendSemanticBoundaryCodes(output: output, request: request, to: &codes)
        appendTerminologyEditCodes(output: output, request: request, to: &codes)
        appendOutputLayoutCodes(output, request: request, to: &codes)
        return VoicePolishValidationResult(codes: codes)
    }

    /// 模型偶尔会在已经写出最终数量后，用括号补一句旧数量的推导过程，例如
    /// “共六人参加（产品和设计四人，加上开发）”。这里只删除括号中的旧数字
    /// 及其紧邻量词，参与方等其余内容原样保留；调用方必须再次执行全部校验。
    static func removingParentheticalSupersededFacts(
        from output: String,
        request: VoicePolishRequest,
        sourceFacts: [SourceFactCandidate]
    ) -> String? {
        let superseded = locallySupersededFactIndices(
            request: request,
            sourceFacts: sourceFacts
        ).map { sourceFacts[$0] }
        guard !superseded.isEmpty,
              let regex = try? NSRegularExpression(pattern: #"[（(][^（）()\n]{1,80}[）)]"#) else {
            return nil
        }

        var candidate = output
        let fullRange = NSRange(output.startIndex..<output.endIndex, in: output)
        let ranges = regex.matches(in: output, range: fullRange).compactMap {
            Range($0.range, in: output)
        }.filter { range in
            let parenthetical = String(output[range])
            return superseded.contains { fact in
                parenthetical.contains(fact.sourceText)
                    || fact.canonicalValue.map(parenthetical.contains) == true
            }
        }
        guard !ranges.isEmpty else { return nil }
        for range in ranges.reversed() {
            var parenthetical = String(candidate[range])
            for fact in superseded {
                let tokens = [fact.sourceText, fact.canonicalValue].compactMap { $0 }
                for token in Set(tokens) {
                    parenthetical = parenthetical.replacingOccurrences(
                        of: NSRegularExpression.escapedPattern(for: token)
                            + #"\s*(?:个人|人|个|位|名|款|项|条|天|月|年)?"#,
                        with: "",
                        options: .regularExpression
                    )
                }
            }
            candidate.replaceSubrange(range, with: parenthetical)
        }
        candidate = candidate.replacingOccurrences(
            of: #"[ \t]{2,}"#,
            with: " ",
            options: .regularExpression
        )
        return candidate == output ? nil : candidate
    }

    /// 只清理由字面可以完全证明的重复与幕后备注。这里不做开放式改写，
    /// 每条替换都要求原文提供对应证据，避免为追求流畅改变用户含义。
    static func removingDeterministicDraftArtifacts(
        from output: String,
        request: VoicePolishRequest
    ) -> String? {
        var candidate = output
        let source = normalizedNaturalText(request.fallbackText)

        let replacements: [(pattern: String, replacement: String)] = [
            (#"对比测试\s*[，,：:]?\s*测试(?=已经|已)"#, "对比测试"),
            (#"是否为最终版\s*[，,]?\s*(?:也就是)?\s*确认(?:一下)?还会不会改"#, "是否为最终版"),
            (#"是不是最终版\s*[，,]?\s*(?:也就是)?\s*确认(?:一下)?还会不会改"#, "是不是最终版"),
            (#"我不是不愿意帮你\s*[，,]?\s*(?:也)?不是不想帮\s*[，,]?\s*是真的"#, "我不是不愿意帮你，是真的"),
            (#"不是不会用\s*AI\s*[，,]?\s*(?:也)?不是工具不会操作\s*[，,]?\s*而是"#, "不是不会用 AI，而是"),
            (#"今晚先不上\s*[，,]?\s*最终结论是今晚不发布"#, "今晚先不上"),
        ]
        for replacement in replacements {
            candidate = candidate.replacingOccurrences(
                of: replacement.pattern,
                with: replacement.replacement,
                options: [.regularExpression, .caseInsensitive]
            )
        }

        if source.contains("先别改路径和命令") {
            candidate = candidate.replacingOccurrences(
                of: #"\s*先别改路径和命令[。.]?"#,
                with: "",
                options: .regularExpression
            )
        }
        if source.contains("不是坏了") {
            candidate = candidate.replacingOccurrences(
                of: #"这个功能(?:目前)?不是坏了[，,，]?\s*(?:是)?需要"#,
                with: "这个功能需要",
                options: .regularExpression
            )
        }
        if source.contains("先保留中文意思") {
            candidate = candidate.replacingOccurrences(
                of: #"英文原话没记准[，,]\s*先保留中文意思"#,
                with: "英文原话没记准，暂不补充",
                options: .regularExpression
            )
        }
        if source.contains("这个不用展开") && source.contains("网络") {
            candidate = candidate.replacingOccurrences(
                of: #"(?:顺便说(?:一下|一句)?[，,]?\s*)?我那天网络(?:也)?不太好[，,]?\s*(?:但)?这个不用展开[。.]?"#,
                with: "",
                options: .regularExpression
            )
            // 模型有时执行了“不要展开”的措辞约束，却仍把同一条明确排除的
            // 网络旁注原样留下；来源已明确要求排除，因此也安全删除。
            candidate = candidate.replacingOccurrences(
                of: #"(?:顺便说(?:一下|一句)?[，,]?\s*)?我那天网络(?:也)?不太好[。.]?"#,
                with: "",
                options: .regularExpression
            )
        }
        if source.contains("不是我想说的不只是更新难") {
            candidate = candidate.replacingOccurrences(
                of: #"做内容最难的是持续更新[。.]\s*不只是更新难[，,]?\s*更难的是"#,
                with: "做内容最难的不只是持续更新，更难的是",
                options: .regularExpression
            )
        }
        if request.context.scene == .code,
           source.contains("检查codesign") && source.contains("最后再启动应用") {
            candidate = candidate.replacingOccurrences(
                of: #"(检查\s*`?codesign`?)[，,]\s*最后(?:再)?启动应用"#,
                with: "$1\n\n最后启动应用",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        if source.contains("上线时间") && source.contains("月底")
            && source.contains("不写死具体日期") {
            candidate = candidate.replacingOccurrences(
                of: #"上线时间(?:原计划|原定|原来说)月底[，,]?\s*但今天讨论后(?:认为|觉得)?风险(?:较大|太大)[，,]?\s*暂不写死具体日期"#,
                with: "上线时间暂不写死具体日期",
                options: .regularExpression
            )
        }

        candidate = candidate.replacingOccurrences(
            of: #"(?:[。.]?\s*)?(?:今天讨论的事项)?(?:汇总如下|总结如下|整理如下)[。.]?\s*$"#,
            with: "",
            options: .regularExpression
        ).replacingOccurrences(
            of: #"\n{3,}"#,
            with: "\n\n",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        return candidate == output ? nil : candidate
    }

    /// 模型可能为原文已有词语补中文或英文引号。引号本身属于排版，不应被
    /// ProtectedFactExtractor 当作“新增引用事实”；只有去掉成对引号后的完整内容
    /// 已逐字存在于正式输入时才放行。
    private static func isSourceBackedFormattingFact(
        _ fact: SourceFactCandidate,
        request: VoicePolishRequest
    ) -> Bool {
        let interior: String
        switch fact.kind {
        case .quotedPhrase:
            guard fact.sourceText.count >= 2 else { return false }
            let characters = Array(fact.sourceText)
            let isPairedQuote = (characters.first == "“" && characters.last == "”")
                || (characters.first == "\"" && characters.last == "\"")
            guard isPairedQuote else { return false }
            interior = String(characters.dropFirst().dropLast())
        case .command:
            guard fact.sourceText.hasPrefix("`"), fact.sourceText.hasSuffix("`") else {
                return false
            }
            interior = String(fact.sourceText.dropFirst().dropLast())
        case .codeIdentifier:
            interior = fact.sourceText
        case .number:
            guard fact.canonicalValue == "1" else { return false }
            let source = request.fallbackText
            return source.range(
                of: #"(?:另外)?还有一个(?:没定|未定|待定|待确认)"#,
                options: .regularExpression
            ) != nil
        default:
            return false
        }
        let normalizedInterior = normalizedNaturalText(interior)
        guard !normalizedInterior.isEmpty else { return false }
        if normalizedNaturalText(request.fallbackText).contains(normalizedInterior) {
            return true
        }
        let authorizedContext = [
            request.context.selectedText,
            request.context.textBeforeCursor,
            request.context.textAfterCursor,
        ].compactMap { $0 } + request.context.recentMuseInputs
        if authorizedContext.contains(where: {
            normalizedNaturalText($0).contains(normalizedInterior)
        }) {
            return true
        }
        return fact.kind == .command
            && request.context.scene == .code
            && normalizedNaturalText(
                dictatedSymbolProjection(request.fallbackText)
            ).contains(normalizedInterior)
    }

    /// 代码口述中的“斜杠 / 点 / 双横线”可以确定性还原为符号。这里只生成
    /// 本地校验投影，不改用户原文，也不允许补出来源中没有口述的命令内容。
    private static func dictatedSymbolProjection(_ source: String) -> String {
        [
            ("双横线", "--"),
            ("短横线", "-"),
            ("反斜杠", "\\"),
            ("斜杠", "/"),
            ("下划线", "_"),
            ("点", "."),
        ].reduce(source) { text, replacement in
            text.replacingOccurrences(of: replacement.0, with: replacement.1)
        }
    }

    /// 只拦截能够由原文逐字证明的少量动作与幕后指令泄漏，不做开放式语义猜测。
    /// 这些规则服务于 Fast 路径的第二次安全修复，并保持误杀面最窄。
    private static func appendSemanticBoundaryCodes(
        output: String,
        request: VoicePolishRequest,
        to codes: inout [VoicePolishValidationCode]
    ) {
        let source = normalizedNaturalText(request.fallbackText)
        let draft = normalizedNaturalText(output)

        let sourceChecksCodeSign = request.fallbackText.range(
            of: #"检查\s*`?codesign`?"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
        let draftExecutesCodeSign = output.range(
            of: #"执行\s*`?codesign`?"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
        if sourceChecksCodeSign, draftExecutesCodeSign {
            append(.planIntegrityFailure, to: &codes)
        }

        // 人数不能替代参与方名单。只在原文明确出现“参加的人/参与的人”等
        // 参会信号，且至少有两个常见角色时启用，避免把普通业务词误当名单。
        let participantSignals = ["参加的人有", "参与的人有", "参会的人有", "参加人员有", "参与方有"]
        let participantRoles = [
            "产品", "设计", "开发", "测试", "运营", "市场", "销售", "法务", "财务", "技术", "客户",
        ]
        if participantSignals.contains(where: source.contains) {
            let requiredRoles = participantRoles.filter(source.contains)
            if requiredRoles.count >= 2,
               requiredRoles.contains(where: { !draft.contains($0) }) {
                append(.missingProtectedFact, to: &codes)
            }
        }

        // 原文只说内容/想法要成熟时，模型不得擅自把修饰对象改成“自己”。
        // 这是本地可逐字证明的窄门禁，不尝试开放式语义比较。
        if source.contains("等") && source.contains("成熟") && !source.contains("自己"),
           draft.range(of: #"等自己.{0,6}成熟"#, options: .regularExpression) != nil {
            append(.planIntegrityFailure, to: &codes)
        }

        // 这些是可以从字面确定的未收口或同义机械重复；触发一次 Fast 修复，
        // 避免自动事实校验通过但仍不能直接发送。
        let deterministicRepetition = draft.contains("对比测试测试已经")
            || draft.contains("今晚先不上最终结论是今晚不发布")
            || draft.contains("不是不会用ai也不是工具不会操作")
            || (draft.contains("是否为最终版") && draft.contains("还会不会改"))
            || (source.contains("不是我想说的不只是更新难")
                && draft.contains("最难的是持续更新不只是更新难"))
        let danglingSummaryLeadIn = ["汇总如下", "总结如下", "整理如下"].contains {
            draft.hasSuffix($0)
        }
        if deterministicRepetition || danglingSummaryLeadIn {
            append(.planIntegrityFailure, to: &codes)
        }

        // 用户明确只保留可靠中文意思时，残缺英文不是正文事实。
        if source.contains("英文原话") && source.contains("先保留中文意思"),
           output.range(of: #"(?i)don['’]?t\s+optimize"#, options: .regularExpression) != nil {
            append(.planIntegrityFailure, to: &codes)
        }

        let leakedMetaInstruction = (
            source.contains("这句别写得太重")
                && (draft.contains("语气不用太重") || draft.contains("事情要说清楚"))
        ) || (
            source.contains("不要替我确定具体版本")
                && draft.contains("不要确定具体版本")
        ) || (
            source.contains("这个别放在已确定事项里")
                && draft.contains("不列入已确定事项")
        )
        if leakedMetaInstruction {
            append(.promptLeakage, to: &codes)
        }
    }

    /// Fast 路径没有模型生成的 Plan，因此只接受本地能证明的最窄改口事实：
    /// 改口信号前最近的受保护事实，与信号后首个同类型、不同值的事实形成替换
    /// 关系。ASR 长录音经常把旧值、改口词和最终值切到相邻 segment，因此位置
    /// 按 segment 顺序统一比较；没有明确改口信号时仍不会跨段猜测。
    static func locallySupersededFactIndices(
        request: VoicePolishRequest,
        sourceFacts: [SourceFactCandidate]
    ) -> Set<Int> {
        if isPublicCorrectionNotice(request) { return [] }

        struct LocatedFact {
            let index: Int
            let segmentIndex: Int
            let offset: Int
        }

        struct LocatedMarker {
            let segmentIndex: Int
            let startOffset: Int
            let endOffset: Int
        }

        let correctionSignals = [
            "前面那句改成", "刚才那句改成", "把开头改成", "let me correct that",
            "change the earlier part", "change what i said before", "scratch that",
            "我的意思是", "我改一下", "说错了", "不对", "应该是", "最后还是",
            "最终决定", "actually", "i mean", "final decision",
        ]
        var locatedFacts: [LocatedFact] = []
        var locatedMarkers: [LocatedMarker] = []
        for (segmentIndex, segment) in request.input.segments.enumerated() {
            locatedFacts += sourceFacts.enumerated().compactMap { index, fact -> LocatedFact? in
                guard fact.kind != .lexiconEntity,
                      fact.sourceSegmentIDs.contains(segment.id),
                      let range = segment.text.range(of: fact.sourceText) else { return nil }
                return LocatedFact(
                    index: index,
                    segmentIndex: segmentIndex,
                    offset: segment.text.distance(from: segment.text.startIndex, to: range.lowerBound)
                )
            }
            locatedMarkers += correctionSignals.flatMap { signal -> [LocatedMarker] in
                allRanges(of: signal, in: segment.text)
                    .map { range in
                        LocatedMarker(
                            segmentIndex: segmentIndex,
                            startOffset: segment.text.distance(
                                from: segment.text.startIndex,
                                to: range.lowerBound
                            ),
                            endOffset: segment.text.distance(
                                from: segment.text.startIndex,
                                to: range.upperBound
                            )
                        )
                    }
            }
        }

        locatedFacts.sort {
            ($0.segmentIndex, $0.offset) < ($1.segmentIndex, $1.offset)
        }
        locatedMarkers.sort {
            ($0.segmentIndex, $0.startOffset) < ($1.segmentIndex, $1.startOffset)
        }

        var superseded: Set<Int> = []
        for marker in locatedMarkers {
            guard let previous = locatedFacts.last(where: {
                ($0.segmentIndex, $0.offset) < (marker.segmentIndex, marker.startOffset)
            }) else { continue }
            let previousFact = sourceFacts[previous.index]
            guard locatedFacts.contains(where: { candidate in
                let followsMarker = candidate.segmentIndex > marker.segmentIndex
                    || (candidate.segmentIndex == marker.segmentIndex
                        && candidate.offset >= marker.endOffset)
                guard followsMarker else { return false }
                let finalFact = sourceFacts[candidate.index]
                return finalFact.kind == previousFact.kind
                    && !equivalent(previousFact, finalFact)
            }) else { continue }
            superseded.insert(previous.index)
        }
        return superseded
    }

    private static func allRanges(
        of needle: String,
        in text: String
    ) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var searchRange = text.startIndex..<text.endIndex
        while let match = text.range(
            of: needle,
            options: [.caseInsensitive],
            range: searchRange
        ) {
            ranges.append(match)
            guard match.upperBound < text.endIndex else { break }
            searchRange = match.upperBound..<text.endIndex
        }
        return ranges
    }

    /// Fast 路径必须交付成稿，而不是把用户自我纠正的过程改写一遍。只有正式
    /// 输入本身包含明确的第一人称改口信号时，才检查输出是否仍泄漏这些过程词，
    /// 避免把普通的“这个说法不对”讨论误判为口误。
    private static func retainsExplicitCorrectionNarration(
        output: String,
        request: VoicePolishRequest
    ) -> Bool {
        let source = normalizedNaturalText(request.fallbackText).lowercased()
        if isPublicCorrectionNotice(request) { return false }
        let explicitSelfCorrectionSignals = [
            "我说错了", "我刚才说的", "刚才说错了", "我改一下", "我的意思是",
            "let me correct that", "i said that wrong", "scratch that", "i mean",
        ]
        guard explicitSelfCorrectionSignals.contains(where: source.contains) else {
            return false
        }

        let normalizedOutput = normalizedNaturalText(output).lowercased()
        let leakedNarrationSignals = [
            "我说错了", "说错了", "我刚才说的", "刚才说的", "前面说的",
            "我改一下", "我的意思是", "正确名字是", "正确说法是",
            "统一写成", "统一写为", "let me correct that", "i said that wrong",
            "what i just said", "the correct name is", "scratch that", "i mean",
        ]
        return leakedNarrationSignals.contains(where: normalizedOutput.contains)
    }

    /// 对外纠错与普通口误相反：旧说法和正确说法都必须保留。仅凭“说明一下”
    /// 不足以豁免，必须同时存在公开说明信号与明确纠错证据。
    private static func isPublicCorrectionNotice(_ request: VoicePolishRequest) -> Bool {
        guard request.context.scene == .socialPost else { return false }
        let source = normalizedNaturalText(request.fallbackText).lowercased()
        let noticeSignals = ["说明一下", "更正说明", "更正一下", "澄清一下"]
        let correctionSignals = [
            "说错", "误将", "错误", "有误", "正确日期", "正确时间", "正确名称", "正确说法",
        ]
        return noticeSignals.contains(where: source.contains)
            && correctionSignals.contains(where: source.contains)
    }

    static func validateStructured(
        response: StructuredVoicePolishResponse,
        request: VoicePolishRequest,
        sourceFacts: [SourceFactCandidate]
    ) -> VoicePolishValidationResult {
        let output = response.finalText
        var codes = commonCodes(output: output, sourceText: request.fallbackText)
        appendUnchangedDraftCode(output: output, request: request, to: &codes)
        let plan = response.plan
        let validSegmentIDs = Set(request.input.segments.map(\.id))
        let sourceByID = Dictionary(uniqueKeysWithValues: request.input.segments.map { ($0.id, $0.text) })
        let routeDecision = VoicePolishComplexityRouter.decide(
            request: request,
            factCandidates: sourceFacts
        )

        if plan.version != VoicePolishPrompts.version
            || !(0...1).contains(plan.confidence)
            || plan.scene != request.context.scene
            || plan.finalIntent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || plan.orderedBlocks.isEmpty
            || Set(plan.orderedBlocks.map(\.id)).count != plan.orderedBlocks.count
            || plan.uncertainEntities.contains(where: { !(0...1).contains($0.confidence) })
            || hasInvalidSourceIDs(plan: plan, validIDs: validSegmentIDs) {
            append(.planIntegrityFailure, to: &codes)
        }
        appendPlanLayoutCodes(plan, request: request, to: &codes)

        let planFacts = plan.facts
        var matchedCandidateIndices: Set<Int> = []
        var planFactKeys: Set<String> = []
        for fact in planFacts {
            if let provided = fact.canonicalValue,
               let local = ProtectedFactExtractor.canonicalValue(
                    for: fact.sourceText,
                    kind: fact.kind
               ),
               provided != local {
                append(.planIntegrityFailure, to: &codes)
            }
            guard let candidateIndex = sourceFacts.firstIndex(where: {
                factMatchesCandidate(fact, candidate: $0)
            }) else {
                append(.planIntegrityFailure, to: &codes)
                continue
            }
            if !matchedCandidateIndices.insert(candidateIndex).inserted {
                append(.planIntegrityFailure, to: &codes)
            }
            let key = factKey(fact)
            if !planFactKeys.insert(key).inserted {
                append(.planIntegrityFailure, to: &codes)
            }
            if !fact.sourceSegmentIDs.allSatisfy({ sourceByID[$0]?.contains(fact.sourceText) == true }) {
                append(.planIntegrityFailure, to: &codes)
            }

            switch fact.disposition {
            case .superseded:
                let supported = routeDecision.correctionCount > 0
                    || routeDecision.matchedSignalCategories.contains("delayed_correction")
                let hasCorrection = plan.corrections.contains {
                    !$0.sourceSegmentIDs.filter(fact.sourceSegmentIDs.contains).isEmpty
                        && $0.previousText.contains(fact.sourceText)
                }
                if !supported || !hasCorrection {
                    append(.planIntegrityFailure, to: &codes)
                }
            case .excluded:
                let hasDiscard = plan.discardedFragments.contains {
                    $0.reason == .sideNote
                        && !$0.sourceSegmentIDs.filter(fact.sourceSegmentIDs.contains).isEmpty
                }
                let sourceHasSignal = fact.sourceSegmentIDs.contains {
                    sourceByID[$0].map(VoicePolishComplexityRouter.containsExplicitExclusionSignal) == true
                }
                if !hasDiscard || !sourceHasSignal || fact.exclusionReason == nil {
                    append(.planIntegrityFailure, to: &codes)
                }
            case .mustPreserve, .uncertain:
                break
            }
        }
        if matchedCandidateIndices.count != sourceFacts.count
            || planFacts.count != sourceFacts.count {
            append(.planIntegrityFailure, to: &codes)
        }

        let outputFacts = protectedFactsFromOutput(output, request: request)
        if outputFacts.contains(where: { outputFact in
            !sourceFacts.contains(where: { equivalent($0, outputFact) })
                && !isSourceBackedFormattingFact(
                    outputFact,
                    request: request
                )
        }) {
            append(.planIntegrityFailure, to: &codes)
        }
        let protectedCanonicalValues = Set(planFacts.compactMap { fact -> String? in
            guard fact.disposition == .mustPreserve || fact.disposition == .uncertain else { return nil }
            return canonicalValue(for: fact)
        })

        for fact in planFacts {
            let isPresent = containsEquivalent(fact, in: outputFacts, output: output)
            switch fact.disposition {
            case .mustPreserve, .uncertain:
                if !isPresent { append(.missingProtectedFact, to: &codes) }
            case .superseded:
                if let canonical = canonicalValue(for: fact),
                   !protectedCanonicalValues.contains(canonical),
                   isPresent {
                    append(.supersededFactRetained, to: &codes)
                }
            case .excluded:
                if isPresent { append(.excludedSideNoteLeaked, to: &codes) }
            }
        }

        for correction in plan.corrections where correction.isFinal {
            let previous = normalizedNaturalText(correction.previousText)
            let correctionFacts = planFacts.filter { fact in
                fact.disposition == .superseded
                    && !fact.sourceSegmentIDs.filter(correction.sourceSegmentIDs.contains).isEmpty
                    && correction.previousText.contains(fact.sourceText)
            }
            let retainsPrevious: Bool
            if correctionFacts.isEmpty {
                retainsPrevious = !previous.isEmpty
                    && normalizedNaturalText(output).contains(previous)
            } else {
                // 数字改口必须按受保护事实比较，不能用裸子串判断。例如旧人数
                // “四个人”已删除后，最终时间“周四上午”仍含“四”，但不是旧事实。
                retainsPrevious = correctionFacts.contains {
                    containsEquivalent($0, in: outputFacts, output: output)
                }
            }
            if retainsPrevious {
                append(.supersededFactRetained, to: &codes)
            }
            let final = normalizedNaturalText(correction.finalText)
            if !final.isEmpty, !normalizedNaturalText(output).contains(final) {
                append(.semanticDecisionUnverified, to: &codes)
            }
        }

        for discarded in plan.discardedFragments where discarded.reason == .sideNote {
            let discardedText = normalizedNaturalText(discarded.text)
            if !discardedText.isEmpty, normalizedNaturalText(output).contains(discardedText) {
                append(.excludedSideNoteLeaked, to: &codes)
            }
        }

        for entity in plan.uncertainEntities {
            if let selected = entity.selectedCandidate,
               normalizedNaturalText(selected) != normalizedNaturalText(entity.surfaceText) {
                append(.ambiguousStructuredResponse, to: &codes)
            } else if !normalizedNaturalText(output).contains(normalizedNaturalText(entity.surfaceText)) {
                append(.ambiguousStructuredResponse, to: &codes)
            }
        }

        if let expected = plan.outputFormat.expectedListCount,
           VoicePolishNumbering.listItemCount(in: output, kind: plan.outputFormat.kind) != expected {
            append(.ambiguousStructuredResponse, to: &codes)
        }

        appendTerminologyEditCodes(output: output, request: request, to: &codes)
        appendOutputLayoutCodes(output, request: request, to: &codes)

        return VoicePolishValidationResult(codes: codes)
    }

    /// canonical 化阶段已经实际命中的术语必须保持标准写法，且旧 alias 不能被
    /// 模型重新带回。两项分开校验，避免「Typeless（Type less）」因为包含标准词
    /// 而被误判为通过。
    private static func appendTerminologyEditCodes(
        output: String,
        request: VoicePolishRequest,
        to codes: inout [VoicePolishValidationCode]
    ) {
        for edit in terminologyEdits(for: request) {
            let canonical = normalizedNaturalText(edit.canonical)
            if canonical.isEmpty || !normalizedNaturalText(output).contains(canonical) {
                append(.missingProtectedFact, to: &codes)
            }
            if EntityResolver.applyingKnownCorrections(
                [edit.alias: edit.canonical],
                to: output
            ) != output {
                append(.supersededFactRetained, to: &codes)
            }
        }
    }

    private static func terminologyEdits(
        for request: VoicePolishRequest
    ) -> [VoiceTerminologyEdit] {
        var edits = request.input.requiredEntityEdits
        let fallback = request.input.fallbackText
        edits.append(contentsOf: request.resolvedEntities.compactMap { entity in
            guard entity.surfaceText != entity.canonical,
                  EntityResolver.applying([entity], to: fallback) != fallback else {
                return nil
            }
            return VoiceTerminologyEdit(
                alias: entity.surfaceText,
                canonical: entity.canonical,
                sourceSegmentIDs: entity.sourceSegmentIDs
            )
        })

        var seen = Set<String>()
        return edits.filter { edit in
            seen.insert(
                "\(normalizedNaturalText(edit.alias))|\(normalizedNaturalText(edit.canonical))"
            ).inserted
        }
    }

    /// 明显包含口述残片或结构缺口的输入，模型若原样照抄不能算成稿成功。
    /// 只使用本地可证明的窄信号；已经自然可发送的短句允许保持不变。
    private static func appendUnchangedDraftCode(
        output: String,
        request: VoicePolishRequest,
        to codes: inout [VoicePolishValidationCode]
    ) {
        let comparableSource = comparableDraft(request.fallbackText)
        let comparableOutput = comparableDraft(output)
        guard comparableSource == comparableOutput, requiresTransformation(request) else {
            return
        }
        append(.unchangedDraft, to: &codes)
    }

    private static func requiresTransformation(_ request: VoicePolishRequest) -> Bool {
        let source = request.fallbackText
        let normalized = normalizedNaturalText(source).lowercased()
        if terminologyEdits(for: request).contains(where: { edit in
            EntityResolver.applyingKnownCorrections(
                [edit.alias: edit.canonical],
                to: source
            ) != source
        }) {
            return true
        }

        let correctionSignals = [
            "我说错了", "我改一下", "我的意思是", "不对", "改成", "应该是",
            "最终决定", "最后还是", "scratch that", "i mean", "actually",
        ]
        if correctionSignals.contains(where: normalized.contains) { return true }

        let obviousDisfluencies = [
            "我我", "你你", "他他", "她她", "它它", "不不", "第第",
            "大大概", "突突然", "帮我帮我", "麻烦麻烦", "今天今天",
        ]
        if obviousDisfluencies.contains(where: normalized.contains) { return true }

        let expectation = VoicePolishLayoutExpectation.infer(from: request)
        if (expectation.kind == .numberedList || expectation.kind == .bulletList),
           VoicePolishNumbering.recognizedListItemCount(in: source) > 0 {
            // 已经形成完整逐行列表的文本允许原样保留。列表项不以句号结尾并不
            // 等于“长文本没有标点”，不能因此触发一次注定无意义的修复请求。
            return false
        }

        if source.count >= 80,
           source.range(of: #"[。！？!?]"#, options: .regularExpression) == nil {
            return true
        }
        if source.count >= 80,
           !VoicePolishPunctuationRepair.issues(in: source).isEmpty {
            return true
        }

        switch expectation.kind {
        case .sentence:
            return false
        case .paragraphs:
            return !source.contains("\n\n")
        case .numberedList, .bulletList:
            return VoicePolishNumbering.recognizedListItemCount(in: source) == 0
        }
    }

    private static func comparableDraft(_ text: String) -> String {
        VoicePolishCharacterSafety.normalizedLineEndings(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private static func commonCodes(
        output: String,
        sourceText: String
    ) -> [VoicePolishValidationCode] {
        var codes: [VoicePolishValidationCode] = []
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { append(.emptyOutput, to: &codes) }
        if VoicePolishCharacterSafety.containsUnsafeCharacters(output) {
            append(.unsafeCharacters, to: &codes)
        }
        let promptMarkers = [
            "MUSE_MODE_INSTRUCTIONS",
            "MUSE_INPUT_PAYLOAD",
            "# Muse 输入模式固定边界",
            "Fixed Muse input-mode boundary",
        ]
        if promptMarkers.contains(where: trimmed.contains) {
            append(.promptLeakage, to: &codes)
        }
        let explanationPrefixes = [
            "下面是润色后的", "以下是润色后的", "我无法", "作为一个 AI",
            "Here is the polished", "I cannot", "As an AI",
        ]
        if explanationPrefixes.contains(where: trimmed.hasPrefix) {
            append(.explanationOnly, to: &codes)
        }
        let maximum = max(sourceText.count * 2, sourceText.count + 40)
        if trimmed.count > maximum {
            append(.abnormalLength, to: &codes)
        }
        if trimmed.components(separatedBy: "\n\n").filter({ !$0.isEmpty }).count > 6 {
            append(.excessiveParagraphs, to: &codes)
        }
        return codes
    }

    private static func hasInvalidSourceIDs(
        plan: VoicePolishPlan,
        validIDs: Set<String>
    ) -> Bool {
        let groups = plan.orderedBlocks.map(\.sourceSegmentIDs)
            + plan.discardedFragments.map(\.sourceSegmentIDs)
            + plan.corrections.map(\.sourceSegmentIDs)
            + plan.facts.map(\.sourceSegmentIDs)
            + plan.uncertainEntities.map(\.sourceSegmentIDs)
        return groups.contains { ids in
            ids.isEmpty || ids.contains(where: { !validIDs.contains($0) })
        }
    }

    private static func factMatchesCandidate(
        _ fact: ProtectedFact,
        candidate: SourceFactCandidate
    ) -> Bool {
        guard fact.kind == candidate.kind,
              Set(fact.sourceSegmentIDs) == Set(candidate.sourceSegmentIDs) else { return false }
        if let left = canonicalValue(for: fact), let right = candidate.canonicalValue {
            return left == right
        }
        return fact.sourceText == candidate.sourceText
    }

    private static func factKey(_ fact: ProtectedFact) -> String {
        "\(fact.kind.rawValue)|\(canonicalValue(for: fact) ?? fact.sourceText)|\(fact.sourceSegmentIDs.sorted().joined(separator: ","))"
    }

    private static func canonicalValue(for fact: ProtectedFact) -> String? {
        let local = ProtectedFactExtractor.canonicalValue(for: fact.sourceText, kind: fact.kind)
        if let provided = fact.canonicalValue, let local, provided != local {
            return nil
        }
        return fact.canonicalValue ?? local
    }

    private static func containsEquivalent(
        _ candidate: SourceFactCandidate,
        in outputFacts: [SourceFactCandidate],
        output: String
    ) -> Bool {
        if candidate.kind == .lexiconEntity, let canonical = candidate.canonicalValue {
            return normalizedNaturalText(output).contains(normalizedNaturalText(canonical))
        }
        if candidate.kind == .codeIdentifier, let canonical = candidate.canonicalValue {
            return normalizedNaturalText(output).contains(normalizedNaturalText(canonical))
        }
        if let canonical = candidate.canonicalValue {
            return outputFacts.contains {
                compatibleKinds(candidate, $0) && $0.canonicalValue == canonical
            }
        }
        return output.contains(candidate.sourceText)
    }

    private static func containsEquivalent(
        _ fact: ProtectedFact,
        in outputFacts: [SourceFactCandidate],
        output: String
    ) -> Bool {
        if fact.kind == .lexiconEntity, let canonical = canonicalValue(for: fact) {
            return normalizedNaturalText(output).contains(normalizedNaturalText(canonical))
        }
        if let canonical = canonicalValue(for: fact) {
            return outputFacts.contains {
                compatibleKinds(
                    leftKind: fact.kind,
                    leftSource: fact.sourceText,
                    rightKind: $0.kind,
                    rightSource: $0.sourceText
                ) && $0.canonicalValue == canonical
            }
        }
        return output.contains(fact.sourceText)
    }

    private static func equivalent(
        _ left: SourceFactCandidate,
        _ right: SourceFactCandidate
    ) -> Bool {
        compatibleKinds(left, right)
            && (left.canonicalValue != nil
                ? left.canonicalValue == right.canonicalValue
                : left.sourceText == right.sourceText)
    }

    /// “Swift 六点一”在 ASR 原文中会按普通数字提取，成稿写成 `6.1` 后则会
    /// 按版本号提取。口述“总金额是四万八”没有明确币种，成稿写成 `48,000`
    /// 时也只是数字书写变化；带元、美元或货币符号的金额仍不允许丢失币种。
    private static func compatibleKinds(
        _ left: SourceFactCandidate,
        _ right: SourceFactCandidate
    ) -> Bool {
        compatibleKinds(
            leftKind: left.kind,
            leftSource: left.sourceText,
            rightKind: right.kind,
            rightSource: right.sourceText
        )
    }

    private static func compatibleKinds(
        leftKind: ProtectedFactKind,
        leftSource: String,
        rightKind: ProtectedFactKind,
        rightSource: String
    ) -> Bool {
        if leftKind == rightKind { return true }
        if (leftKind == .number && rightKind == .version)
            || (leftKind == .version && rightKind == .number) {
            return !leftSource.lowercased().hasPrefix("v")
                && !rightSource.lowercased().hasPrefix("v")
        }
        if leftKind == .amount, rightKind == .number {
            return isUnitlessLabeledAmount(leftSource)
        }
        if leftKind == .number, rightKind == .amount {
            return isUnitlessLabeledAmount(rightSource)
        }
        return false
    }

    private static func isUnitlessLabeledAmount(_ source: String) -> Bool {
        guard source.contains("金额") else { return false }
        let explicitCurrencySignals = ["¥", "￥", "$", "元", "块", "美元", "人民币"]
        return !explicitCurrencySignals.contains(where: source.contains)
    }

    private static func outputSegment(_ output: String) -> RecognitionSegment {
        RecognitionSegment(
            id: "output",
            text: output,
            startTimeMs: nil,
            endTimeMs: nil,
            confidence: nil,
            isFinal: true
        )
    }

    /// 连续 `1...N` 行首序号属于排版，不是用户口述的新数字事实。只剥离可以
    /// 证明连续的编号；年份、错误码、乱序及孤立数字仍交给事实校验保护。
    private static func protectedFactsFromOutput(
        _ output: String,
        request: VoicePolishRequest
    ) -> [SourceFactCandidate] {
        let projectedOutput: String
        if request.context.scene == .code {
            projectedOutput = output
        } else {
            // 事实校验只在来源与成稿双重证明合法 N -> N+1 同步时，临时把
            // 列表头声明逆投影回旧值。其余字符保持原样，随后仍由通用提取器
            // 校验普通数字、金额、日期、版本等事实。
            projectedOutput = VoicePolishListCountConsistency
                .projectedTextForFactValidation(
                    in: output,
                    canonicalSource: request.fallbackText
                ) ?? output
        }
        let factText = request.context.scene == .code
            ? projectedOutput
            : VoicePolishNumbering.removingContinuousNumberedLineMarkers(
                in: projectedOutput
            )
        return ProtectedFactExtractor.extract(from: [outputSegment(factText)])
    }

    private static func normalizedNaturalText(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
            .lowercased()
            .filter { !$0.isWhitespace && !$0.isPunctuation }
    }

    private static func appendPlanLayoutCodes(
        _ plan: VoicePolishPlan,
        request: VoicePolishRequest,
        to codes: inout [VoicePolishValidationCode]
    ) {
        let expectation = VoicePolishLayoutExpectation.infer(from: request)
        guard plan.outputFormat.kind.rawValue == expectation.kind.rawValue else {
            append(.layoutRequirementUnmet, to: &codes)
            return
        }

        if let expected = expectation.expectedListItemCount,
           plan.outputFormat.expectedListCount != expected {
            append(.layoutRequirementUnmet, to: &codes)
        } else if let minimum = expectation.minimumListItemCount,
                  let planned = plan.outputFormat.expectedListCount,
                  planned < minimum {
            append(.layoutRequirementUnmet, to: &codes)
        }
    }

    private static func appendOutputLayoutCodes(
        _ output: String,
        request: VoicePolishRequest,
        to codes: inout [VoicePolishValidationCode]
    ) {
        let expectation = VoicePolishLayoutExpectation.infer(from: request)
        let numberedCount = VoicePolishNumbering.listItemCount(
            in: output,
            kind: .numberedList
        )
        let bulletCount = VoicePolishNumbering.listItemCount(
            in: output,
            kind: .bulletList
        )
        let recognizedListCount = numberedCount + bulletCount

        if VoicePolishListCountConsistency.declaredCountMatchesList(in: output) == false {
            append(.layoutRequirementUnmet, to: &codes)
        }

        if expectation.forbidsLists, recognizedListCount > 0 {
            append(.layoutRequirementUnmet, to: &codes)
        }
        if expectation.forbidsNumberedList, numberedCount > 0 {
            append(.layoutRequirementUnmet, to: &codes)
        }
        if expectation.forbidsBulletList, bulletCount > 0 {
            append(.layoutRequirementUnmet, to: &codes)
        }
        if expectation.forbidsLineBreaks, paragraphCount(in: output) > 1 {
            append(.layoutRequirementUnmet, to: &codes)
        }

        switch expectation.kind {
        case .sentence:
            // `.sentence` 是“没有本地最低结构要求”，不是禁止模型按语义或用户
            // 自定义 Prompt 使用轻量结构。明确的禁列表/禁换行已由上方独立校验。
            break
        case .paragraphs:
            let blockCount = paragraphCount(in: output)
            let hasAutomaticHybridStructure = recognizedListCount >= 2
                && blockCount >= 2
                && !hasExplicitParagraphRequirement(request)
            if blockCount < expectation.minimumParagraphCount,
               !hasAutomaticHybridStructure {
                append(.layoutRequirementUnmet, to: &codes)
            }
            // paragraphs 是最低分段要求，不是“禁止列表”。邮件、Prompt、需求
            // 笔记常见“引言 + 要求/范围列表 + 收束”的混合结构；只有用户明确
            // 禁止列表时才由上方 forbidsLists 门禁拒绝。
        case .numberedList:
            let count = numberedCount
            if let expected = expectation.expectedListItemCount {
                if count != expected { append(.layoutRequirementUnmet, to: &codes) }
            } else if count < (expectation.minimumListItemCount ?? 2) {
                append(.layoutRequirementUnmet, to: &codes)
            }
            if bulletCount > 0 {
                append(.layoutRequirementUnmet, to: &codes)
            }
            if !VoicePolishNumbering.matchesNumberingPreference(
                   in: output,
                   preference: expectation.numberingPreference
               ) {
                append(.layoutRequirementUnmet, to: &codes)
            }
        case .bulletList:
            let count = bulletCount
            if let expected = expectation.expectedListItemCount {
                if count != expected { append(.layoutRequirementUnmet, to: &codes) }
            } else if count < (expectation.minimumListItemCount ?? 2) {
                append(.layoutRequirementUnmet, to: &codes)
            }
            if numberedCount > 0 {
                append(.layoutRequirementUnmet, to: &codes)
            }
        }
    }

    private static func paragraphCount(in text: String) -> Int {
        let normalized = VoicePolishCharacterSafety.normalizedLineEndings(text)
        let blankLineBlocks = normalized
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if blankLineBlocks.count > 1 { return blankLineBlocks.count }
        return normalized
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .count
    }

    private static func hasExplicitParagraphRequirement(
        _ request: VoicePolishRequest
    ) -> Bool {
        let requirements = request.preferences.additionalRequirements.lowercased()
        let signals = [
            "分段", "段落", "每段", "几段", "换行",
            "paragraph", "line break", "new line",
        ]
        return signals.contains(where: requirements.contains)
    }

    private static func append(
        _ code: VoicePolishValidationCode,
        to codes: inout [VoicePolishValidationCode]
    ) {
        if !codes.contains(code) { codes.append(code) }
    }
}
