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

        if sourceFacts.contains(where: { !containsEquivalent($0, in: outputFacts, output: output) }) {
            append(.missingProtectedFact, to: &codes)
        }
        if outputFacts.contains(where: { outputFact in
            !sourceFacts.contains(where: { equivalent($0, outputFact) })
        }) {
            append(.planIntegrityFailure, to: &codes)
        }
        appendTerminologyEditCodes(output: output, request: request, to: &codes)
        appendOutputLayoutCodes(output, request: request, to: &codes)
        return VoicePolishValidationResult(codes: codes)
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
