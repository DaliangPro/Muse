import Foundation

/// 编号列表采用的可见编号风格。项目符号列表和普通段落使用 `.none`。
enum VoicePolishNumberingPreference: String, Codable, Sendable, Equatable {
    case none
    case arabic
    case chinese
}

/// 从本地可验证信号推导出的成稿版式契约。
///
/// 该类型不负责生成正文，只把原文结构、写作场景和用户明确格式偏好转换为
/// Pipeline 与 Validator 都能复用的最小要求。所有判断均为确定性本地逻辑，
/// 不会为了满足版式而要求模型补写不存在的内容。
struct VoicePolishLayoutExpectation: Codable, Sendable, Equatable {
    let kind: OutputKind
    let minimumParagraphCount: Int
    let expectedListItemCount: Int?
    let minimumListItemCount: Int?
    let numberingPreference: VoicePolishNumberingPreference
    /// 用户是否明确禁止所有形式的列表。
    let forbidsLists: Bool
    /// 用户是否明确禁止数字或中文序号列表（禁止所有列表时也为 `true`）。
    let forbidsNumberedList: Bool
    /// 用户是否明确禁止项目符号列表（禁止所有列表时也为 `true`）。
    let forbidsBulletList: Bool
    /// 用户是否明确要求单段、禁止换行。
    let forbidsLineBreaks: Bool

    init(
        kind: OutputKind,
        minimumParagraphCount: Int,
        expectedListItemCount: Int?,
        minimumListItemCount: Int?,
        numberingPreference: VoicePolishNumberingPreference,
        forbidsLists: Bool = false,
        forbidsNumberedList: Bool = false,
        forbidsBulletList: Bool = false,
        forbidsLineBreaks: Bool = false
    ) {
        self.kind = kind
        self.minimumParagraphCount = minimumParagraphCount
        self.expectedListItemCount = expectedListItemCount
        self.minimumListItemCount = minimumListItemCount
        self.numberingPreference = numberingPreference
        self.forbidsLists = forbidsLists
        self.forbidsNumberedList = forbidsLists || forbidsNumberedList
        self.forbidsBulletList = forbidsLists || forbidsBulletList
        self.forbidsLineBreaks = forbidsLineBreaks
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case minimumParagraphCount
        case expectedListItemCount
        case minimumListItemCount
        case numberingPreference
        case forbidsLists
        case forbidsNumberedList
        case forbidsBulletList
        case forbidsLineBreaks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            kind: try container.decode(OutputKind.self, forKey: .kind),
            minimumParagraphCount: try container.decode(Int.self, forKey: .minimumParagraphCount),
            expectedListItemCount: try container.decodeIfPresent(Int.self, forKey: .expectedListItemCount),
            minimumListItemCount: try container.decodeIfPresent(Int.self, forKey: .minimumListItemCount),
            numberingPreference: try container.decode(
                VoicePolishNumberingPreference.self,
                forKey: .numberingPreference
            ),
            forbidsLists: try container.decodeIfPresent(Bool.self, forKey: .forbidsLists) ?? false,
            forbidsNumberedList: try container.decodeIfPresent(
                Bool.self,
                forKey: .forbidsNumberedList
            ) ?? false,
            forbidsBulletList: try container.decodeIfPresent(
                Bool.self,
                forKey: .forbidsBulletList
            ) ?? false,
            forbidsLineBreaks: try container.decodeIfPresent(
                Bool.self,
                forKey: .forbidsLineBreaks
            ) ?? false
        )
    }

    static func infer(from request: VoicePolishRequest) -> VoicePolishLayoutExpectation {
        let source = request.fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        let requirements = request.preferences.additionalRequirements
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let preferences = FormatPreferences(text: requirements)
        let signals = SourceSignals(
            text: source,
            segmentCount: request.input.segments.filter {
                !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }.count,
            scene: request.context.scene
        )

        // “不要分段/单段”是最强的版式约束。矛盾偏好采取更保守的一段正文，
        // 避免应用擅自制造用户明确拒绝的换行。
        if preferences.forbidsParagraphs {
            return sentence(preferences: preferences)
        }

        let listableItemCount = signals.listableItemCount
        let hasListableContent = listableItemCount >= 2

        if preferences.allowsAnyList, hasListableContent {
            if preferences.prefersNumberedList {
                return list(
                    kind: .numberedList,
                    expectedCount: signals.orderedExpectedItemCount,
                    minimumCount: signals.minimumListCount,
                    numbering: preferences.numberingPreference(in: source),
                    preferences: preferences
                )
            }

            if preferences.prefersBulletList {
                return list(
                    kind: .bulletList,
                    expectedCount: signals.explicitBulletItemCount ?? signals.declaredListCount,
                    minimumCount: signals.minimumListCount,
                    numbering: .none,
                    preferences: preferences
                )
            }

            if signals.explicitBulletCount >= 2 {
                return list(
                    kind: preferences.forbidsBulletList ? .numberedList : .bulletList,
                    expectedCount: signals.explicitBulletCount,
                    minimumCount: signals.explicitBulletCount,
                    numbering: preferences.forbidsBulletList
                        ? signals.defaultNumberingPreference
                        : .none,
                    preferences: preferences
                )
            }

            if signals.explicitOrderedCount >= 2 {
                return list(
                    kind: preferences.forbidsNumberedList ? .bulletList : .numberedList,
                    expectedCount: signals.orderedExpectedItemCount,
                    minimumCount: signals.minimumListCount,
                    numbering: preferences.forbidsNumberedList
                        ? .none
                        : signals.explicitNumberingPreference,
                    preferences: preferences
                )
            }

            if signals.declaredMinimumListCount >= 2 {
                return list(
                    kind: preferences.forbidsNumberedList ? .bulletList : .numberedList,
                    expectedCount: signals.declaredListCount,
                    minimumCount: signals.minimumListCount,
                    numbering: preferences.forbidsNumberedList
                        ? .none
                        : signals.defaultNumberingPreference,
                    preferences: preferences
                )
            }

            if signals.implicitStepCount >= 3 {
                return list(
                    kind: preferences.forbidsNumberedList ? .bulletList : .numberedList,
                    expectedCount: nil,
                    minimumCount: signals.minimumListCount,
                    numbering: preferences.forbidsNumberedList
                        ? .none
                        : signals.defaultNumberingPreference,
                    preferences: preferences
                )
            }

            if signals.hasStrongParallelIntroduction,
               signals.strongParallelItemCount >= 3,
               !preferences.prefersParagraphs {
                return list(
                    kind: preferences.forbidsBulletList ? .numberedList : .bulletList,
                    expectedCount: nil,
                    minimumCount: signals.minimumListCount,
                    numbering: preferences.forbidsBulletList
                        ? signals.defaultNumberingPreference
                        : .none,
                    preferences: preferences
                )
            }
        }

        let paragraphCandidateCount = signals.paragraphCandidateCount
        if preferences.prefersParagraphs,
           (paragraphCandidateCount >= 2 || signals.isLongEnoughForRequestedParagraphs) {
            let requested = preferences.requestedParagraphCount
            let availableCount = max(
                paragraphCandidateCount,
                signals.isLongEnoughForRequestedParagraphs ? 2 : 1
            )
            let minimum = requested.map { min($0, availableCount) }
                ?? signals.recommendedParagraphCount
            return paragraphs(minimumCount: minimum, preferences: preferences)
        }

        if signals.isLongMultiTopic {
            return paragraphs(
                minimumCount: signals.recommendedParagraphCount,
                preferences: preferences
            )
        }

        // ASR 标点缺失时不能要求“多句/多主题”证据后才分段，否则最需要整理的
        // 长口述反而会整块通过。代码场景与用户明确单段要求已在前面排除；其余
        // 达到长文阈值的内容至少给出两段契约，具体语义断点由模型与安全 formatter 决定。
        if signals.isLong, signals.allowsAutomaticParagraphs {
            return paragraphs(minimumCount: 2, preferences: preferences)
        }

        // 禁止列表时，原本可列点的长内容仍可自然分段；短内容保持普通句子。
        if preferences.forbidsAllLists,
           signals.isLong,
           paragraphCandidateCount >= 2 {
            return paragraphs(
                minimumCount: signals.recommendedParagraphCount,
                preferences: preferences
            )
        }

        return sentence(preferences: preferences)
    }

    /// 供版式判断与复杂度路由共用同一套“换话题”证据，避免 Router 仅凭
    /// “另外一个问题”这样的名词修饰语就错误进入 Deep。
    static func containsTopicSwitchEvidence(in text: String) -> Bool {
        topicSwitchEvidenceCount(in: text) > 0
    }

    /// 只有明确宣布切换议题、或“另外一个问题是/在于……”这类强语义转折，
    /// 才值得提高模型推理档位。普通的“另外预算”“接下来”仍由一次 Fast
    /// 请求和本地自然分段处理。
    static func containsComplexTopicSwitchEvidence(in text: String) -> Bool {
        regexMatchCount(
            #"换个话题|回到刚才|先说另一件事|另外(?:一个|一件|一点)(?:问题|事情|事项|任务|主题|话题|需求|风险|建议|方案|原因|要点|安排|选择|选项)(?=\s*(?:是|在于|[：:]))|(?i:\bdifferent\s+topic\b|\bback\s+to\s+the\s+earlier\s+(?:point|topic)\b|\banother\s+(?:issue|topic)\s+(?:is|:))"#,
            in: text
        ) > 0
    }

    private static func topicSwitchEvidenceCount(in text: String) -> Int {
        regexMatchCount(
            #"另外(?:[，,]|(?:一个|一件|一点)(?:问题|事情|事项|任务|主题|话题|需求|风险|建议|方案|原因|要点|安排|选择|选项)(?=\s*(?:是|在于|还|也|需要|需|要|得|应该|必须|尚未|没有|没|已经|目前|仍|方面|[：:,，])))|另外(?=(?:预算|成本|费用|进度|测试|排期|上线|交付|合同|人员|资源|时间|风险|权限|数据|模型|方案|需求|提示词)(?:还|也|需要|需|要|得|应该|必须|尚未|没有|没|已经|目前|仍|方面))|另一方面|接下来|再说|先说另一件事|关于|至于|换个话题|回到刚才|第二个(?:问题|主题)|(?i:\banother\s+topic\b|\bon\s+the\s+other\s+hand\b|\bmoving\s+on\b|\bas\s+for\b|\bregarding\b|\bseparately\b|\bin\s+addition\b)"#,
            in: text
        )
    }

    private static func sentence(
        preferences: FormatPreferences
    ) -> VoicePolishLayoutExpectation {
        make(
            kind: .sentence,
            minimumParagraphCount: 1,
            expectedListItemCount: nil,
            minimumListItemCount: nil,
            numberingPreference: .none,
            preferences: preferences
        )
    }

    private static func paragraphs(
        minimumCount: Int,
        preferences: FormatPreferences
    ) -> VoicePolishLayoutExpectation {
        make(
            kind: .paragraphs,
            minimumParagraphCount: max(2, minimumCount),
            expectedListItemCount: nil,
            minimumListItemCount: nil,
            numberingPreference: .none,
            preferences: preferences
        )
    }

    private static func list(
        kind: OutputKind,
        expectedCount: Int?,
        minimumCount: Int,
        numbering: VoicePolishNumberingPreference,
        preferences: FormatPreferences
    ) -> VoicePolishLayoutExpectation {
        let normalizedExpected = expectedCount.map { max(2, $0) }
        return make(
            kind: kind,
            minimumParagraphCount: 1,
            expectedListItemCount: normalizedExpected,
            minimumListItemCount: max(2, min(normalizedExpected ?? minimumCount, minimumCount)),
            numberingPreference: kind == .numberedList ? numbering : .none,
            preferences: preferences
        )
    }

    private static func make(
        kind: OutputKind,
        minimumParagraphCount: Int,
        expectedListItemCount: Int?,
        minimumListItemCount: Int?,
        numberingPreference: VoicePolishNumberingPreference,
        preferences: FormatPreferences
    ) -> VoicePolishLayoutExpectation {
        VoicePolishLayoutExpectation(
            kind: kind,
            minimumParagraphCount: minimumParagraphCount,
            expectedListItemCount: expectedListItemCount,
            minimumListItemCount: minimumListItemCount,
            numberingPreference: numberingPreference,
            forbidsLists: preferences.forbidsAllLists,
            forbidsNumberedList: preferences.forbidsNumberedList,
            forbidsBulletList: preferences.forbidsBulletList,
            forbidsLineBreaks: preferences.forbidsParagraphs
        )
    }
}

private extension VoicePolishLayoutExpectation {
    struct FormatPreferences {
        let normalized: String
        let forbidsAllLists: Bool
        let forbidsNumberedList: Bool
        let forbidsBulletList: Bool
        let forbidsParagraphs: Bool
        let prefersNumberedList: Bool
        let prefersBulletList: Bool
        let prefersParagraphs: Bool
        let requestedParagraphCount: Int?

        init(text: String) {
            let normalizedText = text
                .replacingOccurrences(of: "’", with: "'")
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            normalized = normalizedText
            let numberedPositive = Self.lastPositiveDirectiveLocation(
                Self.numberedListPhrases,
                excluding: Self.noNumberedListPhrases + Self.noListPhrases,
                in: normalizedText
            )
            let bulletPositive = Self.lastPositiveDirectiveLocation(
                Self.bulletListPhrases,
                excluding: Self.noBulletListPhrases + Self.noListPhrases,
                in: normalizedText
            )
            let paragraphPositive = Self.lastPositiveDirectiveLocation(
                Self.paragraphPhrases,
                excluding: Self.noParagraphPhrases,
                in: normalizedText
            )
            let allListBan = Self.lastUnconditionalDirectiveLocation(
                Self.noListPhrases,
                in: normalizedText
            )
            let numberedBan = Self.lastUnconditionalDirectiveLocation(
                Self.noNumberedListPhrases,
                in: normalizedText
            )
            let bulletBan = Self.lastUnconditionalDirectiveLocation(
                Self.noBulletListPhrases,
                in: normalizedText
            )
            let paragraphBan = Self.lastUnconditionalDirectiveLocation(
                Self.noParagraphPhrases,
                in: normalizedText
            )

            let allBanStillBlocksNumbered = allListBan.map { banLocation in
                !Self.hasExplicitPositiveDirective(
                    Self.numberedListPhrases,
                    excluding: Self.noNumberedListPhrases + Self.noListPhrases,
                    after: banLocation,
                    in: normalizedText
                )
            } ?? false
            let allBanStillBlocksBullets = allListBan.map { banLocation in
                !Self.hasExplicitPositiveDirective(
                    Self.bulletListPhrases,
                    excluding: Self.noBulletListPhrases + Self.noListPhrases,
                    after: banLocation,
                    in: normalizedText
                )
            } ?? false
            forbidsAllLists = allBanStillBlocksNumbered && allBanStillBlocksBullets
            forbidsNumberedList = allBanStillBlocksNumbered || numberedBan.map { banLocation in
                !Self.hasExplicitPositiveDirective(
                    Self.numberedListPhrases,
                    excluding: Self.noNumberedListPhrases + Self.noListPhrases,
                    after: banLocation,
                    in: normalizedText
                )
            } ?? false
            forbidsBulletList = allBanStillBlocksBullets || bulletBan.map { banLocation in
                !Self.hasExplicitPositiveDirective(
                    Self.bulletListPhrases,
                    excluding: Self.noBulletListPhrases + Self.noListPhrases,
                    after: banLocation,
                    in: normalizedText
                )
            } ?? false
            forbidsParagraphs = paragraphBan.map { banLocation in
                !Self.hasExplicitPositiveDirective(
                    Self.paragraphPhrases,
                    excluding: Self.noParagraphPhrases,
                    after: banLocation,
                    in: normalizedText
                )
            } ?? false

            prefersNumberedList = !forbidsNumberedList && numberedPositive != nil
            prefersBulletList = !forbidsBulletList
                && !prefersNumberedList
                && bulletPositive != nil
            prefersParagraphs = !forbidsParagraphs && paragraphPositive != nil
            requestedParagraphCount = Self.requestedParagraphCount(in: normalizedText)
        }

        var allowsAnyList: Bool {
            !forbidsNumberedList || !forbidsBulletList
        }

        func numberingPreference(in source: String) -> VoicePolishNumberingPreference {
            let chineseLocation = Self.lastPositiveDirectiveLocation(
                Self.chineseNumberingPhrases,
                excluding: Self.noNumberedListPhrases,
                in: normalized
            )
            let arabicLocation = Self.lastPositiveDirectiveLocation(
                Self.arabicNumberingPhrases,
                excluding: Self.noNumberedListPhrases,
                in: normalized
            )
            if let chineseLocation, let arabicLocation {
                return chineseLocation > arabicLocation ? .chinese : .arabic
            }
            if chineseLocation != nil { return .chinese }
            if arabicLocation != nil { return .arabic }

            let sourceArabic = regexLastMatchLocation(
                #"(?m)(?:^|[。.!?！？；;，,\n])\s*\d{1,2}[.)、）]\s*"#,
                in: source
            )
            let sourceChinese = regexLastMatchLocation(
                #"第(?:[一二三四五六七八九十]{1,3}|\d+)(?:点|条|项|步|个|部分|方面|[，、,:：.）)\s])|(?m)(?:^|[。！？；;，,\n])\s*[一二三四五六七八九十](?:是|、|[.)）])"#,
                in: source
            )
            if let sourceArabic, let sourceChinese {
                return sourceChinese > sourceArabic ? .chinese : .arabic
            }
            if sourceChinese != nil { return .chinese }
            if sourceArabic != nil { return .arabic }
            return .arabic
        }

        private static let noListPhrases = [
            "不要列点", "不要列表", "不用列点", "不用列表", "别列点", "别用列表",
            "不使用列表", "不要随便使用列表", "不要任何列表", "禁止列表",
            "no list", "no lists", "without a list", "without lists",
            "do not use lists", "don't use lists", "avoid lists", "not a list",
        ]

        private static let noNumberedListPhrases = [
            "不要编号", "不用编号", "别编号", "不使用编号", "不要序号", "不用序号",
            "不要一二三", "不用一二三", "不要数字列表", "不要数字编号", "禁止编号",
            "no numbered list", "no numbered lists", "without numbering",
            "do not number", "don't number", "do not use numbering", "don't use numbering",
            "avoid numbering", "no numbering",
        ]

        private static let noBulletListPhrases = [
            "不要项目符号", "不用项目符号", "别用项目符号", "不使用项目符号",
            "禁止项目符号", "不要圆点", "不用圆点",
            "no bullets", "without bullets", "do not use bullets", "don't use bullets",
            "avoid bullets", "no bullet list", "no bullet lists",
        ]

        private static let noParagraphPhrases = [
            "不要分段", "不用分段", "别分段", "不分段", "不要换行", "不换行",
            "合并成一段", "保持一段话", "写成一段话", "整理成一段话", "输出一段话",
            "保持单段", "写成单段", "输出单段", "采用单段",
            "no paragraph", "no paragraphs",
            "no line break", "no line breaks", "without line breaks",
            "do not split into paragraphs", "don't split into paragraphs",
            "keep it to one paragraph", "use one paragraph", "write as one paragraph",
            "return one paragraph", "keep a single paragraph", "use a single paragraph",
        ]

        private static let numberedListPhrases = [
            "一二三", "一、二、三", "第一第二第三", "第一、第二、第三", "编号", "序号",
            "数字列表", "按步骤", "分步骤", "中文编号", "汉字编号", "阿拉伯数字",
            "numbered list", "numbered", "numbering", "number each", "1, 2, 3", "1. 2. 3",
            "1.2.3", "1、2、3",
            "step-by-step", "step by step",
        ]

        private static let bulletListPhrases = [
            "列表", "列点", "要点", "逐条", "项目符号", "bullet", "bulleted",
            "list format", "as a list", "in a list",
        ]

        private static let paragraphPhrases = [
            "分段", "换行", "每段", "段落", "按主题", "自然分段", "分成几段",
            "paragraph", "paragraphs", "line break", "line breaks", "new line", "new paragraph",
            "split by topic", "separate by topic",
        ]

        private static let chineseNumberingPhrases = [
            "一二三", "一、二、三", "第一第二第三", "第一、第二、第三", "中文编号", "汉字编号",
        ]

        private static let arabicNumberingPhrases = [
            "1, 2, 3", "1. 2. 3", "1.2.3", "1、2、3", "阿拉伯数字", "数字编号",
            "numbered", "numbering", "number each",
        ]

        private static func containsAny(_ phrases: [String], in text: String) -> Bool {
            phrases.contains { text.contains($0) }
        }

        private static func lastUnconditionalDirectiveLocation(
            _ phrases: [String],
            in text: String
        ) -> Int? {
            phraseOccurrences(phrases, in: text)
                .filter { !isConditionalClause(containing: $0, in: text) }
                .filter { !isExampleOrQuotedContent(containing: $0, in: text) }
                .map(\.location)
                .max()
        }

        private static func lastPositiveDirectiveLocation(
            _ phrases: [String],
            excluding negativePhrases: [String],
            in text: String
        ) -> Int? {
            positiveDirectiveOccurrences(
                phrases,
                excluding: negativePhrases,
                in: text
            )
            .map(\.location)
            .max()
        }

        private static func positiveDirectiveOccurrences(
            _ phrases: [String],
            excluding negativePhrases: [String],
            in text: String
        ) -> [DirectiveOccurrence] {
            let negatives = phraseOccurrences(negativePhrases, in: text)
            return phraseOccurrences(phrases, in: text)
                .filter { positive in
                    !negatives.contains { negative in
                        NSIntersectionRange(positive.range, negative.range).length > 0
                    }
                }
                .filter { !isMetalinguisticNegationClause(containing: $0, in: text) }
                .filter { !isExampleOrQuotedContent(containing: $0, in: text) }
        }

        /// 禁令采用保守优先级：后文只有出现“请/改成/使用……”这类明确
        /// 命令句时才能覆盖，描述性文字即使包含“列表/分段”也不解除禁令。
        private static func hasExplicitPositiveDirective(
            _ phrases: [String],
            excluding negativePhrases: [String],
            after banLocation: Int,
            in text: String
        ) -> Bool {
            positiveDirectiveOccurrences(
                phrases,
                excluding: negativePhrases,
                in: text
            ).contains { occurrence in
                occurrence.location > banLocation
                    && isExplicitCommandClause(containing: occurrence, in: text)
            }
        }

        private static func phraseOccurrences(
            _ phrases: [String],
            in text: String
        ) -> [DirectiveOccurrence] {
            let source = text as NSString
            return phrases.flatMap { phrase -> [DirectiveOccurrence] in
                guard !phrase.isEmpty else { return [] }
                var results: [DirectiveOccurrence] = []
                var search = NSRange(location: 0, length: source.length)
                while search.length > 0 {
                    let match = source.range(of: phrase, options: [], range: search)
                    guard match.location != NSNotFound else { break }
                    results.append(DirectiveOccurrence(range: match))
                    let next = NSMaxRange(match)
                    search = NSRange(location: next, length: source.length - next)
                }
                return results
            }
        }

        private static func isConditionalClause(
            containing occurrence: DirectiveOccurrence,
            in text: String
        ) -> Bool {
            let clause = clauseText(containing: occurrence, in: text)
            let globalMarkers = [
                "任何内容都", "所有内容都", "始终", "一律", "绝不", "无论",
                "always", "never", "regardless",
            ]
            if containsAny(globalMarkers, in: clause) { return false }
            let conditionalMarkers = [
                "如果", "若", "当", "只有", "除非", "否则", "短内容", "短句",
                "内容较短", "普通叙述", "普通内容", "单个事项", "单一事项",
                "没有多个", "没有多", "无多个", "不含多个",
                "if ", "when ", "unless", "otherwise", "short content", "short sentence",
                "single item", "without multiple", "does not contain multiple", "no multiple",
            ]
            return containsAny(conditionalMarkers, in: clause)
        }

        private static func isMetalinguisticNegationClause(
            containing occurrence: DirectiveOccurrence,
            in text: String
        ) -> Bool {
            let clause = clauseText(containing: occurrence, in: text)
            let markers = [
                "不要因为", "不能因为", "不可因为", "不要仅因", "不能仅因",
                "do not use just because", "don't use just because", "not just because",
            ]
            return containsAny(markers, in: clause)
        }

        private static func isExplicitCommandClause(
            containing occurrence: DirectiveOccurrence,
            in text: String
        ) -> Bool {
            let clause = clauseText(containing: occurrence, in: text)
            return regexMatchCount(
                #"(?i)(?:^|[，,；;：:])\s*(?:(?:现在|接下来|最终|最后)\s*)?(?:请|改成|改为|改用|调整为|切换为|要(?!点|求|素|义|闻|领)|需要|必须|务必|使用|采用|统一(?:使用|采用|改为|改成|用)?|输出(?:为|成)?|写成|整理成|按(?:照)?|please\b|use\b|change\b|switch\b|make\b|format\b|write\b|return\b|present\b|must\b|should\b)"#,
                in: clause
            ) > 0
        }

        private static func isExampleOrQuotedContent(
            containing occurrence: DirectiveOccurrence,
            in text: String
        ) -> Bool {
            if isInsideQuotedContent(occurrence, in: text) { return true }
            let clause = clauseText(containing: occurrence, in: text)
            let exampleMarkers = [
                "错误示例", "反例", "示例", "例子", "例如", "比如", "仅作参考",
                "example", "counterexample", "for example", "e.g.",
            ]
            return containsAny(exampleMarkers, in: clause)
        }

        private static func isInsideQuotedContent(
            _ occurrence: DirectiveOccurrence,
            in text: String
        ) -> Bool {
            let source = text as NSString
            let pairedQuotes = [("“", "”"), ("「", "」"), ("『", "』"), ("《", "》"), ("‘", "'")]
            for (opening, closing) in pairedQuotes {
                let openRange = source.range(
                    of: opening,
                    options: .backwards,
                    range: NSRange(location: 0, length: occurrence.location)
                )
                guard openRange.location != NSNotFound else { continue }
                let closeStart = NSMaxRange(openRange)
                let closeRange = source.range(
                    of: closing,
                    options: [],
                    range: NSRange(location: closeStart, length: source.length - closeStart)
                )
                if closeRange.location != NSNotFound,
                   closeRange.location >= NSMaxRange(occurrence.range) {
                    return true
                }
            }

            // ASCII 单引号也可能只是英文缩写中的撇号，因此只把两端都不贴着
            // 字母或数字的完整成对内容视为引用。反引号则按行内代码处理。
            let inlineQuotePatterns = [
                #"(?<![\p{L}\p{N}])'[^'\r\n]*'(?![\p{L}\p{N}])"#,
                #"`[^`\r\n]*`"#,
            ]
            for pattern in inlineQuotePatterns {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                let fullRange = NSRange(location: 0, length: source.length)
                if regex.matches(in: text, range: fullRange).contains(where: { match in
                    match.range.location <= occurrence.location
                        && NSMaxRange(match.range) >= NSMaxRange(occurrence.range)
                }) {
                    return true
                }
            }

            var doubleQuoteCount = 0
            var search = NSRange(location: 0, length: occurrence.location)
            while search.length > 0 {
                let quote = source.range(of: "\"", options: [], range: search)
                guard quote.location != NSNotFound else { break }
                doubleQuoteCount += 1
                let next = NSMaxRange(quote)
                search = NSRange(location: next, length: occurrence.location - next)
            }
            return doubleQuoteCount % 2 == 1
        }

        private static func clauseText(
            containing occurrence: DirectiveOccurrence,
            in text: String
        ) -> String {
            let source = text as NSString
            let separators = CharacterSet(charactersIn: "；;。.!?！？\n")
            let before = source.rangeOfCharacter(
                from: separators,
                options: .backwards,
                range: NSRange(location: 0, length: occurrence.location)
            )
            let start = before.location == NSNotFound ? 0 : NSMaxRange(before)
            let remainingStart = NSMaxRange(occurrence.range)
            let after = source.rangeOfCharacter(
                from: separators,
                options: [],
                range: NSRange(location: remainingStart, length: source.length - remainingStart)
            )
            let end = after.location == NSNotFound ? source.length : after.location
            return source.substring(with: NSRange(location: start, length: max(0, end - start)))
        }

        private struct DirectiveOccurrence {
            let range: NSRange

            var location: Int { range.location }
        }

        private static func requestedParagraphCount(in text: String) -> Int? {
            capturedSmallCount(
                patterns: [
                    #"(?:分成|拆成|整理成|写成|排成)\s*([2-9]|1[0-9]|[二两三四五六七八九十]{1,3})\s*段"#,
                    #"(?:split|organize|format|write)(?:\s+\w+){0,3}\s+(?:into\s+|as\s+)?(two|three|four|five|six|seven|eight|nine|ten|[2-9]|1[0-9])\s+paragraphs?"#,
                ],
                in: text
            )
        }
    }

    struct SourceSignals {
        let text: String
        let hasCJK: Bool
        let segmentCount: Int
        let sentenceCount: Int
        let explicitOrderedCount: Int
        let explicitBulletCount: Int
        let declaredListCount: Int?
        let declaredMinimumListCount: Int
        let declaredFinalSingleItem: Bool
        let declaredCountOverridesExplicitEnumeration: Bool
        let trailingIncrementCount: Int
        let explicitContinuousOrderedItemCount: Int?
        let implicitStepCount: Int
        let parallelItemCount: Int
        let strongParallelItemCount: Int
        let topicSwitchCount: Int
        let aiSectionCount: Int
        let isLong: Bool
        let allowsAutomaticParagraphs: Bool
        let isLongEnoughForRequestedParagraphs: Bool
        let isLongMultiTopic: Bool
        let hasStrongParallelIntroduction: Bool
        let explicitNumberingPreference: VoicePolishNumberingPreference
        let defaultNumberingPreference: VoicePolishNumberingPreference

        init(text: String, segmentCount: Int, scene: WritingScene) {
            self.text = text
            self.segmentCount = max(1, segmentCount)
            hasCJK = Self.containsCJK(text)
            sentenceCount = Self.sentenceCount(in: text)

            let arabicMarkerPattern = #"(?m)(?:^|[。.!?！？；;，,\n])\s*(\d{1,2})[.)、）]\s*"#
            // ASR 经常不给“第一、第二、第三”补标点，直接得到
            // “第一检查……第二测试……第三记录……”。只有序号后紧接明确行动词
            // 时才把这种零分隔形态当作结构标记，避免“第一次测试”等普通叙述
            // 被拆成列表。
            let chineseOrdinalPattern = #"第([一二三四五六七八九十]{1,3}|\d+)(?:点|条|项|步|个|部分|方面|[，、,:：.）)\s]|(?=(?:检查|测试|记录|确认|安排|完成|处理|整理|明确|建立|设置|选择|分析|说明|梳理|准备|提交|部署|解决|确保|联系|通知|查看|评估|核对|推进|制作|填写|收集|验证|判断|优化|修复|设计|实现|输出|把|将|要|需要|必须)))"#
            let chineseNumeralPattern = #"(?m)(?:^|[。！？；;，,\n])\s*([一二三四五六七八九十])(?:是|、|[.)）])"#
            let arabicMarkerValues = Self.capturedMarkerValues(arabicMarkerPattern, in: text)
            let chineseOrdinalValues = Self.capturedMarkerValues(chineseOrdinalPattern, in: text)
            let chineseNumeralValues = Self.capturedMarkerValues(chineseNumeralPattern, in: text)
            let englishOrdinalValues = Self.englishOrdinalValues(in: text)
            let arabicMarkers = arabicMarkerValues.count
            let chineseOrdinalMarkers = chineseOrdinalValues.count
            let chineseNumeralMarkers = chineseNumeralValues.count
            let chineseWordMarkers = regexMatchCount(#"首先|其次|再次|最后"#, in: text)
            let englishWordMarkers = englishOrdinalValues.count
            let chineseMarkers = max(chineseOrdinalMarkers, chineseNumeralMarkers, chineseWordMarkers)
            let rawExplicitOrderedMarkerCount = max(
                arabicMarkers,
                chineseMarkers,
                englishWordMarkers
            )
            // 结构证据必须形成从 1 开始的连续序号。单独或重复提到“第二项”
            // 只是正文指代，不能因为出现两次就被误认为两条列表项。
            let arabicSequenceCount = Self.continuousSequenceCount(arabicMarkerValues) ?? 0
            let chineseOrdinalSequenceCount = Self.continuousSequenceCount(chineseOrdinalValues) ?? 0
            let chineseNumeralSequenceCount = Self.continuousSequenceCount(chineseNumeralValues) ?? 0
            let englishSequenceCount = Self.continuousSequenceCount(englishOrdinalValues) ?? 0
            let rhetoricalSequenceCount = Self.rhetoricalOrderedItemCount(in: text) ?? 0
            explicitOrderedCount = max(
                arabicSequenceCount,
                chineseOrdinalSequenceCount,
                chineseNumeralSequenceCount,
                englishSequenceCount,
                rhetoricalSequenceCount
            )
            explicitBulletCount = regexMatchCount(#"(?m)^\s*[-*•]\s+"#, in: text)
            let parallelItems = Self.parallelItemCount(in: text)
            let lastExplicitMarkerLocation = [
                regexLastMatchLocation(arabicMarkerPattern, in: text),
                regexLastMatchLocation(chineseOrdinalPattern, in: text),
                regexLastMatchLocation(chineseNumeralPattern, in: text),
            ].compactMap { $0 }.max()
            let rawDeclaredCounts = Self.declaredListCounts(
                in: text,
                lastExplicitMarkerLocation: lastExplicitMarkerLocation
            )
            let unnumberedTrailingIncrementCount = Self.unnumberedTrailingItemCount(
                in: text,
                after: lastExplicitMarkerLocation
            )
            let declaredCounts: DeclaredCountSummary
            if scene == .aiPrompt,
               !rawDeclaredCounts.overridesExplicitEnumeration,
               !(rawExplicitOrderedMarkerCount == 0
                    && explicitBulletCount == 0
                    && rawDeclaredCounts.minimum >= 2
                    && parallelItems >= rawDeclaredCounts.minimum) {
                // “给三个建议”描述的是下游 AI 的输出数量，不代表 Muse 当前要
                // 生成三条建议。aiPrompt 只接受正文中已经出现的真实枚举证据。
                declaredCounts = .empty
            } else {
                declaredCounts = rawDeclaredCounts
            }
            declaredListCount = declaredCounts.exact
            declaredMinimumListCount = declaredCounts.minimum
            declaredFinalSingleItem = declaredCounts.finalSingleItem
            declaredCountOverridesExplicitEnumeration = declaredCounts.overridesExplicitEnumeration
            trailingIncrementCount = declaredCounts.trailingIncrementCount
                + unnumberedTrailingIncrementCount
            explicitContinuousOrderedItemCount = [
                Self.continuousSequenceCount(arabicMarkerValues),
                Self.continuousSequenceCount(chineseOrdinalValues),
                Self.continuousSequenceCount(chineseNumeralValues),
                Self.continuousSequenceCount(englishOrdinalValues),
                Self.rhetoricalOrderedItemCount(in: text),
            ].compactMap { $0 }.max()
            implicitStepCount = Self.implicitStepCount(in: text, hasCJK: hasCJK)
            parallelItemCount = parallelItems
            topicSwitchCount = VoicePolishLayoutExpectation
                .topicSwitchEvidenceCount(in: text)
            aiSectionCount = Self.aiSectionCount(in: text)
            hasStrongParallelIntroduction = Self.hasStrongParallelIntroduction(in: text)
            strongParallelItemCount = Self.strongParallelItemCount(
                in: text,
                parallelItemCount: parallelItemCount,
                hasIntroduction: hasStrongParallelIntroduction
            )

            let cjkLength = text.filter { !$0.isWhitespace }.count
            let wordLength = text.split { $0.isWhitespace || $0.isPunctuation }.count
            // 与 Voice Polish 默认成稿标准保持一致：中文约 80 字、英文约
            // 60 词且存在多主题证据时，就应进入自然分段契约。
            isLong = hasCJK ? cjkLength >= 80 : wordLength >= 60
            allowsAutomaticParagraphs = scene != .code
            isLongEnoughForRequestedParagraphs = hasCJK ? cjkLength >= 80 : wordLength >= 60
            let isVeryLong = hasCJK ? cjkLength >= 180 : wordLength >= 110
            let isMediumLength = hasCJK ? cjkLength >= 45 : wordLength >= 35
            let sceneNaturallyUsesParagraphs: Bool
            switch scene {
            case .email, .document, .note, .socialPost, .aiPrompt:
                sceneNaturallyUsesParagraphs = true
            case .chat, .workChat, .code, .customerSupport, .unknown:
                sceneNaturallyUsesParagraphs = false
            }
            let hasMultipleTopics = topicSwitchCount > 0
                || sentenceCount >= 3
                || aiSectionCount >= 3
                || (sceneNaturallyUsesParagraphs && self.segmentCount >= 2 && sentenceCount >= 2)
            isLongMultiTopic = scene != .code && (
                (isLong && hasMultipleTopics)
                    || (isMediumLength && topicSwitchCount > 0)
                    || (isVeryLong && sentenceCount >= 2)
            )

            if arabicMarkers >= 2 || englishWordMarkers >= 2 {
                explicitNumberingPreference = .arabic
            } else if chineseMarkers >= 2 {
                explicitNumberingPreference = .chinese
            } else {
                explicitNumberingPreference = hasCJK ? .chinese : .arabic
            }
            defaultNumberingPreference = .arabic
        }

        var listableItemCount: Int {
            if declaredFinalSingleItem { return 0 }
            if declaredCountOverridesExplicitEnumeration {
                return declaredMinimumListCount
            }
            return max(
                explicitOrderedCount + trailingIncrementCount,
                explicitBulletCount,
                declaredMinimumListCount,
                implicitStepCount,
                strongParallelItemCount
            )
        }

        var minimumListCount: Int {
            if declaredCountOverridesExplicitEnumeration {
                return min(12, max(2, declaredMinimumListCount))
            }
            return min(12, max(2, declaredMinimumListCount,
                        explicitOrderedCount + trailingIncrementCount,
                        explicitBulletCount, implicitStepCount, strongParallelItemCount))
        }

        var orderedExpectedItemCount: Int? {
            if declaredCountOverridesExplicitEnumeration {
                return declaredListCount
            }
            if trailingIncrementCount > 0 {
                return nil
            }
            switch (explicitContinuousOrderedItemCount, declaredListCount) {
            case let (explicit?, declared?):
                // 局部出现“第一、第二”不代表声明的第三项消失；只有实际连续
                // 枚举更多项时，才允许覆盖较小的旧声明数量。
                return max(explicit, declared)
            case let (explicit?, nil):
                return explicit
            case let (nil, declared?):
                return declared
            case (nil, nil):
                return nil
            }
        }

        var explicitBulletItemCount: Int? {
            explicitBulletCount >= 2 ? explicitBulletCount : nil
        }

        var paragraphCandidateCount: Int {
            min(6, max(1, sentenceCount, segmentCount, topicSwitchCount + 1,
                       aiSectionCount, parallelItemCount))
        }

        var recommendedParagraphCount: Int {
            min(4, max(2, topicSwitchCount + 1, min(sentenceCount, 4),
                       min(segmentCount, 4), min(aiSectionCount, 4)))
        }

        static func containsCJK(_ text: String) -> Bool {
            text.unicodeScalars.contains { scalar in
                (0x3400...0x4DBF).contains(scalar.value)
                    || (0x4E00...0x9FFF).contains(scalar.value)
            }
        }

        private static func capturedMarkerValues(
            _ pattern: String,
            in text: String
        ) -> [Int] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            return regex.matches(in: text, range: range).compactMap { match in
                guard match.numberOfRanges >= 2,
                      let captureRange = Range(match.range(at: 1), in: text) else { return nil }
                return parseSmallCount(String(text[captureRange]))
            }
        }

        private static func englishOrdinalValues(in text: String) -> [Int] {
            // 只接受位于结构边界且带枚举标点的序词。叙事中的
            // “my first job ... finally moved”不能被当成列表标记。
            let pattern = #"(?im)(?:^|[.!?;\n])\s*(first(?:ly)?|second(?:ly)?|third(?:ly)?|fourth(?:ly)?|fifth(?:ly)?|sixth(?:ly)?|seventh(?:ly)?|eighth(?:ly)?|ninth(?:ly)?|tenth(?:ly)?|finally|lastly)\b(?=\s*[,.:：-])"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            var values: [Int] = []
            for match in regex.matches(in: text, range: range) {
                guard match.numberOfRanges >= 2,
                      let captureRange = Range(match.range(at: 1), in: text) else { continue }
                let token = text[captureRange].lowercased()
                let value: Int?
                if token.hasPrefix("first") { value = 1 }
                else if token.hasPrefix("second") { value = 2 }
                else if token.hasPrefix("third") { value = 3 }
                else if token.hasPrefix("fourth") { value = 4 }
                else if token.hasPrefix("fifth") { value = 5 }
                else if token.hasPrefix("sixth") { value = 6 }
                else if token.hasPrefix("seventh") { value = 7 }
                else if token.hasPrefix("eighth") { value = 8 }
                else if token.hasPrefix("ninth") { value = 9 }
                else if token.hasPrefix("tenth") { value = 10 }
                else { value = values.last.map { $0 + 1 } }
                if let value { values.append(value) }
            }
            return values
        }

        private static func continuousSequenceCount(_ values: [Int]) -> Int? {
            guard values.first == 1 else { return nil }
            var count = 0
            for value in values {
                guard value == count + 1 else { break }
                count += 1
            }
            return count >= 2 ? count : nil
        }

        private static func rhetoricalOrderedItemCount(in text: String) -> Int? {
            let pattern = #"首先|其次|再次|最后"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            let tokens = regex.matches(in: text, range: range).compactMap { match -> String? in
                guard let tokenRange = Range(match.range, in: text) else { return nil }
                return String(text[tokenRange])
            }
            guard tokens.count >= 2,
                  tokens.first == "首先",
                  tokens.dropFirst().first == "其次" else { return nil }
            if tokens.count == 2 || tokens.last == "最后" {
                return tokens.count
            }
            return nil
        }

        private static func sentenceCount(in text: String) -> Int {
            let parts = text.split(whereSeparator: { "。！？!?\n".contains($0) })
            return max(1, parts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count)
        }

        private struct DeclaredCountSummary {
            let exact: Int?
            let minimum: Int
            let finalSingleItem: Bool
            let overridesExplicitEnumeration: Bool
            let trailingIncrementCount: Int

            static let empty = DeclaredCountSummary(
                exact: nil,
                minimum: 0,
                finalSingleItem: false,
                overridesExplicitEnumeration: false,
                trailingIncrementCount: 0
            )
        }

        private static func declaredListCounts(
            in text: String,
            lastExplicitMarkerLocation: Int?
        ) -> DeclaredCountSummary {
            let countToken = #"([1-9]|1[0-9]|[一二两三四五六七八九十]{1,3})"#
            let countTokenNoCapture = #"(?:[1-9]|1[0-9]|[一二两三四五六七八九十]{1,3})"#
            let chineseUnit = #"(?:点|条|项|步|个步骤|部分|方面|件事|个事(?:情)?|(?:个)?(?:问题|原因|建议|方案|任务|风险|事项|要点|结论|观点|方法|要求|目标|主题|阶段|选择|选项))"#
            let englishCount = #"(one|two|three|four|five|six|seven|eight|nine|ten|[1-9]|1[0-9])"#
            let englishCountNoCapture = #"(?:one|two|three|four|five|six|seven|eight|nine|ten|[1-9]|1[0-9])"#
            let englishUnit = #"(?:points?|items?|steps?|parts?|topics?|things?|problems?|reasons?|suggestions?|recommendations?|plans?|solutions?|tasks?|risks?|requirements?|goals?|options?)"#
            let patterns: [(pattern: String, isCorrection: Bool)] = [
                (
                    #"(?:所以|因此|最终|最后)[，,、：:\s]*(?:一)?共\s*"#
                        + countToken + #"\s*"# + chineseUnit,
                    true
                ),
                (
                    #"(?:有|共|包括|包含|分为|分成|列出|整理出|原来(?:有)?|本来(?:有)?|之前(?:有)?|(?:先|再)?(?:讲|说|说明|分析|处理|解决|给|提出|讨论|梳理))\s*"#
                        + countToken + #"\s*"# + chineseUnit,
                    false
                ),
                (
                    countToken + #"\s*"# + chineseUnit + #"(?:是|包括|如下|[：:])"#,
                    false
                ),
                (
                    #"(?:不对|更正(?:一下)?|改口|准确(?:地)?说|改成|调整为|而是|应该|其实|最终(?:改成|确定为)?|最后(?:改成|确定为)?)[，,、：:\s]*(?:应该)?(?:是|为|有)?\s*"#
                        + countToken + #"\s*"# + chineseUnit,
                    true
                ),
                (
                    #"(?:不是|并非)\s*"# + countTokenNoCapture + #"\s*"# + chineseUnit
                        + #"[，,、：:\s]*(?:而)?是\s*"# + countToken + #"\s*"# + chineseUnit,
                    true
                ),
                (
                    #"(?i)\b(?:there\s+are|have|include|includes|cover|the\s+following|(?:first|then)\s+(?:discuss|explain|list|give))\s+"#
                        + englishCount + #"\s+"# + englishUnit + #"\b"#,
                    false
                ),
                (
                    #"(?i)\b"# + englishCount + #"\s+"# + englishUnit
                        + #"(?:\s+(?:are|include|as\s+follows)|\s*[:])?\b"#,
                    false
                ),
                (
                    #"(?i)\b(?:correction|actually|rather|make\s+that|change\s+that\s+to)\s*[:,-]?\s*"#
                        + englishCount + #"\s+"# + englishUnit + #"\b"#,
                    true
                ),
                (
                    #"(?i)\bnot\s+"# + englishCountNoCapture + #"\s+"# + englishUnit
                        + #"\s*[,;]?\s*but\s+"# + englishCount + #"\s+"# + englishUnit + #"\b"#,
                    true
                ),
            ]
            let mentions = capturedSmallCountMentions(patterns: patterns, in: text)
            let incrementalPatterns: [(pattern: String, isCorrection: Bool)] = [
                (
                    #"(?:(?:另外|此外)?还有|另有|另(?:外)?|再(?:加|补充|增加)|额外(?:增加|补充)?|加上)[，,、：:\s]*"#
                        + countToken + #"\s*"# + chineseUnit,
                    false
                ),
                (
                    #"(?i)\b(?:plus|add|adding|an\s+additional)\s+"#
                        + englishCount + #"\s+"# + englishUnit + #"\b"#,
                    false
                ),
                (
                    #"(?i)\b"# + englishCount + #"\s+more\s+"# + englishUnit + #"\b"#,
                    false
                ),
            ]
            let increments = capturedSmallCountMentions(
                patterns: incrementalPatterns,
                in: text
            ).filter { isAffirmativeCountIncrement($0, in: text) }
            let incrementLocations = Set(increments.map(\.location))
            let baseMentions = mentions.filter { !incrementLocations.contains($0.location) }

            var groupCounts: [Int] = []
            for mention in baseMentions.sorted(by: { $0.location < $1.location }) {
                if mention.isCorrection, !groupCounts.isEmpty {
                    groupCounts[groupCounts.count - 1] = mention.count
                } else {
                    groupCounts.append(mention.count)
                }
            }
            let latestCorrectionLocation = baseMentions
                .filter(\.isCorrection)
                .map(\.location)
                .max()
            let activeIncrements = increments.filter { increment in
                latestCorrectionLocation.map { increment.location > $0 } ?? true
            }
            let incrementTotal = activeIncrements.reduce(0) { $0 + $1.count }
            guard !groupCounts.isEmpty else {
                return DeclaredCountSummary(
                    exact: nil,
                    minimum: 0,
                    finalSingleItem: false,
                    overridesExplicitEnumeration: false,
                    trailingIncrementCount: incrementTotal
                )
            }

            let positiveGroups = groupCounts.filter { $0 >= 2 }
            let baseMinimum = groupCounts.count == 1
                ? (groupCounts.first ?? 0)
                : (positiveGroups.max() ?? 0)
            let minimum = baseMinimum + incrementTotal
            let overridesExplicitEnumeration: Bool
            if let latestCorrectionLocation, let lastExplicitMarkerLocation {
                overridesExplicitEnumeration = latestCorrectionLocation > lastExplicitMarkerLocation
            } else {
                overridesExplicitEnumeration = false
            }
            if groupCounts.count == 1, let finalCount = groupCounts.first {
                if finalCount < 2, incrementTotal == 0 {
                    return DeclaredCountSummary(
                        exact: nil,
                        minimum: 0,
                        finalSingleItem: true,
                        overridesExplicitEnumeration: overridesExplicitEnumeration,
                        trailingIncrementCount: 0
                    )
                }
                return DeclaredCountSummary(
                    exact: incrementTotal == 0 && finalCount >= 2 ? finalCount : nil,
                    minimum: minimum,
                    finalSingleItem: false,
                    overridesExplicitEnumeration: overridesExplicitEnumeration,
                    trailingIncrementCount: incrementTotal
                )
            }

            // 多个独立数量声明代表多个分组，而不是对同一列表的改口。
            // 契约保留可靠的最低规模，但不把全文锁成最后一个分组的数量。
            return DeclaredCountSummary(
                exact: nil,
                minimum: minimum,
                finalSingleItem: false,
                overridesExplicitEnumeration: overridesExplicitEnumeration,
                trailingIncrementCount: incrementTotal
            )
        }

        /// “第一……第二……另外还要完成测试”中的最后一项没有数量词，
        /// 但“另外/此外 + 明确行动”足以证明它是枚举后的新增事项。普通的
        /// “另外一个话题”只表示话题切换，不在这里凭空增加列表数量。
        private static func unnumberedTrailingItemCount(
            in text: String,
            after lastExplicitMarkerLocation: Int?
        ) -> Int {
            guard let lastExplicitMarkerLocation else { return 0 }
            let pattern = #"(?:^|[。.!?！？；;\n])\s*(?:另外|此外)\s*(?:还)?(?:要|需要|需|得|应当?|必须|完成|处理|确认|安排|补充|检查|测试|部署|解决|确保|推进|准备|提交|上线|说明|梳理|讨论|实现|加入|增加)"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
            let source = text as NSString
            let fullRange = NSRange(location: 0, length: source.length)
            let hasAffirmativeTrailingItem = regex.matches(in: text, range: fullRange)
                .contains { match in
                    guard match.range.location > lastExplicitMarkerLocation else {
                        return false
                    }
                    let suffix = countIncrementCancellationWindow(
                        afterUTF16Location: NSMaxRange(match.range),
                        in: source
                    )
                    return !hasExplicitCountIncrementCancellation(in: suffix)
                }
            return hasAffirmativeTrailingItem ? 1 : 0
        }

        private static func implicitStepCount(in text: String, hasCJK: Bool) -> Int {
            if hasCJK {
                return regexMatchCount(
                    #"(?:^|[，,；;。！？\s])(?:(?:我们|咱们|我|你们|大家)\s*)?先(?=(?:要|把|从|对|将|去|来|做|说|讲|看|读|写|问|查|找|开|关|发|给|用|让|确认|处理|完成|说明|安排|检查|梳理|讨论|准备|建立|设置|选择|明确|定义|提交|进入|运行|测试|分析|收集|整理|联系|等待|解决|确保|核对|部署|上线))|然后|接着|随后|最后|(?:^|[，,；;。！？\s])再(?=(?:要|把|从|对|将|去|来|做|说|讲|看|读|写|问|查|找|开|关|发|给|用|让|确认|处理|完成|说明|安排|检查|梳理|讨论|准备|建立|设置|选择|明确|定义|提交|进入|运行|测试|分析|收集|整理|联系|等待|解决|确保|核对|部署|上线))"#,
                    in: text
                )
            }
            return regexMatchCount(
                #"(?i)\b(?:start\s+by|begin\s+by|first|then|next|after\s+that|finally|lastly)\b"#,
                in: text
            )
        }

        private static func parallelItemCount(in text: String) -> Int {
            let ideographic = text.filter { $0 == "、" }.count
            let chineseCommas = text.filter { $0 == "，" }.count
            let semicolons = text.filter { $0 == "；" || $0 == ";" }.count
            let lines = text.split(separator: "\n").filter {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }.count
            let commaCount = text.filter { $0 == "," }.count
            let englishCommaList = commaCount >= 2
                && regexMatchCount(#"(?i)\b(?:and|or)\b"#, in: text) > 0
                ? commaCount + 1
                : 0
            return max(
                ideographic > 0 ? ideographic + 1 : 0,
                chineseCommas >= 2 ? chineseCommas + 1 : 0,
                semicolons > 0 ? semicolons + 1 : 0,
                lines >= 2 ? lines : 0,
                englishCommaList
            )
        }

        private static func strongParallelItemCount(
            in text: String,
            parallelItemCount: Int,
            hasIntroduction: Bool
        ) -> Int {
            let ideographicCount = text.filter { $0 == "、" }.count
            let semicolonCount = text.filter { $0 == "；" || $0 == ";" }.count
            let englishCommaListCount = text
                .split(whereSeparator: { ".!?;\n".contains($0) })
                .map(String.init)
                .map { clause -> Int in
                    let commaCount = clause.filter { $0 == "," }.count
                    return commaCount >= 2
                        && regexMatchCount(#"(?i)\b(?:and|or)\b"#, in: clause) > 0
                        ? commaCount + 1
                        : 0
                }
                .max() ?? 0
            let delimiterEvidence = max(
                ideographicCount >= 2 ? ideographicCount + 1 : 0,
                semicolonCount >= 2 ? semicolonCount + 1 : 0,
                englishCommaListCount
            )
            if delimiterEvidence >= 3 {
                return delimiterEvidence
            }
            if hasIntroduction, parallelItemCount >= 3 {
                return parallelItemCount
            }
            return 0
        }

        private static func aiSectionCount(in text: String) -> Int {
            let chineseLabels = ["目标", "背景", "要求", "输入", "输出", "限制", "格式", "步骤"]
                .filter { text.contains("\($0)：") || text.contains("\($0):") }
                .count
            let englishLabels = regexMatchCount(
                #"(?i)(?:^|[.!?;\n])\s*(?:goal|context|background|requirements?|input|output|constraints?|format|steps?)\s*:"#,
                in: text
            )
            return max(chineseLabels, englishLabels)
        }

        private static func hasStrongParallelIntroduction(in text: String) -> Bool {
            let normalized = text.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            let phrases = [
                "包括", "分别", "主要有", "有以下", "几个方面", "几件事", "需要做",
                "the following", "includes", "include", "several things", "several aspects",
                "need to", "needs to",
            ]
            return phrases.contains { normalized.contains($0) }
        }
    }
}

private func regexMatchCount(_ pattern: String, in text: String) -> Int {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
    return regex.numberOfMatches(
        in: text,
        range: NSRange(text.startIndex..<text.endIndex, in: text)
    )
}

private func regexLastMatchLocation(_ pattern: String, in text: String) -> Int? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let matches = regex.matches(
        in: text,
        range: NSRange(text.startIndex..<text.endIndex, in: text)
    )
    return matches.last?.range.location
}

private struct SmallCountMention {
    let location: Int
    let fullRange: NSRange
    let count: Int
    let isCorrection: Bool
}

private func capturedSmallCountMentions(
    patterns: [(pattern: String, isCorrection: Bool)],
    in text: String
) -> [SmallCountMention] {
    let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
    let candidates = patterns.flatMap { entry -> [SmallCountMention] in
        guard let regex = try? NSRegularExpression(pattern: entry.pattern) else { return [] }
        return regex.matches(in: text, range: fullRange).compactMap { match in
            guard match.numberOfRanges >= 2,
                  let range = Range(match.range(at: 1), in: text),
                  let count = parseSmallCount(String(text[range])),
                  count >= 1,
                  !isTimeOfDayCountMention(match, in: text) else { return nil }
            return SmallCountMention(
                location: match.range(at: 1).location,
                fullRange: match.range,
                count: count,
                isCorrection: entry.isCorrection
            )
        }
    }
    var unique: [Int: SmallCountMention] = [:]
    for candidate in candidates {
        if let existing = unique[candidate.location],
           existing.isCorrection,
           !candidate.isCorrection {
            continue
        }
        unique[candidate.location] = candidate
    }
    return unique.values.sorted { $0.location < $1.location }
}

/// “下午三点是原计划”中的“三点是”形态会命中“3 点是……”的列表声明正则。
/// 只在数量词紧邻明确时段前缀且单位确为“点”时排除，保留“这次有三点：”等
/// 真正的列表契约。
private func isTimeOfDayCountMention(
    _ match: NSTextCheckingResult,
    in text: String
) -> Bool {
    let source = text as NSString
    let countRange = match.range(at: 1)
    guard countRange.location != NSNotFound,
          NSMaxRange(countRange) < source.length,
          source.substring(with: NSRange(location: NSMaxRange(countRange), length: 1)) == "点" else {
        return false
    }
    let prefixLength = min(8, countRange.location)
    let prefix = source.substring(with: NSRange(
        location: countRange.location - prefixLength,
        length: prefixLength
    )).trimmingCharacters(in: .whitespacesAndNewlines)
    return ["凌晨", "早上", "上午", "中午", "下午", "傍晚", "晚上", "晚间"]
        .contains(where: prefix.hasSuffix)
}

/// 数量递增只接受肯定式口述。否定、取消、假设、示例和引号中的“再补充一项”
/// 都不能改变最终列表契约，否则正确的三项成稿会被错误要求制造第四项。
private func isAffirmativeCountIncrement(
    _ mention: SmallCountMention,
    in text: String
) -> Bool {
    let source = text as NSString
    guard mention.fullRange.location != NSNotFound,
          NSMaxRange(mention.fullRange) <= source.length else {
        return false
    }

    let quotePatterns = [
        #"“[^”\r\n]*”"#,
        #"「[^」\r\n]*」"#,
        #"『[^』\r\n]*』"#,
        #"\"[^\"\r\n]*\""#,
        #"(?<![\p{L}\p{N}])'[^'\r\n]*'(?![\p{L}\p{N}])"#,
        #"`[^`\r\n]*`"#,
    ]
    let fullTextRange = NSRange(location: 0, length: source.length)
    for pattern in quotePatterns {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
        if regex.matches(in: text, range: fullTextRange).contains(where: {
            $0.range.location <= mention.fullRange.location
                && NSMaxRange($0.range) >= NSMaxRange(mention.fullRange)
        }) {
            return false
        }
    }

    let separators = CharacterSet(charactersIn: "；;。.!?！？\n")
    let before = source.rangeOfCharacter(
        from: separators,
        options: .backwards,
        range: NSRange(location: 0, length: mention.fullRange.location)
    )
    let clauseStart = before.location == NSNotFound ? 0 : NSMaxRange(before)
    let prefix = source.substring(with: NSRange(
        location: clauseStart,
        length: max(0, mention.fullRange.location - clauseStart)
    ))
    let suffix = countIncrementCancellationWindow(
        afterUTF16Location: NSMaxRange(mention.fullRange),
        in: source
    )

    // 否定或假设必须出现在“新增”之前；新增后的普通负面事实（例如
    // “预算还没有确认”）仍然是有效的新事项。否定只在紧贴追加动作时生效，
    // 避免“虽然没有新增预算，另外还有一项……”被前文误伤。
    let trimmedPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
    let prefixRejectingPattern = #"(?:不要|不用|无需|别|不再|没有|并未|未曾|取消|放弃|本来想|原本想|只是想|假如|如果|若|例如|比如|示例|反例)[，,\s]*$|(?i:\b(?:do\s+not|don't|dont|no\s+longer|never|for\s+example|example|if|would\s+have|was\s+going\s+to)\s*$)"#
    return trimmedPrefix.range(
        of: prefixRejectingPattern,
        options: .regularExpression
    ) == nil && !hasExplicitCountIncrementCancellation(in: suffix)
}

/// 追加事项允许包含“取消会议”“删掉旧文件”这样的真实动作；只有明确指回
/// 当前追加动作的撤销语才算取消。窗口覆盖当前句及紧随的一句，既识别
/// “算了，这项不用了”，又不让很远的后文影响当前列表。
private func hasExplicitCountIncrementCancellation(in text: String) -> Bool {
    let pattern = #"(?:算了|作罢)(?=$|[，,。.!?！？；;\s])|(?:撤回|取消|删除|删掉|去掉)(?:(?:这个|该|这|那)(?:补充|新增|事项|一项|安排)?|(?:该)?(?:补充|新增)(?:事项|一项)?|它)|不算(?:了|这项|该项|这个|那个)?(?=$|[，,。.!?！？；;\s])|不(?:再)?加了|不补充了|不用了|不要了|别加了|就当没说|别做了|就(?:三|3)项就够了|(?i:\b(?:never\s+mind|scratch\s+that|do\s+not\s+add|don't\s+add|cancel(?:led|ed)?\s+(?:this|that)\s+(?:addition|item))\b)"#
    return text.range(of: pattern, options: .regularExpression) != nil
}

private func countIncrementCancellationWindow(
    afterUTF16Location start: Int,
    in source: NSString
) -> String {
    guard start >= 0, start < source.length else { return "" }
    let hardEnd = min(source.length, start + 160)
    let separators = CharacterSet(charactersIn: "。.!?！？；;\n")
    var cursor = start
    var end = hardEnd
    var boundaryCount = 0
    while cursor < hardEnd, boundaryCount < 2 {
        let boundary = source.rangeOfCharacter(
            from: separators,
            options: [],
            range: NSRange(location: cursor, length: hardEnd - cursor)
        )
        guard boundary.location != NSNotFound else { break }
        boundaryCount += 1
        cursor = NSMaxRange(boundary)
        if boundaryCount == 2 { end = cursor }
    }
    return source.substring(with: NSRange(location: start, length: max(0, end - start)))
}

private func regexMatchLocations(patterns: [String], in text: String) -> [Int] {
    let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
    return patterns.flatMap { pattern -> [Int] in
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: fullRange).map { $0.range.location }
    }
}

private func capturedSmallCount(patterns: [String], in text: String) -> Int? {
    for pattern in patterns {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: text,
                range: NSRange(text.startIndex..<text.endIndex, in: text)
              ),
              match.numberOfRanges >= 2,
              let range = Range(match.range(at: 1), in: text),
              let count = parseSmallCount(String(text[range])),
              count >= 2 else { continue }
        return count
    }
    return nil
}

private func parseSmallCount(_ raw: String) -> Int? {
    let normalized = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    if let value = Int(normalized) { return value }
    let english = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10,
    ]
    if let value = english[normalized] { return value }

    let chineseDigits: [Character: Int] = [
        "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5,
        "六": 6, "七": 7, "八": 8, "九": 9,
    ]
    if normalized == "十" { return 10 }
    if let tenIndex = normalized.firstIndex(of: "十") {
        let before = normalized[..<tenIndex].last.flatMap { chineseDigits[$0] } ?? 1
        let afterStart = normalized.index(after: tenIndex)
        let after = afterStart < normalized.endIndex
            ? chineseDigits[normalized[afterStart]] ?? 0
            : 0
        return before * 10 + after
    }
    guard normalized.count == 1, let character = normalized.first else { return nil }
    return chineseDigits[character]
}
