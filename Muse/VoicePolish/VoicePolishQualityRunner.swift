import AppKit
import CommonCrypto
import Foundation
import Security

/// 仅由显式质量跑测入口写入调用方指定的报告，用来区分模型初稿、修复与
/// 本地处理造成的变化；生产历史和诊断日志不采集正文，也不记录配置或凭据。
struct VoicePolishQualityStageResponse: Codable, Sendable, Equatable {
    let task: String
    let requestPayload: String
    let responseText: String
}

actor VoicePolishProviderAuditSuccessCounter {
    private var count = 0
    private var responses: [VoicePolishQualityStageResponse] = []

    func recordSuccess(request: LLMRequest, response: LLMResponse) {
        count += 1
        responses.append(VoicePolishQualityStageResponse(
            task: request.task.rawValue,
            requestPayload: request.user,
            responseText: response.text
        ))
    }

    func currentCount() -> Int {
        count
    }

    func stageResponses() -> [VoicePolishQualityStageResponse] {
        responses
    }
}

/// `AsyncTimeout` 会在 detached task 内执行模型调用，外层 TaskLocal 不会自动继承。
/// 质量 Runner 因此用每条样本独立的客户端包装器，在真正进入 `generate` 时重新
/// 绑定审计上下文，避免请求成功但网络层看不到 nonce、样本 ID 或回执路径。
struct VoicePolishProviderAuditedLLMClient: LLMClient {
    let base: any LLMClient
    let context: VoicePolishProviderAudit.Context
    let successCounter: VoicePolishProviderAuditSuccessCounter

    init(
        base: any LLMClient,
        runNonce: String,
        testInputID: String,
        receiptPath: String,
        successCounter: VoicePolishProviderAuditSuccessCounter = .init()
    ) {
        self.base = base
        self.successCounter = successCounter
        context = VoicePolishProviderAudit.Context(
            runNonce: runNonce,
            testInputID: testInputID,
            receiptPath: receiptPath
        )
    }

    func generate(_ request: LLMRequest, config: LLMConfig) async throws -> LLMResponse {
        let response = try await VoicePolishProviderAudit.withContext(
            runNonce: context.runNonce,
            testInputID: context.testInputID,
            receiptPath: context.receiptPath
        ) {
            try await base.generate(request, config: config)
        }
        // 网络层只有在 HTTP 200 响应完成解析且回执已经 fsync 后才会返回。
        // 预算尝试可能在超时、本地校验或非 200 响应处结束，不能冒充成功调用数。
        await successCounter.recordSuccess(request: request, response: response)
        return response
    }

    func process(
        text: String,
        prompt: String,
        context: LLMRequestContext,
        config: LLMConfig
    ) async throws -> String {
        try await base.process(text: text, prompt: prompt, context: context, config: config)
    }

    func probeThinkingMode(config: LLMConfig) async throws -> LLMThinkingProbeEvidence {
        try await base.probeThinkingMode(config: config)
    }

    func warmUp(baseURL: String) async {
        await base.warmUp(baseURL: baseURL)
    }
}

/// 由签名后的 Muse.app 显式执行的语音润色质量跑测入口。
///
/// XCTest 必须继续使用隔离凭据；该入口只在传入专用参数时运行，复用正式应用
/// 的 Provider 配置，但不会把 API Key 写入参数、日志或报告。
enum VoicePolishQualityRunner {
    private static let reportSchemaVersion = 4

    struct Invocation: Equatable {
        let runInputPath: String
        let reportPath: String
        let providerAuditPath: String
        let runNonce: String
        let limit: Int?
    }

    private struct QualityRunInputDocument: Decodable {
        let schemaVersion: Int
        let name: String
        let inputs: [QualityInput]
    }

    struct QualityContextFixture: Codable, Equatable {
        let type: String
        let level: WritingContextLevel
        let safety: ContextSafety
        let selectedText: String?
        let textBeforeCursor: String?
        let textAfterCursor: String?
        let recentMuseInputs: [String]

        private enum CodingKeys: String, CodingKey {
            case type
            case level
            case safety
            case selectedText
            case textBeforeCursor
            case textAfterCursor
            case recentMuseInputs
        }

        /// 质量报告必须保留完整夹具，包括显式的 `null` 字段，便于独立评审者
        /// 区分“数据集没有提供”与“Runner 在编码时漏掉了该字段”。
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(type, forKey: .type)
            try container.encode(level, forKey: .level)
            try container.encode(safety, forKey: .safety)
            if let selectedText {
                try container.encode(selectedText, forKey: .selectedText)
            } else {
                try container.encodeNil(forKey: .selectedText)
            }
            if let textBeforeCursor {
                try container.encode(textBeforeCursor, forKey: .textBeforeCursor)
            } else {
                try container.encodeNil(forKey: .textBeforeCursor)
            }
            if let textAfterCursor {
                try container.encode(textAfterCursor, forKey: .textAfterCursor)
            } else {
                try container.encodeNil(forKey: .textAfterCursor)
            }
            try container.encode(recentMuseInputs, forKey: .recentMuseInputs)
        }
    }

    struct QualityArtifactEvidence: Codable, Equatable {
        let runInputSHA256: String
        let executableSHA256: String
        let sourceCommit: String
    }

    struct QualityReportInputEvidence: Codable, Equatable {
        let segmentTexts: [String]
        let contextFixture: QualityContextFixture
    }

    struct QualityValidationEvidence: Equatable {
        let hardValidationCodes: [String]
        let diagnosticCodes: [String]
    }

    private struct QualityInput: Decodable {
        let testInputId: String
        let baseCaseId: String
        let inputKind: String
        let writingScene: WritingScene
        let spokenInput: String
        let preconditions: [String]
        let contextType: String
        let segmentTexts: [String]
        let contextFixture: QualityContextFixture?
    }

    private struct QualityCaseReport: Codable {
        let testInputID: String
        let baseCaseID: String
        let inputKind: String
        let writingScene: String
        let spokenInput: String
        let canonicalInput: String
        let segmentCount: Int
        let segmentTexts: [String]
        let contextFixture: QualityContextFixture
        let modelOutput: String
        let rejectedModelOutput: String?
        let stageResponses: [VoicePolishQualityStageResponse]
        let detectedRoute: String
        let executedRoute: String
        let internalChunkCount: Int
        let llmCallCount: Int
        let llmAttemptCount: Int
        let latencyMilliseconds: Int64
        let fallbackUsed: Bool
        let hardValidationCodes: [String]
        let diagnosticCodes: [String]
        let failureReason: String?
        let plannerValidationTrace: VoicePolishPlannerValidationTrace?
    }

    private struct QualityRunReport: Codable {
        let schemaVersion: Int
        let status: String
        let error: String?
        let runAt: Date
        let runNonce: String
        let processID: Int32
        let runInputName: String?
        let runInputSchemaVersion: Int?
        let runInputSHA256: String?
        let executableSHA256: String?
        let provider: String
        let model: String?
        let endpointURL: String?
        let promptVersion: Int
        let qualityMode: String
        let commit: String
        let requestedInputCount: Int
        let completedInputCount: Int
        let cases: [QualityCaseReport]
    }

    private enum RunnerError: LocalizedError {
        case missingArgument(String)
        case invalidLimit(String)
        case invalidRunNonce(String)
        case duplicateCaseID(String)
        case invalidRunInput
        case forbiddenRunInputField(String)
        case missingLLMConfig
        case noninteractiveKeychainUnavailable(OSStatus)
        case missingExecutableURL
        case missingSourceCommit
        case invalidSourceCommit(String)
        case evidenceFileReadFailed(String)
        case invalidProviderAuditPath(String)
        case providerAuditWasNotEmpty(String)
        case providerAuditUnreadable(String)
        case providerAuditCountMismatch(testID: String, expected: Int, actual: Int)

        var errorDescription: String? {
            switch self {
            case .missingArgument(let argument):
                return "缺少参数 \(argument)"
            case .invalidLimit(let value):
                return "limit 必须是正整数，当前为 \(value)"
            case .invalidRunNonce(let value):
                return "run nonce 必须是 64 位小写十六进制，当前为 \(value)"
            case .duplicateCaseID(let id):
                return "运行输入存在重复 ID：\(id)"
            case .invalidRunInput:
                return "运行输入必须是由 evaluator 生成的无答案 inputs 清单"
            case .forbiddenRunInputField(let field):
                return "运行输入包含禁止交给 Runner 的答案字段：\(field)"
            case .missingLLMConfig:
                return "当前 LLM Provider 没有可用配置"
            case .noninteractiveKeychainUnavailable(let status):
                return "无法禁用质量跑测进程的钥匙串交互，状态码：\(status)"
            case .missingExecutableURL:
                return "无法确定当前运行二进制路径"
            case .missingSourceCommit:
                return "候选应用没有写入 MuseSourceCommit，不能作为质量验收制品"
            case .invalidSourceCommit(let value):
                return "候选应用的 MuseSourceCommit 无效：\(value)"
            case .evidenceFileReadFailed(let path):
                return "无法读取质量验收证据文件：\(path)"
            case .invalidProviderAuditPath(let path):
                return "Provider 审计路径必须是 Evaluator 预建的绝对常规文件：\(path)"
            case .providerAuditWasNotEmpty(let path):
                return "Provider 审计文件在 Runner 启动前不是空文件：\(path)"
            case .providerAuditUnreadable(let path):
                return "Provider 审计文件无法完整读取：\(path)"
            case .providerAuditCountMismatch(let testID, let expected, let actual):
                return "\(testID) 完成后 Provider 回执累计 \(actual) 条，应为 \(expected) 条"
            }
        }
    }

    @MainActor
    static func startIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        if VoicePolishQualityAuthorization.startIfRequested(arguments: arguments) {
            return true
        }
        let invocation: Invocation
        do {
            guard let parsed = try parseInvocation(arguments: arguments) else { return false }
            invocation = parsed
        } catch {
            writeStartupFailure(error, arguments: arguments)
            NSApp.terminate(nil)
            return true
        }

        NSApp.setActivationPolicy(.prohibited)
        Task { @MainActor in
            await run(invocation)
            NSApp.terminate(nil)
        }
        return true
    }

    static func isRequested(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        arguments.contains("--voice-polish-quality-run")
            || arguments.contains(VoicePolishQualityAuthorization.argument)
    }

    static func parseInvocation(arguments: [String]) throws -> Invocation? {
        guard arguments.contains("--voice-polish-quality-run") else { return nil }
        guard !arguments.contains(VoicePolishQualityAuthorization.argument) else {
            throw VoicePolishQualityAuthorization.InvocationError.mixedOperations
        }

        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
                return nil
            }
            return arguments[index + 1]
        }

        guard let runInputPath = value(after: "--run-input") else {
            throw RunnerError.missingArgument("--run-input")
        }
        guard let reportPath = value(after: "--report") else {
            throw RunnerError.missingArgument("--report")
        }
        guard let providerAuditPath = value(after: "--provider-audit") else {
            throw RunnerError.missingArgument("--provider-audit")
        }
        guard let runNonce = value(after: "--run-nonce") else {
            throw RunnerError.missingArgument("--run-nonce")
        }
        guard runNonce.count == 64,
              runNonce.unicodeScalars.allSatisfy({
                  (48...57).contains($0.value) || (97...102).contains($0.value)
              }) else {
            throw RunnerError.invalidRunNonce(runNonce)
        }
        let limit: Int?
        if let rawLimit = value(after: "--limit") {
            guard let parsed = Int(rawLimit), parsed > 0 else {
                throw RunnerError.invalidLimit(rawLimit)
            }
            limit = parsed
        } else {
            limit = nil
        }
        return Invocation(
            runInputPath: runInputPath,
            reportPath: reportPath,
            providerAuditPath: providerAuditPath,
            runNonce: runNonce,
            limit: limit
        )
    }

    static func validatedInputCount(at runInputPath: String) throws -> Int {
        try validatedInputs(from: loadRunInput(at: runInputPath)).count
    }

    @MainActor
    private static func run(_ invocation: Invocation) async {
        let provider = KeychainService.selectedLLMProvider
        let qualityMode = VoicePolishQualityMode.automatic
        var report = QualityRunReport(
            schemaVersion: reportSchemaVersion,
            status: "running",
            error: nil,
            runAt: Date(),
            runNonce: invocation.runNonce,
            processID: ProcessInfo.processInfo.processIdentifier,
            runInputName: nil,
            runInputSchemaVersion: nil,
            runInputSHA256: nil,
            executableSHA256: nil,
            provider: provider.rawValue,
            model: nil,
            endpointURL: nil,
            promptVersion: VoicePolishPrompts.version,
            qualityMode: qualityMode.rawValue,
            commit: "unverified",
            requestedInputCount: 0,
            completedInputCount: 0,
            cases: []
        )

        do {
            // LAContext.interactionNotAllowed 不覆盖 macOS 传统钥匙串的全部
            // 交互路径。质量进程额外关闭本进程的传统交互，避免后台跑测
            // 等待系统授权窗口；不修改钥匙串条目、权限或安装版进程。
            let keychainStatus = SecKeychainSetUserInteractionAllowed(false)
            guard keychainStatus == errSecSuccess else {
                throw RunnerError.noninteractiveKeychainUnavailable(keychainStatus)
            }
            let providerAuditURL = try validatedEmptyProviderAuditURL(
                at: invocation.providerAuditPath
            )
            let artifactEvidence = try runtimeArtifactEvidence(
                runInputPath: invocation.runInputPath
            )
            let runInput = try loadRunInput(at: invocation.runInputPath)
            var inputs = try validatedInputs(from: runInput)
            if let limit = invocation.limit {
                inputs = Array(inputs.prefix(limit))
            }
            guard let loadedConfig = KeychainService.loadLLMConfig() else {
                throw RunnerError.missingLLMConfig
            }
            let config = VoicePolishSettings.modelOverride().map(loadedConfig.withModel) ?? loadedConfig
            let providerClient = LLMProviderRegistry.makeClient(for: provider)
            report = QualityRunReport(
                schemaVersion: report.schemaVersion,
                status: report.status,
                error: nil,
                runAt: report.runAt,
                runNonce: report.runNonce,
                processID: report.processID,
                runInputName: runInput.name,
                runInputSchemaVersion: runInput.schemaVersion,
                runInputSHA256: artifactEvidence.runInputSHA256,
                executableSHA256: artifactEvidence.executableSHA256,
                provider: provider.rawValue,
                model: config.model,
                endpointURL: try endpointIdentity(
                    rawBaseURL: config.baseURL,
                    provider: provider
                ),
                promptVersion: report.promptVersion,
                qualityMode: report.qualityMode,
                commit: artifactEvidence.sourceCommit,
                requestedInputCount: inputs.count,
                completedInputCount: 0,
                cases: []
            )
            try write(report, to: invocation.reportPath)

            var caseReports: [QualityCaseReport] = []
            var expectedProviderReceiptCount = 0
            for (index, input) in inputs.enumerated() {
                let terminology = terminologyRules(from: input.preconditions)
                let envelope = makeEnvelope(for: input, terminology: terminology)
                let canonicalInput = envelope.canonicalText
                let writingContext = makeWritingContext(for: input)
                let inputEvidence = reportInputEvidence(
                    segmentTexts: envelope.rawSegments.map(\.text),
                    contextFixture: input.contextFixture,
                    contextType: input.contextType,
                    appliedContext: writingContext
                )
                // 与正式 RecognitionSession 保持同一条链路：安全上下文先参与
                // 高置信实体解析，再随 payload 交给模型。否则质量跑测只测到了
                // Prompt 是否偶然看懂上下文，不能代表安装版的真实行为。
                let resolvedEntities = EntityResolver.resolve(
                    segments: envelope.segments,
                    lexicon: .empty,
                    snippets: [],
                    hotwords: [],
                    context: writingContext
                )
                let request = VoicePolishRequest(
                    input: envelope,
                    context: writingContext,
                    preferences: UserPolishPreferences(additionalRequirements: ""),
                    qualityMode: qualityMode,
                    resolvedEntities: resolvedEntities
                )
                let startedAt = ContinuousClock.now
                let successCounter = VoicePolishProviderAuditSuccessCounter()
                let auditedClient = VoicePolishProviderAuditedLLMClient(
                    base: providerClient,
                    runNonce: invocation.runNonce,
                    testInputID: input.testInputId,
                    receiptPath: providerAuditURL.path,
                    successCounter: successCounter
                )
                let result = await VoicePolishPipeline(
                    client: auditedClient,
                    config: config
                ).process(request)
                let elapsed = ContinuousClock.now - startedAt
                let successfulProviderCallCount = await successCounter.currentCount()
                expectedProviderReceiptCount += successfulProviderCallCount
                let actualProviderReceiptCount = try providerAuditReceiptCount(
                    at: providerAuditURL
                )
                guard actualProviderReceiptCount == expectedProviderReceiptCount else {
                    throw RunnerError.providerAuditCountMismatch(
                        testID: input.testInputId,
                        expected: expectedProviderReceiptCount,
                        actual: actualProviderReceiptCount
                    )
                }
                let validationEvidence = validationEvidence(for: result.validationCodes)
                caseReports.append(QualityCaseReport(
                    testInputID: input.testInputId,
                    baseCaseID: input.baseCaseId,
                    inputKind: input.inputKind,
                    writingScene: input.writingScene.rawValue,
                    spokenInput: input.spokenInput,
                    canonicalInput: canonicalInput,
                    segmentCount: inputEvidence.segmentTexts.count,
                    segmentTexts: inputEvidence.segmentTexts,
                    contextFixture: inputEvidence.contextFixture,
                    modelOutput: result.text,
                    rejectedModelOutput: result.rejectedDraft,
                    stageResponses: await successCounter.stageResponses(),
                    detectedRoute: result.detectedRoute.rawValue,
                    executedRoute: result.executedRoute.rawValue,
                    internalChunkCount: internalChunkCount(
                        for: request.fallbackText,
                        executedRoute: result.executedRoute
                    ),
                    llmCallCount: successfulProviderCallCount,
                    llmAttemptCount: result.llmAttemptCount,
                    latencyMilliseconds: milliseconds(elapsed),
                    fallbackUsed: result.usedFallback,
                    hardValidationCodes: validationEvidence.hardValidationCodes,
                    diagnosticCodes: validationEvidence.diagnosticCodes,
                    failureReason: result.failureReason?.rawValue,
                    plannerValidationTrace: result.plannerValidationTrace
                ))
                report = replacing(
                    report,
                    status: "running",
                    error: nil,
                    completedInputCount: index + 1,
                    cases: caseReports
                )
                try write(report, to: invocation.reportPath)
                print("VOICE_POLISH_QUALITY_PROGRESS \(index + 1)/\(inputs.count) \(input.testInputId)")
            }

            report = replacing(
                report,
                status: "complete",
                error: nil,
                completedInputCount: caseReports.count,
                cases: caseReports
            )
            try write(report, to: invocation.reportPath)
            print("VOICE_POLISH_QUALITY_COMPLETE \(caseReports.count)")
        } catch {
            report = replacing(
                report,
                status: "failed",
                error: LogRedactor.redact(error.localizedDescription),
                completedInputCount: report.cases.count,
                cases: report.cases
            )
            try? write(report, to: invocation.reportPath)
            print("VOICE_POLISH_QUALITY_FAILED \(LogRedactor.redact(error.localizedDescription))")
        }
    }

    private static let forbiddenRunInputFields: Set<String> = [
        "automatic_checks",
        "factor_assertions",
        "must_not_invent",
        "must_preserve",
        "must_remove",
        "quality_dimensions",
        "reference_output",
        "requires_transformation",
    ]

    /// Runner 只接受 evaluator 派生的无答案输入清单。先检查原始 JSON 键，避免
    /// `JSONDecoder` 静默忽略答案字段后，让完整母集看起来也像合法运行输入。
    private static func loadRunInput(at path: String) throws -> QualityRunInputDocument {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawInputs = object["inputs"] as? [[String: Any]] else {
            throw RunnerError.invalidRunInput
        }
        for rawInput in rawInputs {
            if let forbidden = forbiddenRunInputFields.first(where: rawInput.keys.contains) {
                throw RunnerError.forbiddenRunInputField(forbidden)
            }
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(QualityRunInputDocument.self, from: data)
    }

    private static func validatedInputs(
        from document: QualityRunInputDocument
    ) throws -> [QualityInput] {
        var seenIDs = Set<String>()
        for item in document.inputs {
            guard seenIDs.insert(item.testInputId).inserted else {
                throw RunnerError.duplicateCaseID(item.testInputId)
            }
        }
        return document.inputs
    }

    private static func makeEnvelope(
        for input: QualityInput,
        terminology: [String: String]
    ) -> VoiceInputEnvelope {
        let rawSegments = input.segmentTexts.enumerated().map { index, text in
            RecognitionSegment(
                id: "s\(index + 1)",
                text: text,
                startTimeMs: nil,
                endTimeMs: nil,
                confidence: nil,
                isFinal: true
            )
        }
        let canonicalSegments = rawSegments.map { segment in
            RecognitionSegment(
                id: segment.id,
                text: EntityResolver.applyingKnownCorrections(terminology, to: segment.text),
                startTimeMs: nil,
                endTimeMs: nil,
                confidence: nil,
                isFinal: true
            )
        }
        let edits = terminology.compactMap { alias, canonical -> VoiceTerminologyEdit? in
            let sourceSegmentIDs = rawSegments.compactMap { segment -> String? in
                EntityResolver.applyingKnownCorrections([alias: canonical], to: segment.text)
                    == segment.text ? nil : segment.id
            }
            guard !sourceSegmentIDs.isEmpty else { return nil }
            return VoiceTerminologyEdit(
                alias: alias,
                canonical: canonical,
                sourceSegmentIDs: sourceSegmentIDs
            )
        }
        return VoiceInputEnvelope(
            providerFinalText: input.spokenInput,
            rawSegments: rawSegments,
            canonicalText: canonicalSegments.map(\.text).joined(),
            segments: canonicalSegments,
            requiredEntityEdits: edits,
            durationMs: 0,
            provider: KeychainService.selectedASRProvider
        )
    }

    private static func makeWritingContext(for input: QualityInput) -> WritingContext {
        guard let fixture = input.contextFixture else {
            return WritingContext(
                scene: input.writingScene,
                level: .metadataOnly,
                safety: .unknown
            )
        }
        return WritingContext(
            scene: input.writingScene,
            level: fixture.level,
            safety: fixture.safety,
            selectedText: fixture.selectedText,
            textBeforeCursor: fixture.textBeforeCursor,
            textAfterCursor: fixture.textAfterCursor,
            recentMuseInputs: fixture.recentMuseInputs
        )
    }

    /// 报告记录 Runner 实际用于构造请求的分段，同时完整保留数据集上下文夹具。
    /// 没有显式夹具时也写出真实采用的默认上下文，而不是省略字段。
    static func reportInputEvidence(
        segmentTexts: [String],
        contextFixture: QualityContextFixture?,
        contextType: String,
        appliedContext: WritingContext
    ) -> QualityReportInputEvidence {
        let completeFixture = contextFixture ?? QualityContextFixture(
            type: contextType,
            level: appliedContext.level,
            safety: appliedContext.safety,
            selectedText: appliedContext.selectedText,
            textBeforeCursor: appliedContext.textBeforeCursor,
            textAfterCursor: appliedContext.textAfterCursor,
            recentMuseInputs: appliedContext.recentMuseInputs
        )
        return QualityReportInputEvidence(
            segmentTexts: segmentTexts,
            contextFixture: completeFixture
        )
    }

    private static func terminologyRules(from preconditions: [String]) -> [String: String] {
        var rules: [String: String] = [:]
        for precondition in preconditions {
            guard let arrow = precondition.range(of: "→") else { continue }
            var alias = String(precondition[..<arrow.lowerBound])
            if let marker = alias.range(of: "已确认 ", options: .backwards) {
                alias = String(alias[marker.upperBound...])
            }
            let canonical = String(precondition[arrow.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            alias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            if !alias.isEmpty, !canonical.isEmpty {
                rules[alias] = canonical
            }
        }
        return rules
    }

    /// 报告的是客户端最终请求地址，而不是设置里保存的 base URL。
    static func endpointIdentity(
        rawBaseURL: String,
        provider: LLMProvider,
        localQwenPort: Int? = nil
    ) throws -> String {
        let baseURL = try LLMEndpointPolicy.normalizedBaseURL(
            rawValue: rawBaseURL,
            provider: provider,
            localQwenPort: provider == .localQwen
                ? (localQwenPort ?? LLMEndpointPolicy.currentLocalQwenPort)
                : nil
        )
        let endpoint = try LLMEndpointPolicy.endpoint(
            baseURL: baseURL,
            pathComponents: provider == .claude ? ["messages"] : ["chat", "completions"]
        )
        guard let components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              let scheme = components.scheme,
              let host = components.host else {
            throw LLMEndpointPolicyError.invalidURL
        }
        let port = components.port.map { ":\($0)" } ?? ""
        var path = components.percentEncodedPath
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return "\(scheme.lowercased())://\(host.lowercased())\(port)\(path)"
    }

    static func validationEvidence(
        for codes: [VoicePolishValidationCode]
    ) -> QualityValidationEvidence {
        QualityValidationEvidence(
            hardValidationCodes: codes.filter(\.isHardFailure).map(\.rawValue),
            diagnosticCodes: codes.filter { !$0.isHardFailure }.map(\.rawValue)
        )
    }

    static func internalChunkCount(
        for text: String,
        executedRoute: VoicePolishRoute,
        maximumSourceTokens: Int = VoicePolishPipeline.fastChunkSourceTokenLimit
    ) -> Int {
        guard executedRoute == .fast else { return 1 }
        return max(
            1,
            VoicePolishPipeline.fastChunkTexts(
                from: text,
                maximumSourceTokens: maximumSourceTokens
            ).count
        )
    }

    /// 测试可显式注入伪二进制；生产路径不接受 CLI 或调用方传入的二进制地址，
    /// 始终从 `Bundle.main.executableURL` 读取当前进程制品。
    static func artifactEvidenceForTesting(
        runInputURL: URL,
        executableURL: URL,
        sourceCommit: String = String(repeating: "0", count: 40)
    ) throws -> QualityArtifactEvidence {
        try makeArtifactEvidence(
            runInputURL: runInputURL,
            executableURL: executableURL,
            sourceCommit: sourceCommit
        )
    }

    private static func makeArtifactEvidence(
        runInputURL: URL,
        executableURL: URL,
        sourceCommit: String
    ) throws -> QualityArtifactEvidence {
        let normalizedCommit = try validatedSourceCommit(sourceCommit)
        let runInputSHA256 = try sha256(fileAt: runInputURL)
        let executableSHA256 = try sha256(fileAt: executableURL)
        return QualityArtifactEvidence(
            runInputSHA256: runInputSHA256,
            executableSHA256: executableSHA256,
            sourceCommit: normalizedCommit
        )
    }

    private static func validatedSourceCommit(_ rawValue: String?) throws -> String {
        guard let rawValue else { throw RunnerError.missingSourceCommit }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.count == 40,
              value.unicodeScalars.allSatisfy({
                  (48...57).contains($0.value) || (97...102).contains($0.value)
              }) else {
            throw RunnerError.invalidSourceCommit(value)
        }
        return value
    }

    private static func runtimeArtifactEvidence(
        runInputPath: String
    ) throws -> QualityArtifactEvidence {
        guard let executableURL = Bundle.main.executableURL else {
            throw RunnerError.missingExecutableURL
        }
        let sourceCommit = try validatedSourceCommit(
            Bundle.main.object(forInfoDictionaryKey: "MuseSourceCommit") as? String
        )
        return try makeArtifactEvidence(
            runInputURL: URL(fileURLWithPath: runInputPath),
            executableURL: executableURL,
            sourceCommit: sourceCommit
        )
    }

    private static func sha256(fileAt url: URL) throws -> String {
        guard let stream = InputStream(url: url) else {
            throw RunnerError.evidenceFileReadFailed(url.path)
        }
        stream.open()
        defer { stream.close() }

        var context = CC_SHA256_CTX()
        CC_SHA256_Init(&context)

        let bufferSize = 1024 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while true {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count > 0 {
                CC_SHA256_Update(&context, buffer, CC_LONG(count))
            } else if count == 0 {
                break
            } else {
                throw stream.streamError
                    ?? RunnerError.evidenceFileReadFailed(url.path)
            }
        }

        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256_Final(&digest, &context)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func validatedEmptyProviderAuditURL(at path: String) throws -> URL {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard path.hasPrefix("/"), url.path == path,
              let values = try? url.resourceValues(
                  forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
              ),
              values.isRegularFile == true,
              values.isSymbolicLink != true else {
            throw RunnerError.invalidProviderAuditPath(path)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard (attributes[.size] as? NSNumber)?.intValue == 0 else {
            throw RunnerError.providerAuditWasNotEmpty(path)
        }
        return url
    }

    private static func providerAuditReceiptCount(at url: URL) throws -> Int {
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return 0 }
        guard data.last == 0x0A else {
            throw RunnerError.providerAuditUnreadable(url.path)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        do {
            for line in lines {
                _ = try decoder.decode(
                    VoicePolishProviderAuditReceipt.self,
                    from: Data(line)
                )
            }
        } catch {
            throw RunnerError.providerAuditUnreadable(url.path)
        }
        return lines.count
    }

    private static func milliseconds(_ duration: Duration) -> Int64 {
        duration.components.seconds * 1_000
            + Int64(duration.components.attoseconds / 1_000_000_000_000_000)
    }

    private static func replacing(
        _ report: QualityRunReport,
        status: String,
        error: String?,
        completedInputCount: Int,
        cases: [QualityCaseReport]
    ) -> QualityRunReport {
        QualityRunReport(
            schemaVersion: report.schemaVersion,
            status: status,
            error: error,
            runAt: report.runAt,
            runNonce: report.runNonce,
            processID: report.processID,
            runInputName: report.runInputName,
            runInputSchemaVersion: report.runInputSchemaVersion,
            runInputSHA256: report.runInputSHA256,
            executableSHA256: report.executableSHA256,
            provider: report.provider,
            model: report.model,
            endpointURL: report.endpointURL,
            promptVersion: report.promptVersion,
            qualityMode: report.qualityMode,
            commit: report.commit,
            requestedInputCount: report.requestedInputCount,
            completedInputCount: completedInputCount,
            cases: cases
        )
    }

    private static func write(_ report: QualityRunReport, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(report).write(to: url, options: .atomic)
    }

    @MainActor
    private static func writeStartupFailure(_ error: Error, arguments: [String]) {
        guard let reportIndex = arguments.firstIndex(of: "--report"),
              arguments.indices.contains(reportIndex + 1) else { return }
        let runNonce: String
        if let nonceIndex = arguments.firstIndex(of: "--run-nonce"),
           arguments.indices.contains(nonceIndex + 1) {
            runNonce = arguments[nonceIndex + 1]
        } else {
            runNonce = "invalid"
        }
        var artifactEvidence: QualityArtifactEvidence?
        if let runInputIndex = arguments.firstIndex(of: "--run-input"),
           arguments.indices.contains(runInputIndex + 1) {
            artifactEvidence = try? runtimeArtifactEvidence(
                runInputPath: arguments[runInputIndex + 1]
            )
        }
        let report = QualityRunReport(
            schemaVersion: reportSchemaVersion,
            status: "failed",
            error: LogRedactor.redact(error.localizedDescription),
            runAt: Date(),
            runNonce: runNonce,
            processID: ProcessInfo.processInfo.processIdentifier,
            runInputName: nil,
            runInputSchemaVersion: nil,
            runInputSHA256: artifactEvidence?.runInputSHA256,
            executableSHA256: artifactEvidence?.executableSHA256,
            provider: "unknown",
            model: nil,
            endpointURL: nil,
            promptVersion: VoicePolishPrompts.version,
            qualityMode: VoicePolishQualityMode.automatic.rawValue,
            commit: artifactEvidence?.sourceCommit ?? "unknown",
            requestedInputCount: 0,
            completedInputCount: 0,
            cases: []
        )
        try? write(report, to: arguments[reportIndex + 1])
    }
}
