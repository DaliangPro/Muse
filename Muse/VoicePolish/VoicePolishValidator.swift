import Foundation
import NaturalLanguage

struct VoicePolishValidationResult: Sendable, Equatable {
    let codes: [VoicePolishValidationCode]

    var hasHardFailure: Bool {
        codes.contains(where: \.isHardFailure)
    }
}

enum VoicePolishValidator {

    struct SupersededFactOccurrence: Hashable, Sendable {
        let factIndex: Int
        let segmentIndex: Int
        let offset: Int
        let length: Int
        let globalOffset: Int
        let replacementFactIndex: Int?
        let relationAnchor: String?
        let factDescriptor: String?
        let replacementDescriptor: String?

        var globalEndOffset: Int { globalOffset + length }
    }

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
        let preservedDeclaredCount = VoicePolishListCountConsistency
            .preservedDeclaredCountEvidence(
                in: output,
                canonicalSource: request.fallbackText
            )
        let supersededOccurrences = locallySupersededFactOccurrences(
            request: request,
            sourceFacts: sourceFacts
        )
        let supersededFactIndices = locallySupersededFactIndices(
            request: request,
            sourceFacts: sourceFacts
        )

        if sourceFacts.enumerated().contains(where: { index, fact in
            !supersededFactIndices.contains(index)
                && !containsEquivalent(fact, in: outputFacts, output: output)
                && preservedDeclaredCount?.satisfiesSourceFact(fact) != true
        }) {
            append(.missingProtectedFact, to: &codes)
        }
        if outputFacts.contains(where: { outputFact in
            !sourceFacts.contains(where: { equivalent($0, outputFact) })
                && !isSourceBackedFormattingFact(
                    outputFact,
                    request: request
                )
                && preservedDeclaredCount?.backsCandidateFact(outputFact) != true
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
        appendSupersededRelationCodes(
            output: output,
            sourceFacts: sourceFacts,
            supersededOccurrences: supersededOccurrences,
            fullySupersededFactIndices: supersededFactIndices,
            to: &codes
        )
        appendDeliberateRepetitionCodes(output: output, request: request, to: &codes)
        appendUnchangedDraftCode(output: output, request: request, to: &codes)
        appendSemanticBoundaryCodes(output: output, request: request, to: &codes)
        appendTerminologyEditCodes(output: output, request: request, to: &codes)
        appendOutputLayoutCodes(output, request: request, to: &codes)
        return VoicePolishValidationResult(codes: codes)
    }

    /// 极短口语里的重复不都属于口吃。三连回应词和少数双词强调具有明确的
    /// 语气功能；模型若机械压成一次，会把“行行行”从带情绪的确认改成普通
    /// 应答。这里只收录高置信模式，避免把“我我”“今天今天”等口吃误保留。
    static func deliberateRepetitionPhrases(in text: String) -> [String] {
        guard text.count <= 32 else { return [] }
        let normalized = normalizedNaturalText(text)
        var phrases: [String] = []
        for word in ["真的", "确实", "特别", "绝对", "非常"] {
            let phrase = word + word
            if normalized.contains(normalizedNaturalText(phrase)),
               hasUnretractedOccurrence(of: phrase, in: text) {
                phrases.append(phrase)
            }
        }
        for word in ["行", "对", "好"] {
            let phrase = String(repeating: word, count: 3)
            if hasDelimitedResponsePhrase(phrase, in: text),
               hasUnretractedOccurrence(of: phrase, in: text) {
                phrases.append(phrase)
            }
        }
        return Array(Set(phrases)).sorted()
    }

    private static func hasUnretractedOccurrence(of phrase: String, in text: String) -> Bool {
        allRanges(of: phrase, in: text).contains { range in
            let nearbySuffix = String(text[range.upperBound...].prefix(18))
            var normalizedSuffix = normalizedNaturalText(nearbySuffix).lowercased()
            // 口述里常在真正的改口词前夹一个“呃/那个”。这些填充词不能把
            // 已经撤回的强调伪装成仍需保护的有意重复。
            let correctionFillers = ["嗯", "呃", "额", "那个", "就是", "然后"]
            var removedFiller = true
            while removedFiller {
                removedFiller = false
                for filler in correctionFillers where normalizedSuffix.hasPrefix(filler) {
                    normalizedSuffix.removeFirst(filler.count)
                    removedFiller = true
                    break
                }
            }
            let immediateCorrectionSignals = [
                "不对", "我改一下", "我说错了", "说错了", "我的意思是",
                "应该是", "最后改成", "改成", "改为", "调整为", "现定为",
                "scratchthat", "imean", "actually",
            ]
            return !immediateCorrectionSignals.contains(where: normalizedSuffix.hasPrefix)
        }
    }

    private static func hasDelimitedResponsePhrase(_ phrase: String, in text: String) -> Bool {
        guard let range = text.range(of: phrase) else { return false }
        let hasLeftBoundary = range.lowerBound == text.startIndex
            || text[text.index(before: range.lowerBound)].isWhitespace
            || text[text.index(before: range.lowerBound)].isPunctuation
        let hasRightBoundary = range.upperBound == text.endIndex
            || text[range.upperBound].isWhitespace
            || text[range.upperBound].isPunctuation
        guard hasLeftBoundary else { return false }
        if hasRightBoundary { return true }

        // ASR 经常不在句首三连回应后补停顿：“行行行我知道了”“对对对我明白”。
        // “行/对”的句首三连本身已经是高置信语用回应；“好好好”则只在后面
        // 明确进入人称或行动小句时保护，避免把“好｜好像可以”的起步重来误保留。
        if phrase == "行行行" || phrase == "对对对" { return true }
        guard phrase == "好好好" else { return false }
        let suffix = String(text[range.upperBound...])
        let independentStarts = [
            "我", "你", "他", "她", "它", "我们", "你们", "他们",
            "这", "那", "就", "先", "马上", "现在", "请",
        ]
        return independentStarts.contains(where: suffix.hasPrefix)
    }

    private static func appendDeliberateRepetitionCodes(
        output: String,
        request: VoicePolishRequest,
        to codes: inout [VoicePolishValidationCode]
    ) {
        let normalizedOutput = normalizedNaturalText(output)
        if deliberateRepetitionPhrases(in: request.fallbackText).contains(where: {
            !normalizedOutput.contains(normalizedNaturalText($0))
        }) {
            append(.missingProtectedFact, to: &codes)
        }
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

    /// 不在本地对模型成稿做语义改写。过去这里按少量测试夹具删除固定短语，
    /// 会把“先别改路径”“不是故障”等真实否定意图一并删掉。语义整理必须由
    /// 模型完成并接受校验；本地层只负责验证，不能静默替用户改意思。
    static func removingDeterministicDraftArtifacts(
        from output: String,
        request: VoicePolishRequest
    ) -> String? {
        _ = output
        _ = request
        return nil
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
    static func dictatedSymbolProjection(_ source: String) -> String {
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

    /// 把代码口述里可以确定性恢复的完整路径与命令作为显式证据交给模型。
    /// 路径每一层都按口述顺序保留，不能因为目录名与文件名前缀相同而去重；
    /// 命令只在已口述的 flag 后合并明显的 CamelCase 测试标识符。
    static func dictatedCodeArtifacts(in request: VoicePolishRequest) -> [String] {
        guard request.context.scene == .code else { return [] }
        let projected = dictatedSymbolProjection(request.fallbackText)
            .replacingOccurrences(
                of: #"\s*/\s*"#,
                with: "/",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"\s*\.\s*(?=[A-Za-z])"#,
                with: ".",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"\s*--\s*([A-Za-z])"#,
                with: " --$1",
                options: .regularExpression
            )
        var artifacts: [String] = []

        let pathPattern = #"(?i)(?:[A-Za-z][A-Za-z0-9_ ]*/)+[A-Za-z][A-Za-z0-9_ ]*\.[A-Za-z][A-Za-z0-9_]*"#
        for match in regexMatches(pathPattern, in: projected) {
            let path = match.split(separator: "/", omittingEmptySubsequences: false)
                .map { component in component.filter { !$0.isWhitespace } }
                .joined(separator: "/")
            if path.contains("/"), path.contains(".") { artifacts.append(path) }
        }

        let commandPattern = #"(?i)(?<![A-Za-z0-9_])(?:swift|git|xcodebuild|python3?|bash|sh|npm|pnpm|yarn)\s+[^，。！？!?\n]+"#
        for rawCommand in regexMatches(commandPattern, in: projected) {
            var tokens = rawCommand.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            if let filterIndex = tokens.firstIndex(of: "--filter"),
               tokens.indices.contains(filterIndex + 2) {
                let identifier = tokens[(filterIndex + 1)...].joined()
                tokens.replaceSubrange((filterIndex + 1)..., with: [identifier])
            }
            let command = tokens.joined(separator: " ")
            if tokens.count >= 2 { artifacts.append(command) }
        }
        return Array(Set(artifacts)).sorted()
    }

    private static func regexMatches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            return String(text[matchRange]).trimmingCharacters(in: .whitespacesAndNewlines)
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
        let sourceAlreadyMentionsExecution = request.fallbackText.range(
            of: #"执行\s*`?codesign`?"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
        let draftExecutesCodeSign = output.range(
            of: #"执行\s*`?codesign`?"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
        if sourceChecksCodeSign, !sourceAlreadyMentionsExecution, draftExecutesCodeSign {
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

        // 句末只剩“汇总如下”却没有正文，是可由结构直接证明的未完成成稿。
        // 不再按测试夹具里的完整句子做本地语义改写或判定。
        let danglingSummaryLeadIn = ["汇总如下", "总结如下", "整理如下"].contains {
            draft.hasSuffix($0)
        }
        if danglingSummaryLeadIn {
            append(.planIntegrityFailure, to: &codes)
        }

        // 用户明确表示英文原话不可靠且只保留中文时，任何连续三词以上的英文
        // 都属于未经确认的补写。规则只看语用证据，不绑定某一句测试答案。
        let sourceMarksEnglishUncertain = source.contains("英文原话")
            && ["记不准", "没记准", "没记清", "不确定"].contains(where: source.contains)
            && ["保留中文", "只留中文", "不要猜", "别猜"].contains(where: source.contains)
        if sourceMarksEnglishUncertain,
           output.range(
               of: #"(?i)(?:\b[a-z][a-z'’\-]*\b[\s,，]*){3,}"#,
               options: .regularExpression
           ) != nil {
            append(.planIntegrityFailure, to: &codes)
        }

        // 只把明确指向“如何写成稿”的话当幕后指令；“给开发说先别改路径”
        // 是收件人要执行的正文，不能因含“别”字就删除。若输出仍逐字保留这类
        // 写作指令，或只是换一种幕后措辞复述，则触发修复。
        let sourceMetaSpans = editorInstructionSpans(in: request)
        let repeatsMetaSpan = sourceMetaSpans.contains { !$0.isEmpty && draft.contains($0) }
        let paraphrasesMetaInstruction = !sourceMetaSpans.isEmpty && [
            #"(?:语气|措辞).{0,8}(?:不用|不要|别).{0,4}(?:重|强)"#,
            #"(?:不列入|别放|不要放).{0,8}(?:正文|成稿|已确定)"#,
            #"(?:不要|别).{0,6}(?:确定|猜).{0,8}(?:版本|名称|名字|日期)"#,
        ].contains { draft.range(of: $0, options: .regularExpression) != nil }
        if repeatsMetaSpan || paraphrasesMetaInstruction {
            append(.promptLeakage, to: &codes)
        }

        let excludedClaims = excludedDisclosureClaims(in: request)
        if excludedClaims.contains(where: { claim in
            let normalizedClaim = normalizedNaturalText(claim)
            return normalizedClaim.count >= 3 && draft.contains(normalizedClaim)
        }) {
            append(.excludedSideNoteLeaked, to: &codes)
        }

        appendProtectedNegativeIntentCodes(
            output: output,
            request: request,
            to: &codes
        )
    }

    /// 返回明确只用于指导成稿、不能逐字进入正文的本地片段。判断以语用证据
    /// 为主：明确指向“这句/正文/已确定事项”的编辑要求始终属于幕后；“别替
    /// 我猜”只有在没有收件人指向、也不是“名称未确认，先保留”这类完整对外
    /// 意图时才按幕后处理，避免再按场景一刀切。
    static func editorInstructionSpans(in request: VoicePolishRequest) -> [String] {
        let source = request.fallbackText
        let explicitPatterns = [
            #"(?:这个|这句|这段|这部分|上面这(?:句|段)|以下内容).{0,14}(?:别写|不要写|不用展开|别展开|不要展开|别放|不要放)"#,
            #"(?:不要|别)(?:对客户)?(?:说|写|告诉).{0,18}(?:操作问题|内部原因|猜测)"#,
        ]
        var spans = explicitPatterns.flatMap { matchedNormalizedSpans($0, in: source) }

        let ambiguousPattern = #"(?:不要|别)(?:替我|帮我).{0,14}(?:确定|猜|补写|编)"#
        guard let regex = try? NSRegularExpression(pattern: ambiguousPattern) else {
            return Array(Set(spans)).sorted()
        }
        let fullRange = NSRange(source.startIndex..<source.endIndex, in: source)
        for match in regex.matches(in: source, range: fullRange) {
            guard let matchRange = Range(match.range, in: source) else { continue }
            let clauseRange = localSentenceRange(containing: matchRange, in: source)
            let clause = normalizedNaturalText(String(source[clauseRange]))
            let recipientFacingIntent = containsRecipientCue(clause)
            let explicitEditorCue = [
                "润色器", "模型", "成稿", "正文", "编辑要求", "幕后提醒", "只写",
                "不要放入", "别放入", "不要写进", "别写进",
            ].contains(where: clause.contains)
            guard explicitEditorCue, !recipientFacingIntent else { continue }
            spans.append(normalizedNaturalText(String(source[matchRange])))
        }
        return Array(Set(spans.filter { !$0.isEmpty })).sorted()
    }

    /// 给 Fast repair 的待确认内容。这里只返回带有明确未决状态或外部确认条件
    /// 的完整局部小句，并先移除已识别的幕后编辑片段；模型必须保留事项与状态，
    /// 但不能把“别放进已确定事项”继续写给读者。
    static func pendingEditorialItems(in request: VoicePolishRequest) -> [String] {
        let editorSpans = editorInstructionSpans(in: request)
        return semanticClauses(in: request.fallbackText).compactMap { rawClause in
            var clause = normalizedNaturalText(rawClause)
            guard ["未确认", "没确认", "尚未确认", "未定", "没定", "待定", "要等", "等待"].contains(
                where: clause.contains
            ) else { return nil }
            for span in editorSpans where !span.isEmpty {
                clause = clause.replacingOccurrences(of: span, with: "")
            }
            clause = clause.trimmingCharacters(in: .whitespacesAndNewlines)
            guard clause.count >= 4,
                  !["另外还有一个没定的是", "还有一个没定的是", "另有一项待定"].contains(clause) else {
                return nil
            }
            return clause
        }
    }

    /// 从“明确禁止向客户披露”的内部判断中提取核心 claim。只有客服场景、
    /// 内部不确定判断与相邻披露禁令同时存在时才启用；普通的“原因尚未确认”
    /// 不会被当作秘密，用户主动要求告知客户某个未确认可能性时也不会触发。
    static func excludedDisclosureClaims(in request: VoicePolishRequest) -> [String] {
        guard request.context.scene == .customerSupport else { return [] }
        let clauses = semanticClauses(in: request.fallbackText)
        let disclosureVetoes = [
            "不要告诉客户", "别告诉客户", "先不要告诉客户", "暂时不要告诉客户",
            "不要对客户说", "别对客户说", "不要写给客户", "别写给客户",
        ]
        let internalSignals = [
            "内部看", "内部判断", "内部初步判断", "内部猜测", "内部推测",
            "我们内部看", "我们内部判断", "我们内部猜测", "我们内部推测",
        ]
        var claims: [String] = []
        for (index, rawClause) in clauses.enumerated() {
            let clause = normalizedNaturalText(rawClause)
            guard internalSignals.contains(where: clause.contains),
                  ["可能", "初步", "猜测", "推测", "怀疑"].contains(where: clause.contains) else {
                continue
            }
            let nearby = clauses[max(0, index - 1)...min(clauses.count - 1, index + 1)]
                .map(normalizedNaturalText)
                .joined()
            guard disclosureVetoes.contains(where: nearby.contains) else { continue }

            var claim = clause
            for signal in internalSignals.sorted(by: { $0.count > $1.count }) {
                if let range = claim.range(of: signal) {
                    claim = String(claim[range.upperBound...])
                    break
                }
            }
            for prefix in ["初步判断", "初步认为", "可能是", "可能与", "可能跟", "可能和", "怀疑是", "推测是", "是"] {
                if claim.hasPrefix(prefix) {
                    claim.removeFirst(prefix.count)
                    break
                }
            }
            for suffix in ["这个原因", "该原因", "这个判断", "该判断", "目前没有确认", "目前未确认", "尚未确认", "没有确认", "未确认"] {
                if let range = claim.range(of: suffix) {
                    claim = String(claim[..<range.lowerBound])
                    break
                }
            }
            if claim.count >= 3 { claims.append(claim) }
        }
        return Array(Set(claims)).sorted()
    }

    private static func matchedNormalizedSpans(
        _ pattern: String,
        in source: String
    ) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.matches(in: source, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: source) else { return nil }
            return normalizedNaturalText(String(source[matchRange]))
        }
    }

    private static func localSentenceRange(
        containing target: Range<String.Index>,
        in source: String
    ) -> Range<String.Index> {
        let boundaries = CharacterSet(charactersIn: "。！？!?；;\n")
        var lower = target.lowerBound
        while lower > source.startIndex {
            let previous = source.index(before: lower)
            guard source[previous].unicodeScalars.allSatisfy({ !boundaries.contains($0) }) else {
                break
            }
            lower = previous
        }
        var upper = target.upperBound
        while upper < source.endIndex {
            guard source[upper].unicodeScalars.allSatisfy({ !boundaries.contains($0) }) else {
                break
            }
            upper = source.index(after: upper)
        }
        return lower..<upper
    }

    /// 保护用户真正要传达给收件人的否定要求与否定事实。这里只覆盖本地可以
    /// 高置信证明的三类表达：明确禁止某个动作、明确否认故障状态，以及
    /// “不是不愿意/不想……”这类态度澄清。写作幕后指令仍由上面的 meta 规则
    /// 处理，不能因为同样含“不要/别”就混为一谈。
    private static func appendProtectedNegativeIntentCodes(
        output: String,
        request: VoicePolishRequest,
        to codes: inout [VoicePolishValidationCode]
    ) {
        if !protectedNegativeIntentFailures(output: output, request: request).isEmpty {
            append(.missingProtectedFact, to: &codes)
        }
    }

    /// 返回本地可说明的否定意图缺失原因，供回归测试定位误报；生产只把非空
    /// 结果折叠为一个 missingProtectedFact，不把用户正文写入日志。
    static func protectedNegativeIntentFailures(
        output: String,
        request: VoicePolishRequest
    ) -> [String] {
        let source = request.fallbackText
        // 长口述中的否定约束往往会被自然改写，靠局部字面规则无法可靠证明
        // “遗漏”还是“同义表达”。把这里限定为短消息的高置信兜底，避免
        // validator 因误报把已经完成的长文整段退回原文；长文完整性由逐项
        // claim/关系门禁和真实质量集共同验收。
        guard source.count <= 300 else { return [] }
        let outputClauses = semanticClauses(in: output)
        var failures: [String] = []

        for action in recipientFacingNegativeActions(in: source, scene: request.context.scene) {
            let normalizedAction = normalizedNaturalText(action)
            guard !normalizedAction.isEmpty else { continue }
            let variants = negativeActionVariants(for: normalizedAction)
                .sorted { $0.count > $1.count }
            var hasNegatedAction = false
            var hasAffirmedAction = false
            for clause in outputClauses {
                let normalizedClause = normalizedNaturalText(clause)
                let preservesByInverseState = inverseStatePreservesNegativeAction(
                    action: normalizedAction,
                    clause: normalizedClause
                )
                if preservesByInverseState {
                    hasNegatedAction = true
                }
                var occurrences: [(range: Range<String.Index>, variant: String)] = []
                for variant in variants {
                    var searchStart = normalizedClause.startIndex
                    while searchStart < normalizedClause.endIndex,
                          let range = normalizedClause.range(
                            of: variant,
                            range: searchStart..<normalizedClause.endIndex
                          ) {
                        occurrences.append((range, variant))
                        searchStart = range.upperBound
                    }
                }
                // “修改方案”同时包含较短变体“改方案”。只让最长、互不重叠的
                // 动作命中参与极性判断，避免较短子串从否定范围中漏出来，反把
                // “先不要修改方案”判成既否定又肯定。
                var selectedRanges: [Range<String.Index>] = []
                for occurrence in occurrences.sorted(by: {
                    if $0.variant.count != $1.variant.count {
                        return $0.variant.count > $1.variant.count
                    }
                    return $0.range.lowerBound < $1.range.lowerBound
                }) {
                    guard !selectedRanges.contains(where: { $0.overlaps(occurrence.range) }) else {
                        continue
                    }
                    selectedRanges.append(occurrence.range)
                    if preservesByInverseState,
                       occurrence.variant != normalizedAction {
                        // “第一版不包含搜索功能”会自然出现较短概念词“搜索”，
                        // 但它属于已证明的排除状态，不是肯定执行“做复杂搜索”。
                        continue
                    }
                    if actionIsLocallyNegated(in: normalizedClause, range: occurrence.range) {
                        hasNegatedAction = true
                    } else {
                        hasAffirmedAction = true
                    }
                }
            }
            if !hasNegatedAction || hasAffirmedAction {
                failures.append("negative_action:\(normalizedAction)")
            }
        }

        for requirement in excludedScopeRequirements(in: source) {
            if !outputPreservesExcludedScope(requirement, output: output) {
                failures.append("excluded_scope:\(requirement.item)->\(requirement.scope)")
            }
        }

        let normalizedOutput = normalizedNaturalText(output)
        for requirement in deferredActionOrders(in: source) {
            guard let deferredRange = firstRange(
                ofAny: negativeActionVariants(for: requirement.deferredAction),
                in: normalizedOutput
            ),
            let prerequisiteRange = firstRange(
                ofAny: negativeActionVariants(for: requirement.prerequisiteAction),
                in: normalizedOutput
            ) else {
                // 开放式同义改写无法靠字面规则证明遗漏；这里只拦截两项动作都
                // 明确出现、但顺序仍与原意相反的高置信情况。
                continue
            }
            if deferredRange.lowerBound < prerequisiteRange.lowerBound {
                failures.append(
                    "deferred_action_order:\(requirement.prerequisiteAction)->\(requirement.deferredAction)"
                )
            }
        }

        let failureStates = [
            "坏了", "故障", "损坏", "失效", "出问题", "崩了", "不可用", "无法使用",
        ]
        if containsNegatedTerm(in: source, terms: failureStates),
           !containsNegatedTerm(in: output, terms: failureStates) {
            failures.append("negated_failure_state")
        }

        for attitude in clarifiedPositiveAttitudes(in: source) {
            if !containsPositiveAttitude(attitude, in: output) {
                failures.append("clarified_attitude:\(normalizedNaturalText(attitude))")
            }
        }
        return failures
    }

    private static let negativeMarkers = [
        "先不要", "先别", "不要", "别", "请勿", "不得", "禁止", "暂不", "不能",
        "不是", "并非", "没有", "未", "无",
    ]

    private struct DeferredActionOrder {
        let deferredAction: String
        let prerequisiteAction: String
    }

    private struct ExcludedScopeRequirement {
        let item: String
        let scope: String
    }

    private static func semanticClauses(in text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: "，,。！？!?；;：:\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func recipientFacingNegativeActions(
        in text: String,
        scene: WritingScene
    ) -> [String] {
        let markerPattern = #"(?:先不要|先别|不要|别|请勿|不得|禁止|暂不)"#
        guard let regex = try? NSRegularExpression(pattern: markerPattern) else { return [] }
        let explicitMetaSignals = [
            "正文", "成稿", "这句", "这段", "这部分", "上面这句", "上面这段",
            "措辞", "语气", "不要替我", "别替我", "不用展开", "不要展开", "别展开",
        ]
        let disclosureMetaSignals = [
            "不要对客户说", "别对客户说", "不要告诉客户", "别告诉客户",
            "不要写给客户", "别写给客户",
        ]
        let disclosureObjects = ["内部原因", "猜测", "操作问题", "旁注"]
        var actions: [String] = []

        for clause in semanticClauses(in: text) {
            let normalizedClause = normalizedNaturalText(clause)
            if !excludedScopeRequirements(in: normalizedClause).isEmpty {
                // “搜索功能暂不纳入第一版”是 item×scope 的状态关系，不是一个
                // 缺少宾语的永久禁止动作“不要纳入”。由 typed scope gate 校验。
                continue
            }
            if explicitMetaSignals.contains(where: normalizedClause.contains) {
                continue
            }
            if disclosureMetaSignals.contains(where: normalizedClause.contains),
               disclosureObjects.contains(where: normalizedClause.contains) {
                continue
            }
            if (scene == .code || scene == .aiPrompt),
               !containsRecipientCue(normalizedClause) {
                // “先别改路径和命令”这类位于代码记录或 Prompt 末尾的要求，
                // 默认是给润色器的幕后约束；只有明确说给某个收件人时才作为
                // 正文中的禁止动作保护。
                continue
            }
            let searchRange = NSRange(clause.startIndex..<clause.endIndex, in: clause)
            let markerRanges = regex.matches(in: clause, range: searchRange).compactMap {
                Range($0.range, in: clause)
            }.filter { range in
                let marker = String(clause[range])
                guard marker == "别" else { return true }
                if range.lowerBound > clause.startIndex {
                    let previous = clause[clause.index(before: range.lowerBound)]
                    if "特个分类区告差辨识".contains(previous) { return false }
                }
                if range.upperBound < clause.endIndex,
                   "人的处样".contains(clause[range.upperBound]) {
                    return false
                }
                return true
            }

            for (index, markerRange) in markerRanges.enumerated() {
                let marker = String(clause[markerRange])
                var actionEnd = clause.endIndex
                if markerRanges.indices.contains(index + 1) {
                    actionEnd = markerRanges[index + 1].lowerBound
                    if actionEnd > markerRange.upperBound {
                        let previous = clause.index(before: actionEnd)
                        if clause[previous] == "也" { actionEnd = previous }
                    }
                }
                var action = String(clause[markerRange.upperBound..<actionEnd])
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if isDeferredOrderingInstruction(action) {
                    // “不要先 A 再 B / 不要马上 A，先 B”约束的是顺序，不是
                    // 永久禁止 A。顺序由 deferredActionOrders 单独做高置信校验。
                    continue
                }

                // ASR 常把“不要覆盖安装先跑测试”压成一个无标点句。第二个
                // “先 + 明确动作”是新行动，不属于前面的禁止对象；若本句以
                // “把/将”起头，则“先”更可能是同一动作内部的先后修饰，不切。
                if !action.hasPrefix("把"), !action.hasPrefix("将"), action.count > 2 {
                    let boundarySearchStart = action.index(
                        action.startIndex,
                        offsetBy: min(2, action.count)
                    )
                    let boundaryPattern = #"(?:然后|接着|随后|同时|另外|而后|再|(?<!优)先)(?=(?:把|将|去|做|跑|导出|发送|发|修改|改|删除|删|重启|检查|核对|打开|关闭|启动|停止|提交|同步|确认|整理|等待|保留))"#
                    if let boundary = action.range(
                        of: boundaryPattern,
                        options: .regularExpression,
                        range: boundarySearchStart..<action.endIndex
                    ) {
                        action = String(action[..<boundary.lowerBound])
                    }
                }
                if marker == "别",
                   ["看", "说", "提"].contains(where: action.hasPrefix) {
                    // “别看今天下雨”“别说三天”“别提多开心”是让步/程度
                    // 表达，不是收件人的禁止动作；开放语义不能作为硬回退依据。
                    continue
                }
                for prefix in ["把", "将"] where action.hasPrefix(prefix) {
                    action.removeFirst(prefix.count)
                    break
                }
                if let connector = action.range(
                    of: #"(?:第[一二三四五六七八九十]+(?!版)|第一版|最后|然后|再|同时|另外|而是|只要|只需|只|改为|改成)"#,
                    options: .regularExpression
                ) {
                    action = String(action[..<connector.lowerBound])
                }
                action = action.trimmingCharacters(in: .whitespacesAndNewlines)
                if scene == .customerSupport,
                   ["说", "告诉客户", "写给客户", "承诺"].contains(where: action.hasPrefix) {
                    // 客服口述中的“别说内部原因 / 不要告诉客户未确认信息 / 别承诺
                    // 一定修好”是在规定成稿边界，不是要逐字写给客户的禁止动作。
                    continue
                }
                if (2...24).contains(normalizedNaturalText(action).count) {
                    actions.append(action)
                }
            }
        }
        return Array(Set(actions)).sorted()
    }

    private static func excludedScopeRequirements(in text: String) -> [ExcludedScopeRequirement] {
        let scopes = "第一版|本版|这版|当前版本|本期|本轮|范围|计划"
        let patterns = [
            #"^([\p{Han}A-Za-z0-9._/-]{2,24}?)(?:暂不|不再|不予|未|没有)(?:纳入|列入|加入|包含在|包含于)("#
                + scopes + #")$"#,
            #"^("# + scopes
                + #")(?:先)?(?:不包含|暂不包含|不加入|暂不加入|不纳入|暂不纳入)([\p{Han}A-Za-z0-9._/-]{2,24})$"#,
        ]
        var requirements: [ExcludedScopeRequirement] = []
        for clause in semanticClauses(in: text) {
            let normalizedClause = normalizedNaturalText(clause)
            for (patternIndex, pattern) in patterns.enumerated() {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                let range = NSRange(
                    normalizedClause.startIndex..<normalizedClause.endIndex,
                    in: normalizedClause
                )
                guard let match = regex.firstMatch(in: normalizedClause, range: range),
                      let firstRange = Range(match.range(at: 1), in: normalizedClause),
                      let secondRange = Range(match.range(at: 2), in: normalizedClause) else {
                    continue
                }
                let first = String(normalizedClause[firstRange])
                let second = String(normalizedClause[secondRange])
                requirements.append(ExcludedScopeRequirement(
                    item: patternIndex == 0 ? first : second,
                    scope: patternIndex == 0 ? second : first
                ))
            }
        }
        var seen = Set<String>()
        return requirements.filter {
            seen.insert("\($0.item)|\($0.scope)").inserted
        }
    }

    private static func outputPreservesExcludedScope(
        _ requirement: ExcludedScopeRequirement,
        output: String
    ) -> Bool {
        let compact = normalizedNaturalText(output)
        let item = NSRegularExpression.escapedPattern(for: requirement.item)
        let scope = NSRegularExpression.escapedPattern(for: requirement.scope)
        let patterns = [
            "\(item).{0,8}(?:暂不|不再|不予|未|没有)(?:纳入|列入|加入|包含在|包含于).{0,6}\(scope)",
            "\(scope).{0,8}(?:先)?(?:不包含|暂不包含|不加入|暂不加入|不纳入|暂不纳入).{0,8}\(item)",
            "\(item).{0,8}(?:排除在|不在).{0,6}\(scope).{0,4}(?:之外|范围外)?",
        ]
        return patterns.contains {
            compact.range(of: $0, options: .regularExpression) != nil
        }
    }

    private static func isDeferredOrderingInstruction(_ action: String) -> Bool {
        let normalized = normalizedNaturalText(action)
        let pattern = #"^(?:先|马上|立即)[\p{Han}A-Za-z0-9._/-]{2,24}?(?:再|然后|接着|随后|先)[\p{Han}A-Za-z0-9._/-]{2,24}$"#
        return normalized.range(of: pattern, options: .regularExpression) != nil
    }

    private static func deferredActionOrders(in text: String) -> [DeferredActionOrder] {
        let pattern = #"(?:不要|别)(?:先|马上|立即)([\p{Han}A-Za-z0-9._/-]{2,24}?)(?:再|然后|接着|随后|先)([\p{Han}A-Za-z0-9._/-]{2,24})$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return semanticClauses(in: text).compactMap { clause in
            let normalized = normalizedNaturalText(clause)
            let searchRange = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
            guard let match = regex.firstMatch(in: normalized, range: searchRange),
                  let deferredRange = Range(match.range(at: 1), in: normalized),
                  let prerequisiteRange = Range(match.range(at: 2), in: normalized) else {
                return nil
            }
            return DeferredActionOrder(
                deferredAction: String(normalized[deferredRange]),
                prerequisiteAction: String(normalized[prerequisiteRange])
            )
        }
    }

    private static func firstRange(
        ofAny candidates: [String],
        in text: String
    ) -> Range<String.Index>? {
        candidates.compactMap { candidate in
            text.range(of: normalizedNaturalText(candidate))
        }.min { $0.lowerBound < $1.lowerBound }
    }

    private static func containsRecipientCue(_ text: String) -> Bool {
        [
            "给开发说", "告诉开发", "通知开发", "请开发", "让开发",
            "给客户说", "告诉客户", "通知客户", "请客户", "让客户",
            "给团队说", "告诉团队", "通知团队", "请团队", "让团队",
            "给他说", "告诉他", "通知他", "请他", "让他",
            "发给开发", "发给客户", "发给团队", "发给供应商", "发给负责人",
            "发给收件人", "写给开发", "写给客户", "写给团队", "写给供应商",
            "告诉供应商", "通知供应商", "请供应商", "让供应商",
            "给读者", "写给读者", "告诉读者", "收件人看到",
        ].contains(where: text.contains)
    }

    /// 精确短语之外，只接受少数能证明语义等价的动作变体。例如
    /// “先别动图片”可以对应“先不要改图片”，“请不要只回复让我耐心等待”
    /// 可以对应“而不是只让我继续等待”。不再把“重启服务”缩成“服务”，
    /// 否则另一句“服务无法连接”会替肯定执行的“重启服务”假通过。
    private static func negativeActionVariants(for action: String) -> [String] {
        var candidates = [action]
        if action.hasPrefix("动"), action.count > 1 {
            let object = String(action.dropFirst())
            candidates.append("改\(object)")
            candidates.append("修改\(object)")
        }
        if action.hasPrefix("改"), action.count > 1 {
            let object = action.dropFirst()
            candidates.append("修改\(object)")
            candidates.append("调整\(object)")
            candidates.append("变更\(object)")
        }
        if action.hasPrefix("关闭"), action.count > 2 {
            let object = action.dropFirst(2)
            candidates.append("关掉\(object)")
        }
        if action.contains("等待") { candidates.append("等待") }
        if action.contains("搜索") { candidates.append("搜索") }
        if action.contains("一上来") {
            candidates.append(action.replacingOccurrences(of: "一上来", with: "一开始"))
        }
        return Array(Set(candidates.filter { $0.count >= 2 }))
    }

    private static func inverseStatePreservesNegativeAction(
        action: String,
        clause: String
    ) -> Bool {
        var patterns: [String] = []
        if action.hasPrefix("关闭"), action.count > 2 {
            let object = String(action.dropFirst(2))
            let escapedObject = NSRegularExpression.escapedPattern(for: object)
            patterns += [
                "\(escapedObject).{0,6}(?:保持|继续).{0,4}(?:打开|开启)",
                "(?:保持|继续).{0,4}\(escapedObject).{0,4}(?:打开|开启)",
            ]
        }
        for prefix in ["开启", "打开", "启用", "启动"] where action.hasPrefix(prefix) && action.count > prefix.count {
            let object = String(action.dropFirst(prefix.count))
            let escapedObject = NSRegularExpression.escapedPattern(for: object)
            patterns += [
                "\(escapedObject).{0,6}(?:保持|继续)?(?:关闭|停用|禁用)",
                "(?:保持|继续)(?:关闭|停用|禁用).{0,4}\(escapedObject)",
            ]
        }
        for prefix in ["删除", "清除", "移除"] where action.hasPrefix(prefix) && action.count > prefix.count {
            let object = String(action.dropFirst(prefix.count))
            let escapedObject = NSRegularExpression.escapedPattern(for: object)
            patterns += [
                "\(escapedObject).{0,4}(?:要|应|必须|继续)?(?:保留|保存)",
                "(?:保留|保存).{0,4}\(escapedObject)",
            ]
        }
        if action.contains("搜索") {
            patterns += [
                #"(?:第一版|本版|这版|当前版本|本期|本轮).{0,6}(?:先)?(?:不包含|不支持|不提供|暂不包含|暂不支持|暂不提供).{0,6}(?:复杂)?搜索(?:功能)?"#,
                #"(?:复杂)?搜索(?:功能)?.{0,6}(?:暂不|不再|不予|未|没有)(?:纳入|列入)(?:第一版|本版|这版|当前版本|本期|本轮|范围|计划)"#,
            ]
        }
        for pattern in patterns {
            guard let range = clause.range(of: pattern, options: .regularExpression) else {
                continue
            }
            let prefix = String(clause[..<range.lowerBound].suffix(6))
            if !["不", "没", "未", "无"].contains(where: prefix.contains) {
                return true
            }
        }
        return false
    }

    private static func actionIsLocallyNegated(
        in clause: String,
        range: Range<String.Index>
    ) -> Bool {
        let prefix = String(clause[..<range.lowerBound].suffix(12))
        let suffix = String(clause[range.upperBound...].prefix(10))
        // 否定词必须直接支配动作。不能因为同一句更早出现了“并非故障”，
        // 就把后面的“重启服务”误判为禁止动作；也不能把动作后的
        // “并非禁止 / 不能拖延 / 不需要等待”反向理解为“不执行动作”。
        let reversedPolarityPattern = #"(?:不能不|不得不|并非(?:不|不要|别|禁止)|不是(?:不|不要|别|禁止)|没有(?:禁止|不让|不准)|未(?:禁止|阻止)|不(?:禁止|反对))(?:再|立即|马上|直接|继续|重新)?$"#
        if prefix.range(of: reversedPolarityPattern, options: .regularExpression) != nil {
            return false
        }
        let leadingPattern = #"(?:先不要|先别|不要|别|请勿|不得|禁止|暂不|不再|不能|不需要|无需|无须|不必|先不|不|没|未)(?:再|立即|马上|直接|继续|重新)?$"#
        if prefix.range(of: leadingPattern, options: .regularExpression) != nil {
            return true
        }
        let trailingPatterns = [
            #"^(?:这项|该项|相关操作)?(?:暂不|不再|不予)(?:执行|进行|安排|启动|实施|操作)?(?:$|[。；;，,])"#,
            #"^(?:这项|该项|相关操作)?(?:不能|不得|禁止)(?:执行|进行|安排|启动|实施|操作)(?:$|[。；;，,])"#,
            #"^(?:这项|该项|相关操作)?(?:已)?(?:取消|作废|暂停|停止)(?:执行|进行|安排|启动|实施|操作)?(?:$|[。；;，,])"#,
            #"^(?:功能|事项|能力|内容|模块)?(?:暂不|不再|不予|未|没有)(?:纳入|列入)(?:第一版|本版|这版|当前版本|本期|本轮|范围|计划)"#,
        ]
        if trailingPatterns.contains(where: {
            suffix.range(of: $0, options: .regularExpression) != nil
        }) { return true }
        if prefix.hasSuffix("不是只让我继续") || prefix.hasSuffix("而不是只让我继续") {
            return true
        }
        return false
    }

    private static func containsNegatedTerm(in text: String, terms: [String]) -> Bool {
        let normalized = normalizedNaturalText(text)
        for term in terms {
            var searchStart = normalized.startIndex
            while searchStart < normalized.endIndex,
                  let range = normalized.range(
                    of: normalizedNaturalText(term),
                    range: searchStart..<normalized.endIndex
                  ) {
                let prefix = String(normalized[..<range.lowerBound].suffix(8))
                if negativeMarkers.contains(where: prefix.contains) { return true }
                searchStart = range.upperBound
            }
        }
        return false
    }

    private static func clarifiedPositiveAttitudes(in text: String) -> [String] {
        let pattern = #"(?:不是|并非)不(愿意|想|肯|打算|同意|支持)([\p{Han}A-Za-z0-9]{0,10})$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return semanticClauses(in: text).compactMap { clause in
            let range = NSRange(clause.startIndex..<clause.endIndex, in: clause)
            guard let match = regex.firstMatch(in: clause, range: range),
                  let verbRange = Range(match.range(at: 1), in: clause),
                  let tailRange = Range(match.range(at: 2), in: clause) else { return nil }
            return String(clause[verbRange.lowerBound..<tailRange.upperBound])
        }
    }

    private static func containsPositiveAttitude(_ attitude: String, in text: String) -> Bool {
        let normalized = normalizedNaturalText(text)
        let target = normalizedNaturalText(attitude)
        var searchStart = normalized.startIndex
        while searchStart < normalized.endIndex,
              let range = normalized.range(of: target, range: searchStart..<normalized.endIndex) {
            let prefix = String(normalized[..<range.lowerBound].suffix(3))
            if !["不", "没", "未", "无"].contains(where: prefix.hasSuffix) {
                return true
            }
            if prefix.hasSuffix("不是不") || prefix.hasSuffix("并非不") {
                return true
            }
            searchStart = range.upperBound
        }
        return false
    }

    /// Fast 路径没有模型生成的 Plan，因此只接受本地能证明的最窄改口事实：
    /// 改口信号前最近的受保护事实，与信号后首个同类型、不同值的事实形成替换
    /// 关系。ASR 长录音经常把旧值、改口词和最终值切到相邻 segment，因此位置
    /// 按 segment 顺序统一比较；没有明确改口信号时仍不会跨段猜测。
    static func locallySupersededFactIndices(
        request: VoicePolishRequest,
        sourceFacts: [SourceFactCandidate]
    ) -> Set<Int> {
        let supersededOccurrences = locallySupersededFactOccurrences(
            request: request,
            sourceFacts: sourceFacts
        )
        guard !supersededOccurrences.isEmpty else { return [] }
        let allOccurrences = ProtectedFactExtractor.locations(
            of: sourceFacts.filter { $0.kind != .lexiconEntity },
            in: request.input.segments
        ).compactMap { location -> SupersededFactOccurrence? in
            guard let index = sourceFacts.firstIndex(where: {
                $0.kind == location.candidate.kind
                    && $0.canonicalValue == location.candidate.canonicalValue
                    && $0.sourceSegmentIDs == location.candidate.sourceSegmentIDs
            }) else { return nil }
            return SupersededFactOccurrence(
                factIndex: index,
                segmentIndex: location.segmentIndex,
                offset: location.offset,
                length: location.length,
                globalOffset: 0,
                replacementFactIndex: nil,
                relationAnchor: nil,
                factDescriptor: nil,
                replacementDescriptor: nil
            )
        }
        let countsByIndex = Dictionary(grouping: allOccurrences, by: \.factIndex)
        let supersededCounts = Dictionary(grouping: supersededOccurrences, by: \.factIndex)
        return Set(countsByIndex.compactMap { index, occurrences in
            supersededCounts[index]?.count == occurrences.count ? index : nil
        })
    }

    /// 返回被明确改口覆盖的具体事实出现位置。候选事实会为全局事实校验按
    /// segment 去重，但长语音内部切片必须区分同一 segment 中两个相同数字：
    /// 例如北京仍为 3 人、上海从 3 人改为 4 人，只有上海那一次 3 可删除。
    static func locallySupersededFactOccurrences(
        request: VoicePolishRequest,
        sourceFacts: [SourceFactCandidate]
    ) -> Set<SupersededFactOccurrence> {
        if isPublicCorrectionNotice(request) { return [] }

        typealias LocatedFact = SupersededFactOccurrence

        struct LocatedMarker {
            let globalStartOffset: Int
            let globalEndOffset: Int
            let signal: String
        }

        let correctionSignals = [
            "前面那句改成", "刚才那句改成", "把开头改成", "let me correct that",
            "change the earlier part", "change what i said before", "scratch that", "把前面",
            "我的意思是", "我改一下", "说错了", "不对", "应该是", "最后还是",
            "最终决定", "改到", "改为", "调整为", "现定为", "改成",
            "actually", "i mean", "final decision",
        ]
        let distantSignals = [
            "前面那句改成", "刚才那句改成", "把开头改成", "把前面",
            "change the earlier part", "change what i said before",
        ]
        let inlineRewriteSignals = ["改到", "改为", "调整为", "现定为", "改成"]
        let resetSignals = correctionSignals.filter { signal in
            !distantSignals.contains(signal) && !inlineRewriteSignals.contains(signal)
        }
        var segmentGlobalOffsets: [Int] = []
        var nextGlobalOffset = 0
        for segment in request.input.segments {
            segmentGlobalOffsets.append(nextGlobalOffset)
            nextGlobalOffset += segment.text.count
        }
        // Provider segment 只是传输边界，不是用户语义边界。同一段口述无论被
        // 切成 1 段、4 段，甚至把“不对”拆在两个 segment 中，改口关系都应
        // 保持一致。因此所有 marker 与距离判断都在无人工分隔符的连续正文上做。
        let combinedSource = request.input.segments.map(\.text).joined()

        func textBetween(_ start: Int, _ end: Int) -> String {
            let safeStart = max(0, min(start, combinedSource.count))
            let safeEnd = max(safeStart, min(end, combinedSource.count))
            let lower = combinedSource.index(combinedSource.startIndex, offsetBy: safeStart)
            let upper = combinedSource.index(combinedSource.startIndex, offsetBy: safeEnd)
            return String(combinedSource[lower..<upper])
        }

        func hardBoundaryCount(in text: String) -> Int {
            text.reduce(into: 0) { count, character in
                if "。！？；.!?;\n".contains(character) { count += 1 }
            }
        }

        func containsSignal(_ signal: String, in candidates: [String]) -> Bool {
            candidates.contains { signal.localizedCaseInsensitiveContains($0) }
        }

        func quantityDescriptor(after fact: LocatedFact, until limit: Int) -> String? {
            let raw = textBetween(
                fact.globalEndOffset,
                min(limit, fact.globalEndOffset + 18)
            )
            let leading = raw
                .prefix { character in
                    !"，。！？；,.!?;、\n".contains(character)
                        && !character.isNumber
                }
            var compact = String(leading)
                .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
            // 量词本身不足以证明两个数字描述同一个对象。“3 个问题改成
            // 1 个表格”两侧都是“个”，但它是格式转换，不是把数量 3 更正为
            // 1。保留量词后的短对象词，并在改口动词处截断，得到“个问题”与
            // “个表格”；真正的“3 个问题改成 4 个问题”仍能正确配对。
            let stopSignals = [
                "改成", "改为", "改到", "调整为", "现定为", "应该是",
                "不对", "说错了", "我的意思是", "最后还是", "最终决定",
            ]
            if let boundary = stopSignals.compactMap({ compact.range(of: $0)?.lowerBound }).min() {
                compact = String(compact[..<boundary])
            }
            let classifiers = [
                "分钟", "小时", "个月", "工作日", "公里", "万元",
                "个", "条", "张", "份", "项", "人", "位", "名", "台",
                "款", "套", "本", "页", "章", "段", "次", "遍", "场",
                "组", "种", "件", "家", "只", "天", "周", "月", "年",
            ]
            guard let classifier = classifiers
                .sorted(by: { $0.count > $1.count })
                .first(where: { compact.hasPrefix($0) }) else { return nil }
            let maximumLength = classifier.count + 4
            return String(compact.prefix(maximumLength))
        }

        func quantityDescriptorParts(_ descriptor: String?) -> (family: String, object: String?)? {
            guard var descriptor, !descriptor.isEmpty else { return nil }
            descriptor = normalizedNaturalText(descriptor)
            let peopleClassifiers = ["个人", "人", "位", "名"]
            if let classifier = peopleClassifiers.first(where: descriptor.hasPrefix) {
                let object = String(descriptor.dropFirst(classifier.count))
                return ("people", object.isEmpty ? nil : object)
            }
            let classifiers = [
                "分钟", "小时", "个月", "工作日", "公里", "万元",
                "个", "条", "张", "份", "项", "台", "款", "套", "本",
                "页", "章", "段", "次", "遍", "场", "组", "种", "件",
                "家", "只", "天", "周", "月", "年",
            ]
            guard let classifier = classifiers
                .sorted(by: { $0.count > $1.count })
                .first(where: descriptor.hasPrefix) else { return nil }
            let object = String(descriptor.dropFirst(classifier.count))
            return (classifier, object.isEmpty ? nil : object)
        }

        func quantityDescriptorsAreCompatible(_ left: String?, _ right: String?) -> Bool {
            if left == nil, right == nil { return true }
            guard let leftParts = quantityDescriptorParts(left),
                  let rightParts = quantityDescriptorParts(right) else { return false }
            if let leftObject = leftParts.object,
               let rightObject = rightParts.object,
               leftObject != rightObject {
                return false
            }
            if leftParts.family == "people", rightParts.family == "people" {
                return true
            }
            if let leftObject = leftParts.object, let rightObject = rightParts.object {
                return leftObject == rightObject
            }
            return leftParts.family == rightParts.family
        }

        func relationLabel(before fact: LocatedFact) -> String? {
            let lower = max(0, fact.globalOffset - 28)
            let raw = textBetween(lower, fact.globalOffset)
            let clause = raw.split(
                whereSeparator: { "，。！？；,.!?;、\n".contains($0) }
            ).last.map(String.init) ?? raw
            var label = normalizedNaturalText(clause)
            // “发布日期从 8 月 20 日改到 8 月 28 日”中，最终值前面的
            // 整段还包含旧值；明确的“从 A 改到 B / 由 A 改为 B”应取 A
            // 之前的对象词作为关系标签。
            for transition in ["从", "由"] {
                guard let range = label.range(of: transition) else { continue }
                let suffix = String(label[range.upperBound...])
                if ["改到", "改为", "改成", "调整为", "现定为"].contains(
                    where: { suffix.contains($0) }
                ) {
                    label = String(label[..<range.lowerBound])
                    break
                }
            }
            let removablePrefixes = [
                "不对", "我改一下", "我说错了", "说错了", "我的意思是",
                "应该是", "刚确认", "确认", "先说", "正确", "最终", "最后", "原来",
                "原定", "先按", "先记", "预计", "大约", "共", "有", "为", "是",
            ]
            var changed = true
            while changed {
                changed = false
                for prefix in removablePrefixes where label.hasPrefix(prefix) {
                    label.removeFirst(prefix.count)
                    changed = true
                    break
                }
            }
            let removableSuffixes = [
                "也先安排", "最终安排", "最后安排", "先安排", "仍安排", "安排",
                "改成", "改为", "改到", "调整为", "现定为", "应该是",
                "最终决定", "最后还是", "先按", "先记", "预计", "大约",
                "原定", "最终", "最后", "仍是", "也是", "共", "有", "为",
                "是", "从", "由",
            ]
            changed = true
            while changed {
                changed = false
                for suffix in removableSuffixes where label.hasSuffix(suffix) {
                    label.removeLast(suffix.count)
                    changed = true
                    break
                }
            }
            return label.isEmpty ? nil : label
        }

        func relationLabelsAreCompatible(_ left: String, _ right: String) -> Bool {
            if left == right { return true }
            let genericAnchors = [
                "预算", "费用", "总价", "单价", "报价", "金额", "日期", "时间",
                "期限", "截止", "排期", "周期", "附件", "页数", "页面", "人数",
                "名额", "数量", "版本", "地址", "路径", "端口", "比例", "折扣",
            ]
            return genericAnchors.contains { anchor in
                (left == anchor && right.hasSuffix(anchor))
                    || (right == anchor && left.hasSuffix(anchor))
            }
        }

        func minimalRelationAnchor(_ label: String?) -> String? {
            guard var label, !label.isEmpty else { return nil }
            // “上海团队参会人数”真正稳定的对象是“上海”；模型自然可简写成
            // “上海安排 4 人”。只剥离明确的数量/金额字段后缀，剩余对象词
            // 为空时不建立关系硬门禁，避免对开放实体做猜测。
            let fieldSuffixes = [
                "参会人数", "参与人数", "安排人数", "人员数量", "人数",
                "名额", "数量", "预算", "价格", "费用", "金额",
            ]
            for suffix in fieldSuffixes
            where label.hasSuffix(suffix) && label.count > suffix.count {
                label.removeLast(suffix.count)
                break
            }
            return label.isEmpty ? nil : label
        }

        func relationAnchorsAreCompatible(_ left: String, _ right: String) -> Bool {
            if left == right { return true }
            let genericSubjectSuffixes = ["团队", "项目", "小组", "部门"]
            return genericSubjectSuffixes.contains { suffix in
                left == right + suffix || right == left + suffix
            }
        }

        /// “前面上海团队参会人数说错了”把撤回对象放在 marker 前，而旧值和
        /// 最终值附近使用的动词可能完全不同。只接受以明确事实字段结尾、且不含
        /// 数值的对象短语，避免把普通“预算 3 万说错了”整句误作对象标签。
        func explicitRetractionLabel(before marker: LocatedMarker) -> String? {
            let raw = textBetween(max(0, marker.globalStartOffset - 48), marker.globalStartOffset)
            let clause = raw.split(
                whereSeparator: { "，。！？；,.!?;、\n".contains($0) }
            ).last.map(String.init) ?? raw
            var label = normalizedNaturalText(clause)
            for prefix in ["前面", "刚才", "刚刚", "上面", "前述", "这里", "这个"]
            where label.hasPrefix(prefix) {
                label.removeFirst(prefix.count)
                break
            }
            let fieldSuffixes = [
                "参会人数", "参与人数", "安排人数", "人员数量", "人数", "名额",
                "数量", "预算", "价格", "费用", "金额", "日期", "时间", "期限",
                "截止时间", "版本", "地址", "路径", "端口", "比例", "折扣",
            ]
            guard (2...32).contains(label.count),
                  fieldSuffixes.contains(where: label.hasSuffix),
                  label.range(of: #"[0-9一二三四五六七八九十百千万亿两]"#, options: .regularExpression) == nil else {
                return nil
            }
            return label
        }

        var locatedFacts: [LocatedFact] = []
        var locatedMarkers: [LocatedMarker] = []
        locatedFacts = ProtectedFactExtractor.locations(
            of: sourceFacts.filter { $0.kind != .lexiconEntity },
            in: request.input.segments
        ).compactMap { location in
            guard let index = sourceFacts.firstIndex(where: {
                $0.kind == location.candidate.kind
                    && $0.canonicalValue == location.candidate.canonicalValue
                    && $0.sourceSegmentIDs == location.candidate.sourceSegmentIDs
            }) else { return nil }
            let globalOffset = segmentGlobalOffsets[location.segmentIndex] + location.offset
            return LocatedFact(
                factIndex: index,
                segmentIndex: location.segmentIndex,
                offset: location.offset,
                length: location.length,
                globalOffset: globalOffset,
                replacementFactIndex: nil,
                relationAnchor: nil,
                factDescriptor: nil,
                replacementDescriptor: nil
            )
        }
        locatedMarkers = correctionSignals.flatMap { signal -> [LocatedMarker] in
            correctionRanges(of: signal, in: combinedSource).map { range in
                LocatedMarker(
                    globalStartOffset: combinedSource.distance(
                        from: combinedSource.startIndex,
                        to: range.lowerBound
                    ),
                    globalEndOffset: combinedSource.distance(
                        from: combinedSource.startIndex,
                        to: range.upperBound
                    ),
                    signal: signal
                )
            }
        }

        locatedFacts.sort { $0.globalOffset < $1.globalOffset }
        locatedMarkers.sort {
            if $0.globalStartOffset != $1.globalStartOffset {
                return $0.globalStartOffset < $1.globalStartOffset
            }
            return $0.globalEndOffset > $1.globalEndOffset
        }
        locatedMarkers = locatedMarkers.reduce(into: []) { result, marker in
            let isContained = result.contains {
                $0.globalStartOffset <= marker.globalStartOffset
                    && $0.globalEndOffset >= marker.globalEndOffset
            }
            if !isContained { result.append(marker) }
        }
        // “不对，最终预算……改成……”中的复位词和改写动词描述的是同一次
        // 改口。把二者合成一个定位范围，既能跨一个 ASR segment 找到最终值，
        // 也不会像直接丢弃后一个关键词那样截断事实。“不对，应该是”这类
        // 连续复位词只有在中间没有事实时合并；一旦出现 4，再遇到“不对”，
        // 就会开始新的事件，因此连续两次改口仍分别处理。
        let rawMarkers = locatedMarkers
        locatedMarkers = rawMarkers.reduce(into: []) { result, marker in
            guard let previous = result.last,
                  containsSignal(previous.signal, in: resetSignals),
                  (containsSignal(marker.signal, in: inlineRewriteSignals)
                    || containsSignal(marker.signal, in: resetSignals)),
                  marker.globalStartOffset - previous.globalEndOffset <= 96 else {
                result.append(marker)
                return
            }
            let gap = textBetween(previous.globalEndOffset, marker.globalStartOffset)
            let containsInterveningFact = locatedFacts.contains {
                $0.globalOffset >= previous.globalEndOffset
                    && $0.globalEndOffset <= marker.globalStartOffset
            }
            guard hardBoundaryCount(in: gap) <= 2, !containsInterveningFact else {
                result.append(marker)
                return
            }
            result[result.count - 1] = LocatedMarker(
                globalStartOffset: previous.globalStartOffset,
                globalEndOffset: marker.globalEndOffset,
                signal: previous.signal + "|" + marker.signal
            )
        }
        var superseded: Set<SupersededFactOccurrence> = []
        for (markerIndex, marker) in locatedMarkers.enumerated() {
            let allowsDistantPrevious = containsSignal(marker.signal, in: distantSignals)
            let isResetSignal = containsSignal(marker.signal, in: resetSignals)
            let isInlineRewrite = containsSignal(marker.signal, in: inlineRewriteSignals)
                && !isResetSignal
            let nextMarker = locatedMarkers.indices.contains(markerIndex + 1)
                ? locatedMarkers[markerIndex + 1]
                : nil
            let possibleFinals = locatedFacts.filter { candidate in
                let followsMarker = candidate.globalOffset >= marker.globalEndOffset
                let precedesNextMarker = nextMarker.map {
                    candidate.globalOffset < $0.globalStartOffset
                } ?? true
                let gap = textBetween(marker.globalEndOffset, candidate.globalOffset)
                let isNearby = candidate.globalOffset - marker.globalEndOffset <= 96
                    && hardBoundaryCount(in: gap) <= 1
                return followsMarker && precedesNextMarker && isNearby
            }

            for final in possibleFinals {
                let finalFact = sourceFacts[final.factIndex]
                let finalLabel = relationLabel(before: final)
                let hasExplicitRetraction = [
                        "不对", "说错了", "我说错了", "我改一下", "我的意思是",
                        "scratch that", "let me correct that", "actually", "i mean",
                    ].contains(where: {
                        marker.signal.localizedCaseInsensitiveContains($0)
                    })
                let explicitRetractionAnchor = hasExplicitRetraction
                    ? minimalRelationAnchor(explicitRetractionLabel(before: marker))
                    : nil
                let finalAnchor = minimalRelationAnchor(finalLabel)
                if let explicitRetractionAnchor,
                   let finalAnchor,
                   !relationAnchorsAreCompatible(explicitRetractionAnchor, finalAnchor) {
                    continue
                }
                let previousCandidates = locatedFacts.filter { candidate in
                    let precedesMarker = candidate.globalEndOffset <= marker.globalStartOffset
                    let followsPreviousCorrection = allowsDistantPrevious
                        || markerIndex == 0
                        || candidate.globalOffset >= locatedMarkers[markerIndex - 1].globalEndOffset
                    let gap = textBetween(candidate.globalEndOffset, marker.globalStartOffset)
                    let boundaryCount = hardBoundaryCount(in: gap)
                    let distance = marker.globalStartOffset - candidate.globalEndOffset
                    let candidateLabel = relationLabel(before: candidate)
                    let exactAnchoredRetraction = hasExplicitRetraction
                        && ((finalLabel != nil && candidateLabel == finalLabel)
                            || (explicitRetractionAnchor != nil
                                && minimalRelationAnchor(candidateLabel).map {
                                    relationAnchorsAreCompatible(explicitRetractionAnchor!, $0)
                                } == true))
                        && distance <= 512
                        && boundaryCount <= 12
                    let isNearby = allowsDistantPrevious
                        || (distance <= 128
                            && (boundaryCount == 0 || (isResetSignal && boundaryCount <= 2)))
                        || exactAnchoredRetraction
                    return precedesMarker
                        && followsPreviousCorrection
                        && isNearby
                        && sourceFacts[candidate.factIndex].kind == finalFact.kind
                }
                guard !previousCandidates.isEmpty else { continue }

                let nextFactOffset = locatedFacts.first(where: {
                    $0.globalOffset > final.globalEndOffset
                })?.globalOffset ?? combinedSource.count
                let finalDescriptor = finalFact.kind == .number
                    ? quantityDescriptor(after: final, until: nextFactOffset)
                    : nil
                let compatiblePrevious = previousCandidates.filter { candidate in
                    guard finalFact.kind == .number else { return true }
                    let candidateDescriptor = quantityDescriptor(
                        after: candidate,
                        until: marker.globalStartOffset
                    )
                    return quantityDescriptorsAreCompatible(
                        candidateDescriptor,
                        finalDescriptor
                    )
                }
                guard !compatiblePrevious.isEmpty else { continue }
                let exactLabelMatches = compatiblePrevious.filter { candidate in
                    guard let finalLabel, let candidateLabel = relationLabel(before: candidate) else {
                        return false
                    }
                    return candidateLabel == finalLabel
                }
                let compatibleLabelMatches = compatiblePrevious.filter { candidate in
                    guard let finalLabel, let candidateLabel = relationLabel(before: candidate) else {
                        return false
                    }
                    return relationLabelsAreCompatible(candidateLabel, finalLabel)
                }
                let explicitAnchorMatches = compatiblePrevious.filter { candidate in
                    guard let explicitRetractionAnchor,
                          let candidateAnchor = minimalRelationAnchor(
                            relationLabel(before: candidate)
                          ) else { return false }
                    return relationAnchorsAreCompatible(explicitRetractionAnchor, candidateAnchor)
                }
                // 同类事实之间优先按“预算/附件/发布日期”等局部对象标签配对；
                // 完全相同的对象标签优先。若最终只说“预算”，同时可匹配“项目
                // 预算”和“附件预算”，指向并不唯一，不能再靠最近位置猜一个。
                let previous: LocatedFact?
                if explicitAnchorMatches.count == 1 {
                    previous = explicitAnchorMatches[0]
                } else if explicitAnchorMatches.count > 1 {
                    previous = nil
                } else if !exactLabelMatches.isEmpty {
                    previous = exactLabelMatches.last
                } else if compatibleLabelMatches.count == 1 {
                    previous = compatibleLabelMatches[0]
                } else if compatibleLabelMatches.count > 1 {
                    previous = nil
                } else if compatiblePrevious.count == 1 {
                    let onlyCandidate = compatiblePrevious[0]
                    let candidateLabel = relationLabel(before: onlyCandidate)
                    // 两侧只要都有明确对象词却无法证明兼容，就不能因为同类型
                    // 事实只剩一个而强行配对。对象词是开放集合，不能依赖“预算/
                    // 日期”等有限白名单；例如“基础版价格 2 万，高级版改成 3 万”
                    // 也是并列事实，不是把基础版价格改掉。
                    if !allowsDistantPrevious,
                       !hasExplicitRetraction,
                       finalLabel != nil,
                       candidateLabel != nil {
                        previous = nil
                    } else {
                        previous = onlyCandidate
                    }
                } else {
                    // 多个同类型、同量词事实都可能成为旧值，而最终事实又没有
                    // 可与之绑定的对象标签时，不能靠“离改口词最近”猜测。
                    previous = nil
                }
                guard let previous else { continue }
                let previousFact = sourceFacts[previous.factIndex]
                guard !equivalent(previousFact, finalFact) else { continue }

                // “应该是 / 最后还是 / 最终决定”也常用于并列说明，而非撤回前
                // 一项，例如“基础版 2 万，高级版应该是 3 万”。没有显式撤回
                // 词时，只有同一明确对象标签才能建立替换关系。
                let weakStandaloneSignals = ["应该是", "最后还是", "最终决定"]
                if containsSignal(marker.signal, in: weakStandaloneSignals),
                   !hasExplicitRetraction {
                    guard let finalLabel,
                          let previousLabel = relationLabel(before: previous),
                          finalLabel == previousLabel else {
                        continue
                    }
                }

                // “改成/改为”等普通动词只有在同一语义小句内明确出现 A→B 时
                // 才算事实改口；否则它很可能只是“改成营销文案”这类写作要求。
                if isInlineRewrite && !allowsDistantPrevious {
                    let previousGap = textBetween(
                        previous.globalEndOffset,
                        marker.globalStartOffset
                    )
                    let semanticGap = normalizedNaturalText(previousGap)
                    guard hardBoundaryCount(in: previousGap) == 0,
                          semanticGap.count <= 4 else {
                        continue
                    }

                    // “把这 3 个问题改成 1 张表格”是对成稿形式的要求，不是
                    // 把同一个数量从 3 更正为 1。裸“改成/改为”只有在数字前后
                    // 的量词与对象一致（或双方都没有对象）时，才允许建立 A→B
                    // 的事实替换关系；无法证明时宁可继续保护两个数字。
                    if previousFact.kind == .number, finalFact.kind == .number {
                        let oldDescriptor = quantityDescriptor(
                            after: previous,
                            until: marker.globalStartOffset
                        )
                        let newDescriptor = quantityDescriptor(
                            after: final,
                            until: nextFactOffset
                        )
                        if !quantityDescriptorsAreCompatible(oldDescriptor, newDescriptor) {
                            continue
                        }
                    }
                }

                superseded.insert(SupersededFactOccurrence(
                    factIndex: previous.factIndex,
                    segmentIndex: previous.segmentIndex,
                    offset: previous.offset,
                    length: previous.length,
                    globalOffset: previous.globalOffset,
                    replacementFactIndex: final.factIndex,
                    relationAnchor: explicitRetractionAnchor ?? minimalRelationAnchor(finalLabel),
                    factDescriptor: previousFact.kind == .number
                        ? quantityDescriptor(after: previous, until: marker.globalStartOffset)
                        : nil,
                    replacementDescriptor: finalFact.kind == .number
                        ? quantityDescriptor(after: final, until: nextFactOffset)
                        : nil
                ))
                break
            }
        }
        return superseded
    }

    /// 只有当同一语义值在全文中没有仍然有效的另一处来源时，才可以把它作为
    /// “全文禁用事实”交给模型。相同的 3 可能同时表示仍有效的北京人数和已被
    /// 改成 4 的上海人数；这时关系可在对应片段内处理，但绝不能全局禁止 3。
    static func unambiguouslySupersededFactIndices(
        request: VoicePolishRequest,
        sourceFacts: [SourceFactCandidate]
    ) -> Set<Int> {
        let superseded = locallySupersededFactIndices(
            request: request,
            sourceFacts: sourceFacts
        )
        return Set(superseded.filter { index in
            !sourceFacts.enumerated().contains { otherIndex, other in
                otherIndex != index
                    && !superseded.contains(otherIndex)
                    && equivalent(sourceFacts[index], other)
            }
        })
    }

    /// 当同一个 canonical 值在别处仍然有效时，集合校验不能区分“北京 3 人”
    /// 与已经被推翻的“上海 3 人”。这里消费改口定位阶段保留下来的对象关系：
    /// 成稿必须把对象绑定到最终值，同时不得继续把它绑定到旧值。
    private static func appendSupersededRelationCodes(
        output: String,
        sourceFacts: [SourceFactCandidate],
        supersededOccurrences: Set<SupersededFactOccurrence>,
        fullySupersededFactIndices: Set<Int>,
        to codes: inout [VoicePolishValidationCode]
    ) {
        let relationOccurrences = supersededOccurrences.filter {
            guard sourceFacts.indices.contains($0.factIndex) else { return false }
            let oldFact = sourceFacts[$0.factIndex]
            let canonicalStillRequired = sourceFacts.enumerated().contains { index, fact in
                !fullySupersededFactIndices.contains(index) && equivalent(oldFact, fact)
            }
            return canonicalStillRequired
                && $0.replacementFactIndex != nil
                && !($0.relationAnchor ?? "").isEmpty
        }
        guard !relationOccurrences.isEmpty else { return }

        func sentenceParts(_ text: String) -> [String] {
            text.split(whereSeparator: { "。！？；.!?;".contains($0) })
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }

        func relationBlocks(_ text: String) -> [String] {
            let listMarker = #"^\s*(?:(?:\d{1,3}[.)、）]|[一二三四五六七八九十]{1,3}[、.)）])\s*|[-*•]\s+)"#
            var blocks: [String] = []
            var currentListItem: [String] = []
            var currentParagraph: [String] = []

            func flushParagraph() {
                guard !currentParagraph.isEmpty else { return }
                blocks.append(contentsOf: sentenceParts(currentParagraph.joined(separator: " ")))
                currentParagraph.removeAll(keepingCapacity: true)
            }

            func flushListItem() {
                guard !currentListItem.isEmpty else { return }
                blocks.append(currentListItem.joined(separator: " "))
                currentListItem.removeAll(keepingCapacity: true)
            }

            for rawLine in VoicePolishCharacterSafety.normalizedLineEndings(text)
                .split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(rawLine).trimmingCharacters(in: .whitespaces)
                if line.isEmpty {
                    flushParagraph()
                    flushListItem()
                } else if line.range(of: listMarker, options: .regularExpression) != nil {
                    flushParagraph()
                    flushListItem()
                    currentListItem = [line]
                } else if !currentListItem.isEmpty {
                    // 同一列表项允许“对象：\n最终值”这种自然换行；遇到下一项
                    // 会在上面的 list marker 分支立刻截断，绝不跨项借词。
                    currentListItem.append(line)
                } else {
                    currentParagraph.append(line)
                }
            }
            flushParagraph()
            flushListItem()
            return blocks
        }

        let blocks = relationBlocks(output)

        func descriptorParts(_ descriptor: String?) -> (family: String, object: String?)? {
            guard var descriptor, !descriptor.isEmpty else { return nil }
            descriptor = normalizedNaturalText(descriptor)
            for classifier in ["个人", "人", "位", "名"] where descriptor.hasPrefix(classifier) {
                let object = String(descriptor.dropFirst(classifier.count))
                return ("people", object.isEmpty ? nil : object)
            }
            let classifiers = [
                "分钟", "小时", "个月", "工作日", "公里", "万元",
                "个", "条", "张", "份", "项", "台", "款", "套", "本",
                "页", "章", "段", "次", "遍", "场", "组", "种", "件",
                "家", "只", "天", "周", "月", "年",
            ]
            guard let classifier = classifiers
                .sorted(by: { $0.count > $1.count })
                .first(where: descriptor.hasPrefix) else { return nil }
            let object = String(descriptor.dropFirst(classifier.count))
            return (classifier, object.isEmpty ? nil : object)
        }

        func descriptorsAreCompatible(_ expected: String?, _ actual: String?) -> Bool {
            guard let expected else { return true }
            guard let expectedParts = descriptorParts(expected),
                  let actualParts = descriptorParts(actual) else { return false }
            if let expectedObject = expectedParts.object,
               let actualObject = actualParts.object,
               expectedObject != actualObject {
                return false
            }
            if expectedParts.family == "people", actualParts.family == "people" {
                return true
            }
            if let expectedObject = expectedParts.object,
               let actualObject = actualParts.object {
                return expectedObject == actualObject
            }
            return expectedParts.family == actualParts.family
        }

        func outputDescriptor(
            in block: String,
            after location: ProtectedFactExtractor.FactLocation
        ) -> String? {
            let factEnd = block.index(
                block.startIndex,
                offsetBy: location.offset + location.length
            )
            let raw = String(block[factEnd...].prefix(10))
            let leading = raw.prefix { character in
                !"，。！？；,.!?;、\n".contains(character) && !character.isNumber
            }
            let compact = String(leading)
                .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
            let classifiers = [
                "分钟", "小时", "个月", "工作日", "公里", "万元",
                "个", "条", "张", "份", "项", "人", "位", "名", "台",
                "款", "套", "本", "页", "章", "段", "次", "遍", "场",
                "组", "种", "件", "家", "只", "天", "周", "月", "年",
            ]
            guard let classifier = classifiers.sorted(by: { $0.count > $1.count })
                .first(where: { compact.hasPrefix($0) }) else { return nil }
            return String(compact.prefix(classifier.count + 4))
        }

        func hasCompatibleOutputDescriptor(
            in block: String,
            location: ProtectedFactExtractor.FactLocation,
            expected: String?
        ) -> Bool {
            guard let expected else { return true }
            if descriptorsAreCompatible(
                expected,
                outputDescriptor(in: block, after: location)
            ) {
                return true
            }
            guard descriptorParts(expected)?.family == "people" else { return false }
            let factStart = block.index(block.startIndex, offsetBy: location.offset)
            let prefix = normalizedNaturalText(String(block[..<factStart].suffix(12)))
            return prefix.range(
                of: #"(?:参会|参与|安排|团队|项目)?人数(?:为|是|有|共)?$"#,
                options: .regularExpression
            ) != nil
        }

        func blockExpresses(
            _ block: String,
            anchor: String,
            fact: SourceFactCandidate,
            descriptor: String?
        ) -> Bool {
            let normalizedAnchor = normalizedNaturalText(anchor)
            guard !normalizedAnchor.isEmpty else { return false }
            let segment = RecognitionSegment(
                id: "relation-output",
                text: block,
                startTimeMs: nil,
                endTimeMs: nil,
                confidence: nil,
                isFinal: true
            )
            let outputFacts = ProtectedFactExtractor.extract(from: [segment])
            let locations = ProtectedFactExtractor.locations(of: outputFacts, in: [segment])

            // “北京团队和上海团队分别安排 3 人和 4 人”必须按两边顺序绑定，
            // 不能因为上海出现在第一个数字之前，就把 3 也误判成上海人数。
            if let separateRange = block.range(of: "分别") {
                let subjectPrefix = String(block[..<separateRange.lowerBound])
                let subjectClause = subjectPrefix.split(
                    whereSeparator: { "，。！？；,.!?;\n".contains($0) }
                ).last.map(String.init) ?? subjectPrefix
                let subjects = subjectClause.components(
                    separatedBy: CharacterSet(charactersIn: "和与、及")
                ).map(normalizedNaturalText).filter { !$0.isEmpty }
                if subjects.count >= 2,
                   let anchorIndex = subjects.firstIndex(where: {
                       $0.contains(normalizedAnchor)
                   }) {
                    let separateOffset = block.distance(
                        from: block.startIndex,
                        to: separateRange.upperBound
                    )
                    let orderedValues = locations.filter { $0.offset >= separateOffset }
                        .sorted { $0.offset < $1.offset }
                    if orderedValues.count == subjects.count,
                       orderedValues.indices.contains(anchorIndex) {
                        let assigned = orderedValues[anchorIndex]
                        return equivalent(fact, assigned.candidate)
                            && hasCompatibleOutputDescriptor(
                                in: block,
                                location: assigned,
                                expected: descriptor
                            )
                    }
                }
            }

            return locations.contains { location in
                guard equivalent(fact, location.candidate) else { return false }
                if !hasCompatibleOutputDescriptor(
                    in: block,
                    location: location,
                    expected: descriptor
                ) {
                    return false
                }
                let factStart = block.index(block.startIndex, offsetBy: location.offset)
                let factEnd = block.index(factStart, offsetBy: location.length)
                let prefix = normalizedNaturalText(String(block[..<factStart]))
                let trailing = normalizedNaturalText(String(block[factEnd...].prefix(16)))
                let disqualifiers = [
                    "不", "未", "没有", "并非", "不是", "不再", "无关", "否认",
                    "排除", "如果", "假如", "假设", "假定", "举例", "例如",
                    "曾经", "原定", "之前", "原先", "撤销", "取消", "作废", "不作数",
                ]
                if let anchorRange = prefix.range(of: normalizedAnchor, options: .backwards) {
                    let relationGap = String(prefix[anchorRange.upperBound...])
                    let leading = String(prefix[..<anchorRange.lowerBound].suffix(10))
                    let relationContext = leading + relationGap + trailing
                    let positiveSignals = [
                        "人数", "人员", "安排", "分配", "共有", "共", "有", "为", "是",
                        "达到", "调整为", "改为", "现为", "最终",
                    ]
                    let directLabelValue = relationGap.isEmpty
                    if relationGap.count <= 18,
                       (directLabelValue || positiveSignals.contains(where: relationGap.contains)),
                       !disqualifiers.contains(where: relationContext.contains) {
                        return true
                    }
                }

                // 同时接受“3 人仍安排给上海”这类 value→subject 句法，但必须
                // 有明确关系谓词，不能因后文偶然又出现“上海”就借词通过。
                let nextFactOffset = locations
                    .filter { $0.offset > location.offset }
                    .map(\.offset)
                    .min() ?? block.count
                let nextFactIndex = block.index(
                    block.startIndex,
                    offsetBy: min(nextFactOffset, block.count)
                )
                let rawSuffix = String(block[factEnd..<nextFactIndex])
                let boundedSuffix = rawSuffix.split(
                    whereSeparator: { "，,；;。！？!?\n".contains($0) }
                ).first.map(String.init) ?? rawSuffix
                let suffix = normalizedNaturalText(String(boundedSuffix.prefix(24)))
                guard let anchorRange = suffix.range(of: normalizedAnchor) else { return false }
                let relationGap = String(suffix[..<anchorRange.lowerBound])
                let assignmentSignals = ["安排给", "分配给", "留在", "属于", "交给", "给"]
                let leading = String(prefix.suffix(10))
                let afterAnchor = String(suffix[anchorRange.upperBound...].prefix(12))
                let relationContext = leading + relationGap + afterAnchor
                return relationGap.count <= 16
                    && assignmentSignals.contains(where: relationGap.contains)
                    && !disqualifiers.contains(where: relationContext.contains)
            }
        }

        for occurrence in relationOccurrences {
            guard sourceFacts.indices.contains(occurrence.factIndex),
                  let replacementIndex = occurrence.replacementFactIndex,
                  sourceFacts.indices.contains(replacementIndex),
                  let anchor = occurrence.relationAnchor else { continue }
            let oldFact = sourceFacts[occurrence.factIndex]
            let finalFact = sourceFacts[replacementIndex]
            if blocks.contains(where: {
                blockExpresses(
                    $0,
                    anchor: anchor,
                    fact: oldFact,
                    descriptor: occurrence.factDescriptor
                )
            }) {
                append(.supersededFactRetained, to: &codes)
            }
            if !blocks.contains(where: {
                blockExpresses(
                    $0,
                    anchor: anchor,
                    fact: finalFact,
                    descriptor: occurrence.replacementDescriptor
                )
            }) {
                append(.missingProtectedFact, to: &codes)
            }
        }
    }

    private static func correctionRanges(
        of signal: String,
        in text: String
    ) -> [Range<String.Index>] {
        allRanges(of: signal, in: text).filter { range in
            if signal == "不对" {
                let suffix = String(text[range.upperBound...].prefix(3))
                let nonCorrectionContinuations = ["外", "内", "应", "等", "劲", "称", "付"]
                if nonCorrectionContinuations.contains(where: suffix.hasPrefix) {
                    return false
                }
            }
            guard signal.unicodeScalars.allSatisfy({ $0.isASCII }) else { return true }
            let leftIsWord = range.lowerBound > text.startIndex
                && text[text.index(before: range.lowerBound)].isLetter
            let rightIsWord = range.upperBound < text.endIndex
                && text[range.upperBound].isLetter
            return !leftIsWord && !rightIsWord
        }
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
        let inlineCorrectionPattern = #"(?:^|[，,。！？!?；;])\s*不对(?:\s*[，,：:]\s*(?=\S)|\s*(?=还是|应该说|准确地说|更准确地说))"#
        if request.fallbackText.range(
            of: inlineCorrectionPattern,
            options: .regularExpression
        ) != nil {
            return output.range(
                of: inlineCorrectionPattern,
                options: .regularExpression
            ) != nil
        }
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
        let publicScenes: Set<WritingScene> = [
            .workChat, .email, .document, .socialPost, .customerSupport,
        ]
        guard publicScenes.contains(request.context.scene) else { return false }
        let source = normalizedNaturalText(request.fallbackText).lowercased()
        let readerFacingSignals = [
            "上一条", "上一版", "刚才发的", "刚才写的", "此前发布", "此前发送",
            "向大家", "请以", "以这条为准", "以本条为准", "更正通知",
            "纠错通知", "勘误", "公告",
        ]
        let correctionSignals = [
            "说错", "误将", "错误", "有误", "正确日期", "正确时间", "正确名称", "正确说法",
        ]
        let publishedArtifactSignals = [
            "视频", "文章里", "文章中", "公告中", "发布内容",
            "已经发布", "已发布", "预约链接",
        ]
        let audienceSignals = ["大家", "读者", "用户", "客户", "观众", "学员"]
        let correctionOffsets = correctionSignals.flatMap { signal in
            allRanges(of: signal, in: source).map {
                source.distance(from: source.startIndex, to: $0.lowerBound)
            }
        }
        guard !correctionOffsets.isEmpty else { return false }
        func signalIsNearCorrection(_ signals: [String], maximumDistance: Int = 120) -> Bool {
            signals.contains { signal in
                allRanges(of: signal, in: source).contains { range in
                    let offset = source.distance(from: source.startIndex, to: range.lowerBound)
                    return correctionOffsets.contains { abs($0 - offset) <= maximumDistance }
                }
            }
        }
        let hasReaderFacingEvidence = signalIsNearCorrection(readerFacingSignals)
            || (signalIsNearCorrection(publishedArtifactSignals)
                && (request.context.scene == .socialPost
                    || signalIsNearCorrection(audienceSignals)))
        return hasReaderFacingEvidence
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
        let preservedDeclaredCount = VoicePolishListCountConsistency
            .preservedDeclaredCountEvidence(
                in: output,
                canonicalSource: request.fallbackText
            )
        if outputFacts.contains(where: { outputFact in
            !sourceFacts.contains(where: { equivalent($0, outputFact) })
                && !isSourceBackedFormattingFact(
                    outputFact,
                    request: request
                )
                && preservedDeclaredCount?.backsCandidateFact(outputFact) != true
        }) {
            append(.planIntegrityFailure, to: &codes)
        }
        let protectedCanonicalValues = Set(planFacts.compactMap { fact -> String? in
            guard fact.disposition == .mustPreserve || fact.disposition == .uncertain else { return nil }
            return canonicalValue(for: fact)
        })

        for fact in planFacts {
            let isPresent = containsEquivalent(fact, in: outputFacts, output: output)
                || preservedDeclaredCount?.satisfiesSourceFact(fact) == true
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
        let layoutInsensitiveSource = layoutInsensitiveDraft(request.fallbackText)
        let layoutInsensitiveOutput = layoutInsensitiveDraft(output)
        let normalizedOutput = normalizedNaturalText(output)
        // 只加标点或换行、却完整保留“嗯/我我/这个这个”等口述残片，仍然
        // 不是成稿。长文只检查未处于引号/示例语境的高置信残片，避免文档在
        // 讲解口吃示例时被误退。
        let sourceDisfluencies = request.fallbackText.count <= 80
            ? obviousDisfluencies(in: request.fallbackText)
            : highConfidenceLongDraftDisfluencies(in: request.fallbackText)
        let retainsSourceDisfluency = sourceDisfluencies.contains {
            normalizedOutput.contains(normalizedNaturalText($0))
        }
        let repairedMissingTerminalPunctuation = needsTerminalPunctuationRepair(request)
            && hasTerminalPunctuation(output)
        let sourcePunctuationIssues = VoicePolishPunctuationRepair.issues(
            in: request.fallbackText
        )
        let repairedLocalPunctuationIssues = !sourcePunctuationIssues.isEmpty
            && VoicePolishPunctuationRepair.issues(in: output).isEmpty
        let completedLocalOnlyRepair = repairedMissingTerminalPunctuation
            || repairedLocalPunctuationIssues
        let exactLongDraftNeedsAnotherPass = request.fallbackText.count > 80
            && request.context.scene != .code
            && !isClearlyStructuredSendReadySource(request)
            && layoutInsensitiveSource == layoutInsensitiveOutput
        let transformationStillMissing = (
            (comparableSource == comparableOutput || exactLongDraftNeedsAnotherPass)
                && !completedLocalOnlyRepair
        ) || retainsSourceDisfluency
        guard (requiresTransformation(request) || exactLongDraftNeedsAnotherPass),
              transformationStillMissing else {
            return
        }
        append(.unchangedDraft, to: &codes)
    }

    private static func needsTerminalPunctuationRepair(
        _ request: VoicePolishRequest
    ) -> Bool {
        guard request.context.scene != .code else { return false }
        let source = request.fallbackText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let semanticCharacters = source.filter {
            !$0.isWhitespace && !$0.isPunctuation && !$0.isSymbol
        }
        guard semanticCharacters.count >= 6 else { return false }
        return !hasTerminalPunctuation(source)
    }

    private static func hasTerminalPunctuation(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).range(
            of: #"[。！？!?…](?:[”’\"』」）)】])?$"#,
            options: .regularExpression
        ) != nil
    }

    private static func isClearlyStructuredSendReadySource(
        _ request: VoicePolishRequest
    ) -> Bool {
        let expectation = VoicePolishLayoutExpectation.infer(from: request)
        guard expectation.kind == .numberedList || expectation.kind == .bulletList else {
            return false
        }
        let itemCount = VoicePolishNumbering.recognizedListItemCount(
            in: request.fallbackText
        )
        guard itemCount >= 2 else { return false }
        if let expected = expectation.expectedListItemCount {
            return itemCount == expected
        }
        if let minimum = expectation.minimumListItemCount {
            return itemCount >= minimum
        }
        return true
    }

    private static func highConfidenceLongDraftDisfluencies(in text: String) -> [String] {
        let fixedRestarts = [
            "我我", "你你", "他他", "她她", "它它", "不不", "第第",
            "这个这个", "那个那个", "大大概", "突突然", "帮我帮我", "麻烦麻烦",
        ]
        var results: [String] = []

        func isInsideQuotedOrLocalExample(
            _ range: Range<String.Index>,
            in scope: String
        ) -> Bool {
            let before = String(scope[..<range.lowerBound])
            let after = String(scope[range.upperBound...])
            let lastOpen = before.lastIndex(where: { "“‘".contains($0) })
            let lastClose = before.lastIndex(where: { "”’".contains($0) })
            if let lastOpen,
               lastClose == nil || lastOpen > lastClose!,
               after.contains(where: { "”’".contains($0) }) {
                return true
            }
            if before.filter({ $0 == "\"" }).count % 2 == 1,
               after.contains("\"") {
                return true
            }
            let localSuffix = normalizedNaturalText(String(after.prefix(40)))
            let metalinguisticPatterns = [
                #"^.{0,12}(?:属于|是|只是)(?:典型的?)?(?:口吃|示例|样例)"#,
                #"^.{0,12}保留.{0,8}(?:没有意义|没有必要)"#,
                #"^.{0,12}(?:应该|需要|应当)(?:被)?清理"#,
            ]
            // “比如/例如”也常用于普通叙述，不能因此豁免其后整段里的真实口吃。
            // 无引号时必须由紧随残片的元语言说明证明“这里正在讲示例”。
            return metalinguisticPatterns.contains {
                localSuffix.range(of: $0, options: .regularExpression) != nil
            }
        }

        // 口吃示例的解释可能紧跟在逗号后的下一小句中，所以固定残片在全文
        // 范围定位；填充词仍按小句起点检查，避免正文中普通语气词被误判。
        for fragment in fixedRestarts {
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let range = text.range(
                    of: fragment,
                    range: searchStart..<text.endIndex
                  ) {
                if !isInsideQuotedOrLocalExample(range, in: text) {
                    results.append(fragment)
                }
                searchStart = range.upperBound
            }
        }
        for clause in semanticClauses(in: text) {
            if let filler = clause.range(
                of: #"^\s*(?:嗯+|呃+|额+)(?=\s|[\p{Han}])"#,
                options: .regularExpression
            ), !isInsideQuotedOrLocalExample(filler, in: clause) {
                let value = String(clause[filler])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { results.append(value) }
            }
        }

        // 长语音即使已经有句号和分段，仍可能只是 ASR 原稿。
        // “然后的话/怎么说呢”位于小句起点时是高置信口语支架；“就是说”
        // 单独也可能承担解释功能，只在全文同时存在其他口语支架时才拦截。
        var discourseFillers: [String] = []
        for clause in semanticClauses(in: text) {
            let normalizedClause = normalizedNaturalText(clause)
            for phrase in ["然后的话", "怎么说呢", "就是说"]
                where normalizedClause.hasPrefix(phrase) {
                guard let range = clause.range(of: phrase),
                      !isInsideQuotedOrLocalExample(range, in: clause) else { continue }
                discourseFillers.append(phrase)
            }
        }
        let hasStrongDiscourseFiller = discourseFillers.contains {
            $0 == "然后的话" || $0 == "怎么说呢"
        }
        if hasStrongDiscourseFiller || discourseFillers.count >= 2 {
            results.append(contentsOf: discourseFillers)
        }
        return Array(Set(results)).sorted()
    }

    private static func obviousDisfluencies(in text: String) -> [String] {
        let normalized = normalizedNaturalText(text)
        var results = [
            "我我", "你你", "他他", "她她", "它它", "不不", "第第",
            "大大概", "突突然", "帮我帮我", "麻烦麻烦", "今天今天",
        ].filter { normalized.contains(normalizedNaturalText($0)) }
        results.append(contentsOf: repeatedSpeechFragments(in: text))
        results.append(contentsOf: delimitedFillerWords(in: text))
        return Array(Set(results)).sorted()
    }

    private static func delimitedFillerWords(in text: String) -> [String] {
        guard text.count <= 80 else { return [] }
        var results: [String] = []
        if let leading = text.range(
            of: #"^\s*((?:嗯+|呃+|额+)(?:\s*(?:那个|这个))?)(?=\s|[，,。！？!?；;]|[\p{Han}])"#,
            options: .regularExpression
        ) {
            let value = String(text[leading])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { results.append(value) }
        }
        guard let regex = try? NSRegularExpression(
                  pattern: #"(?:^|[\s，,。！？!?；;])((?:嗯+|呃+|额+))(?=$|[\s，,。！？!?；;])"#
              ) else { return results }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        results.append(contentsOf: regex.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[matchRange])
        })
        return Array(Set(results)).sorted()
    }

    /// 捕获开放词汇里的相邻起步重复，例如“这这周五”“功功能”和
    /// “你明天你明天”。有意强调与常见词汇重叠会被排除，避免把“好好学习”
    /// 或“真的真的很好”当口吃。这里只用于 80 字以内的残留门禁。
    private static func repeatedSpeechFragments(in text: String) -> [String] {
        guard text.count <= 80 else { return [] }
        let characters = Array(text)
        let protectedPhrases = deliberateRepetitionPhrases(in: text)
        var protectedIndices = Set<Int>()
        for phrase in protectedPhrases {
            let phraseCharacters = Array(phrase)
            guard !phraseCharacters.isEmpty, phraseCharacters.count <= characters.count else {
                continue
            }
            for start in 0...(characters.count - phraseCharacters.count) where
                Array(characters[start..<(start + phraseCharacters.count)]) == phraseCharacters {
                protectedIndices.formUnion(start..<(start + phraseCharacters.count))
            }
        }

        let lexicalReduplications: Set<String> = [
            "看看", "想想", "说说", "聊聊", "问问", "听听", "试试", "走走",
            "等等", "找找", "读读", "写写", "学学", "用用", "改改", "尝尝",
            "谢谢", "妈妈", "爸爸", "爷爷", "奶奶", "哥哥", "姐姐", "弟弟",
            "妹妹", "宝宝", "星星", "人人", "家家", "户户", "处处", "时时",
            "天天", "年年", "刚刚", "渐渐", "慢慢", "常常", "往往", "仅仅",
            "偏偏", "恰恰", "足足", "久久", "轻轻", "纷纷", "明明", "好好",
            "哈哈", "呵呵", "嘿嘿", "嘻嘻", "彬彬", "楚楚", "津津",
            "滔滔", "井井", "念念", "欣欣", "亭亭", "落落", "息息",
            "面面", "头头", "历历", "栩栩", "侃侃", "姗姗", "喋喋",
        ]
        let grammaticalRepeatedUnits: Set<String> = [
            "研究", "考虑", "讨论", "商量", "检查", "确认", "了解", "分析",
            "比较", "整理", "规划", "调整", "观察", "总结", "沟通", "安排",
        ]

        func isHan(_ character: Character) -> Bool {
            guard character.unicodeScalars.count == 1,
                  let value = character.unicodeScalars.first?.value else { return false }
            return (0x3400...0x4DBF).contains(value)
                || (0x4E00...0x9FFF).contains(value)
                || (0xF900...0xFAFF).contains(value)
                || (0x20000...0x3134F).contains(value)
        }

        var fragments: [String] = []
        guard characters.count >= 2 else { return [] }

        // 借助系统中文分词识别开放词汇里的 partial-word restart：
        // “可｜可以”“功｜功能”会被分成一个单字残片和一个以它开头的完整词，
        // 而“太太”“叔叔”仍是一个合法词。对相邻整词重复，仅把非动词视为
        // 高置信口吃，所以“周五周五发”需清理，“学习学习方案”保留。
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var wordTokens: [(text: String, range: Range<String.Index>)] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let token = String(text[range])
            if token.contains(where: isHan) {
                wordTokens.append((token, range))
            }
            return true
        }
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        if wordTokens.count >= 2 {
            for index in 0..<(wordTokens.count - 1) {
                let first = wordTokens[index]
                let second = wordTokens[index + 1]
                let firstText = normalizedNaturalText(first.text)
                let secondText = normalizedNaturalText(second.text)
                guard !firstText.isEmpty, !secondText.isEmpty else { continue }
                let combined = firstText + secondText
                if protectedPhrases.contains(where: {
                    normalizedNaturalText($0) == combined
                }) {
                    continue
                }
                if firstText.count == 1,
                   secondText.count >= 2,
                   secondText.hasPrefix(firstText) {
                    fragments.append(combined)
                    continue
                }
                if firstText == secondText, firstText.count >= 2 {
                    let lexicalClass = tagger.tag(
                        at: first.range.lowerBound,
                        unit: .word,
                        scheme: .lexicalClass
                    ).0
                    if lexicalClass != .verb {
                        fragments.append(combined)
                    }
                }
            }
        }

        // “好好好像可以”不是词汇“好好”，而是“好 | 好像”的起步重来。
        // 三个相同汉字后仍紧接正文时是高置信 partial-word restart；位于句界的
        // “好好好”仍由 deliberateRepetitionPhrases 保护。
        if characters.count >= 4 {
            for start in 0...(characters.count - 4) {
                let first = characters[start]
                guard isHan(first),
                      characters[start + 1] == first,
                      characters[start + 2] == first,
                      isHan(characters[start + 3]),
                      characters[start + 3] != first else { continue }
                let range = start..<(start + 3)
                if !range.allSatisfy({ protectedIndices.contains($0) }) {
                    fragments.append(String(characters[range]))
                }
            }
        }

        let highConfidenceRestartInitials: Set<Character> = [
            "我", "你", "他", "她", "它", "这", "那", "哪", "谁", "怎",
            "第", "突", "不", "没", "请", "帮", "麻", "就", "还", "再",
        ]
        for unitLength in stride(from: 4, through: 1, by: -1) {
            guard characters.count >= unitLength * 2 else { continue }
            for start in 0...(characters.count - unitLength * 2) {
                let first = Array(characters[start..<(start + unitLength)])
                let second = Array(characters[(start + unitLength)..<(start + unitLength * 2)])
                guard first == second, first.allSatisfy(isHan) else { continue }
                let range = start..<(start + unitLength * 2)
                if range.allSatisfy({ protectedIndices.contains($0) }) { continue }
                let fragment = String(characters[range])
                if unitLength == 1, lexicalReduplications.contains(fragment) { continue }
                if unitLength >= 2, grammaticalRepeatedUnits.contains(String(first)) { continue }
                // 未知 AA/ABAB 默认视为可能的合法叠词或语气，不以有限词表
                // 反推它一定是口吃。只有句首功能词/人称词等高置信 restart 才
                // 作为硬门禁；其余交给模型保守保留。
                if unitLength == 1,
                   !highConfidenceRestartInitials.contains(first[0]) {
                    continue
                }
                if unitLength >= 2,
                   !highConfidenceRestartInitials.contains(first[0]) {
                    continue
                }
                fragments.append(fragment)
            }
        }
        return Array(Set(fragments)).sorted()
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

        let explicitCorrectionSignals = [
            "我说错了", "我改一下", "我的意思是", "前面那句改成",
            "刚才那句改成", "把开头改成", "最终决定", "最后还是",
            "scratch that", "i mean", "actually",
        ]
        if explicitCorrectionSignals.contains(where: normalized.contains) { return true }
        if source.range(
            of: #"(?:^|[，,。！？!?；;])\s*不对(?:\s*[，,：:]\s*(?=\S)|\s*(?=还是|应该说|准确地说|更准确地说))"#,
            options: .regularExpression
        ) != nil {
            return true
        }

        let sourceFacts = ProtectedFactExtractor.extract(from: request.input.segments)
        if !locallySupersededFactIndices(
            request: request,
            sourceFacts: sourceFacts
        ).isEmpty {
            return true
        }

        if !obviousDisfluencies(in: source).isEmpty
            || !highConfidenceLongDraftDisfluencies(in: source).isEmpty {
            return true
        }

        let expectation = VoicePolishLayoutExpectation.infer(from: request)
        if (expectation.kind == .numberedList || expectation.kind == .bulletList),
           VoicePolishNumbering.recognizedListItemCount(in: source) > 0 {
            // 已经形成完整逐行列表的文本允许原样保留。列表项不以句号结尾并不
            // 等于“长文本没有标点”，不能因此触发一次注定无意义的修复请求。
            return false
        }

        if needsTerminalPunctuationRepair(request) {
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
            .filter { !$0.isPunctuation }
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private static func layoutInsensitiveDraft(_ text: String) -> String {
        VoicePolishCharacterSafety.normalizedLineEndings(text)
            .filter { !$0.isPunctuation && !$0.isWhitespace }
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
        // 长口述的核心目标是整理成可直接发送的完整成稿，不是摘要。只看最大
        // 长度无法阻止模型把近千字独立约束压成百字套话；同时按原始字符比例
        // 又会误伤大量口吃/重复。这里先把重复语义片段去重，再使用很保守的 30%
        // 下限：只拦截明显截断或摘要，正常删口头冗余仍有充分空间。
        if sourceText.count >= 500 {
            let sourceSemanticLength = distinctSemanticContentLength(sourceText)
            let outputSemanticLength = distinctSemanticContentLength(trimmed)
            if sourceSemanticLength >= 240,
               outputSemanticLength * 10 < sourceSemanticLength * 3 {
                append(.abnormalLength, to: &codes)
            }
        }
        // 长文可以天然拥有很多语义段。固定“最多六段”会把正常的会议纪要、
        // 邮件和文档判成失败，最终又静默退回整段口述。阈值随源文本长度有界
        // 增长；短文本仍保持原来的六段上限，超长文本最多允许六十四段。
        // 超长正文按语义分段后可能自然超过 32 段。上限仍随原文长度受控，
        // 但不能把完整的 6k～8k 字成稿误判成“段落过多”再退回原文。
        let paragraphLimit = max(6, min(64, sourceText.count / 100 + 8))
        if trimmed.components(separatedBy: "\n\n").filter({ !$0.isEmpty }).count > paragraphLimit {
            append(.excessiveParagraphs, to: &codes)
        }
        return codes
    }

    private static func distinctSemanticContentLength(_ text: String) -> Int {
        var seen = Set<String>()
        return semanticClauses(in: text).reduce(into: 0) { total, clause in
            let normalizedClause = normalizedNaturalText(clause).lowercased()
            guard !normalizedClause.isEmpty,
                  seen.insert(normalizedClause).inserted else { return }
            total += normalizedClause.count
        }
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
        if candidate.kind == .filePath, let canonical = candidate.canonicalValue {
            return output.contains(canonical)
        }
        if candidate.kind == .version, let canonical = candidate.canonicalValue {
            return output.localizedCaseInsensitiveContains(canonical)
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
        if fact.kind == .filePath, let canonical = canonicalValue(for: fact) {
            return output.contains(canonical)
        }
        if fact.kind == .version, let canonical = canonicalValue(for: fact) {
            return output.localizedCaseInsensitiveContains(canonical)
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
