import AppKit
import Foundation

/// 由签名后的 Muse.app 显式执行的语音润色质量跑测入口。
///
/// XCTest 必须继续使用隔离凭据；该入口只在传入专用参数时运行，复用正式应用
/// 的 Provider 配置，但不会把 API Key 写入参数、日志或报告。
enum VoicePolishQualityRunner {
    struct Invocation: Equatable {
        let datasetPath: String
        let reportPath: String
        let limit: Int?
        let commit: String
    }

    private struct QualityDataset: Decodable {
        let schemaVersion: Int
        let name: String
        let cases: [QualityBaseCase]
        let stressVariants: [QualityVariant]
    }

    private struct QualityBaseCase: Decodable {
        let id: String
        let writingScene: WritingScene
        let spokenInput: String
        let referenceOutput: String
        let mustPreserve: [String]
        let mustRemove: [String]
        let mustNotInvent: [String]
        let preconditions: [String]?
    }

    private struct QualityVariant: Decodable {
        let id: String
        let baseCaseId: String
        let inputFactors: [String]
        let stutterForm: String?
        let spokenInput: String
        let preconditions: [String]?
    }

    private struct QualityInput {
        let testInputID: String
        let baseCaseID: String
        let inputKind: String
        let scene: WritingScene
        let inputFactors: [String]
        let stutterForm: String?
        let spokenInput: String
        let referenceOutput: String
        let mustPreserve: [String]
        let mustRemove: [String]
        let mustNotInvent: [String]
        let preconditions: [String]
    }

    private struct QualityCaseReport: Encodable {
        let testInputID: String
        let baseCaseID: String
        let inputKind: String
        let writingScene: String
        let inputFactors: [String]
        let stutterForm: String?
        let spokenInput: String
        let canonicalInput: String
        let referenceOutput: String
        let mustPreserve: [String]
        let mustRemove: [String]
        let mustNotInvent: [String]
        let modelOutput: String
        let rejectedModelOutput: String?
        let detectedRoute: String
        let executedRoute: String
        let llmCallCount: Int
        let latencyMilliseconds: Int64
        let fallbackUsed: Bool
        let validationCodes: [String]
        let failureReason: String?
    }

    private struct QualityRunReport: Encodable {
        let schemaVersion: Int
        let status: String
        let error: String?
        let runAt: Date
        let datasetName: String?
        let datasetSchemaVersion: Int?
        let provider: String
        let model: String?
        let endpointOrigin: String?
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
        case duplicateCaseID(String)
        case missingBaseCase(String)
        case missingLLMConfig

        var errorDescription: String? {
            switch self {
            case .missingArgument(let argument):
                return "缺少参数 \(argument)"
            case .invalidLimit(let value):
                return "limit 必须是正整数，当前为 \(value)"
            case .duplicateCaseID(let id):
                return "测试集存在重复 ID：\(id)"
            case .missingBaseCase(let id):
                return "专项变体指向不存在的基准样本：\(id)"
            case .missingLLMConfig:
                return "当前 LLM Provider 没有可用配置"
            }
        }
    }

    @MainActor
    static func startIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
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

    static func parseInvocation(arguments: [String]) throws -> Invocation? {
        guard arguments.contains("--voice-polish-quality-run") else { return nil }

        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
                return nil
            }
            return arguments[index + 1]
        }

        guard let datasetPath = value(after: "--dataset") else {
            throw RunnerError.missingArgument("--dataset")
        }
        guard let reportPath = value(after: "--report") else {
            throw RunnerError.missingArgument("--report")
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
            datasetPath: datasetPath,
            reportPath: reportPath,
            limit: limit,
            commit: value(after: "--commit") ?? "unknown"
        )
    }

    static func validatedInputCount(at datasetPath: String) throws -> Int {
        try flattenedInputs(from: loadDataset(at: datasetPath)).count
    }

    @MainActor
    private static func run(_ invocation: Invocation) async {
        let provider = KeychainService.selectedLLMProvider
        let qualityMode = VoicePolishQualityMode.balanced
        var report = QualityRunReport(
            schemaVersion: 1,
            status: "running",
            error: nil,
            runAt: Date(),
            datasetName: nil,
            datasetSchemaVersion: nil,
            provider: provider.rawValue,
            model: nil,
            endpointOrigin: nil,
            promptVersion: VoicePolishPrompts.version,
            qualityMode: qualityMode.rawValue,
            commit: invocation.commit,
            requestedInputCount: 0,
            completedInputCount: 0,
            cases: []
        )

        do {
            let dataset = try loadDataset(at: invocation.datasetPath)
            var inputs = try flattenedInputs(from: dataset)
            if let limit = invocation.limit {
                inputs = Array(inputs.prefix(limit))
            }
            guard let loadedConfig = KeychainService.loadLLMConfig() else {
                throw RunnerError.missingLLMConfig
            }
            let config = VoicePolishSettings.modelOverride().map(loadedConfig.withModel) ?? loadedConfig
            let client = LLMProviderRegistry.makeClient(for: provider)
            report = QualityRunReport(
                schemaVersion: report.schemaVersion,
                status: report.status,
                error: nil,
                runAt: report.runAt,
                datasetName: dataset.name,
                datasetSchemaVersion: dataset.schemaVersion,
                provider: provider.rawValue,
                model: config.model,
                endpointOrigin: endpointOrigin(config.baseURL),
                promptVersion: report.promptVersion,
                qualityMode: report.qualityMode,
                commit: report.commit,
                requestedInputCount: inputs.count,
                completedInputCount: 0,
                cases: []
            )
            try write(report, to: invocation.reportPath)

            var caseReports: [QualityCaseReport] = []
            for (index, input) in inputs.enumerated() {
                let terminology = terminologyRules(from: input.preconditions)
                let canonicalInput = EntityResolver.applyingKnownCorrections(
                    terminology,
                    to: input.spokenInput
                )
                let rawSegment = RecognitionSegment(
                    id: "s1",
                    text: input.spokenInput,
                    startTimeMs: nil,
                    endTimeMs: nil,
                    confidence: nil,
                    isFinal: true
                )
                let canonicalSegment = RecognitionSegment(
                    id: "s1",
                    text: canonicalInput,
                    startTimeMs: nil,
                    endTimeMs: nil,
                    confidence: nil,
                    isFinal: true
                )
                let edits = terminology.compactMap { alias, canonical -> VoiceTerminologyEdit? in
                    guard canonicalInput != input.spokenInput,
                          EntityResolver.applyingKnownCorrections([alias: canonical], to: input.spokenInput)
                            != input.spokenInput else { return nil }
                    return VoiceTerminologyEdit(
                        alias: alias,
                        canonical: canonical,
                        sourceSegmentIDs: ["s1"]
                    )
                }
                let envelope = VoiceInputEnvelope(
                    providerFinalText: input.spokenInput,
                    rawSegments: [rawSegment],
                    canonicalText: canonicalInput,
                    segments: [canonicalSegment],
                    requiredEntityEdits: edits,
                    durationMs: 0,
                    provider: KeychainService.selectedASRProvider
                )
                let request = VoicePolishRequest(
                    input: envelope,
                    context: WritingContext(
                        scene: input.scene,
                        level: .metadataOnly,
                        safety: .unknown
                    ),
                    preferences: UserPolishPreferences(additionalRequirements: ""),
                    qualityMode: qualityMode
                )
                let startedAt = ContinuousClock.now
                let result = await VoicePolishPipeline(client: client, config: config).process(request)
                let elapsed = ContinuousClock.now - startedAt
                caseReports.append(QualityCaseReport(
                    testInputID: input.testInputID,
                    baseCaseID: input.baseCaseID,
                    inputKind: input.inputKind,
                    writingScene: input.scene.rawValue,
                    inputFactors: input.inputFactors,
                    stutterForm: input.stutterForm,
                    spokenInput: input.spokenInput,
                    canonicalInput: canonicalInput,
                    referenceOutput: input.referenceOutput,
                    mustPreserve: input.mustPreserve,
                    mustRemove: input.mustRemove,
                    mustNotInvent: input.mustNotInvent,
                    modelOutput: result.text,
                    rejectedModelOutput: result.rejectedDraft,
                    detectedRoute: result.detectedRoute.rawValue,
                    executedRoute: result.executedRoute.rawValue,
                    llmCallCount: result.llmAttemptCount,
                    latencyMilliseconds: milliseconds(elapsed),
                    fallbackUsed: result.usedFallback,
                    validationCodes: result.validationCodes.map(\.rawValue),
                    failureReason: result.failureReason?.rawValue
                ))
                report = replacing(
                    report,
                    status: "running",
                    error: nil,
                    completedInputCount: index + 1,
                    cases: caseReports
                )
                try write(report, to: invocation.reportPath)
                print("VOICE_POLISH_QUALITY_PROGRESS \(index + 1)/\(inputs.count) \(input.testInputID)")
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

    private static func loadDataset(at path: String) throws -> QualityDataset {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(QualityDataset.self, from: data)
    }

    private static func flattenedInputs(from dataset: QualityDataset) throws -> [QualityInput] {
        var baseByID: [String: QualityBaseCase] = [:]
        for item in dataset.cases {
            guard baseByID.updateValue(item, forKey: item.id) == nil else {
                throw RunnerError.duplicateCaseID(item.id)
            }
        }

        var seenIDs = Set<String>()
        var result: [QualityInput] = []
        for item in dataset.cases {
            guard seenIDs.insert(item.id).inserted else {
                throw RunnerError.duplicateCaseID(item.id)
            }
            result.append(QualityInput(
                testInputID: item.id,
                baseCaseID: item.id,
                inputKind: "base",
                scene: item.writingScene,
                inputFactors: [],
                stutterForm: nil,
                spokenInput: item.spokenInput,
                referenceOutput: item.referenceOutput,
                mustPreserve: item.mustPreserve,
                mustRemove: item.mustRemove,
                mustNotInvent: item.mustNotInvent,
                preconditions: item.preconditions ?? []
            ))
        }
        for item in dataset.stressVariants {
            guard seenIDs.insert(item.id).inserted else {
                throw RunnerError.duplicateCaseID(item.id)
            }
            guard let base = baseByID[item.baseCaseId] else {
                throw RunnerError.missingBaseCase(item.baseCaseId)
            }
            result.append(QualityInput(
                testInputID: item.id,
                baseCaseID: item.baseCaseId,
                inputKind: "stress_variant",
                scene: base.writingScene,
                inputFactors: item.inputFactors,
                stutterForm: item.stutterForm,
                spokenInput: item.spokenInput,
                referenceOutput: base.referenceOutput,
                mustPreserve: base.mustPreserve,
                mustRemove: base.mustRemove,
                mustNotInvent: base.mustNotInvent,
                preconditions: (base.preconditions ?? []) + (item.preconditions ?? [])
            ))
        }
        return result
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

    private static func endpointOrigin(_ rawValue: String) -> String? {
        guard let components = URLComponents(string: rawValue),
              let scheme = components.scheme,
              let host = components.host else { return nil }
        let port = components.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
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
            datasetName: report.datasetName,
            datasetSchemaVersion: report.datasetSchemaVersion,
            provider: report.provider,
            model: report.model,
            endpointOrigin: report.endpointOrigin,
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
        let report = QualityRunReport(
            schemaVersion: 1,
            status: "failed",
            error: LogRedactor.redact(error.localizedDescription),
            runAt: Date(),
            datasetName: nil,
            datasetSchemaVersion: nil,
            provider: "unknown",
            model: nil,
            endpointOrigin: nil,
            promptVersion: VoicePolishPrompts.version,
            qualityMode: VoicePolishQualityMode.balanced.rawValue,
            commit: "unknown",
            requestedInputCount: 0,
            completedInputCount: 0,
            cases: []
        )
        try? write(report, to: arguments[reportIndex + 1])
    }
}
