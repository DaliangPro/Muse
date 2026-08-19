import Foundation

enum VoicePolishLedgerIntegrityError: Error, Equatable, CustomStringConvertible {
    case invalidLedger
    case invalidLedgerReason(String)

    var description: String {
        switch self {
        case .invalidLedger:
            return "invalid_ledger"
        case .invalidLedgerReason(let reason):
            return reason
        }
    }
}

enum VoicePolishLedgerIntegrityValidator {
    private static let spanTargetCharacters = 120
    private static let spanHardLimitCharacters = 180
    private static let naturalSpanBoundaries: Set<Character> = ["。", "！", "？", "；", "\n"]
    private static let allowedKinds: Set<String> = [
        "claim", "action", "advice", "constraint", "question", "uncertainty", "style",
    ]
    private static let allowedRoles: Set<String> = [
        "recipient_content", "style_directive", "editor_directive", "excluded_content",
    ]
    private static let allowedStatuses: Set<String> = ["keep", "replace", "remove"]
    private static let allowedModalities: Set<String> = [
        "confirmed", "possible", "pending", "prohibited", "not_promised", "promised",
        "recommended",
    ]
    private static let allowedConditionalOperators: Set<String> = [
        "if_then", "only_if", "as_long_as", "unless", "otherwise", "negative_then",
    ]
    private static let nonCommitmentPattern = try! NSRegularExpression(
        pattern: #"(?:不要|不得|不能|无法|不|未)(?:再|轻易|直接)?(?:承诺|保证)"#
    )
    private static let explicitLogicPattern = try! NSRegularExpression(
        pattern: #"(?:如果|若是|要是|只要|除非|否则)|只有(?=[^。！？；\n]{0,40}才)|不能(?=[^。！？；\n]{0,40}就)"#
    )
    private static let asciiTechnicalTokenPattern = try! NSRegularExpression(
        pattern: #"^[A-Za-z][A-Za-z0-9]*(?:\s+[A-Za-z0-9]+)+$"#
    )
    private static let dictatedSymbols: [(String, String)] = [
        ("反斜杠", "\\"), ("双横线", "--"), ("下划线", "_"),
        ("斜杠", "/"), ("短横线", "-"), ("冒号", ":"), ("点", "."),
    ]
    private static let explicitAudiencePattern = try! NSRegularExpression(
        pattern: #"(?:跟|给)(客户|用户|对方|团队|大家|同事|开发|产品组|老师|他|她|他们|她们)(?:说|发(?:消息|邮件)?|回复)|告诉(客户|用户|对方|团队|大家|同事|开发|产品组|老师|他|她|他们|她们)|回复(?:给)?(客户|用户|对方|团队|大家|同事|开发|产品组|老师|他|她|他们|她们)"#
    )

    static func evidenceSpans(for request: VoicePolishRequest) -> [VoicePolishEvidenceSpan] {
        let source = request.input.fallbackText
        var segments = request.input.segments.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if segments.isEmpty || segments.map(\.text).joined() != source {
            segments = [RecognitionSegment(
                id: "s1",
                text: source,
                startTimeMs: 0,
                endTimeMs: request.input.durationMs,
                confidence: nil,
                isFinal: true
            )]
        }

        var offset = 0
        var usedIDs: Set<String> = []
        var result: [VoicePolishEvidenceSpan] = []
        for (segmentIndex, segment) in segments.enumerated() {
            let segmentID = segment.id.isEmpty ? "segment-\(segmentIndex + 1)" : segment.id
            for (partIndex, text) in splitEvidenceText(segment.text).enumerated() {
                let preferred = partIndex == 0 ? segmentID : "\(segmentID)#\(partIndex + 1)"
                var id = preferred
                var suffix = 2
                while usedIDs.contains(id) {
                    id = "\(preferred)#\(suffix)"
                    suffix += 1
                }
                usedIDs.insert(id)
                result.append(span(id: id, segmentID: segmentID, start: offset, text: text))
                offset += text.count
            }
        }
        return result
    }

    static func requiredLogicCues(
        source: String,
        spans: [VoicePolishEvidenceSpan]
    ) -> [VoicePolishLogicCue] {
        var result: [VoicePolishLogicCue] = []
        for span in spans {
            let range = NSRange(span.text.startIndex..<span.text.endIndex, in: span.text)
            let matches = explicitLogicPattern.matches(in: span.text, range: range)
            for match in matches {
                guard let swiftRange = Range(match.range, in: span.text) else { continue }
                let tail = span.text[swiftRange.lowerBound...]
                let boundary = tail.firstIndex(where: naturalSpanBoundaries.contains)
                    ?? span.text.endIndex
                let end = boundary < span.text.endIndex
                    ? span.text.index(after: boundary)
                    : span.text.endIndex
                let cueText = String(span.text[swiftRange.lowerBound..<end])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cueText.isEmpty else { continue }
                result.append(VoicePolishLogicCue(
                    id: String(format: "lc%03d", result.count + 1),
                    text: cueText,
                    sourceSpanIds: [span.id],
                    operatorKind: conditionalOperator(for: String(span.text[swiftRange]))
                ))
            }
        }
        return result
    }

    static func verifiedMappings(
        request: VoicePolishRequest,
        spans: [VoicePolishEvidenceSpan]
    ) -> [VoicePolishLedgerContextMapping] {
        let source = request.input.fallbackText
        let spanIDs = Set(spans.map(\.id))
        var result: [VoicePolishLedgerContextMapping] = []
        var seen: Set<String> = []

        func append(
            alias: String,
            canonical: String,
            sourceSegmentIDs: [String],
            evidence: String
        ) {
            let trimmedAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedCanonical = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedAlias.isEmpty,
                  !trimmedCanonical.isEmpty,
                  trimmedAlias != trimmedCanonical,
                  source.contains(trimmedAlias),
                  !seen.contains(trimmedAlias) else { return }
            let matching = spans.filter { span in
                (sourceSegmentIDs.contains(span.segmentID) || sourceSegmentIDs.contains(span.id))
                    && span.text.contains(trimmedAlias)
            }.map(\.id)
            let resolvedSpanIDs = matching.isEmpty
                ? spans.filter { $0.text.contains(trimmedAlias) }.map(\.id)
                : matching
            guard !resolvedSpanIDs.isEmpty,
                  resolvedSpanIDs.allSatisfy(spanIDs.contains) else { return }
            seen.insert(trimmedAlias)
            result.append(VoicePolishLedgerContextMapping(
                alias: trimmedAlias,
                canonical: trimmedCanonical,
                sourceSpanIds: resolvedSpanIDs,
                evidence: evidence
            ))
        }

        for edit in request.input.requiredEntityEdits {
            append(
                alias: edit.alias,
                canonical: edit.canonical,
                sourceSegmentIDs: edit.sourceSegmentIDs,
                evidence: "required_entity_edit"
            )
        }
        for entity in request.resolvedEntities {
            append(
                alias: entity.surfaceText,
                canonical: entity.canonical,
                sourceSegmentIDs: entity.sourceSegmentIDs,
                evidence: "resolved_entity"
            )
        }
        return result
    }

    static func validatedLedger(
        _ rawLedger: VoicePolishIntentLedger,
        spans: [VoicePolishEvidenceSpan],
        verifiedMappings: [VoicePolishLedgerContextMapping],
        requiredLogicCues: [VoicePolishLogicCue],
        scene: WritingScene
    ) throws -> VoicePolishIntentLedger {
        var ledger = rawLedger
        let spanByID = Dictionary(uniqueKeysWithValues: spans.map { ($0.id, $0) })
        let validSpanIDs = Set(spanByID.keys)
        let verifiedCanonicalBySpanID = verifiedMappings.reduce(into: [String: Set<String>]()) {
            partial, mapping in
            for spanID in mapping.sourceSpanIds {
                partial[spanID, default: []].insert(mapping.canonical)
            }
        }
        guard !ledger.units.isEmpty else {
            throw VoicePolishLedgerIntegrityError.invalidLedgerReason("units_empty")
        }
        // 技术断词和口述符号都属于可机械证明的字符变换，不再信任 Planner
        // 自报 mapping。程序直接从每个来源 span 识别最小 alias 并生成 canonical；
        // 这样错误数组不会让整份 Ledger 回退，也不能借冗余 span 把 canonical
        // 扇出到无证据的 unit。
        let localTokenMappings = locallyVerifiedTokenMappings(
            spans: spans,
            sceneAllowsMappings: scene == .code || scene == .aiPrompt
        )
        ledger.technicalTokenMappings = localTokenMappings.technical
        ledger.dictatedSymbolMappings = localTokenMappings.dictated
        do {
            try validateTokenMappings(
                ledger.technicalTokenMappings,
                transform: "remove_internal_ascii_whitespace",
                spans: spanByID,
                sceneAllowsMappings: scene == .code || scene == .aiPrompt
            )
        } catch {
            throw VoicePolishLedgerIntegrityError.invalidLedgerReason(
                "technical_token_mappings_invalid"
            )
        }
        do {
            try validateTokenMappings(
                ledger.dictatedSymbolMappings,
                transform: nil,
                spans: spanByID,
                sceneAllowsMappings: scene == .code || scene == .aiPrompt
            )
        } catch {
            throw VoicePolishLedgerIntegrityError.invalidLedgerReason(
                "dictated_symbol_mappings_invalid"
            )
        }
        let verifiedTokenMappings = ledger.technicalTokenMappings
            + ledger.dictatedSymbolMappings
        try validateCorrections(
            ledger.corrections,
            spans: spanByID,
            validSpanIDs: validSpanIDs
        )
        let fullSource = spans.map(\.text).joined()
        var locallyRemovedEditorUnitIDs: Set<String> = []
        var unitIds: Set<String> = []
        for index in ledger.units.indices {
            var unit = ledger.units[index]
            guard !unit.id.isEmpty,
                  unitIds.insert(unit.id).inserted,
                  allowedKinds.contains(unit.kind),
                  allowedRoles.contains(unit.deliveryRole),
                  allowedStatuses.contains(unit.status),
                  allowedModalities.contains(unit.modality),
                  !unit.finalMeaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !unit.sourceSpanIds.isEmpty,
                  unit.sourceSpanIds.allSatisfy(validSpanIDs.contains) else {
                throw VoicePolishLedgerIntegrityError.invalidLedgerReason(
                    "unit_identity_enum_or_source_span_invalid:\(unit.id)"
                )
            }
            if spans.count >= 3, unit.sourceSpanIds.count > 2 {
                throw VoicePolishLedgerIntegrityError.invalidLedgerReason(
                    "unit_references_more_than_two_source_spans:\(unit.id)"
                )
            }
            if unit.kind == "advice" && unit.modality != "recommended" {
                throw VoicePolishLedgerIntegrityError.invalidLedgerReason(
                    "advice_unit_requires_recommended_modality:\(unit.id)"
                )
            }
            let evidence = unit.sourceSpanIds.compactMap { spanByID[$0]?.text }.joined()
            if scene == .aiPrompt,
               unit.deliveryRole == "recipient_content",
               unit.status != "remove",
               let editorToken = currentAIPromptEditorInstruction(
                    in: evidence,
                    unitMeaning: unit.finalMeaning,
                    fullSource: fullSource
               ) {
                unit.deliveryRole = "editor_directive"
                unit.status = "remove"
                unit.exactTokens = []
                unit.surfaceTokens = [editorToken]
                locallyRemovedEditorUnitIDs.insert(unit.id)
            }
            if unit.deliveryRole == "recipient_content" {
                // surface_tokens 只用于证明幕后说明或排除内容是否泄漏；正文 unit
                // 不消费这个字段。模型即使冗余填写，也在本地清空，不能让一个
                // 无语义作用的协议细节导致整段口述回退。
                unit.surfaceTokens = []
            } else {
                guard !unit.surfaceTokens.isEmpty,
                      unit.surfaceTokens.allSatisfy({ !$0.isEmpty && evidence.contains($0) }) else {
                    throw VoicePolishLedgerIntegrityError.invalidLedgerReason(
                        "non_recipient_unit_requires_source_backed_surface_tokens:\(unit.id)"
                    )
                }
            }
            let unitSourceSpanIDs = Set(unit.sourceSpanIds)
            let tokenCanonical = verifiedTokenMappings.compactMap { mapping -> String? in
                // 一条 mapping 可能由多个相邻 span 共同证明。只有当前 unit
                // 同时引用全部证据、且自己的证据正文确实含 alias 时，才能
                // 消费 canonical；不能把 canonical 扇出给 mapping 中任一 span。
                guard Set(mapping.sourceSpanIds).isSubset(of: unitSourceSpanIDs),
                      evidence.contains(mapping.alias) else { return nil }
                return mapping.canonical
            }
            let allowedCanonical = Set(
                unit.sourceSpanIds.flatMap { spanID in
                    Array(verifiedCanonicalBySpanID[spanID] ?? [])
                } + tokenCanonical
            )
            let evidenceFacts = facts(in: evidence).union(
                allowedCanonical.flatMap { facts(in: $0) }
            )
            unit.finalMeaning = normalizingUnsupportedMeasurementFamilies(
                in: unit.finalMeaning,
                against: evidence
            )
            var normalizedExactTokens: [String] = []
            for token in unit.exactTokens {
                guard !token.isEmpty else {
                    throw VoicePolishLedgerIntegrityError.invalidLedgerReason(
                        "unit_contains_unbacked_exact_token:\(unit.id)"
                    )
                }
                if evidence.contains(token) || allowedCanonical.contains(token) {
                    normalizedExactTokens.append(token)
                    continue
                }
                throw VoicePolishLedgerIntegrityError.invalidLedgerReason(
                    "unit_contains_unbacked_exact_token:\(unit.id)"
                )
            }
            unit.exactTokens = normalizedExactTokens
            guard facts(in: unit.finalMeaning).isSubset(of: evidenceFacts) else {
                throw VoicePolishLedgerIntegrityError.invalidLedgerReason(
                    "unit_contains_unbacked_fact:\(unit.id)"
                )
            }
            let evidenceMeasurements = activeMeasurementScan(
                sourceSpanIDs: unit.sourceSpanIds,
                spans: spanByID,
                corrections: ledger.corrections
            )
            let finalMeasurements = outputMeasurementScan(
                in: unit.finalMeaning,
                sourceSpanIDs: unit.sourceSpanIds,
                corrections: ledger.corrections
            )
            if unit.deliveryRole == "recipient_content", unit.status != "remove" {
                guard measurementsAreSourceBacked(
                    source: evidenceMeasurements,
                    final: finalMeasurements,
                    requiresCompleteCoverage: false
                ) else {
                    throw VoicePolishLedgerIntegrityError.invalidLedgerReason(
                        "unit_contains_unbacked_fact:\(unit.id)"
                    )
                }
            }
            if explicitNonCommitment(in: unit.finalMeaning) {
                unit.modality = "not_promised"
            }
            for mapping in verifiedMappings
            where unit.deliveryRole == "recipient_content"
                && unit.status != "remove"
                && !Set(unit.sourceSpanIds).isDisjoint(with: mapping.sourceSpanIds) {
                // 一个 ASR span 可能同时包含收件人正文和“内部内容不要告诉客户”。
                // 仅凭 span 相交不能证明实体属于正文；必须由该 recipient unit
                // 自己的语义或精确 token 明确引用这条映射。
                guard unit.finalMeaning.contains(mapping.alias)
                        || unit.finalMeaning.contains(mapping.canonical)
                        || unit.exactTokens.contains(mapping.alias)
                        || unit.exactTokens.contains(mapping.canonical) else {
                    continue
                }
                unit.finalMeaning = unit.finalMeaning.replacingOccurrences(
                    of: mapping.alias,
                    with: mapping.canonical
                )
                if unit.deliveryRole == "recipient_content",
                   !unit.exactTokens.contains(mapping.canonical) {
                    unit.exactTokens.append(mapping.canonical)
                }
            }
            ledger.units[index] = unit
        }
        if !locallyRemovedEditorUnitIDs.isEmpty {
            ledger.structure = VoicePolishLedgerStructure(
                kind: ledger.structure.kind,
                orderedUnitIds: ledger.structure.orderedUnitIds.filter {
                    !locallyRemovedEditorUnitIDs.contains($0)
                }
            )
        }
        let activeRecipientUnits = ledger.units.filter {
            $0.deliveryRole == "recipient_content" && $0.status != "remove"
        }
        let recipientSpanIDs = Set(activeRecipientUnits.flatMap(\.sourceSpanIds))
        if !recipientSpanIDs.isEmpty {
            let orderedSpanIDs = spans.map(\.id).filter(recipientSpanIDs.contains)
            let excludedRanges = nonRecipientMeasurementRanges(
                ledger: ledger,
                spans: spanByID
            )
            let sourceMeasurements = activeMeasurementScan(
                sourceSpanIDs: orderedSpanIDs,
                spans: spanByID,
                corrections: ledger.corrections,
                excludedRangesBySpanID: excludedRanges
            )
            let finalMeasurements = mergedMeasurementScan(
                activeRecipientUnits.map { unit in
                    outputMeasurementScan(
                        in: unit.finalMeaning,
                        sourceSpanIDs: unit.sourceSpanIds,
                        corrections: ledger.corrections
                    )
                }
            )
            guard measurementsAreSourceBacked(
                source: sourceMeasurements,
                final: finalMeasurements,
                requiresCompleteCoverage: true
            ) else {
                throw VoicePolishLedgerIntegrityError.invalidLedgerReason(
                    "ledger_measurement_coverage_invalid"
                )
            }
        }
        let recipientUnitIDs = ledger.units.filter {
            $0.deliveryRole == "recipient_content" && $0.status != "remove"
        }.map(\.id)
        guard !recipientUnitIDs.isEmpty,
              Set(ledger.structure.orderedUnitIds) == Set(recipientUnitIDs),
              ledger.structure.orderedUnitIds.count == recipientUnitIDs.count,
              ["sentence", "paragraphs", "numbered_list", "mixed", "ai_prompt"]
                .contains(ledger.structure.kind) else {
            throw VoicePolishLedgerIntegrityError.invalidLedgerReason(
                "structure_must_exactly_order_active_recipient_units"
            )
        }

        let referencedSpanIDs = Set(ledger.units.flatMap(\.sourceSpanIds))
        guard validSpanIDs.isSubset(of: referencedSpanIDs) else {
            let missing = validSpanIDs.subtracting(referencedSpanIDs).sorted().joined(separator: ",")
            throw VoicePolishLedgerIntegrityError.invalidLedgerReason(
                "source_spans_without_unit:\(missing)"
            )
        }

        for audience in ledger.audience {
            guard !audience.text.isEmpty,
                  !audience.sourceSpanIds.isEmpty,
                  audience.sourceSpanIds.allSatisfy(validSpanIDs.contains),
                  !audience.surfaceTokens.isEmpty,
                  ["direct_address", "explicit_reference"].contains(audience.deliveryMode)
            else {
                throw VoicePolishLedgerIntegrityError.invalidLedgerReason("audience_invalid")
            }
            let evidence = audience.sourceSpanIds.compactMap { spanByID[$0]?.text }.joined()
            guard audience.surfaceTokens.allSatisfy({ evidence.contains($0) }) else {
                throw VoicePolishLedgerIntegrityError.invalidLedgerReason(
                    "audience_surface_token_not_in_source"
                )
            }
        }
        let source = spans.map(\.text).joined()
        let requiredAudience = requiredAudienceTokens(in: source)
        let plannedAudience = Set(ledger.audience.flatMap(\.surfaceTokens))
        guard requiredAudience.isSubset(of: plannedAudience) else {
            let missing = requiredAudience.subtracting(plannedAudience).sorted().joined(separator: ",")
            throw VoicePolishLedgerIntegrityError.invalidLedgerReason(
                "required_audience_missing:\(missing)"
            )
        }
        do {
            try validateConditionals(
                ledger.conditionals,
                requiredLogicCues: requiredLogicCues,
                spans: spanByID
            )
        } catch {
            throw VoicePolishLedgerIntegrityError.invalidLedgerReason("conditionals_invalid")
        }
        ledger.contextMappings = verifiedMappings.filter { mapping in
            ledger.units.contains { unit in
                unit.deliveryRole == "recipient_content"
                    && unit.status != "remove"
                    && !Set(unit.sourceSpanIds).isDisjoint(with: mapping.sourceSpanIds)
                    && (unit.finalMeaning.contains(mapping.alias)
                        || unit.finalMeaning.contains(mapping.canonical)
                        || unit.exactTokens.contains(mapping.alias)
                        || unit.exactTokens.contains(mapping.canonical))
            }
        }
        return ledger
    }

    static func deterministicIssues(
        output rawOutput: String,
        request: VoicePolishRequest,
        ledger: VoicePolishIntentLedger,
        spans: [VoicePolishEvidenceSpan]
    ) -> [VoicePolishReviewerIssue] {
        let source = request.input.fallbackText
        let output = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        var issues: [VoicePolishReviewerIssue] = []
        guard !output.isEmpty else {
            return [issue(type: "missing", instruction: "成稿为空，请根据原文恢复完整正文。")]
        }
        if VoicePolishCharacterSafety.containsUnsafeCharacters(output) {
            issues.append(issue(type: "invented", instruction: "删除不安全控制字符。"))
        }
        if source.count >= 280,
           whitespaceInsensitive(source) == whitespaceInsensitive(output) {
            issues.append(issue(
                type: "missing",
                instruction: "成稿只改变了空白或原样返回，仍未完成本次语音润色，请清理口述残片并形成可直接发送的表达。"
            ))
        }
        if source.count >= 280,
           nearOriginalSimilarity(source, output) >= 0.94 {
            for artifact in highConfidenceOralScaffolding(in: source)
            where output.contains(artifact) {
                issues.append(issue(
                    type: "instruction_leak",
                    instruction: "成稿与原口述近似原样，仍残留高置信口述支架“\(artifact)”，请完成自然语言收口。"
                ))
            }
        }
        if source.count >= 280, output.count < max(100, source.count * 55 / 100) {
            issues.append(issue(
                type: "missing",
                instruction: "成稿相对原文异常过短，恢复遗漏的独立约束和事项，不得摘要。"
            ))
        }
        if output.count > max(240, source.count * 22 / 10) {
            issues.append(issue(
                type: "invented",
                instruction: "成稿异常膨胀，删除无来源扩写，只保留原文可追溯内容。"
            ))
        }

        let outputFacts = facts(in: output)
        for unit in ledger.units where unit.deliveryRole == "recipient_content" {
            for fact in protectedFactCandidates(in: unit.finalMeaning) {
                let semanticValue = fact.canonicalValue ?? fact.sourceText
                let key = "\(fact.kind.rawValue)|\(semanticValue)"
                guard !outputFacts.contains(key) else { continue }
                issues.append(VoicePolishReviewerIssue(
                    type: "missing",
                    severity: "major",
                    unitIds: [unit.id],
                    sourceSpanIds: unit.sourceSpanIds,
                    draftSpan: nil,
                    repairInstruction: "恢复该意图单元中有来源的事实“\(fact.sourceText)”。"
                ))
            }
        }

        let firstPersonUnits = ledger.units.filter {
            $0.deliveryRole == "recipient_content"
                && ($0.finalMeaning.contains("我") || $0.finalMeaning.contains("咱们"))
        }
        if !source.contains("用户"), output.contains("用户"), !firstPersonUnits.isEmpty {
            issues.append(VoicePolishReviewerIssue(
                type: "task_layer",
                severity: "major",
                unitIds: firstPersonUnits.map(\.id),
                sourceSpanIds: Array(Set(firstPersonUnits.flatMap(\.sourceSpanIds))).sorted(),
                draftSpan: "用户",
                repairInstruction: "保持第一人称可直接发送的表达，不得把“我/我们”改写成幕后视角的“用户”。"
            ))
        }

        for unit in ledger.units where unit.deliveryRole == "recipient_content" {
            for token in unit.exactTokens where !token.isEmpty && !preservesToken(token, in: output) {
                issues.append(VoicePolishReviewerIssue(
                    type: "missing",
                    severity: "major",
                    unitIds: [unit.id],
                    sourceSpanIds: unit.sourceSpanIds,
                    draftSpan: nil,
                    repairInstruction: "恢复必须精确保留的内容“\(token)”。"
                ))
            }
        }

        // direct_address 表示“这段正文就是发给该收件人的话”，自然成稿无需再把
        // “客户/团队”机械写进正文；只有 explicit_reference 才要求字面保留。
        for audience in ledger.audience
        where audience.deliveryMode == "explicit_reference"
            && !audience.surfaceTokens.contains(where: output.contains) {
            issues.append(VoicePolishReviewerIssue(
                type: "wrong_relation",
                severity: "major",
                unitIds: ledger.structure.orderedUnitIds,
                sourceSpanIds: audience.sourceSpanIds,
                draftSpan: nil,
                repairInstruction: "恢复原文明确指定的收件人或转达对象“\(audience.text)”。"
            ))
        }

        for correction in ledger.corrections {
            let unitIds = recipientUnitIDs(
                overlapping: correction.oldSpanIds + correction.finalSpanIds,
                ledger: ledger
            )
            if !preservesToken(correction.finalValue, in: output) {
                issues.append(VoicePolishReviewerIssue(
                    type: "missing",
                    severity: "major",
                    unitIds: unitIds,
                    sourceSpanIds: correction.finalSpanIds,
                    draftSpan: nil,
                    repairInstruction: "恢复“\(correction.subject)”的最终值“\(correction.finalValue)”。"
                ))
            }
        }

        for mapping in ledger.technicalTokenMappings + ledger.dictatedSymbolMappings
        where !recipientUnitIDs(overlapping: mapping.sourceSpanIds, ledger: ledger).isEmpty {
            if !output.contains(mapping.canonical) {
                issues.append(VoicePolishReviewerIssue(
                    type: "missing",
                    severity: "major",
                    unitIds: recipientUnitIDs(overlapping: mapping.sourceSpanIds, ledger: ledger),
                    sourceSpanIds: mapping.sourceSpanIds,
                    draftSpan: nil,
                    repairInstruction: "恢复已由原文确定的精确技术内容“\(mapping.canonical)”。"
                ))
            }
            if output.contains(mapping.alias) {
                issues.append(VoicePolishReviewerIssue(
                    type: "wrong_relation",
                    severity: "major",
                    unitIds: recipientUnitIDs(overlapping: mapping.sourceSpanIds, ledger: ledger),
                    sourceSpanIds: mapping.sourceSpanIds,
                    draftSpan: mapping.alias,
                    repairInstruction: "把口述技术内容“\(mapping.alias)”还原为“\(mapping.canonical)”。"
                ))
            }
        }

        for mapping in ledger.contextMappings
        where !recipientUnitIDs(overlapping: mapping.sourceSpanIds, ledger: ledger).isEmpty {
            if !output.contains(mapping.canonical) {
                issues.append(VoicePolishReviewerIssue(
                    type: "missing",
                    severity: "major",
                    unitIds: recipientUnitIDs(overlapping: mapping.sourceSpanIds, ledger: ledger),
                    sourceSpanIds: mapping.sourceSpanIds,
                    draftSpan: nil,
                    repairInstruction: "恢复已确认的标准实体“\(mapping.canonical)”，不得引入上下文其他事实。"
                ))
            }
            if output.contains(mapping.alias) {
                issues.append(VoicePolishReviewerIssue(
                    type: "wrong_relation",
                    severity: "major",
                    unitIds: recipientUnitIDs(overlapping: mapping.sourceSpanIds, ledger: ledger),
                    sourceSpanIds: mapping.sourceSpanIds,
                    draftSpan: mapping.alias,
                    repairInstruction: "把正文别名“\(mapping.alias)”统一为“\(mapping.canonical)”。"
                ))
            }
        }

        let recipientMeanings = ledger.units
            .filter { $0.deliveryRole == "recipient_content" }
            .map(\.finalMeaning)
            .joined(separator: "\n")
        for unit in ledger.units where unit.deliveryRole != "recipient_content" {
            for token in unit.surfaceTokens
            where output.contains(token) && !recipientMeanings.contains(token) {
                issues.append(VoicePolishReviewerIssue(
                    type: unit.deliveryRole == "excluded_content" ? "context_leak" : "instruction_leak",
                    severity: "major",
                    unitIds: [unit.id],
                    sourceSpanIds: unit.sourceSpanIds,
                    draftSpan: token,
                    repairInstruction: unit.deliveryRole == "excluded_content"
                        ? "删除明确不得向当前收件人披露的内容及其同义改写。"
                        : "删除照抄的幕后写作说明，只落实它的作用。"
                ))
            }
        }

        for unit in ledger.units
        where unit.deliveryRole == "recipient_content" && unit.modality == "not_promised" {
            if !preservesNonCommitment(output: output, unit: unit) {
                issues.append(VoicePolishReviewerIssue(
                    type: "wrong_modality",
                    severity: "major",
                    unitIds: [unit.id],
                    sourceSpanIds: unit.sourceSpanIds,
                    draftSpan: nil,
                    repairInstruction: "恢复“不承诺/不保证”边界；不得改成事情确定不会发生。"
                ))
            }
        }

        if request.context.scene == .aiPrompt,
           output.range(
                of: #"(?:整理|改写|生成|制作|输出|写)(?:为|成)?[^\n。]{0,36}(?:Prompt|任务|要求)|不(?:要)?(?:现在|先|暂时|目前)?(?:开始|执行|进行)(?:研究|分析|任务)"#,
                options: [.regularExpression, .caseInsensitive]
           ) != nil {
            issues.append(issue(
                type: "task_layer",
                instruction: "直接交付未来 AI 可执行的 Prompt 本身，删除再次整理 Prompt 或当前先不执行的外层说明。"
            ))
        }
        for artifact in highConfidenceOralArtifacts(in: source)
        where output.contains(artifact) {
            issues.append(issue(
                type: "instruction_leak",
                instruction: "清理原文中仍残留的高置信口述起步或填充片段“\(artifact)”。"
            ))
        }
        return deduplicated(issues)
    }

    private static func splitEvidenceText(_ text: String) -> [String] {
        if text.count <= spanHardLimitCharacters {
            var parts: [String] = []
            var start = text.startIndex
            for index in text.indices where naturalSpanBoundaries.contains(text[index]) {
                let end = text.index(after: index)
                let part = String(text[start..<end])
                if !part.isEmpty { parts.append(part) }
                start = end
            }
            if start < text.endIndex { parts.append(String(text[start...])) }
            return parts.count > 1 ? parts : [text]
        }
        let characters = Array(text)
        var result: [String] = []
        var start = 0
        while start < characters.count {
            let target = min(characters.count, start + spanTargetCharacters)
            let hardEnd = min(characters.count, start + spanHardLimitCharacters)
            let lower = min(characters.count, start + spanTargetCharacters / 2)
            var end: Int?
            if lower < hardEnd {
                for index in stride(from: target, through: lower, by: -1)
                where index > start && naturalSpanBoundaries.contains(characters[index - 1]) {
                    end = index
                    break
                }
                if end == nil, target < hardEnd {
                    for index in (target + 1)...hardEnd
                    where naturalSpanBoundaries.contains(characters[index - 1]) {
                        end = index
                        break
                    }
                }
            }
            var resolvedEnd = end ?? target
            while resolvedEnd > lower,
                  resolvedEnd < characters.count,
                  characters[resolvedEnd - 1].isASCII,
                  characters[resolvedEnd - 1].isLetter || characters[resolvedEnd - 1].isNumber,
                  characters[resolvedEnd].isASCII,
                  characters[resolvedEnd].isLetter || characters[resolvedEnd].isNumber {
                resolvedEnd -= 1
            }
            if resolvedEnd <= start { resolvedEnd = hardEnd }
            result.append(String(characters[start..<resolvedEnd]))
            start = resolvedEnd
        }
        return result
    }

    private static func validateConditionals(
        _ conditionals: [VoicePolishLedgerConditional],
        requiredLogicCues: [VoicePolishLogicCue],
        spans: [String: VoicePolishEvidenceSpan]
    ) throws {
        let cueByID = Dictionary(uniqueKeysWithValues: requiredLogicCues.map { ($0.id, $0) })
        let allowedCueIDs = Set(cueByID.keys)
        let validSpanIDs = Set(spans.keys)
        var conditionalIDs: Set<String> = []
        var coveredCueIDs: [String] = []
        for conditional in conditionals {
            guard !conditional.id.isEmpty,
                  conditionalIDs.insert(conditional.id).inserted,
                  !conditional.cueIds.isEmpty,
                  conditional.cueIds.allSatisfy(allowedCueIDs.contains),
                  allowedConditionalOperators.contains(conditional.operatorKind),
                  !conditional.condition.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !conditional.condition.predicate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !conditional.condition.sourceSpanIds.isEmpty,
                  conditional.condition.sourceSpanIds.allSatisfy(validSpanIDs.contains),
                  !conditional.consequences.isEmpty else {
                throw VoicePolishLedgerIntegrityError.invalidLedger
            }
            let cueSpanIDs = Set(conditional.cueIds.compactMap { cueByID[$0] }
                .flatMap(\.sourceSpanIds))
            let cueOperators = Set(conditional.cueIds.compactMap { cueByID[$0]?.operatorKind })
            guard !cueSpanIDs.isEmpty,
                  !cueSpanIDs.isDisjoint(with: conditional.condition.sourceSpanIds),
                  cueOperators == Set([conditional.operatorKind]) else {
                throw VoicePolishLedgerIntegrityError.invalidLedger
            }
            let conditionEvidence = conditional.condition.sourceSpanIds
                .compactMap { spans[$0]?.text }
                .joined()
            guard evidenceContainsMeaning(conditional.condition.subject, in: conditionEvidence),
                  evidenceContainsMeaning(conditional.condition.predicate, in: conditionEvidence) else {
                throw VoicePolishLedgerIntegrityError.invalidLedger
            }
            for consequence in conditional.consequences {
                guard !consequence.action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !consequence.sourceSpanIds.isEmpty,
                      consequence.sourceSpanIds.allSatisfy(validSpanIDs.contains),
                      !cueSpanIDs.isDisjoint(with: consequence.sourceSpanIds) else {
                    throw VoicePolishLedgerIntegrityError.invalidLedger
                }
                let consequenceEvidence = consequence.sourceSpanIds
                    .compactMap { spans[$0]?.text }
                    .joined()
                guard evidenceContainsMeaning(consequence.action, in: consequenceEvidence) else {
                    throw VoicePolishLedgerIntegrityError.invalidLedger
                }
            }
            coveredCueIDs.append(contentsOf: conditional.cueIds)
        }
        guard Set(coveredCueIDs) == allowedCueIDs,
              coveredCueIDs.count == Set(coveredCueIDs).count else {
            throw VoicePolishLedgerIntegrityError.invalidLedger
        }
    }

    private static func validateTokenMappings(
        _ mappings: [VoicePolishLedgerTokenMapping],
        transform expectedTransform: String?,
        spans: [String: VoicePolishEvidenceSpan],
        sceneAllowsMappings: Bool
    ) throws {
        guard sceneAllowsMappings || mappings.isEmpty else {
            throw VoicePolishLedgerIntegrityError.invalidLedger
        }
        var aliases: Set<String> = []
        for mapping in mappings {
            guard !mapping.alias.isEmpty,
                  !mapping.canonical.isEmpty,
                  mapping.alias != mapping.canonical,
                  aliases.insert(mapping.alias).inserted,
                  !mapping.sourceSpanIds.isEmpty,
                  mapping.sourceSpanIds.allSatisfy({ spans[$0] != nil }) else {
                throw VoicePolishLedgerIntegrityError.invalidLedger
            }
            let evidence = mapping.sourceSpanIds.compactMap { spans[$0]?.text }.joined()
            guard evidence.contains(mapping.alias) else {
                throw VoicePolishLedgerIntegrityError.invalidLedger
            }
            if let expectedTransform {
                let range = NSRange(mapping.alias.startIndex..<mapping.alias.endIndex, in: mapping.alias)
                guard mapping.transform == expectedTransform,
                      asciiTechnicalTokenPattern.firstMatch(in: mapping.alias, range: range)?.range == range,
                      mapping.canonical == mapping.alias.replacingOccurrences(
                        of: #"(?<=[A-Za-z0-9])\s+(?=[A-Za-z0-9])"#,
                        with: "",
                        options: .regularExpression
                      ),
                      isHighConfidenceJoinedTechnicalToken(mapping) else {
                    throw VoicePolishLedgerIntegrityError.invalidLedger
                }
            } else {
                guard ["spoken_ascii_symbols", "spoken_cli_symbols"].contains(mapping.transform),
                      let canonical = dictatedCanonical(
                        mapping.alias,
                        transform: mapping.transform
                      ),
                      canonical == mapping.canonical,
                      canonical.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value <= 0x7E }) else {
                    throw VoicePolishLedgerIntegrityError.invalidLedger
                }
            }
        }
    }

    /// AI Prompt 场景里“帮我整理成 Prompt，先别开始研究，只整理任务”是
    /// 给 Muse 的当前编辑指令，不是要传给未来 AI 的任务正文。Planner 若把
    /// 这一句误标为正文，Writer/Repair 会反复照抄。只在同一来源同时出现
    /// 明确的 Prompt 整理请求、unit 自己也表达该指令时，程序把逐字命中的
    /// 局部句子改回 editor/remove；不会对普通研究 Prompt 做开放式推断。
    private static func currentAIPromptEditorInstruction(
        in evidence: String,
        unitMeaning: String,
        fullSource: String
    ) -> String? {
        let outerRequest = #"(?:帮我|请|把).{0,80}(?:整理|改写|生成).{0,24}(?:Prompt|提示词|任务)"#
        let editorInstruction = #"(?:先|暂时|目前)?(?:别|不要|不用)(?:现在|先|暂时|目前)?(?:开始|执行|进行)(?:研究|分析|任务)[，,、\s]*(?:只)?(?:整理|改写)(?:任务|要求|Prompt|提示词)"#
        guard fullSource.range(of: outerRequest, options: .regularExpression) != nil,
              unitMeaning.range(of: editorInstruction, options: .regularExpression) != nil,
              let range = evidence.range(of: editorInstruction, options: .regularExpression) else {
            return nil
        }
        return String(evidence[range])
    }

    private static func locallyVerifiedTokenMappings(
        spans: [VoicePolishEvidenceSpan],
        sceneAllowsMappings: Bool
    ) -> (
        technical: [VoicePolishLedgerTokenMapping],
        dictated: [VoicePolishLedgerTokenMapping]
    ) {
        guard sceneAllowsMappings else { return ([], []) }
        let technicalPattern = #"(?<![A-Za-z0-9])(?:[A-Za-z0-9]{1,32}\s+){2,}[A-Za-z0-9]{1,32}(?![A-Za-z0-9])"#
        let symbolPattern = dictatedSymbols
            .map { NSRegularExpression.escapedPattern(for: $0.0) }
            .joined(separator: "|")
        let dictatedPattern = #"(?<![A-Za-z0-9])(?:[A-Za-z0-9._]+(?:\s+[A-Za-z0-9._]+)*)(?:(?:"#
            + symbolPattern
            + #")[A-Za-z0-9._]+(?:\s+[A-Za-z0-9._]+)*)+(?![A-Za-z0-9])"#
        guard let technicalRegex = try? NSRegularExpression(pattern: technicalPattern),
              let dictatedRegex = try? NSRegularExpression(pattern: dictatedPattern) else {
            return ([], [])
        }

        var technical: [VoicePolishLedgerTokenMapping] = []
        var dictated: [VoicePolishLedgerTokenMapping] = []
        var technicalKeys: Set<String> = []
        var dictatedKeys: Set<String> = []
        for span in spans {
            let fullRange = NSRange(span.text.startIndex..<span.text.endIndex, in: span.text)
            for match in technicalRegex.matches(in: span.text, range: fullRange) {
                guard let range = Range(match.range, in: span.text) else { continue }
                let alias = String(span.text[range])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let canonical = alias.replacingOccurrences(
                    of: #"(?<=[A-Za-z0-9])\s+(?=[A-Za-z0-9])"#,
                    with: "",
                    options: .regularExpression
                )
                let mapping = VoicePolishLedgerTokenMapping(
                    alias: alias,
                    canonical: canonical,
                    sourceSpanIds: [span.id],
                    transform: "remove_internal_ascii_whitespace"
                )
                guard isHighConfidenceJoinedTechnicalToken(mapping),
                      technicalKeys.insert("\(span.id)|\(alias)").inserted else { continue }
                technical.append(mapping)
            }
            for match in dictatedRegex.matches(in: span.text, range: fullRange) {
                guard let range = Range(match.range, in: span.text) else { continue }
                let alias = String(span.text[range])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let transform = alias.contains(where: \.isWhitespace)
                    ? "spoken_cli_symbols"
                    : "spoken_ascii_symbols"
                guard let canonical = dictatedCanonical(alias, transform: transform),
                      dictatedKeys.insert("\(span.id)|\(alias)").inserted else { continue }
                dictated.append(VoicePolishLedgerTokenMapping(
                    alias: alias,
                    canonical: canonical,
                    sourceSpanIds: [span.id],
                    transform: transform
                ))
            }
        }
        return (technical, dictated)
    }

    /// 条件字段属于安全关键契约，不能只靠“引用了某个 span ID”自证。
    /// Planner 必须复制来源中的最短语义短语；这里只忽略空白和标点，不做
    /// 同义推断，避免把“客户确认后发布”伪造成“老板批准后删除数据库”。
    private static func evidenceContainsMeaning(_ meaning: String, in evidence: String) -> Bool {
        func normalized(_ value: String) -> String {
            value.replacingOccurrences(
                of: #"[\s\p{P}\p{S}]+"#,
                with: "",
                options: .regularExpression
            )
        }
        let normalizedMeaning = normalized(meaning)
        return !normalizedMeaning.isEmpty && normalized(evidence).contains(normalizedMeaning)
    }

    private static func dictatedCanonical(_ alias: String, transform: String) -> String? {
        var result = alias
        var replaced = false
        for (spoken, symbol) in dictatedSymbols where result.contains(spoken) {
            result = result.replacingOccurrences(of: spoken, with: symbol)
            replaced = true
        }
        guard replaced else { return nil }
        if transform == "spoken_cli_symbols" {
            result = result.replacingOccurrences(
                of: #"(?<=[A-Za-z0-9])(?=--[A-Za-z])"#,
                with: " ",
                options: .regularExpression
            )
            result = result.replacingOccurrences(
                of: #"(?<=[A-Za-z0-9])-(?=[A-Za-z](?:\s|$))"#,
                with: " -",
                options: .regularExpression
            )
        }
        return result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isHighConfidenceJoinedTechnicalToken(
        _ mapping: VoicePolishLedgerTokenMapping
    ) -> Bool {
        let components = mapping.alias.split(whereSeparator: \.isWhitespace).map(String.init)
        // 没有词典或已授权 canonical 证据时，只接受明显被 ASR 拆碎的单个标识：
        // 至少三个片段、至少两个 1～3 字母碎片，且不能含纯数字版本片段。
        // 这样 Voice Pol ish 可恢复为 VoicePolish，而 Swift 6 / Node 20 / Claude Code
        // 都不会被程序强制改写。
        guard components.count >= 3,
              components.allSatisfy({ component in
                  !component.allSatisfy(\.isNumber)
                      && component.allSatisfy({ $0.isLetter || $0.isNumber })
              }) else { return false }
        let shortLetterFragments = components.filter {
            (1...3).contains($0.count) && $0.allSatisfy(\.isLetter)
        }
        return shortLetterFragments.count >= 2
    }

    private static func conditionalOperator(for cue: String) -> String {
        if cue.hasPrefix("只有") { return "only_if" }
        if cue.hasPrefix("只要") { return "as_long_as" }
        if cue.hasPrefix("除非") { return "unless" }
        if cue.hasPrefix("否则") { return "otherwise" }
        if cue.hasPrefix("不能") { return "negative_then" }
        return "if_then"
    }

    private static func validateCorrections(
        _ corrections: [VoicePolishLedgerCorrection],
        spans: [String: VoicePolishEvidenceSpan],
        validSpanIDs: Set<String>
    ) throws {
        for correction in corrections {
            guard !correction.subject.isEmpty,
                  !correction.oldValue.isEmpty,
                  !correction.finalValue.isEmpty,
                  correction.oldValue != correction.finalValue,
                  !correction.oldSpanIds.isEmpty,
                  !correction.finalSpanIds.isEmpty,
                  correction.oldSpanIds.allSatisfy(validSpanIDs.contains),
                  correction.finalSpanIds.allSatisfy(validSpanIDs.contains),
                  ["final_only", "announce_change"].contains(correction.renderingPolicy)
            else {
                throw VoicePolishLedgerIntegrityError.invalidLedgerReason(
                    "correction_schema_invalid"
                )
            }
            let oldEvidence = correction.oldSpanIds.compactMap { spans[$0]?.text }.joined()
            let finalEvidence = correction.finalSpanIds.compactMap { spans[$0]?.text }.joined()
            guard oldEvidence.contains(correction.oldValue),
                  finalEvidence.contains(correction.finalValue) else {
                throw VoicePolishLedgerIntegrityError.invalidLedgerReason(
                    "correction_value_not_found_in_its_source_span"
                )
            }
            let oldValueIsSubjectBacked = correction.oldSpanIds.contains { spanID in
                guard let text = spans[spanID]?.text else { return false }
                return ranges(of: correction.oldValue, in: text).contains { range in
                    correctionRangeIsSubjectBacked(
                        range,
                        in: text,
                        subject: correction.subject
                    )
                }
            }
            let finalValueIsSubjectBacked = correction.finalSpanIds.contains { spanID in
                guard let text = spans[spanID]?.text else { return false }
                return ranges(of: correction.finalValue, in: text).contains { range in
                    correctionRangeIsSubjectBacked(
                        range,
                        in: text,
                        subject: correction.subject
                    )
                }
            }
            let localOmittedSubjectRanges = locallyPairedCorrectionOldRanges(
                correction,
                spans: spans
            )
            let hasLocalOmittedSubjectPair = !localOmittedSubjectRanges.isEmpty
            let hasSameSegmentBackwardCancellation = finalValueIsSubjectBacked
                && explicitlyCancelsOldValueInSameSegment(
                    correction,
                    spans: spans
                )
            guard (oldValueIsSubjectBacked && finalValueIsSubjectBacked)
                    || hasLocalOmittedSubjectPair
                    || hasSameSegmentBackwardCancellation else {
                throw VoicePolishLedgerIntegrityError.invalidLedgerReason(
                    oldValueIsSubjectBacked
                        ? "correction_subject_not_bound_to_final_value"
                        : "correction_subject_not_bound_to_old_value"
                )
            }
        }
    }

    /// 自然交接里常先给最终安排，再补一句“原来说周二录，这个取消”。旧句
    /// 会省略“录制安排”全称，但同一个 ASR segment 已明确包含最终对象、旧值
    /// 与取消证据。这里只接受非 measurement、同 segment、旧/新值各自唯一且
    /// 旧句同时带历史状态与取消词的反向改口，不能跨 segment 借另一个对象。
    private static func explicitlyCancelsOldValueInSameSegment(
        _ correction: VoicePolishLedgerCorrection,
        spans: [String: VoicePolishEvidenceSpan]
    ) -> Bool {
        guard measurementScan(in: correction.oldValue).occurrences.isEmpty,
              measurementScan(in: correction.finalValue).occurrences.isEmpty else {
            return false
        }
        for oldID in correction.oldSpanIds {
            guard let oldSpan = spans[oldID] else { continue }
            for finalID in correction.finalSpanIds {
                guard let finalSpan = spans[finalID],
                      oldSpan.segmentID == finalSpan.segmentID else { continue }
                let segmentSpans = spans.values
                    .filter { $0.segmentID == oldSpan.segmentID }
                    .sorted { $0.start < $1.start }
                let segmentText = segmentSpans.map(\.text).joined()
                guard ranges(of: correction.oldValue, in: segmentText).count == 1,
                      ranges(of: correction.finalValue, in: segmentText).count == 1 else {
                    continue
                }
                let oldClause = clause(
                    in: oldSpan.text,
                    containing: ranges(of: correction.oldValue, in: oldSpan.text).first
                        ?? NSRange(location: 0, length: 0)
                )
                let hasHistoricalCue = oldClause.range(
                    of: #"(?:原来|原定|原先|之前|先前|本来)"#,
                    options: .regularExpression
                ) != nil
                let hasCancellationCue = oldSpan.text.range(
                    of: #"(?:取消|作废|不再采用|不算|不要了)"#,
                    options: .regularExpression
                ) != nil
                if hasHistoricalCue && hasCancellationCue { return true }
            }
        }
        return false
    }

    private static func facts(in text: String) -> Set<String> {
        Set(protectedFacts(in: text))
    }

    private struct MeasurementOccurrence {
        let value: String
        let family: String
        let anchor: String
        let range: NSRange
    }

    private struct MeasurementScan {
        let occurrences: [MeasurementOccurrence]
        let bareValueCounts: [String: Int]
    }

    /// ProtectedFactExtractor 负责数值本身的规范化；这里额外保留容易改变原意的
    /// 时间单位、币种及其局部对象锚点。对象锚点使安全调序不依赖出现顺序，
    /// 同时拒绝把相同数值的工期与预算等关系互换；日期范围会先排除，避免把
    /// `2026-08-28` 与 `2026年8月28日` 的安全格式化误判为工期变化。
    private static func measurementScan(in text: String) -> MeasurementScan {
        let pattern = #"(?:([$¥￥]|美元|人民币)\s*)?([-+]?\d[\d,]*(?:\.\d+)?|[负零〇一二两双三四五六七八九十百千万亿点]+)\s*(万|亿)?\s*(年|个月|月|周|天|日|小时|分钟|秒|美元|人民币|元|块)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return MeasurementScan(occurrences: [], bareValueCounts: [:])
        }
        let dateRanges = measurementDateRanges(in: text)
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var occurrences: [MeasurementOccurrence] = []
        var bareValueCounts: [String: Int] = [:]
        for match in regex.matches(in: text, range: fullRange) {
            guard !dateRanges.contains(where: {
                NSIntersectionRange($0, match.range).length > 0
            }),
            let numberRange = Range(match.range(at: 2), in: text),
            var value = ProtectedFactExtractor.canonicalValue(
                for: String(text[numberRange]),
                kind: .number
            ) else { continue }
            let prefix = Range(match.range(at: 1), in: text).map { String(text[$0]) } ?? ""
            let scale = Range(match.range(at: 3), in: text).map { String(text[$0]) } ?? ""
            let unit = Range(match.range(at: 4), in: text).map { String(text[$0]) } ?? ""
            if !scale.isEmpty,
               let scaled = scaledMeasurementValue(value, scale: scale) {
                value = scaled
            }
            let prefixFamily: String? = {
                switch prefix {
                case "$": return "currency_usd"
                case "¥", "￥": return "currency_cny"
                case "美元": return "currency_usd"
                case "人民币": return "currency_cny"
                default: return nil
                }
            }()
            let unitFamily: String? = {
                switch unit {
                case "年": return "duration_year"
                case "个月", "月": return "duration_month"
                case "周": return "duration_week"
                case "天", "日": return "duration_day"
                case "小时": return "duration_hour"
                case "分钟": return "duration_minute"
                case "秒": return "duration_second"
                case "美元": return "currency_usd"
                case "人民币", "元", "块": return "currency_cny"
                default: return nil
                }
            }()
            let anchor = measurementAnchor(in: text, matchRange: match.range)
            if let prefixFamily, let unitFamily, prefixFamily != unitFamily {
                occurrences.append(MeasurementOccurrence(
                    value: value,
                    family: "currency_conflict",
                    anchor: anchor,
                    range: match.range
                ))
            } else if let family = prefixFamily ?? unitFamily {
                occurrences.append(MeasurementOccurrence(
                    value: value,
                    family: family,
                    anchor: anchor,
                    range: match.range
                ))
            } else {
                bareValueCounts[value, default: 0] += 1
            }
        }
        return MeasurementScan(occurrences: occurrences, bareValueCounts: bareValueCounts)
    }

    /// Planner 偶尔会把“预算一万六”自行补成“预算 16000 元”。来源没有
    /// 单位或币种时，程序不能把该推断交给 Writer；但也无需让整段 1K 文本
    /// 因一个可机械撤销的后缀回退。仅当同一 unit 中该裸值和新增 measurement
    /// 都各自唯一时，把整段 measurement 收口为原值 canonical，随后仍走事实、
    /// 对象关系与 Reviewer 门禁。已有单位的删除、替换或跨对象借值不会进入此路。
    private static func normalizingUnsupportedMeasurementFamilies(
        in finalMeaning: String,
        against evidence: String
    ) -> String {
        let source = measurementScan(in: evidence)
        let final = measurementScan(in: finalMeaning)
        let candidates = final.occurrences.filter { occurrence in
            source.bareValueCounts[occurrence.value, default: 0] == 1
                && final.occurrences.filter({ $0.value == occurrence.value }).count == 1
                && !source.occurrences.contains(where: {
                    $0.value == occurrence.value && $0.family == occurrence.family
                })
        }
        guard !candidates.isEmpty else { return finalMeaning }
        let mutable = NSMutableString(string: finalMeaning)
        for occurrence in candidates.sorted(by: { $0.range.location > $1.range.location }) {
            mutable.replaceCharacters(in: occurrence.range, with: occurrence.value)
        }
        return mutable as String
    }

    private static func activeMeasurementScan(
        sourceSpanIDs: [String],
        spans: [String: VoicePolishEvidenceSpan],
        corrections: [VoicePolishLedgerCorrection],
        excludedRangesBySpanID: [String: [NSRange]] = [:]
    ) -> MeasurementScan {
        var occurrences: [MeasurementOccurrence] = []
        var bareValueCounts: [String: Int] = [:]
        for spanID in sourceSpanIDs {
            guard let span = spans[spanID] else { continue }
            let scan = measurementScan(in: span.text)
            let supersededRanges = supersededMeasurementRanges(
                in: span.text,
                spanID: spanID,
                corrections: corrections,
                spans: spans
            )
            let excludedRanges = excludedRangesBySpanID[spanID] ?? []
            let activeOccurrences = scan.occurrences.filter { occurrence in
                !supersededRanges.contains(where: {
                    NSIntersectionRange($0, occurrence.range).length > 0
                })
                    && !excludedRanges.contains(where: {
                        NSIntersectionRange($0, occurrence.range).length > 0
                    })
            }
            occurrences.append(contentsOf: activeOccurrences.map { occurrence in
                let matchingCorrections = corrections.filter { correction in
                    correction.finalSpanIds.contains(spanID)
                        && ranges(of: correction.finalValue, in: span.text).contains(where: {
                            NSIntersectionRange($0, occurrence.range).length > 0
                        })
                }
                guard matchingCorrections.count == 1,
                      let correction = matchingCorrections.first else { return occurrence }
                return MeasurementOccurrence(
                    value: occurrence.value,
                    family: occurrence.family,
                    anchor: normalizedMeasurementAnchor(correction.subject),
                    range: occurrence.range
                )
            })
            for (value, count) in scan.bareValueCounts {
                bareValueCounts[value, default: 0] += count
            }
        }
        return MeasurementScan(
            occurrences: deduplicatedSourceMeasurements(occurrences),
            bareValueCounts: bareValueCounts
        )
    }

    private static func deduplicatedSourceMeasurements(
        _ occurrences: [MeasurementOccurrence]
    ) -> [MeasurementOccurrence] {
        var seen: Set<String> = []
        return occurrences.filter { occurrence in
            let anchor = canonicalMeasurementAnchor(occurrence.anchor)
            // 没有对象锚点的两个同值仍可能是两条不同事实，不能合并。
            guard !anchor.isEmpty else { return true }
            return seen.insert("\(anchor)|\(occurrence.value)|\(occurrence.family)").inserted
        }
    }

    /// Writer 可以把“九个月”安全格式化为“9 个月”，也可以补回省略的对象。
    /// 只在当前 unit 的证据中恰有一个已验证 correction 与该 measurement
    /// 同值同单位时，将成稿关系投影回 correction.subject；同值多改口时安全失败。
    private static func outputMeasurementScan(
        in text: String,
        sourceSpanIDs: [String],
        corrections: [VoicePolishLedgerCorrection]
    ) -> MeasurementScan {
        let scan = measurementScan(in: text)
        let sourceIDs = Set(sourceSpanIDs)
        let relevant = corrections.filter {
            !sourceIDs.isDisjoint(with: $0.finalSpanIds)
        }
        let projected = scan.occurrences.map { occurrence in
            let matching = relevant.filter { correction in
                measurementScan(in: correction.finalValue).occurrences.contains {
                    $0.value == occurrence.value && $0.family == occurrence.family
                }
            }
            let sameSignatureCount = scan.occurrences.filter {
                $0.value == occurrence.value && $0.family == occurrence.family
            }.count
            guard matching.count == 1,
                  sameSignatureCount == 1,
                  let correction = matching.first else { return occurrence }
            return MeasurementOccurrence(
                value: occurrence.value,
                family: occurrence.family,
                anchor: normalizedMeasurementAnchor(correction.subject),
                range: occurrence.range
            )
        }
        return MeasurementScan(
            occurrences: projected,
            bareValueCounts: scan.bareValueCounts
        )
    }

    private static func mergedMeasurementScan(_ scans: [MeasurementScan]) -> MeasurementScan {
        var bareValueCounts: [String: Int] = [:]
        for scan in scans {
            for (value, count) in scan.bareValueCounts {
                bareValueCounts[value, default: 0] += count
            }
        }
        return MeasurementScan(
            occurrences: scans.flatMap(\.occurrences),
            bareValueCounts: bareValueCounts
        )
    }

    private static func measurementsAreSourceBacked(
        source: MeasurementScan,
        final: MeasurementScan,
        requiresCompleteCoverage: Bool
    ) -> Bool {
        guard (requiresCompleteCoverage
                ? source.occurrences.count == final.occurrences.count
                : final.occurrences.count <= source.occurrences.count),
              !final.occurrences.contains(where: { $0.family == "currency_conflict" })
        else { return false }

        let measuredSourceValues = Set(source.occurrences.map(\.value))
        guard measuredSourceValues.allSatisfy({ value in
            final.bareValueCounts[value, default: 0]
                <= source.bareValueCounts[value, default: 0]
        }) else { return false }

        // 二分图匹配按对象—数值—单位关系核对，顺序不参与语义判断。
        var sourceMatch = Array(repeating: -1, count: source.occurrences.count)
        func assign(_ finalIndex: Int, visited: inout Set<Int>) -> Bool {
            let candidate = final.occurrences[finalIndex]
            for sourceIndex in source.occurrences.indices {
                guard visited.insert(sourceIndex).inserted else { continue }
                let evidence = source.occurrences[sourceIndex]
                let singletonUnanchoredRelation = evidence.anchor.isEmpty
                    && candidate.anchor.isEmpty
                    && source.occurrences.count == 1
                    && final.occurrences.count == 1
                guard candidate.value == evidence.value,
                      candidate.family == evidence.family,
                      (measurementAnchorsAreCompatible(evidence.anchor, candidate.anchor)
                        || singletonUnanchoredRelation)
                else { continue }
                if sourceMatch[sourceIndex] == -1 {
                    sourceMatch[sourceIndex] = finalIndex
                    return true
                }
                if assign(sourceMatch[sourceIndex], visited: &visited) {
                    sourceMatch[sourceIndex] = finalIndex
                    return true
                }
            }
            return false
        }
        for finalIndex in final.occurrences.indices {
            var visited: Set<Int> = []
            guard assign(finalIndex, visited: &visited) else { return false }
        }
        return true
    }

    private static func measurementAnchor(in text: String, matchRange: NSRange) -> String {
        guard let range = Range(matchRange, in: text) else { return "" }
        let clauseDelimiters: Set<Character> = ["，", "。", "！", "？", "；", "：", ",", "!", "?", ";", "\n"]
        let before = text[..<range.lowerBound]
        let start = before.lastIndex(where: clauseDelimiters.contains)
            .map { text.index(after: $0) } ?? text.startIndex
        let prefix = String(text[start..<range.lowerBound])
        let normalizedPrefix = normalizedMeasurementAnchor(prefix)
        if !normalizedPrefix.isEmpty { return normalizedPrefix }

        let after = text[range.upperBound...]
        let end = after.firstIndex(where: clauseDelimiters.contains) ?? text.endIndex
        let suffix = String(text[range.upperBound..<end])
        let linkedSuffix = suffix.replacingOccurrences(
            of: #"^\s*(?:的|是|为|属于)\s*"#,
            with: "",
            options: .regularExpression
        )
        let knownAnchors = [
            "工期", "周期", "时长", "期限", "预算", "费用", "金额", "成本", "报价",
            "人数", "数量", "名额", "天数", "时长",
        ]
        if let knownAnchor = knownAnchors.first(where: { linkedSuffix.hasPrefix($0) }) {
            return knownAnchor
        }
        // 数值位于句首时，后置谓词同样承担对象关系，例如“30天交付”。
        // 保留这个短语义锚点，避免把同值改绑成“30天质保”。
        return normalizedMeasurementAnchor(linkedSuffix)
    }

    private static func normalizedMeasurementAnchor(_ raw: String) -> String {
        var result = raw.replacingOccurrences(
            of: #"[\s“”\"'（）()【】\[\]]+"#,
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"^(?:第[零〇一二两三四五六七八九十百千万亿\d]+项|另外|其中|至于|关于|目前|当前|最终|最后|本次|这个|该|预计|计划|原定|暂定|先按|暂按|项目)+"#,
            with: "",
            options: .regularExpression
        )
        let trailing = #"(?:最后通过的?是?|最终(?:调整|改)?(?:为|成)|调整为|改成|改为|定为|原定|暂定|先定|先按|暂按|按照|按|控制在|不超过|不高于|不低于|至少|最多|最少|约为|大约|预计|计划|安排|合计|一共|总共|共|需要|最终|最后|是|为)+$"#
        while true {
            let trimmed = result.replacingOccurrences(
                of: trailing,
                with: "",
                options: .regularExpression
            )
            if trimmed == result { break }
            result = trimmed
        }
        result = result.trimmingCharacters(in: .punctuationCharacters)
        guard result.count >= 2 else { return "" }
        return String(result.suffix(16)).lowercased()
    }

    private static func measurementAnchorsAreCompatible(_ source: String, _ final: String) -> Bool {
        let sourceKey = canonicalMeasurementAnchor(source)
        let finalKey = canonicalMeasurementAnchor(final)
        guard !sourceKey.isEmpty || !finalKey.isEmpty else { return false }
        return !sourceKey.isEmpty && sourceKey == finalKey
    }

    private static func canonicalMeasurementAnchor(_ anchor: String) -> String {
        guard !anchor.isEmpty else { return "" }
        for suffix in ["工期", "周期", "时长"] where anchor.hasSuffix(suffix) {
            var prefix = String(anchor.dropLast(suffix.count))
            if prefix.hasSuffix("项目") {
                prefix.removeLast("项目".count)
            }
            return "\(prefix)#duration"
        }
        return anchor
    }

    private static func nonRecipientMeasurementRanges(
        ledger: VoicePolishIntentLedger,
        spans: [String: VoicePolishEvidenceSpan]
    ) -> [String: [NSRange]] {
        var result: [String: [NSRange]] = [:]
        for unit in ledger.units
        where unit.deliveryRole != "recipient_content" || unit.status == "remove" {
            for spanID in unit.sourceSpanIds {
                guard let span = spans[spanID] else { continue }
                let sourceMeasurements = measurementScan(in: span.text).occurrences
                for token in unit.surfaceTokens where !token.isEmpty {
                    let tokenRanges = ranges(of: token, in: span.text)
                    // 排除 token 必须精确定位到一个来源位置；重复的“30天”
                    // 不能同时豁免正文工期与内部保留期。
                    guard tokenRanges.count == 1,
                          let tokenRange = tokenRanges.first else { continue }
                    let tokenMeasurements = measurementScan(in: token).occurrences
                    // token 自身必须携带且只携带一个带对象的 measurement，
                    // “内部成本”或裸“50元”都不足以证明要排除哪条关系。
                    guard tokenMeasurements.count == 1,
                          let tokenMeasurement = tokenMeasurements.first,
                          !tokenMeasurement.anchor.isEmpty else { continue }
                    let matchingSource = sourceMeasurements.filter { occurrence in
                        tokenRange.location <= occurrence.range.location
                            && NSMaxRange(occurrence.range) <= NSMaxRange(tokenRange)
                            && occurrence.value == tokenMeasurement.value
                            && occurrence.family == tokenMeasurement.family
                            && measurementAnchorsAreCompatible(
                                occurrence.anchor,
                                tokenMeasurement.anchor
                            )
                    }
                    guard matchingSource.count == 1,
                          let occurrence = matchingSource.first else { continue }
                    result[spanID, default: []].append(occurrence.range)
                }
            }
        }
        return result
    }

    private static func supersededMeasurementRanges(
        in text: String,
        spanID: String,
        corrections: [VoicePolishLedgerCorrection],
        spans: [String: VoicePolishEvidenceSpan]
    ) -> [NSRange] {
        corrections.filter { $0.oldSpanIds.contains(spanID) }.flatMap { correction in
            let valueRanges = ranges(of: correction.oldValue, in: text)
            let strictlyBound = valueRanges.filter { range in
                correctionRangeIsSubjectBacked(
                    range,
                    in: text,
                    subject: correction.subject
                )
            }
            let locallyPaired = locallyPairedCorrectionOldRanges(
                correction,
                spans: spans
            )[spanID] ?? []
            return Array(Set(strictlyBound + locallyPaired))
        }
    }

    /// 自然口述常在后半句省略对象，例如“工期先定 30 天，不对，改成 20 天”。
    /// 这里只在旧值—明确改口词—同类最终值形成局部唯一配对，且最终片段没有
    /// 引入另一个强对象时继承主语；返回精确旧值 range，避免同值事实被全局作废。
    private static func locallyPairedCorrectionOldRanges(
        _ correction: VoicePolishLedgerCorrection,
        spans: [String: VoicePolishEvidenceSpan]
    ) -> [String: [NSRange]] {
        struct Candidate {
            let spanID: String
            let oldRange: NSRange
            let distance: Int
        }
        let cues = [
            "不对", "说错了", "说错", "错了", "我改一下", "更正",
            "改成", "改为", "调整为", "应该是", "应该为", "应为",
        ]
        let subjectAnchor = normalizedMeasurementAnchor(correction.subject)
        let subjectKey = canonicalMeasurementAnchor(subjectAnchor)
        var candidates: [Candidate] = []

        for oldSpanID in correction.oldSpanIds {
            guard let oldText = spans[oldSpanID]?.text else { continue }
            let oldOccurrences = measurementScan(in: oldText).occurrences
            for oldRange in ranges(of: correction.oldValue, in: oldText) {
                guard let oldMeasurement = oldOccurrences.first(where: {
                    NSIntersectionRange($0.range, oldRange).length > 0
                }) else { continue }
                let oldKey = canonicalMeasurementAnchor(oldMeasurement.anchor)
                if isStrongMeasurementAnchor(subjectKey),
                   !subjectMayDescribeMeasurement(subjectKey, measurementKey: oldKey) {
                    continue
                }

                for finalSpanID in correction.finalSpanIds {
                    guard let finalText = spans[finalSpanID]?.text else { continue }
                    let finalOccurrences = measurementScan(in: finalText).occurrences
                    for finalRange in ranges(of: correction.finalValue, in: finalText) {
                        guard let finalMeasurement = finalOccurrences.first(where: {
                            NSIntersectionRange($0.range, finalRange).length > 0
                        }), oldMeasurement.family == finalMeasurement.family else { continue }

                        let bridge: String
                        if oldSpanID == finalSpanID {
                            guard NSMaxRange(oldRange) <= finalRange.location,
                                  let range = Range(
                                    NSRange(
                                        location: NSMaxRange(oldRange),
                                        length: finalRange.location - NSMaxRange(oldRange)
                                    ),
                                    in: oldText
                                  ) else { continue }
                            bridge = String(oldText[range])
                        } else {
                            let oldNSString = oldText as NSString
                            let finalNSString = finalText as NSString
                            let oldTail = oldNSString.substring(
                                from: min(NSMaxRange(oldRange), oldNSString.length)
                            )
                            let finalPrefix = finalNSString.substring(
                                to: min(finalRange.location, finalNSString.length)
                            )
                            bridge = oldTail + "\n" + finalPrefix
                        }
                        guard bridge.count <= 120,
                              let cue = lastCorrectionCue(in: bridge, cues: cues) else { continue }

                        let beforeCue = String(bridge[..<cue.lowerBound])
                        // 省略主语只能承接改口词前最近的同类事实。若中间已经
                        // 出现另一条工期/金额等，不能跨过去把更早对象改掉。
                        guard !measurementScan(in: beforeCue).occurrences.contains(where: {
                            $0.family == oldMeasurement.family
                        }) else { continue }

                        let finalPrefixAfterCue = String(bridge[cue.upperBound...])
                        let finalNSString = finalText as NSString
                        let suffixStart = min(NSMaxRange(finalRange), finalNSString.length)
                        let suffix = finalNSString.substring(from: suffixStart)
                        let suffixBoundary = suffix.firstIndex(where: {
                            ["，", "。", "！", "？", "；", ",", "!", "?", ";", "\n"].contains($0)
                        }) ?? suffix.endIndex
                        let localSuffix = String(suffix[..<suffixBoundary])
                        let localFinalText = finalPrefixAfterCue
                            + correction.finalValue
                            + localSuffix
                        let localValueLocation = (finalPrefixAfterCue as NSString).length
                        let localFinalAnchor = measurementAnchor(
                            in: localFinalText,
                            matchRange: NSRange(
                                location: localValueLocation,
                                length: (correction.finalValue as NSString).length
                            )
                        )
                        let finalKey = canonicalMeasurementAnchor(localFinalAnchor)
                        let finalCarriesSubject = finalKey.isEmpty
                            || isOmittedSubjectCorrectionAnchor(localFinalAnchor)
                        if !finalCarriesSubject {
                            let referenceKey = isStrongMeasurementAnchor(subjectKey)
                                ? subjectKey
                                : oldKey
                            guard subjectMayDescribeMeasurement(
                                referenceKey,
                                measurementKey: finalKey
                            ) else { continue }
                        }

                        candidates.append(Candidate(
                            spanID: oldSpanID,
                            oldRange: oldRange,
                            distance: bridge.count
                        ))
                    }
                }
            }
        }
        guard let selected = candidates.min(by: { lhs, rhs in
            lhs.distance == rhs.distance
                ? lhs.oldRange.location > rhs.oldRange.location
                : lhs.distance < rhs.distance
        }) else { return [:] }
        return [selected.spanID: [selected.oldRange]]
    }

    private static func lastCorrectionCue(
        in text: String,
        cues: [String]
    ) -> Range<String.Index>? {
        cues.compactMap { text.range(of: $0, options: .backwards) }
            .max(by: { $0.lowerBound < $1.lowerBound })
    }

    private static func isStrongMeasurementAnchor(_ key: String) -> Bool {
        guard !key.isEmpty else { return false }
        if key.hasSuffix("#duration") { return true }
        return [
            "期限", "预算", "费用", "金额", "成本", "报价",
            "人数", "数量", "名额", "天数",
        ].contains(where: { key.hasSuffix($0) })
    }

    private static func subjectMayDescribeMeasurement(
        _ subjectKey: String,
        measurementKey: String
    ) -> Bool {
        guard !subjectKey.isEmpty, !measurementKey.isEmpty else { return false }
        if subjectKey == measurementKey { return true }
        if subjectKey == "#duration", measurementKey.hasSuffix("#duration") { return true }
        return ["期限", "预算", "费用", "金额", "成本", "报价", "人数", "数量", "名额", "天数"]
            .contains(where: { subjectKey == $0 && measurementKey.hasSuffix($0) })
    }

    private static func isOmittedSubjectCorrectionAnchor(_ anchor: String) -> Bool {
        let compact = anchor.replacingOccurrences(
            of: #"[\s，。！？；,:：]+"#,
            with: "",
            options: .regularExpression
        )
        return compact.range(
            of: #"^(?:我们)?(?:数据)?(?:只有|改成|改为|调整为|应为|应该是|应该为)$"#,
            options: .regularExpression
        ) != nil
    }

    private static func correctionRangeIsSubjectBacked(
        _ range: NSRange,
        in text: String,
        subject: String
    ) -> Bool {
        let subjectAnchor = normalizedMeasurementAnchor(subject)
        let intersectingMeasurements = measurementScan(in: text).occurrences.filter { occurrence in
            NSIntersectionRange(occurrence.range, range).length > 0
        }
        if !intersectingMeasurements.isEmpty {
            guard !subjectAnchor.isEmpty else { return false }
            return intersectingMeasurements.contains { occurrence in
                measurementAnchorsAreCompatible(occurrence.anchor, subjectAnchor)
            }
        }
        // 非 measurement 的颜色、地点等改口仍允许同小句对象绑定；数值关系
        // 已在上面走严格对象锚点，不能再用“整句出现过 subject”短路。
        return clause(in: text, containing: range).contains(subject)
    }

    private static func ranges(of needle: String, in text: String) -> [NSRange] {
        guard !needle.isEmpty else { return [] }
        var result: [NSRange] = []
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(of: needle, range: searchStart..<text.endIndex) {
            result.append(NSRange(range, in: text))
            searchStart = range.upperBound
        }
        return result
    }

    private static func clause(in text: String, containing range: NSRange) -> String {
        guard let stringRange = Range(range, in: text) else { return "" }
        let delimiters: Set<Character> = ["，", "。", "！", "？", "；", ",", "!", "?", ";", "\n"]
        let before = text[..<stringRange.lowerBound]
        let start = before.lastIndex(where: delimiters.contains)
            .map { text.index(after: $0) } ?? text.startIndex
        let after = text[stringRange.upperBound...]
        let end = after.firstIndex(where: delimiters.contains) ?? text.endIndex
        return String(text[start..<end])
    }

    private static func scaledMeasurementValue(_ value: String, scale: String) -> String? {
        guard let decimal = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) else {
            return nil
        }
        let multiplier: Decimal
        switch scale {
        case "万": multiplier = 10_000
        case "亿": multiplier = 100_000_000
        default: return value
        }
        return NSDecimalNumber(decimal: decimal * multiplier).stringValue
    }

    private static func measurementDateRanges(in text: String) -> [NSRange] {
        let patterns = [
            #"(?<![A-Za-z0-9_])\d{4}(?:[-/.年])\d{1,2}(?:[-/.月])\d{1,2}日?(?![A-Za-z0-9_])"#,
            #"(?:\d{1,2}|[零〇一二两三四五六七八九十]+)\s*月\s*(?:\d{1,2}|[零〇一二两三四五六七八九十]+)\s*日"#,
        ]
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return patterns.flatMap { pattern in
            (try? NSRegularExpression(pattern: pattern))?.matches(in: text, range: fullRange)
                .map(\.range) ?? []
        }
    }

    private static func protectedFactCandidates(in text: String) -> [SourceFactCandidate] {
        let segment = RecognitionSegment(
            id: "fact",
            text: text,
            startTimeMs: 0,
            endTimeMs: 0,
            confidence: nil,
            isFinal: true
        )
        return ProtectedFactExtractor.extract(from: [segment])
    }

    private static func whitespaceInsensitive(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func nearOriginalSimilarity(_ lhs: String, _ rhs: String) -> Double {
        func comparable(_ value: String) -> [Character] {
            Array(value.replacingOccurrences(
                of: #"[\s\p{P}\p{S}]+"#,
                with: "",
                options: .regularExpression
            ))
        }
        let left = comparable(lhs)
        let right = comparable(rhs)
        let longest = max(left.count, right.count)
        guard longest > 0 else { return 1 }
        if left == right { return 1 }

        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = Array(repeating: 0, count: right.count + 1)
            current[0] = leftIndex + 1
            for (rightIndex, rightCharacter) in right.enumerated() {
                current[rightIndex + 1] = min(
                    min(previous[rightIndex + 1] + 1, current[rightIndex] + 1),
                    previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                )
            }
            previous = current
        }
        return 1 - Double(previous[right.count]) / Double(longest)
    }

    /// 这些不是开放式“所有口头词”词表，而是带语法形态的高置信口述支架。
    /// 只有长文与原文高度相似时才作为硬门禁，避免正常成稿偶尔使用“就是说”。
    private static func highConfidenceOralScaffolding(in source: String) -> [String] {
        let pattern = try! NSRegularExpression(
            pattern: #"(?:嗯{1,3}|呃{1,3}|额{1,3}|然后的话|怎么说呢|怎么讲呢|就是说)"#
        )
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        var result: [String] = []
        for match in pattern.matches(in: source, range: range) {
            guard let swiftRange = Range(match.range, in: source) else { continue }
            let lower = source.index(swiftRange.lowerBound, offsetBy: -18, limitedBy: source.startIndex)
                ?? source.startIndex
            let upper = source.index(swiftRange.upperBound, offsetBy: 18, limitedBy: source.endIndex)
                ?? source.endIndex
            let window = String(source[lower..<upper])
            if window.range(of: #"[“”\"「」『』]"#, options: .regularExpression) != nil
                || window.range(of: #"口吃|示例|比如|例如|照录|原样保留"#, options: .regularExpression) != nil {
                continue
            }
            result.append(String(source[swiftRange]))
        }
        return Array(Set(result)).sorted()
    }

    /// 这里只检查可以从字符结构直接证明的起步重复；未知叠词、有意强调、
    /// 引号与“示例/口吃”讲解一律交给 Reviewer，避免再造开放词表。
    private static func highConfidenceOralArtifacts(in source: String) -> [String] {
        let pattern = try! NSRegularExpression(
            pattern: #"(?:我[，,]?我|这[，,]?这|那[，,]?那|可[，,]?可|功[，,]?功|这个[，,]?这个|那个[，,]?那个)(?=[\p{Han}])"#
        )
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        var result: [String] = []
        for match in pattern.matches(in: source, range: range) {
            guard let swiftRange = Range(match.range, in: source) else { continue }
            let lower = source.index(swiftRange.lowerBound, offsetBy: -18, limitedBy: source.startIndex)
                ?? source.startIndex
            let upper = source.index(swiftRange.upperBound, offsetBy: 18, limitedBy: source.endIndex)
                ?? source.endIndex
            let window = String(source[lower..<upper])
            if window.range(of: #"[“”\"「」『』]"#, options: .regularExpression) != nil
                || window.range(of: #"口吃|示例|比如|例如|照录|原样保留"#, options: .regularExpression) != nil {
                continue
            }
            result.append(String(source[swiftRange]))
        }
        return Array(Set(result)).sorted()
    }

    private static func preservesToken(_ token: String, in output: String) -> Bool {
        if output.contains(token) { return true }
        let tokenFacts = protectedFacts(in: token)
        guard !tokenFacts.isEmpty else { return false }
        let outputFacts = Set(protectedFacts(in: output))
        return Set(tokenFacts).isSubset(of: outputFacts)
    }

    private static func protectedFacts(in text: String) -> [String] {
        protectedFactCandidates(in: text).map {
            "\($0.kind.rawValue)|\($0.canonicalValue ?? $0.sourceText)"
        }
    }

    private static func span(
        id: String,
        segmentID: String,
        start: Int,
        text: String
    ) -> VoicePolishEvidenceSpan {
        VoicePolishEvidenceSpan(
            id: id,
            segmentID: segmentID,
            start: start,
            end: start + text.count,
            text: text,
            digest: VoicePolishProviderAudit.sha256Hex(Data(text.utf8))
        )
    }

    private static func explicitNonCommitment(in text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return nonCommitmentPattern.firstMatch(in: text, range: range) != nil
    }

    private static func requiredAudienceTokens(in text: String) -> Set<String> {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return Set(explicitAudiencePattern.matches(in: text, range: range).compactMap { match in
            for index in 1..<match.numberOfRanges where match.range(at: index).location != NSNotFound {
                if let swiftRange = Range(match.range(at: index), in: text) {
                    return String(text[swiftRange])
                }
            }
            return nil
        })
    }

    private static func preservesNonCommitment(
        output: String,
        unit: VoicePolishLedgerUnit
    ) -> Bool {
        let anchors = unit.exactTokens.filter { !$0.isEmpty }
        guard !anchors.isEmpty else { return explicitNonCommitment(in: output) }
        for anchor in anchors {
            var searchStart = output.startIndex
            while let range = output.range(of: anchor, range: searchStart..<output.endIndex) {
                let lower = output.index(range.lowerBound, offsetBy: -120, limitedBy: output.startIndex)
                    ?? output.startIndex
                let upper = output.index(range.upperBound, offsetBy: 160, limitedBy: output.endIndex)
                    ?? output.endIndex
                if explicitNonCommitment(in: String(output[lower..<upper])) { return true }
                searchStart = range.upperBound
            }
        }
        return false
    }

    private static func recipientUnitIDs(
        overlapping spanIDs: [String],
        ledger: VoicePolishIntentLedger
    ) -> [String] {
        let target = Set(spanIDs)
        return ledger.units.filter {
            $0.deliveryRole == "recipient_content"
                && !target.isDisjoint(with: $0.sourceSpanIds)
        }.map(\.id)
    }

    private static func issue(
        type: String,
        instruction: String
    ) -> VoicePolishReviewerIssue {
        VoicePolishReviewerIssue(
            type: type,
            severity: "major",
            unitIds: [],
            sourceSpanIds: [],
            draftSpan: nil,
            repairInstruction: instruction
        )
    }

    private static func deduplicated(
        _ issues: [VoicePolishReviewerIssue]
    ) -> [VoicePolishReviewerIssue] {
        var seen: Set<String> = []
        return issues.filter {
            let key = [$0.type, $0.unitIds.joined(separator: ","), $0.repairInstruction]
                .joined(separator: "\u{0}")
            return seen.insert(key).inserted
        }
    }
}
