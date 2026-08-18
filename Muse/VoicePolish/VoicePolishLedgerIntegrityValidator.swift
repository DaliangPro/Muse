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
            if unit.deliveryRole == "recipient_content" {
                guard unit.surfaceTokens.isEmpty else {
                    throw VoicePolishLedgerIntegrityError.invalidLedgerReason(
                        "recipient_unit_surface_tokens_must_be_empty:\(unit.id)"
                    )
                }
            } else {
                guard !unit.surfaceTokens.isEmpty,
                      unit.surfaceTokens.allSatisfy({ !$0.isEmpty && evidence.contains($0) }) else {
                    throw VoicePolishLedgerIntegrityError.invalidLedgerReason(
                        "non_recipient_unit_requires_source_backed_surface_tokens:\(unit.id)"
                    )
                }
            }
            let allowedCanonical = Set(unit.sourceSpanIds.flatMap {
                Array(verifiedCanonicalBySpanID[$0] ?? [])
            })
            guard unit.exactTokens.allSatisfy({ token in
                !token.isEmpty && (evidence.contains(token) || allowedCanonical.contains(token))
            }), facts(in: unit.finalMeaning).isSubset(of: facts(in: evidence).union(
                allowedCanonical.flatMap { facts(in: $0) }
            )) else {
                throw VoicePolishLedgerIntegrityError.invalidLedgerReason(
                    "unit_contains_unbacked_exact_token_or_fact:\(unit.id)"
                )
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
        for correction in ledger.corrections {
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
                throw VoicePolishLedgerIntegrityError.invalidLedgerReason("correction_schema_invalid")
            }
            let oldEvidence = correction.oldSpanIds.compactMap { spanByID[$0]?.text }.joined()
            let finalEvidence = correction.finalSpanIds.compactMap { spanByID[$0]?.text }.joined()
            guard oldEvidence.contains(correction.oldValue),
                  finalEvidence.contains(correction.finalValue) else {
                throw VoicePolishLedgerIntegrityError.invalidLedgerReason(
                    "correction_value_not_found_in_its_source_span"
                )
            }
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

    private static func facts(in text: String) -> Set<String> {
        Set(protectedFacts(in: text))
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
