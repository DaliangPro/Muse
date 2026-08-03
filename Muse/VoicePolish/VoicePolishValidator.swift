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
                && !isSourceBackedQuotedFormattingFact(
                    outputFact,
                    sourceText: request.fallbackText
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
        appendTerminologyEditCodes(output: output, request: request, to: &codes)
        appendOutputLayoutCodes(output, request: request, to: &codes)
        return VoicePolishValidationResult(codes: codes)
    }

    /// 模型可能为原文已有词语补中文或英文引号。引号本身属于排版，不应被
    /// ProtectedFactExtractor 当作“新增引用事实”；只有去掉成对引号后的完整内容
    /// 已逐字存在于正式输入时才放行。
    private static func isSourceBackedQuotedFormattingFact(
        _ fact: SourceFactCandidate,
        sourceText: String
    ) -> Bool {
        guard fact.kind == .quotedPhrase, fact.sourceText.count >= 2 else { return false }
        let characters = Array(fact.sourceText)
        let isPairedQuote = (characters.first == "“" && characters.last == "”")
            || (characters.first == "\"" && characters.last == "\"")
        guard isPairedQuote else { return false }
        let interior = String(characters.dropFirst().dropLast())
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !interior.isEmpty && sourceText.contains(interior)
    }

    /// Fast 路径没有模型生成的 Plan，因此只接受本地能证明的最窄改口事实：
    /// 同一 segment 中，改口信号前最近的受保护事实，与信号后首个同类型、不同值
    /// 的事实形成替换关系。其余金额、日期、版本等仍全部要求保留。
    private static func locallySupersededFactIndices(
        request: VoicePolishRequest,
        sourceFacts: [SourceFactCandidate]
    ) -> Set<Int> {
        struct LocatedFact {
            let index: Int
            let location: String.Index
        }

        let correctionSignals = [
            "前面那句改成", "刚才那句改成", "把开头改成", "let me correct that",
            "change the earlier part", "change what i said before", "scratch that",
            "我的意思是", "我改一下", "说错了", "不对", "应该是", "最后还是",
            "最终决定", "actually", "i mean", "final decision",
        ]
        var superseded: Set<Int> = []

        for segment in request.input.segments {
            let located = sourceFacts.enumerated().compactMap { index, fact -> LocatedFact? in
                guard fact.kind != .lexiconEntity,
                      fact.sourceSegmentIDs.contains(segment.id),
                      let range = segment.text.range(of: fact.sourceText) else { return nil }
                return LocatedFact(index: index, location: range.lowerBound)
            }.sorted { $0.location < $1.location }
            guard located.count >= 2 else { continue }

            let markers = correctionSignals.flatMap { signal -> [Range<String.Index>] in
                allRanges(of: signal, in: segment.text)
            }.sorted { $0.lowerBound < $1.lowerBound }

            for marker in markers {
                guard let previous = located.last(where: { $0.location < marker.lowerBound }) else {
                    continue
                }
                let previousFact = sourceFacts[previous.index]
                guard located.contains(where: { candidate in
                    guard candidate.location >= marker.upperBound else { return false }
                    let finalFact = sourceFacts[candidate.index]
                    return finalFact.kind == previousFact.kind
                        && !equivalent(previousFact, finalFact)
                }) else { continue }
                superseded.insert(previous.index)
            }
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

    static func validateStructured(
        response: StructuredVoicePolishResponse,
        request: VoicePolishRequest,
        sourceFacts: [SourceFactCandidate]
    ) -> VoicePolishValidationResult {
        let output = response.finalText
        var codes = commonCodes(output: output, sourceText: request.fallbackText)
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
            if !previous.isEmpty, normalizedNaturalText(output).contains(previous) {
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
        if let canonical = candidate.canonicalValue {
            return outputFacts.contains {
                $0.kind == candidate.kind && $0.canonicalValue == canonical
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
                $0.kind == fact.kind && $0.canonicalValue == canonical
            }
        }
        return output.contains(fact.sourceText)
    }

    private static func equivalent(
        _ left: SourceFactCandidate,
        _ right: SourceFactCandidate
    ) -> Bool {
        left.kind == right.kind
            && (left.canonicalValue != nil
                ? left.canonicalValue == right.canonicalValue
                : left.sourceText == right.sourceText)
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
            if paragraphCount(in: output) < expectation.minimumParagraphCount {
                append(.layoutRequirementUnmet, to: &codes)
            }
            if recognizedListCount >= 2 {
                append(.layoutRequirementUnmet, to: &codes)
            }
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

    private static func append(
        _ code: VoicePolishValidationCode,
        to codes: inout [VoicePolishValidationCode]
    ) {
        if !codes.contains(code) { codes.append(code) }
    }
}
