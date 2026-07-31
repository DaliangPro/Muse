import Foundation

enum WritingScene: String, Codable, Sendable, CaseIterable {
    case chat
    case workChat
    case email
    case document
    case note
    case aiPrompt
    case code
    case socialPost
    case customerSupport
    case unknown
}

enum ContextSafety: String, Codable, Sendable, Equatable {
    case safe
    case secure
    case unknown
}

enum WritingContextLevel: String, Codable, Sendable, Equatable {
    case metadataOnly
    case selectedText
    case nearbyText
}

struct WritingContext: Sendable, Equatable, Codable {
    let applicationBundleID: String?
    let applicationName: String?
    let focusedRole: String?
    let scene: WritingScene
    let level: WritingContextLevel
    let safety: ContextSafety
    let selectedText: String?
    let textBeforeCursor: String?
    let textAfterCursor: String?
    let localeIdentifier: String?

    init(
        applicationBundleID: String? = nil,
        applicationName: String? = nil,
        focusedRole: String? = nil,
        scene: WritingScene = .unknown,
        level: WritingContextLevel = .metadataOnly,
        safety: ContextSafety = .unknown,
        selectedText: String? = nil,
        textBeforeCursor: String? = nil,
        textAfterCursor: String? = nil,
        localeIdentifier: String? = nil
    ) {
        self.applicationBundleID = applicationBundleID
        self.applicationName = applicationName
        self.focusedRole = focusedRole
        self.scene = scene
        self.level = level
        self.safety = safety
        self.localeIdentifier = localeIdentifier

        if safety == .safe, level != .metadataOnly {
            self.selectedText = selectedText
            self.textBeforeCursor = level == .nearbyText ? textBeforeCursor : nil
            self.textAfterCursor = level == .nearbyText ? textAfterCursor : nil
        } else {
            self.selectedText = nil
            self.textBeforeCursor = nil
            self.textAfterCursor = nil
        }
    }

    static let phaseOneUnknown = WritingContext()
}

enum VoicePolishQualityMode: String, Codable, CaseIterable, Sendable, Equatable {
    case fast
    case balanced
    case quality
}

enum VoicePolishRoute: String, Codable, Sendable, Equatable {
    case fast
    case structured
    case deep
}

struct UserPolishPreferences: Sendable, Equatable {
    let additionalRequirements: String

    init(additionalRequirements: String) {
        self.additionalRequirements = additionalRequirements
            .removingPromptTextPlaceholder()
    }
}

enum EntityCandidateSource: String, Codable, Sendable, Equatable {
    case personalLexicon
    case snippet
    case hotword
    case authorizedContext

    var priority: Int {
        switch self {
        case .personalLexicon: return 4
        case .snippet: return 3
        case .hotword: return 2
        case .authorizedContext: return 1
        }
    }
}

struct ResolvedEntity: Codable, Sendable, Equatable {
    let surfaceText: String
    let canonical: String
    let sourceSegmentIDs: [String]
    let candidateSource: EntityCandidateSource
    let confidence: Double
}

struct VoicePolishRequest: Sendable, Equatable {
    let input: VoiceInputEnvelope
    let context: WritingContext
    let preferences: UserPolishPreferences
    let qualityMode: VoicePolishQualityMode
    let resolvedEntities: [ResolvedEntity]

    init(
        input: VoiceInputEnvelope,
        context: WritingContext,
        preferences: UserPolishPreferences,
        qualityMode: VoicePolishQualityMode,
        resolvedEntities: [ResolvedEntity] = []
    ) {
        self.input = input
        self.context = context
        self.preferences = preferences
        self.qualityMode = qualityMode
        self.resolvedEntities = resolvedEntities
    }

    var fallbackText: String {
        EntityResolver.applying(resolvedEntities, to: input.fallbackText)
    }
}

struct VoicePolishResult: Sendable, Equatable {
    let text: String
    let detectedRoute: VoicePolishRoute
    let executedRoute: VoicePolishRoute
    let llmAttemptCount: Int
    let validationCodes: [VoicePolishValidationCode]
    let usedFallback: Bool
    let failureReason: VoicePolishFailureReason?
}

enum VoicePolishFailureReason: String, Sendable, Equatable {
    case timeout
    case requestFailed
    case validationFailed
    case setupFailed
}

struct VoicePolishPlan: Codable, Sendable, Equatable {
    let version: Int
    let language: String?
    let scene: WritingScene
    let finalIntent: String
    let orderedBlocks: [VoicePolishBlock]
    let discardedFragments: [DiscardedFragment]
    let corrections: [VoiceCorrection]
    let sideNotes: [String]
    let facts: [ProtectedFact]
    let uncertainEntities: [UncertainEntity]
    let outputFormat: VoiceOutputFormat
    let confidence: Double
}

struct VoicePolishBlock: Codable, Sendable, Equatable {
    let id: String
    let text: String
    let sourceSegmentIDs: [String]
    let kind: BlockKind
}

enum BlockKind: String, Codable, Sendable {
    case content
    case conclusion
    case question
    case instruction
    case listItem
    case emphasis
}

struct DiscardedFragment: Codable, Sendable, Equatable {
    let text: String
    let sourceSegmentIDs: [String]
    let reason: DiscardReason
}

enum DiscardReason: String, Codable, Sendable {
    case filler
    case repetition
    case abandoned
    case superseded
    case sideNote
}

struct VoiceCorrection: Codable, Sendable, Equatable {
    let previousText: String
    let finalText: String
    let sourceSegmentIDs: [String]
    let isFinal: Bool
}

struct UncertainEntity: Codable, Sendable, Equatable {
    let surfaceText: String
    let sourceSegmentIDs: [String]
    let description: String?
    let selectedCandidate: String?
    let confidence: Double
}

struct VoiceOutputFormat: Codable, Sendable, Equatable {
    let kind: OutputKind
    let expectedListCount: Int?
}

enum OutputKind: String, Codable, Sendable {
    case sentence
    case paragraphs
    case numberedList
    case bulletList
}

struct ProtectedFact: Codable, Sendable, Equatable {
    let sourceText: String
    let canonicalValue: String?
    let kind: ProtectedFactKind
    let disposition: ProtectedFactDisposition
    let exclusionReason: DiscardReason?
    let sourceSegmentIDs: [String]
}

enum ProtectedFactKind: String, Codable, Sendable, CaseIterable {
    case number
    case amount
    case percentage
    case date
    case time
    case version
    case url
    case email
    case filePath
    case command
    case codeIdentifier
    case lexiconEntity
    case quotedPhrase
}

enum ProtectedFactDisposition: String, Codable, Sendable {
    case mustPreserve
    case superseded
    case excluded
    case uncertain
}

struct SourceFactCandidate: Sendable, Equatable, Codable {
    let sourceText: String
    let canonicalValue: String?
    let kind: ProtectedFactKind
    let sourceSegmentIDs: [String]
}

enum VoicePolishValidationCode: String, Codable, Sendable, Equatable, CaseIterable {
    case emptyOutput
    case explanationOnly
    case promptLeakage
    case missingProtectedFact
    case supersededFactRetained
    case excludedSideNoteLeaked
    case invalidStructuredResponse
    case ambiguousStructuredResponse
    case abnormalLength
    case unsafeCharacters
    case planIntegrityFailure
    case excessiveParagraphs
    case sceneStyleMismatch
    case harmlessRepetition
    case semanticDecisionUnverified

    var isHardFailure: Bool {
        switch self {
        case .excessiveParagraphs, .sceneStyleMismatch, .harmlessRepetition,
             .semanticDecisionUnverified:
            return false
        default:
            return true
        }
    }
}

struct StructuredVoicePolishResponse: Codable, Sendable, Equatable {
    let plan: VoicePolishPlan
    let finalText: String
}
