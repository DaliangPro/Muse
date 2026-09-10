import Foundation

/// 新语音润色链路中可回溯的原文证据。范围使用 canonical 文本的 Character offset，
/// digest 用于防止 Planner 引用一段已经被替换的文字。
struct VoicePolishEvidenceSpan: Codable, Sendable, Equatable {
    let id: String
    let segmentID: String
    let start: Int
    let end: Int
    let text: String
    let digest: String
}

struct VoicePolishLedgerAudience: Codable, Sendable, Equatable {
    let text: String
    let sourceSpanIds: [String]
    let surfaceTokens: [String]
    let deliveryMode: String
}

struct VoicePolishLedgerUnit: Codable, Sendable, Equatable {
    let id: String
    var kind: String
    var deliveryRole: String
    var finalMeaning: String
    let sourceSpanIds: [String]
    var status: String
    var modality: String
    var exactTokens: [String]
    var surfaceTokens: [String]
}

struct VoicePolishLedgerCorrection: Codable, Sendable, Equatable {
    let subject: String
    let oldValue: String
    let finalValue: String
    let oldSpanIds: [String]
    let finalSpanIds: [String]
    let renderingPolicy: String
}

/// 程序只负责确认条件句确实来自原文；条件含义与作用范围由 Planner 提取，
/// Reviewer 再独立核对。这样不会再用本地关键词正则裁决开放式语义。
struct VoicePolishLedgerCondition: Codable, Sendable, Equatable {
    let subject: String
    let predicate: String
    let polarity: Bool
    let sourceSpanIds: [String]
}

struct VoicePolishLedgerConsequence: Codable, Sendable, Equatable {
    let action: String
    let polarity: Bool
    let sourceSpanIds: [String]
}

struct VoicePolishLedgerConditional: Codable, Sendable, Equatable {
    let id: String
    let cueIds: [String]
    /// 由本地从原文连接词确定，Planner 只能逐字复制，不能自行推断。
    /// only_if 表示必要条件，不能被 Writer 升级成 if_then 的充分条件。
    let operatorKind: String
    let condition: VoicePolishLedgerCondition
    let consequences: [VoicePolishLedgerConsequence]
}

struct VoicePolishLedgerTokenMapping: Codable, Sendable, Equatable {
    let alias: String
    let canonical: String
    let sourceSpanIds: [String]
    let transform: String
}

struct VoicePolishLogicCue: Codable, Sendable, Equatable {
    let id: String
    let text: String
    let sourceSpanIds: [String]
    let operatorKind: String
}

struct VoicePolishLedgerContextMapping: Codable, Sendable, Equatable {
    let alias: String
    let canonical: String
    let sourceSpanIds: [String]
    let evidence: String
}

struct VoicePolishLedgerStructure: Codable, Sendable, Equatable {
    let kind: String
    let orderedUnitIds: [String]
    /// `mixed` 结构中需要由程序连续编号的正文 unit。`numbered_list`
    /// 缺省把全部 orderedUnitIds 视为编号项；其他结构缺省为空。
    let numberedUnitIds: [String]?

    init(
        kind: String,
        orderedUnitIds: [String],
        numberedUnitIds: [String]? = nil
    ) {
        self.kind = kind
        self.orderedUnitIds = orderedUnitIds
        self.numberedUnitIds = numberedUnitIds
    }
}

struct VoicePolishIntentLedger: Codable, Sendable, Equatable {
    var audience: [VoicePolishLedgerAudience]
    var units: [VoicePolishLedgerUnit]
    var corrections: [VoicePolishLedgerCorrection]
    var conditionals: [VoicePolishLedgerConditional]
    var technicalTokenMappings: [VoicePolishLedgerTokenMapping]
    var dictatedSymbolMappings: [VoicePolishLedgerTokenMapping]
    var contextMappings: [VoicePolishLedgerContextMapping]
    var structure: VoicePolishLedgerStructure
}

/// Writer 不再返回无法核对覆盖范围的一整段自由文本。每个需要交付的 unit
/// 必须恰好对应一个稳定 fragment，程序据此证明没有在生成阶段静默漏项；
/// 语义是否正确仍由隔离 Reviewer 对照 source spans 判断。
struct VoicePolishLedgerDraftFragment: Codable, Sendable, Equatable {
    let id: String
    let unitIds: [String]
    var text: String
    /// 意图覆盖和自然段边界独立。省略时兼容旧阶段记录的一单元一段；
    /// 新 Writer 显式决定相邻单元是否继续同一段，不改变逐项来源与修复边界。
    var paragraphBreakBefore: Bool? = nil
}

struct VoicePolishLedgerDraftDocument: Codable, Sendable, Equatable {
    var fragments: [VoicePolishLedgerDraftFragment]
}

struct VoicePolishReviewerIssue: Codable, Sendable, Equatable {
    let type: String
    let severity: String
    let unitIds: [String]
    let sourceSpanIds: [String]
    let draftSpan: String?
    let repairInstruction: String
}

struct VoicePolishReviewerResult: Codable, Sendable, Equatable {
    let verdict: String
    let issues: [VoicePolishReviewerIssue]
}

enum VoicePolishLedgerFailureStage: String, Sendable, Equatable {
    case planning
    case writing
    case reviewing
    case repairing
    case confirming
}

struct VoicePolishPlannerValidationTrace: Codable, Sendable, Equatable {
    let initialCode: String
    let repairedCode: String?
}

struct VoicePolishLedgerRunResult: Sendable, Equatable {
    let text: String?
    let attempts: Int
    let validationCodes: [VoicePolishValidationCode]
    let failureReason: VoicePolishFailureReason?
    let failureStage: VoicePolishLedgerFailureStage?
    /// 仅包含稳定的本地证据错误代码，用于质量跑测比较修复前后结果。
    /// 不写入正常用户界面、历史记录或性能统计。
    let plannerValidationTrace: VoicePolishPlannerValidationTrace?
    let rejectedDraft: String?

    static func polished(
        _ text: String,
        attempts: Int,
        validationCodes: [VoicePolishValidationCode] = []
    ) -> VoicePolishLedgerRunResult {
        VoicePolishLedgerRunResult(
            text: text,
            attempts: attempts,
            validationCodes: validationCodes,
            failureReason: nil,
            failureStage: nil,
            plannerValidationTrace: nil,
            rejectedDraft: nil
        )
    }

    static func unavailable(
        stage: VoicePolishLedgerFailureStage,
        attempts: Int,
        codes: [VoicePolishValidationCode],
        reason: VoicePolishFailureReason,
        plannerValidationTrace: VoicePolishPlannerValidationTrace? = nil,
        rejectedDraft: String? = nil
    ) -> VoicePolishLedgerRunResult {
        VoicePolishLedgerRunResult(
            text: nil,
            attempts: attempts,
            validationCodes: codes,
            failureReason: reason,
            failureStage: stage,
            plannerValidationTrace: plannerValidationTrace,
            rejectedDraft: rejectedDraft
        )
    }
}
