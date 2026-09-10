import Foundation
import NaturalLanguage

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
        ledger.pendingSemanticChecks = []
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
        // Planner 偶尔把已由安全上下文确认的 alias→canonical 又重复声明成
        // source correction。二者职责不同：上下文映射由本地 verifiedMappings
        // 执行，冗余 correction 既不增加证据，反而会因 canonical 不在原文而
        // 触发 schema repair。仅在映射、span 与 final_only 完全一致时删除它；
        // 其他改口仍严格走来源 old/final 双证据门禁。
        ledger.corrections.removeAll { correction in
            verifiedMappings.contains { mapping in
                guard correction.renderingPolicy == "final_only",
                      correction.oldValue == mapping.alias,
                      Set(correction.oldSpanIds).isSubset(of: Set(mapping.sourceSpanIds)) else {
                    return false
                }
                if correction.finalValue == mapping.canonical,
                   Set(correction.finalSpanIds).isSubset(of: Set(mapping.sourceSpanIds)) {
                    return true
                }
                // 已确认的上下文纠名不应被 Planner 伪装成来源改口。若所谓
                // final_value 在它自己声明的来源 span 中根本不存在，删除这条
                // 幻觉 correction；真正有来源的新值仍交给严格改口门禁处理。
                return !correction.finalSpanIds.compactMap { spanByID[$0]?.text }
                    .joined().contains(correction.finalValue)
            }
        }
        try validateCorrections(
            ledger.corrections,
            spans: spanByID,
            validSpanIDs: validSpanIDs
        )
        ledger.conditionals = normalizedConditionals(
            ledger.conditionals,
            requiredLogicCues: requiredLogicCues,
            spans: spanByID
        )
        let fullSource = spans.map(\.text).joined()
        if scene == .aiPrompt {
            appendRecipientUnitsForUncoveredConditionalSpans(
                to: &ledger,
                spans: spans
            )
            appendRecipientUnitsForRequiredAIPromptMappings(
                to: &ledger,
                spans: spans,
                verifiedMappings: verifiedMappings,
                fullSource: fullSource
            )
        }
        ledger.audience = try normalizedAudiences(
            ledger.audience,
            spans: spanByID,
            fullSource: fullSource
        )
        var unitIds: Set<String> = []
        for index in ledger.units.indices {
            var unit = ledger.units[index]
            let invalidSpanIDs = unit.sourceSpanIds.filter { !validSpanIDs.contains($0) }
            let evidence = unit.sourceSpanIds.compactMap { spanByID[$0]?.text }.joined()
            if !allowedKinds.contains(unit.kind) {
                // kind 只影响问句标点与建议展示，不承担事实、角色或状态安全。
                // Planner 偶尔会把 delivery_role 的值（如 editor_directive）
                // 错填到 kind；依据已经受 schema 约束的 role/modality 与来源标点
                // 机械恢复即可。role、status、modality 和 span 仍严格拒绝非法值。
                unit.kind = inferredUnitKind(for: unit, evidence: evidence)
            }
            guard !unit.id.isEmpty,
                  unitIds.insert(unit.id).inserted,
                  allowedKinds.contains(unit.kind),
                  allowedRoles.contains(unit.deliveryRole),
                  allowedStatuses.contains(unit.status),
                  allowedModalities.contains(unit.modality),
                  !unit.finalMeaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !unit.sourceSpanIds.isEmpty,
                  invalidSpanIDs.isEmpty else {
                throw VoicePolishLedgerIntegrityError.invalidLedgerReason(
                    "unit_identity_enum_or_source_span_invalid:"
                        + "id=\(unit.id),kind=\(unit.kind),role=\(unit.deliveryRole),"
                        + "status=\(unit.status),modality=\(unit.modality),"
                        + "invalid_span_ids=\(invalidSpanIDs.joined(separator: ","))"
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
            var evidenceFacts = facts(in: evidence).union(
                allowedCanonical.flatMap { facts(in: $0) }
            )
            let sourceTimes = protectedFactCandidates(in: evidence).filter { $0.kind == .time }
            for fact in protectedFactCandidates(in: unit.finalMeaning) where fact.kind == .time {
                guard let value = fact.canonicalValue,
                      let separator = value.firstIndex(of: "|") else { continue }
                let day = String(value[..<separator])
                let clock = String(value[value.index(after: separator)...])
                // 只允许来源中已出现的日期承接显式改口里的省略时钟。
                // 例如旧值含日期，最终值只说半点；其他 unit 的时间不可借用。
                let hasPartialClock = sourceTimes.contains { $0.canonicalValue == clock }
                let hasSourceDay = sourceTimes.contains { $0.canonicalValue?.hasPrefix(day + "|") == true }
                let hasCorrection = ledger.corrections.contains { correction in
                    Set(correction.finalSpanIds).isSubset(of: unitSourceSpanIDs)
                        && Set(correction.oldSpanIds).isSubset(of: unitSourceSpanIDs)
                        && ProtectedFactExtractor.canonicalValue(for: correction.finalValue, kind: .time) == clock
                        && ProtectedFactExtractor.canonicalValue(for: correction.oldValue, kind: .time)?.hasPrefix(day + "|") == true
                }
                if hasPartialClock && hasSourceDay && hasCorrection {
                    evidenceFacts.insert(protectedFactKey(fact, in: unit.finalMeaning))
                }
            }
            // 给来源中已有短语加引号只改变标点。仍要求引号内逐字来自该
            // unit 自己的证据，不能借此新增引语，也不影响命令的精确保留。
            for fact in protectedFactCandidates(in: unit.finalMeaning) where fact.kind == .quotedPhrase {
                let inner = String(fact.sourceText.dropFirst().dropLast())
                if !inner.isEmpty, evidence.contains(inner) {
                    evidenceFacts.insert(protectedFactKey(fact, in: unit.finalMeaning))
                }
            }
            unit.finalMeaning = normalizingUnsupportedMeasurementFamilies(
                in: unit.finalMeaning,
                against: evidence
            )
            let sharesSpanWithNonRecipientContent = ledger.units.contains { other in
                other.id != unit.id
                    && (other.deliveryRole == "excluded_content"
                        || other.deliveryRole == "editor_directive")
                    && !Set(other.sourceSpanIds).isDisjoint(with: unitSourceSpanIDs)
            }
            if scene == .aiPrompt,
               unit.deliveryRole == "recipient_content",
               unit.status != "remove",
               !facts(in: unit.finalMeaning).isSubset(of: evidenceFacts),
               !sharesSpanWithNonRecipientContent {
                // AI Prompt 的 Planner 若在某个 unit 中擅加受保护事实，最安全的
                // 本地恢复不是请求它继续猜，而是退回该 unit 自己的 canonical
                // 来源 span，让 Writer 再做表达清理。混合 editor/excluded span
                // 不走此路，避免把明确排除内容重新带回正文。
                unit.finalMeaning = evidence
                unit.exactTokens = []
            }
            if unit.deliveryRole == "recipient_content", unit.status != "remove",
               ledger.corrections.contains(where: { correction in
                   guard correction.renderingPolicy == "final_only",
                         !unitSourceSpanIDs.isDisjoint(with: correction.oldSpanIds),
                         preservesToken(correction.oldValue, in: unit.finalMeaning) else { return false }
                   let oldScan = measurementScan(in: correction.oldValue)
                   let oldValues = Set(oldScan.occurrences.map(\.value) + Array(oldScan.bareValueCounts.keys))
                   let oldCount: Int
                   if let declared = declaredCountValue(correction.oldValue) {
                       oldCount = declaredCountRanges(value: declared.value,
                           classifier: declared.classifier, in: evidence).count
                   } else if oldValues.count == 1, let value = oldValues.first {
                       let sourceScan = measurementScan(in: evidence)
                       oldCount = sourceScan.occurrences.filter { $0.value == value }.count
                           + sourceScan.bareValueCounts[value, default: 0]
                   } else {
                       oldCount = ranges(of: correction.oldValue, in: evidence).count
                   }
                   // 同值多事项不能整体作废；这里只要求唯一旧值的计划显式更新。
                   let returnsToOldValue = ledger.corrections.contains {
                       $0.subject == correction.subject && $0.finalValue == correction.oldValue
                   }
                   return oldCount == 1 && !returnsToOldValue
               }) {
                throw VoicePolishLedgerIntegrityError.invalidLedgerReason(
                    "recipient_unit_retains_superseded_value:\(unit.id)"
                )
            }
            if scene == .aiPrompt,
               unit.deliveryRole == "recipient_content", unit.status != "remove",
               currentAIPromptEditorInstruction(
                    in: evidence, unitMeaning: unit.finalMeaning, fullSource: fullSource
               ) != nil {
                throw VoicePolishLedgerIntegrityError.invalidLedgerReason(
                    "recipient_unit_contains_editor_process:\(unit.id)"
                )
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
            var normalizedExactTokens: [String] = []
            for token in unit.exactTokens {
                guard !token.isEmpty else {
                    throw VoicePolishLedgerIntegrityError.invalidLedgerReason(
                        "unit_contains_unbacked_exact_token:\(unit.id)"
                    )
                }
                if evidence.contains(token) || allowedCanonical.contains(token) {
                    if !normalizedExactTokens.contains(token) {
                        normalizedExactTokens.append(token)
                    }
                    continue
                }
                let enclosingCanonical = allowedCanonical.filter {
                    $0.contains(token) && unit.finalMeaning.contains($0)
                }
                if enclosingCanonical.count == 1, let canonical = enclosingCanonical.first {
                    // Planner 偶尔把完整、已验证路径/命令拆成多个 exact token。
                    // 局部片段本身不够证明来源，但所属完整 canonical 已由同一
                    // unit 的口述符号映射机械证明；收口为完整值，不能只放宽片段。
                    if !normalizedExactTokens.contains(canonical) {
                        normalizedExactTokens.append(canonical)
                    }
                    continue
                }
                throw VoicePolishLedgerIntegrityError.invalidLedgerReason(
                    "unit_contains_unbacked_exact_token:\(unit.id)"
                )
            }
            unit.exactTokens = normalizedExactTokens
            let finalFacts = facts(in: unit.finalMeaning)
            guard finalFacts.isSubset(of: evidenceFacts) else {
                throw VoicePolishLedgerIntegrityError.invalidLedgerReason(
                    "unit_contains_unbacked_fact:\(unit.id):unexpected=\(finalFacts.subtracting(evidenceFacts).sorted())"
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
                guard measurementValuesHaveSources(
                    source: evidenceMeasurements,
                    final: finalMeasurements,
                    requiresCompleteCoverage: false
                ) else {
                    throw VoicePolishLedgerIntegrityError.invalidLedgerReason(
                        "unit_contains_unbacked_fact:\(unit.id):source_measurements=\(evidenceMeasurements.summary),final_measurements=\(finalMeasurements.summary)"
                    )
                }
            }
            if unit.deliveryRole == "recipient_content", unit.status != "remove",
               !evidenceMeasurements.occurrences.isEmpty || !finalMeasurements.occurrences.isEmpty
                    || !numericSourceEvidence(spanIDs: unit.sourceSpanIds, spans: spanByID).isEmpty {
                ledger.pendingSemanticChecks?.append(VoicePolishSemanticCheck(
                    id: "measurement_\(unit.id)", kind: "measurement_relation",
                    claim: "核对该片段所有数值的主体、动作、币种、上限下限和条件，不能借用同值的其他事项。",
                    unitIds: [unit.id], sourceSpanIds: unit.sourceSpanIds,
                    requiredEvidence: numericSourceEvidence(spanIDs: unit.sourceSpanIds, spans: spanByID)
                ))
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
            guard measurementValuesHaveSources(
                source: sourceMeasurements,
                final: finalMeasurements,
                requiresCompleteCoverage: true
            ) else {
                throw VoicePolishLedgerIntegrityError.invalidLedgerReason(
                    "ledger_measurement_coverage_invalid:source=\(sourceMeasurements.summary),final=\(finalMeasurements.summary)"
                )
            }
        }
        let recipientUnitIDs = ledger.units.filter {
            $0.deliveryRole == "recipient_content" && $0.status != "remove"
        }.map(\.id)
        let recipientUnitIDSet = Set(recipientUnitIDs)
        // structure 只描述最终正文顺序。Planner 偶尔把 style/editor/excluded
        // unit 一并列进 ordered_unit_ids；这类额外 ID 可机械删除，而缺失正文、
        // 重复正文或未知 ID 仍由下方严格集合与数量检查拒绝。
        ledger.structure = VoicePolishLedgerStructure(
            kind: ledger.structure.kind,
            orderedUnitIds: ledger.structure.orderedUnitIds.filter(recipientUnitIDSet.contains),
            numberedUnitIds: normalizedNumberedUnitIDs(
                structure: ledger.structure,
                activeRecipientUnitIDs: recipientUnitIDSet
            )
        )
        let numberedUnitIDs = ledger.structure.numberedUnitIds ?? []
        guard !recipientUnitIDs.isEmpty,
              Set(ledger.structure.orderedUnitIds) == Set(recipientUnitIDs),
              ledger.structure.orderedUnitIds.count == recipientUnitIDs.count,
              Set(numberedUnitIDs).count == numberedUnitIDs.count,
              Set(numberedUnitIDs).isSubset(of: Set(ledger.structure.orderedUnitIds)),
              ["sentence", "paragraphs", "numbered_list", "mixed", "ai_prompt"]
                .contains(ledger.structure.kind) else {
            throw VoicePolishLedgerIntegrityError.invalidLedgerReason(
                "structure_must_exactly_order_active_recipient_units"
            )
        }
        try validateDeclaredCountStructure(
            ledger: ledger,
            spans: spanByID
        )

        let referencedSpanIDs = Set(ledger.units.flatMap(\.sourceSpanIds))
        guard validSpanIDs.isSubset(of: referencedSpanIDs) else {
            let missing = validSpanIDs.subtracting(referencedSpanIDs).sorted().joined(separator: ",")
            throw VoicePolishLedgerIntegrityError.invalidLedgerReason(
                "source_spans_without_unit:\(missing)"
            )
        }

        let source = spans.map(\.text).joined()
        let requiredAudience = requiredAudienceTokens(in: source)
        let plannedAudience = Set(ledger.audience.flatMap(\.surfaceTokens))
        let audienceMentions = requiredAudience.union(plannedAudience)
        if !audienceMentions.isEmpty {
            // 受众名称正确不等于说话视角正确。关系可能延续到后面的片段，
            // 所以完整来源都须参与核对，也覆盖 ASR 在受众词中间分段的情况。
            ledger.pendingSemanticChecks?.append(VoicePolishSemanticCheck(
                id: "audience_context", kind: "audience_relation",
                claim: "独立核对谁向谁表达、每项行动或承诺由谁承担。来源中的“\(audienceMentions.sorted().joined(separator: "、"))”可能是收件人或正文第三方，Planner 分类不是答案。直接客户稿中发件方暂不承诺的边界不能变成命令客户不要承诺；原文明说要求客户执行的动作则保留。给内部收件人的下游沟通、措辞和验收要求属于任务正文。逐项对照成稿的实际主体，名字出现不代表视角正确。",
                unitIds: ledger.units.map(\.id),
                sourceSpanIds: spans.map(\.id),
                requiredEvidence: spans.map { .init(spanId: $0.id, text: $0.text) }
            ))
        }
        for unit in ledger.units where unit.deliveryRole != "recipient_content" || unit.status == "remove" {
            let evidence = unit.sourceSpanIds.compactMap { spanByID[$0] }
            ledger.pendingSemanticChecks?.append(VoicePolishSemanticCheck(
                id: "source_role_\(unit.id)", kind: "source_disposition",
                claim: "这些来源被候选计划作为非正文处置，但该分类尚未证明。逐句检查是否混有本次产出的对象名、主题、有效事实、原因、身份或收件人的行动要求；它们不能随编辑指令一起消失。明确要求不对收件人披露的内容和已撤销的值不能补回。只有最终稿保留全部应交付信息、并正确执行实际编辑要求，才能回答 supported。",
                unitIds: [unit.id], sourceSpanIds: evidence.map(\.id),
                requiredEvidence: evidence.map { .init(spanId: $0.id, text: $0.text) }
            ))
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
        for (index, correction) in ledger.corrections.enumerated() {
            let sourceIDs = Set(correction.oldSpanIds + correction.finalSpanIds)
            ledger.pendingSemanticChecks?.append(VoicePolishSemanticCheck(
                id: "correction_\(index + 1)", kind: "correction_relation",
                claim: "待核对的改口：主体=\(correction.subject)，旧值=\(correction.oldValue)，最终值=\(correction.finalValue)，呈现策略=\(correction.renderingPolicy)。这些均是待验证假设。按来源判断普通口误还是公开更正：普通口误只留最终值；原文明示已公布或按旧值执行时保留有用旧值。两种情况都须保留仍有效的原因、身份和其他事项。",
                unitIds: ledger.units.filter {
                    !Set($0.sourceSpanIds).isDisjoint(with: sourceIDs)
                }.map(\.id),
                sourceSpanIds: sourceIDs.sorted(),
                requiredEvidence: sourceEvidence(spanIDs: sourceIDs.sorted(), spans: spanByID,
                    tokens: [correction.oldValue, correction.finalValue])
            ))
        }
        return ledger
    }

    private static func numericSourceEvidence(
        spanIDs: [String], spans: [String: VoicePolishEvidenceSpan]
    ) -> [VoicePolishSourceQuote] {
        let numericKinds: Set<ProtectedFactKind> = [.number, .amount, .percentage, .date, .time]
        return spanIDs.flatMap { id in
            sourceEvidence(spanIDs: [id], spans: spans,
                tokens: protectedFactCandidates(in: spans[id]?.text ?? "")
                    .filter { numericKinds.contains($0.kind) }.map(\.sourceText))
        }
    }

    /// 只按明确标点取得值所在原文子句，不推断主语、受众或取消范围。
    private static func sourceEvidence(
        spanIDs: [String], spans: [String: VoicePolishEvidenceSpan], tokens: [String]
    ) -> [VoicePolishSourceQuote] {
        var result: [VoicePolishSourceQuote] = []
        for id in spanIDs {
            guard let text = spans[id]?.text else { continue }
            for token in tokens where !token.isEmpty {
                for range in ranges(of: token, in: text) {
                    let quote = VoicePolishSourceQuote(spanId: id, text: clause(in: text, containing: range))
                    if !result.contains(quote) { result.append(quote) }
                }
            }
        }
        return result
    }

    /// 引用真实性可由本地证明，关系是否成立由 Reviewer 承担。两者缺一不可。
    /// 每次初审和修复后的确认都必须重新回答全部检查，不能沿用上次 supported。
    static func validateSemanticReview(
        _ review: VoicePolishReviewerResult,
        ledger: VoicePolishIntentLedger,
        spans: [VoicePolishEvidenceSpan],
        allowRepairFindings: Bool = false
    ) throws {
        let pending = ledger.pendingSemanticChecks ?? []
        let answers = review.semanticChecks ?? []
        let answerIDs = answers.map(\.checkId)
        guard Set(answerIDs).count == answerIDs.count,
              Set(answerIDs) == Set(pending.map(\.id)) else {
            throw VoicePolishLedgerIntegrityError.invalidLedgerReason("semantic_checks_incomplete")
        }
        let spanByID = Dictionary(uniqueKeysWithValues: spans.map { ($0.id, $0) })
        let unitIDs = Set(ledger.units.map(\.id))
        for check in pending {
            guard !check.sourceSpanIds.isEmpty,
                  !check.unitIds.isEmpty,
                  Set(check.unitIds).isSubset(of: unitIDs),
                  let answer = answers.first(where: { $0.checkId == check.id }),
                  !answer.evidence.isEmpty,
                  Set(answer.evidence.map(\.spanId)) == Set(check.sourceSpanIds),
                  (check.requiredEvidence ?? []).allSatisfy({ required in
                      answer.evidence.contains { $0.spanId == required.spanId && $0.text.contains(required.text) }
                  }),
                  answer.evidence.allSatisfy({ quote in
                      guard let span = spanByID[quote.spanId] else { return false }
                      // 全来源核对可能含独立空行、标点或表情。只允许按本地
                      // requiredEvidence 引用该非文字 span 全文，不能从正文摘标点冒充证据。
                      let completeNonLexicalSpan = ["audience_relation", "source_disposition"].contains(check.kind)
                          && !span.text.isEmpty
                          && span.text.rangeOfCharacter(from: .alphanumerics) == nil
                          && quote.text == span.text
                          && (check.requiredEvidence ?? []).contains {
                              $0.spanId == quote.spanId && $0.text == span.text
                          }
                      return (quote.text.rangeOfCharacter(from: .alphanumerics) != nil || completeNonLexicalSpan)
                          && span.text.contains(quote.text)
                  }) else {
                throw VoicePolishLedgerIntegrityError.invalidLedgerReason(
                    "semantic_decision_unverified:\(check.id)"
                )
            }
            // 有证据的“不支持”是修稿输入。它不能作为成功结论，但也不应在
            // 进入局部修复前就抛错。修复后的成稿仍须通过新一轮完整确认。
            let hasLinkedRepair = review.issues.contains { issue in
                issue.severity == "major" && issue.type != "style_shift"
                    && !issue.repairInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !Set(issue.unitIds).isDisjoint(with: check.unitIds)
                    && !Set(issue.sourceSpanIds).isDisjoint(with: check.sourceSpanIds)
            }
            guard answer.verdict == "supported"
                    || (allowRepairFindings && review.verdict == "repair"
                        && answer.verdict == "unsupported" && hasLinkedRepair) else {
                throw VoicePolishLedgerIntegrityError.invalidLedgerReason(
                    "semantic_decision_unverified:\(check.id)"
                )
            }
        }
    }

    private static func inferredUnitKind(
        for unit: VoicePolishLedgerUnit,
        evidence: String
    ) -> String {
        switch unit.deliveryRole {
        case "style_directive":
            return "style"
        case "editor_directive", "excluded_content":
            return "constraint"
        default:
            if unit.modality == "recommended" { return "advice" }
            if unit.modality == "possible" || unit.modality == "pending" {
                return "uncertainty"
            }
            if evidence.contains("？") || evidence.contains("?") {
                return "question"
            }
            if unit.modality == "prohibited" || unit.modality == "not_promised" {
                return "constraint"
            }
            return "claim"
        }
    }

    /// `conditional` 是语义关系约束，不是 Writer 可消费的正文 fragment。Planner
    /// 偶尔会把一整段条件要求只写进 conditionals，导致关系提取正确却仍触发
    /// `source_spans_without_unit`。仅在 AI Prompt 中，把已经通过本地来源校验、
    /// 且完全未被任何 unit 处置的条件 span 原样补成正文 unit；普通漏段、被标成
    /// editor/excluded 的 span 以及非条件 span 仍由完整性门禁拒绝。
    private static func appendRecipientUnitsForUncoveredConditionalSpans(
        to ledger: inout VoicePolishIntentLedger,
        spans: [VoicePolishEvidenceSpan]
    ) {
        let referencedSpanIDs = Set(ledger.units.flatMap(\.sourceSpanIds))
        let conditionalSpanIDs = Set(ledger.conditionals.flatMap { conditional in
            conditional.condition.sourceSpanIds
                + conditional.consequences.flatMap(\.sourceSpanIds)
        })
        let missingSpans = spans.filter {
            conditionalSpanIDs.contains($0.id) && !referencedSpanIDs.contains($0.id)
        }
        guard !missingSpans.isEmpty else { return }

        var usedUnitIDs = Set(ledger.units.map(\.id))
        var startByUnitID = Dictionary(uniqueKeysWithValues: ledger.units.map { unit in
            let start = unit.sourceSpanIds.compactMap { spanID in
                spans.first(where: { $0.id == spanID })?.start
            }.min() ?? Int.max
            return (unit.id, start)
        })
        var orderedUnitIDs = ledger.structure.orderedUnitIds

        for span in missingSpans {
            let baseID = "conditional_" + String(span.id.map { character in
                character.isLetter || character.isNumber ? character : "_"
            })
            var unitID = baseID
            var suffix = 2
            while usedUnitIDs.contains(unitID) {
                unitID = "\(baseID)_\(suffix)"
                suffix += 1
            }
            usedUnitIDs.insert(unitID)
            ledger.units.append(VoicePolishLedgerUnit(
                id: unitID,
                kind: "constraint",
                deliveryRole: "recipient_content",
                finalMeaning: span.text,
                sourceSpanIds: [span.id],
                status: "keep",
                modality: "confirmed",
                exactTokens: [],
                surfaceTokens: []
            ))
            startByUnitID[unitID] = span.start
            let insertionIndex = orderedUnitIDs.firstIndex {
                (startByUnitID[$0] ?? Int.max) > span.start
            } ?? orderedUnitIDs.endIndex
            orderedUnitIDs.insert(unitID, at: insertionIndex)
        }

        ledger.structure = VoicePolishLedgerStructure(
            kind: ledger.structure.kind,
            orderedUnitIds: orderedUnitIDs,
            numberedUnitIds: ledger.structure.numberedUnitIds
        )
    }

    /// “选中的标题是准的，按标题写”同时包含当前编辑说明和应进入未来
    /// Prompt 的项目名。Planner 若把整段都标成 editor，不能连已由安全上下文
    /// 确认的标题一起删掉。这里只识别明确要求采用选中/标准标题的 AI Prompt，
    /// 并只补 canonical 本身；内部内容、明确不披露映射和普通上下文映射不触发。
    private static func appendRecipientUnitsForRequiredAIPromptMappings(
        to ledger: inout VoicePolishIntentLedger,
        spans: [VoicePolishEvidenceSpan],
        verifiedMappings: [VoicePolishLedgerContextMapping],
        fullSource: String
    ) {
        let spanByID = Dictionary(uniqueKeysWithValues: spans.map { ($0.id, $0) })
        var usedUnitIDs = Set(ledger.units.map(\.id))
        var orderedUnitIDs = ledger.structure.orderedUnitIds
        var startByUnitID = Dictionary(uniqueKeysWithValues: ledger.units.map { unit in
            let start = unit.sourceSpanIds.compactMap { spanByID[$0]?.start }.min() ?? Int.max
            return (unit.id, start)
        })
        let explicitSelectedTitlePattern = #"(?:选中(?:的)?(?:标题|名称|文本|内容)[^。！？\n]{0,24}(?:是准的|为准|正确)|(?:按|以|使用|采用)[^。！？\n]{0,12}(?:选中(?:的)?(?:标题|名称|文本|内容)|标准(?:名|名称)|标题))"#

        for (mappingIndex, mapping) in verifiedMappings.enumerated() {
            let mappingSpanIDs = Set(mapping.sourceSpanIds)
            let evidence = mapping.sourceSpanIds.compactMap { spanByID[$0]?.text }.joined()
            guard evidence.range(of: explicitSelectedTitlePattern, options: .regularExpression) != nil else {
                continue
            }
            let alreadyDelivered = ledger.units.contains { unit in
                guard unit.deliveryRole == "recipient_content",
                      unit.status != "remove",
                      !Set(unit.sourceSpanIds).isDisjoint(with: mappingSpanIDs),
                      unit.finalMeaning.contains(mapping.alias)
                        || unit.finalMeaning.contains(mapping.canonical) else {
                    return false
                }
                let unitEvidence = unit.sourceSpanIds.compactMap { spanByID[$0]?.text }.joined()
                return currentAIPromptEditorInstruction(
                    in: unitEvidence,
                    unitMeaning: unit.finalMeaning,
                    fullSource: fullSource
                ) == nil
            }
            guard !alreadyDelivered else { continue }

            let baseID = String(format: "context_title_%03d", mappingIndex + 1)
            var unitID = baseID
            var suffix = 2
            while usedUnitIDs.contains(unitID) {
                unitID = "\(baseID)_\(suffix)"
                suffix += 1
            }
            usedUnitIDs.insert(unitID)
            let label = evidence.contains("项目名") ? "项目名" : "标题"
            ledger.units.append(VoicePolishLedgerUnit(
                id: unitID,
                kind: "claim",
                deliveryRole: "recipient_content",
                finalMeaning: "\(label)：\(mapping.canonical)",
                sourceSpanIds: mapping.sourceSpanIds,
                status: "replace",
                modality: "confirmed",
                exactTokens: [mapping.canonical],
                surfaceTokens: []
            ))
            let start = mapping.sourceSpanIds.compactMap { spanByID[$0]?.start }.min() ?? Int.max
            startByUnitID[unitID] = start
            let insertionIndex = orderedUnitIDs.firstIndex {
                (startByUnitID[$0] ?? Int.max) > start
            } ?? orderedUnitIDs.endIndex
            orderedUnitIDs.insert(unitID, at: insertionIndex)
        }

        ledger.structure = VoicePolishLedgerStructure(
            kind: ledger.structure.kind,
            orderedUnitIds: orderedUnitIDs,
            numberedUnitIds: ledger.structure.numberedUnitIds
        )
    }

    /// 整篇包含命令不代表命令属于正确步骤。局部修复按 unit ID 定位，
    /// 因此必须同时检查单元与文本的绑定，避免标题占位造成后续内容全部错位。
    static func fragmentBindingIssues(
        document: VoicePolishLedgerDraftDocument,
        ledger: VoicePolishIntentLedger
    ) -> [VoicePolishReviewerIssue] {
        let activeUnits = ledger.units.filter {
            $0.deliveryRole == "recipient_content" && $0.status != "remove"
        }
        var issues: [VoicePolishReviewerIssue] = []
        for unit in activeUnits {
            let ownText = document.fragments.filter { $0.unitIds.contains(unit.id) }
                .map(\.text).joined(separator: "\n")
            for token in unit.exactTokens where !token.isEmpty && !ownText.contains(token) {
                let otherIDs = Set(document.fragments.filter {
                    !$0.unitIds.contains(unit.id) && $0.text.contains(token)
                }.flatMap(\.unitIds))
                let affected = activeUnits.filter { $0.id == unit.id || otherIDs.contains($0.id) }
                issues.append(VoicePolishReviewerIssue(
                    type: "missing", severity: "major", unitIds: affected.map(\.id),
                    sourceSpanIds: Array(Set(affected.flatMap(\.sourceSpanIds))).sorted(),
                    draftSpan: nil,
                    repairInstruction: "单元 \(unit.id) 对应的片段必须承载自身 final_meaning 和标识“\(token)”。标识出现在其他片段不算本项完成。核对涉及的片段与各自单元，修正错位内容；不得移动 id/unit_ids 或用标题替代行动，编号由程序生成。"
                ))
            }
        }
        return issues
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
            let remainingScaffolding = Set(highConfidenceOralScaffolding(in: output))
            for artifact in highConfidenceOralScaffolding(in: source)
            where remainingScaffolding.contains(artifact) {
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
                let key = protectedFactKey(fact, in: unit.finalMeaning)
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

        // 群体收件人若被完全删掉，“跟团队说……”会退化成一条没有称呼、
        // 不知道发给谁的事实陈述。客户一对一回复可自然省略“客户”，但团队、
        // 同事等群体直达消息至少要保留一个自然群体称呼。
        for audience in ledger.audience
        where audience.deliveryMode == "direct_address"
            && isGroupAudience(audience.text)
            && !groupAudienceTokens(for: audience.text).contains(where: output.contains) {
            issues.append(VoicePolishReviewerIssue(
                type: "wrong_relation",
                severity: "major",
                unitIds: ledger.structure.orderedUnitIds,
                sourceSpanIds: audience.sourceSpanIds,
                draftSpan: nil,
                repairInstruction: "用自然称呼保留群体收件人“\(audience.text)”，例如“大家/各位”，再表达正文。"
            ))
        }

        // direct_address 的正文应直接对收件人说话，不能把“给客户回一下”这类
        // 幕后转达动作原样发给客户。只在 Ledger 已确认一对一直达受众时启用。
        if ledger.audience.contains(where: {
            $0.deliveryMode == "direct_address" && ["客户", "用户", "对方"].contains($0.text)
        }), let relayRange = output.range(
            of: #"(?:给|跟)(?:客户|用户|对方)(?:回一下|回复一下|说一下|发一下)"#,
            options: .regularExpression
        ) {
            let relay = String(output[relayRange])
            issues.append(VoicePolishReviewerIssue(
                type: "task_layer",
                severity: "major",
                unitIds: ledger.structure.orderedUnitIds,
                sourceSpanIds: ledger.audience.flatMap(\.sourceSpanIds),
                draftSpan: relay,
                repairInstruction: "删除幕后转达动作“\(relay)”，改为直接对客户可发送的第二人称正文。"
            ))
        }

        let spanByID = Dictionary(uniqueKeysWithValues: spans.map { ($0.id, $0) })
        for correction in ledger.corrections {
            let unitIds = recipientUnitIDs(
                overlapping: correction.oldSpanIds + correction.finalSpanIds,
                ledger: ledger
            )
            let declaredCountIsStructurallyPreserved = explicitlyUpdatesDeclaredCount(
                correction,
                spans: spanByID
            ) && declaredCountValue(correction.finalValue).flatMap { Int($0.value) }
                == ledger.structure.numberedUnitIds?.count
            let supersededByLaterCorrection = ledger.corrections.contains { next in
                guard next.subject == correction.subject,
                      next.oldValue == correction.finalValue,
                      let currentFinal = correctionPositions(correction, spans: spanByID)?.final,
                      let nextPositions = correctionPositions(next, spans: spanByID) else { return false }
                return currentFinal == nextPositions.old && nextPositions.final > currentFinal
            }
            if !preservesToken(correction.finalValue, in: output),
               !declaredCountIsStructurallyPreserved,
               !supersededByLaterCorrection {
                issues.append(VoicePolishReviewerIssue(
                    type: "missing",
                    severity: "major",
                    unitIds: unitIds,
                    sourceSpanIds: correction.finalSpanIds,
                    draftSpan: nil,
                    repairInstruction: "恢复“\(correction.subject)”的最终值“\(correction.finalValue)”。"
                ))
            }
            if correction.renderingPolicy == "final_only",
               explicitlyUpdatesDeclaredCount(correction, spans: spanByID),
               containsDeclaredCountToken(correction.oldValue, in: output) {
                issues.append(VoicePolishReviewerIssue(
                    type: "obsolete_retained",
                    severity: "major",
                    unitIds: unitIds,
                    sourceSpanIds: correction.oldSpanIds,
                    draftSpan: correction.oldValue,
                    repairInstruction: "删除已被最终总数“\(correction.finalValue)”替代的旧声明“\(correction.oldValue)”。"
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
        where unit.deliveryRole == "recipient_content" && unit.status != "remove"
            && unit.modality == "not_promised"
            && explicitNonCommitment(in: unit.sourceSpanIds.compactMap { spanByID[$0]?.text }.joined()) {
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

    /// 条件关系的方向由本地 cue 决定，模型只负责在证据内拆出主体和后果。
    /// 若 Planner 漏填、错填枚举或把字段写成同义改写，继续请求它修 JSON
    /// 只会制造随机回退。此时退化为一条“整句、原文、固定 operator”的保守
    /// conditional：不提供模型发明的语义细分，但仍保证 only_if/if_then 等
    /// 方向不被改写，完整正文则由同一 source span 的 Writer unit 交付。
    private static func normalizedConditionals(
        _ planned: [VoicePolishLedgerConditional],
        requiredLogicCues: [VoicePolishLogicCue],
        spans: [String: VoicePolishEvidenceSpan]
    ) -> [VoicePolishLedgerConditional] {
        do {
            try validateConditionals(
                planned,
                requiredLogicCues: requiredLogicCues,
                spans: spans
            )
            return planned
        } catch {
            return requiredLogicCues.enumerated().map { index, cue in
                VoicePolishLedgerConditional(
                    id: String(format: "local_c%03d", index + 1),
                    cueIds: [cue.id],
                    operatorKind: cue.operatorKind,
                    condition: VoicePolishLedgerCondition(
                        subject: cue.text,
                        predicate: cue.text,
                        polarity: cue.operatorKind != "negative_then",
                        sourceSpanIds: cue.sourceSpanIds
                    ),
                    consequences: [VoicePolishLedgerConsequence(
                        action: cue.text,
                        polarity: true,
                        sourceSpanIds: cue.sourceSpanIds
                    )]
                )
            }
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

    /// 连续改口按原文位置连接，不能仅凭两个相同值把循环改口的最终值也作废。
    private static func correctionPositions(
        _ correction: VoicePolishLedgerCorrection,
        spans: [String: VoicePolishEvidenceSpan]
    ) -> (old: Int, final: Int)? {
        func positions(_ value: String, ids: [String]) -> [Int] {
            ids.flatMap { id -> [Int] in
                guard let span = spans[id] else { return [] }
                return ranges(of: value, in: span.text).compactMap { range in
                    guard let swiftRange = Range(range, in: span.text) else { return nil }
                    return span.start + span.text.distance(from: span.text.startIndex, to: swiftRange.lowerBound)
                }
            }
        }
        guard let final = positions(correction.finalValue, ids: correction.finalSpanIds).max(),
              let old = positions(correction.oldValue, ids: correction.oldSpanIds).filter({ $0 < final }).max()
        else { return nil }
        return (old, final)
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
            // 改口值必须完整出现于一个真实 span；不能把不相邻的片段拼成新值。
            guard correction.oldSpanIds.contains(where: { spans[$0]?.text.contains(correction.oldValue) == true }),
                  correction.finalSpanIds.contains(where: { spans[$0]?.text.contains(correction.finalValue) == true }) else {
                throw VoicePolishLedgerIntegrityError.invalidLedgerReason(
                    "correction_value_not_found_in_its_source_span"
                )
            }
            // 对象、指代和改口范围由隔离 Reviewer 逐项确认。
            // 后续即使词面完全相同也必须带来源回答，不能用裸 pass 清除。

        }
    }

    /// “部署要做三步……等一下还有一步……所以一共四步”不是普通数值关系，
    /// 但旧总数与最终总数可由同一来源、同一量词和明确补充/汇总词机械证明。
    /// 只允许旧值前能找到 correction.subject 的稳定主体核心、旧新值各唯一，
    /// 且桥接文本同时包含补充或纠正证据和最终总数证据。
    private static func explicitlyUpdatesDeclaredCount(
        _ correction: VoicePolishLedgerCorrection,
        spans: [String: VoicePolishEvidenceSpan]
    ) -> Bool {
        guard let oldCount = declaredCountValue(correction.oldValue),
              let finalCount = declaredCountValue(correction.finalValue),
              oldCount.classifier == finalCount.classifier,
              oldCount.value != finalCount.value else { return false }

        var subjectCore = correction.subject.replacingOccurrences(
            of: #"(?:步骤数|步数|条目数|项目数|项数|件数|轮数|次数|总数|数量|数)$"#,
            with: "",
            options: .regularExpression
        )
        subjectCore = subjectCore.trimmingCharacters(in: .whitespacesAndNewlines)
        guard subjectCore.count >= 2 else { return false }

        for oldID in correction.oldSpanIds {
            guard let oldSpan = spans[oldID] else { continue }
            for finalID in correction.finalSpanIds {
                guard let finalSpan = spans[finalID],
                      oldSpan.segmentID == finalSpan.segmentID else { continue }
                let segmentText = spans.values
                    .filter { $0.segmentID == oldSpan.segmentID }
                    .sorted { $0.start < $1.start }
                    .map(\.text)
                    .joined()
                let oldRanges = ranges(of: correction.oldValue, in: segmentText)
                let finalRanges = ranges(of: correction.finalValue, in: segmentText)
                guard oldRanges.count == 1,
                      finalRanges.count == 1,
                      let oldRange = oldRanges.first,
                      let finalRange = finalRanges.first,
                      NSMaxRange(oldRange) <= finalRange.location,
                      let prefixRange = Range(
                        NSRange(location: 0, length: oldRange.location),
                        in: segmentText
                      ),
                      let bridgeRange = Range(
                        NSRange(
                            location: NSMaxRange(oldRange),
                            length: finalRange.location - NSMaxRange(oldRange)
                        ),
                        in: segmentText
                      ) else { continue }
                let prefix = String(segmentText[prefixRange])
                let bridge = String(segmentText[bridgeRange])
                guard String(prefix.suffix(48)).contains(subjectCore),
                      bridge.count <= 180,
                      bridge.range(
                        of: #"(?:等一下|等等|不对|说错|更正|还有|再加|补充|漏了|少算).{0,100}(?:所以|因此|这样|那么)?(?:一共|总共|合计|共)"#,
                        options: .regularExpression
                      ) != nil else { continue }
                return true
            }
        }
        return false
    }

    private static func declaredCountValue(
        _ raw: String
    ) -> (value: String, classifier: String)? {
        let pattern = #"^\s*([零〇一二两双三四五六七八九十百千万亿\d]+)\s*(步|项|条|件|个|样|轮|次)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: raw,
                range: NSRange(raw.startIndex..<raw.endIndex, in: raw)
              ),
              let valueRange = Range(match.range(at: 1), in: raw),
              let classifierRange = Range(match.range(at: 2), in: raw),
              let value = ProtectedFactExtractor.canonicalValue(
                for: String(raw[valueRange]),
                kind: .number
              ) else { return nil }
        return (value, String(raw[classifierRange]))
    }

    private static func containsDeclaredCountToken(_ token: String, in text: String) -> Bool {
        guard let count = declaredCountValue(token) else { return false }
        return !declaredCountRanges(value: count.value, classifier: count.classifier, in: text).isEmpty
    }

    /// 总数“三步”与序数“第三步”有确定的字符边界；中英文数字等值处理。
    private static func declaredCountRanges(value: String, classifier: String, in text: String) -> [NSRange] {
        let numeral = #"零〇一二两双三四五六七八九十百千万亿\d"#
        guard let regex = try? NSRegularExpression(
            pattern: "(?<![第\(numeral)])[\(numeral)]+\\s*"
                + NSRegularExpression.escapedPattern(for: classifier) + "(?![\(numeral)])"
        ) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: text),
                  text[..<swiftRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).last != "第",
                  declaredCountValue(String(text[swiftRange]))?.value == value else { return nil }
            return match.range
        }
    }

    /// Planner 可以省略可机械恢复的 audience.surface_tokens，或把明确的
    /// “给团队发……”写成非协议枚举。这里只依据它自己引用的来源 span 和
    /// 本地识别出的显式收件人做归一，不从普通提及中猜受众。
    private static func normalizedAudiences(
        _ audiences: [VoicePolishLedgerAudience],
        spans: [String: VoicePolishEvidenceSpan],
        fullSource: String
    ) throws -> [VoicePolishLedgerAudience] {
        let validSpanIDs = Set(spans.keys)
        let requiredAudience = requiredAudienceTokens(in: fullSource)
        return try audiences.enumerated().map { index, audience in
            let text = audience.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let invalidSpanIDs = audience.sourceSpanIds.filter {
                !validSpanIDs.contains($0)
            }
            guard !text.isEmpty,
                  !audience.sourceSpanIds.isEmpty,
                  invalidSpanIDs.isEmpty else {
                throw VoicePolishLedgerIntegrityError.invalidLedgerReason(
                    "audience_invalid:index=\(index),text=\(text),"
                        + "invalid_span_ids=\(invalidSpanIDs.joined(separator: ","))"
                )
            }

            let evidence = audience.sourceSpanIds.compactMap { spans[$0]?.text }.joined()
            var tokens = audience.surfaceTokens.filter {
                !$0.isEmpty && evidence.contains($0)
            }
            if tokens.isEmpty, evidence.contains(text) {
                tokens = [text]
            }
            if tokens.isEmpty {
                let candidates = requiredAudience.filter { token in
                    evidence.contains(token)
                        && (text.contains(token) || token.contains(text))
                }
                if candidates.count == 1, let token = candidates.first {
                    tokens = [token]
                }
            }

            var deliveryMode = audience.deliveryMode
            if !["direct_address", "explicit_reference"].contains(deliveryMode),
               tokens.contains(where: requiredAudience.contains) {
                deliveryMode = "direct_address"
            }
            guard !tokens.isEmpty,
                  ["direct_address", "explicit_reference"].contains(deliveryMode)
            else {
                throw VoicePolishLedgerIntegrityError.invalidLedgerReason(
                    "audience_invalid:index=\(index),text=\(text),"
                        + "delivery_mode=\(audience.deliveryMode),surface_tokens_missing"
                )
            }
            return VoicePolishLedgerAudience(
                text: text,
                sourceSpanIds: audience.sourceSpanIds,
                surfaceTokens: Array(Set(tokens)).sorted(),
                deliveryMode: deliveryMode
            )
        }
    }

    private static func normalizedNumberedUnitIDs(
        structure: VoicePolishLedgerStructure,
        activeRecipientUnitIDs: Set<String>
    ) -> [String] {
        switch structure.kind {
        case "numbered_list":
            return structure.orderedUnitIds.filter(activeRecipientUnitIDs.contains)
        case "mixed":
            return (structure.numberedUnitIds ?? []).filter(activeRecipientUnitIDs.contains)
        default:
            return []
        }
    }

    /// “原来说三步，补充后共四步”已经把列表总数变成结构事实。最终 Ledger
    /// 必须准确指出哪四个 unit 是编号步骤；前言和“完成后启动”不能混进四步。
    private static func validateDeclaredCountStructure(
        ledger: VoicePolishIntentLedger,
        spans: [String: VoicePolishEvidenceSpan]
    ) throws {
        for correction in ledger.corrections
        where correction.renderingPolicy == "final_only"
            && explicitlyUpdatesDeclaredCount(correction, spans: spans) {
            guard let finalCount = declaredCountValue(correction.finalValue),
                  let expected = Int(finalCount.value),
                  ["numbered_list", "mixed"].contains(ledger.structure.kind),
                  ledger.structure.numberedUnitIds?.count == expected else {
                throw VoicePolishLedgerIntegrityError.invalidLedgerReason(
                    "declared_count_structure_invalid:subject=\(correction.subject),"
                        + "expected=\(correction.finalValue),"
                        + "numbered_unit_ids=\((ledger.structure.numberedUnitIds ?? []).joined(separator: ","))"
                )
            }
        }
    }

    /// 三档新路径复用现有数值、技术字符与单位检查，不要求先让模型重建 Ledger。
    /// 此处只裁决无来源新增；遗漏、改口对象与开放式语义由实际差异复核处理。
    static func sourceBackedDraftCodes(
        sourceText: String,
        outputText: String,
        scene: WritingScene,
        allowsPartialTimeReview: Bool = false
    ) -> [VoicePolishValidationCode] {
        let source = sourceText
        let output = scene == .code ? outputText
            : VoicePolishNumbering.removingContinuousNumberedLineMarkers(in: outputText)
        let normalizedSource = scene == .code ? source
            : VoicePolishNumbering.removingContinuousNumberedLineMarkers(in: source)
        let sourceKeys = facts(in: normalizedSource)
        let sourceTimes = protectedFactCandidates(in: normalizedSource)
            .filter { $0.kind == .time }.compactMap(\.canonicalValue)
        let compactSource = whitespaceInsensitive(normalizedSource)
        // 口述符号只补充技术字符的匹配来源，不得改写时间、小数或普通词语里的“点”。
        let compactTechnicalSource = whitespaceInsensitive(
            VoicePolishValidator.dictatedSymbolProjection(normalizedSource)
        )
        let unbacked = protectedFactCandidates(in: output).contains { candidate in
            if candidate.kind == .quotedPhrase { return false }
            if sourceKeys.contains(protectedFactKey(candidate, in: output)) { return false }
            if allowsPartialTimeReview, candidate.kind == .time,
               let value = candidate.canonicalValue, let separator = value.firstIndex(of: "|") {
                let day = String(value[...separator])
                let clock = String(value[value.index(after: separator)...])
                // 裸时钟与日期都有来源时只能说明可承接，归属对象仍须标准的全文复核。
                if sourceTimes.contains(clock), sourceTimes.contains(where: { $0.hasPrefix(day) }) {
                    return false
                }
            }
            switch candidate.kind {
            case .filePath, .command, .codeIdentifier, .lexiconEntity:
                let content = candidate.kind == .command && candidate.sourceText.hasPrefix("`")
                    && candidate.sourceText.hasSuffix("`")
                    ? String(candidate.sourceText.dropFirst().dropLast()) : candidate.sourceText
                let token = whitespaceInsensitive(content)
                return !compactSource.contains(token) && !compactTechnicalSource.contains(token)
            default:
                return true
            }
        }
        let measurementsHaveSources = measurementValuesHaveSources(
            source: measurementScan(in: normalizedSource),
            final: measurementScan(in: output),
            requiresCompleteCoverage: false
        )
        return unbacked || !measurementsHaveSources ? [.planIntegrityFailure] : []
    }

    private static func facts(in text: String) -> Set<String> {
        Set(protectedFacts(in: text))
    }

    /// “预算最后通过的是一万六”与“最终通过的预算是 16000”只改变语序和
    /// 数字写法。ProtectedFactExtractor 会因“预算是”是否相邻而分别抽成
    /// number/amount；在没有任何单位或币种时，把 amount 归一回 number。
    /// 一旦出现元、美元、天、月等 measurement，仍保留原 kind 并走严格门禁。
    private static func protectedFactKey(
        _ fact: SourceFactCandidate,
        in text: String
    ) -> String {
        let semanticValue = fact.canonicalValue ?? fact.sourceText
        if fact.kind == .amount {
            let scan = measurementScan(in: text)
            let hasExplicitFamily = scan.occurrences.contains {
                $0.value == semanticValue
            }
            if !hasExplicitFamily {
                return "\(ProtectedFactKind.number.rawValue)|\(semanticValue)"
            }
        }
        return "\(fact.kind.rawValue)|\(semanticValue)"
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

        /// 仅供 Planner 的证据修复定位；生产诊断仍只记录冒号前的稳定错误码。
        var summary: String {
            occurrences.map { "\($0.anchor)|\($0.value)|\($0.family)" }.joined(separator: ";")
        }
    }

    /// ProtectedFactExtractor 负责数值本身的规范化；这里额外保留容易改变原意的
    /// 时间单位、币种及其局部对象锚点。对象锚点使安全调序不依赖出现顺序，
    /// 同时拒绝把相同数值的工期与预算等关系互换；日期范围会先排除，避免把
    /// `2026-08-28` 与 `2026年8月28日` 的安全格式化误判为工期变化。
    private static func measurementScan(in text: String) -> MeasurementScan {
        let pattern = #"(?:([$¥￥]|美元|人民币)\s*)?([-+]?\d[\d,]*(?:\.\d+)?|[负零〇一二两双三四五六七八九十百千万亿点]+)\s*(万|亿)?\s*(年|个月|月|周|天|日|小时|分钟|秒|美元|人民币|元|块|个人|人|位|名)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return MeasurementScan(occurrences: [], bareValueCounts: [:])
        }
        let dateRanges = measurementDateRanges(in: text)
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: fullRange)
        let personUnits: Set<String> = ["个人", "人", "位", "名"]
        var wordEnds: Set<String.Index> = []
        if matches.contains(where: { match in
            Range(match.range(at: 4), in: text).map { personUnits.contains(String(text[$0])) } == true
        }) {
            // 数量单位不得截进后面的整词。使用项目已有的系统分词能力，
            // 区分“两个｜人”与“一个｜人工智能”，不维护业务词语特判表。
            let tokenizer = NLTokenizer(unit: .word)
            tokenizer.string = text
            tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
                wordEnds.insert(range.upperBound)
                return true
            }
        }
        var occurrences: [MeasurementOccurrence] = []
        var bareValueCounts: [String: Int] = [:]
        for match in matches {
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
            if unit == "块", prefix.isEmpty,
               let wholeRange = Range(match.range, in: text),
               text[..<wholeRange.lowerBound].last.map({ "这那哪每".contains($0) }) == true {
                // “这一块内容”中的块是普通量词，不是人民币单位。
                continue
            }
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
                case "个人", "人", "位", "名":
                    // “第一名 / 第一位”描述名次或顺序，不是人数；允许
                    // “冠军 / 首位”等等义表达，关系仍交由冷复核确认。
                    let beforeNumber = text[..<numberRange.lowerBound]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard beforeNumber.last != "第",
                          let wholeRange = Range(match.range, in: text),
                          wordEnds.contains(wholeRange.upperBound) else { return nil }
                    return "count_person"
                default: return nil
                }
            }()
            let isCalendarYear = unit == "年" && Int(value).map { (1000...2999).contains($0) } == true
            let anchor = isCalendarYear ? "#calendar_year" : measurementAnchor(in: text, matchRange: match.range)
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
            occurrences: deduplicatedSourceMeasurements(scans.flatMap(\.occurrences)),
            bareValueCounts: bareValueCounts
        )
    }

    private static func measurementValuesHaveSources(
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

        // 这里只证明数值、单位与数量有来源，绝不证明对象关系。
        // 调用方为每个带测量的正文单元建立必须回答的冷复核项。
        var sourceMatch = Array(repeating: -1, count: source.occurrences.count)
        func assign(_ finalIndex: Int, visited: inout Set<Int>) -> Bool {
            let candidate = final.occurrences[finalIndex]
            for sourceIndex in source.occurrences.indices {
                let evidence = source.occurrences[sourceIndex]
                guard candidate.value == evidence.value,
                      candidate.family == evidence.family else { continue }
                // 只标记实际存在的边；提前标记不兼容节点会阻断后续增广路径，
                // 使同值事实的合法重排依赖遍历顺序。
                guard visited.insert(sourceIndex).inserted else { continue }
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
        corrections.filter {
            $0.renderingPolicy == "final_only" && $0.oldSpanIds.contains(spanID)
        }.flatMap { correction in
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
            let totalOldOccurrences = correction.oldSpanIds.reduce(0) { count, id in
                count + ranges(of: correction.oldValue, in: spans[id]?.text ?? "").count
            }
            let uniquelyLocated = totalOldOccurrences == 1 ? valueRanges : []
            return Array(Set(strictlyBound + locallyPaired + uniquelyLocated))
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
        // 非 measurement 的指代可以跨逗号承接，保留在同一句来源范围内，
        // 具体关系仍须冷复核；金额与工期已在上面走严格对象锚点。
        return sentence(in: text, containing: range).contains(subject)
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

    private static func sentence(in text: String, containing range: NSRange) -> String {
        guard let stringRange = Range(range, in: text) else { return "" }
        let delimiters: Set<Character> = ["。", "！", "？", "!", "?", "\n"]
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
            let token = String(source[swiftRange])
            if token.count == 1, ["嗯", "呃", "额"].contains(token) {
                let before = source[..<swiftRange.lowerBound].last
                let after = source[swiftRange.upperBound...].first
                guard before.map({ $0.isWhitespace || $0.isPunctuation }) ?? true,
                      after.map({ $0.isWhitespace || $0.isPunctuation }) ?? true else { continue }
            }
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
        if declaredCountValue(token) != nil {
            return containsDeclaredCountToken(token, in: output)
        }
        if let clock = ProtectedFactExtractor.canonicalValue(for: token, kind: .time) {
            // “十点”是“十点半”的子串，但二者不是同一个时间事实。
            return protectedFactCandidates(in: output).contains {
                $0.kind == .time && ($0.canonicalValue == clock
                    || (!clock.contains("|") && $0.canonicalValue?.hasSuffix("|" + clock) == true))
            }
        }
        let exactNumericFacts = protectedFactCandidates(in: token).filter {
            $0.sourceText == token && [.number, .amount, .percentage, .date, .version].contains($0.kind)
        }
        if !exactNumericFacts.isEmpty {
            return Set(exactNumericFacts.map { protectedFactKey($0, in: token) })
                .isSubset(of: Set(protectedFacts(in: output)))
        }
        if output.contains(token) { return true }
        let tokenFacts = protectedFacts(in: token)
        guard !tokenFacts.isEmpty else { return false }
        let outputFacts = Set(protectedFacts(in: output))
        return Set(tokenFacts).isSubset(of: outputFacts)
    }

    private static func protectedFacts(in text: String) -> [String] {
        protectedFactCandidates(in: text).map { protectedFactKey($0, in: text) }
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

    private static func isGroupAudience(_ audience: String) -> Bool {
        ["团队", "大家", "同事", "开发", "产品组", "老师", "他们", "她们"]
            .contains(audience)
    }

    private static func groupAudienceTokens(for audience: String) -> [String] {
        switch audience {
        case "开发": return ["开发", "研发", "各位", "大家", "同事"]
        case "产品组": return ["产品组", "产品同事", "各位", "大家", "同事"]
        case "老师": return ["老师", "各位", "大家"]
        case "他们", "她们": return [audience, "各位", "大家"]
        default: return [audience, "各位", "大家", "同事"]
        }
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
