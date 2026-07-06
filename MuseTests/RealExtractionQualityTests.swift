import XCTest
@testable import Muse

/// 2026-07 重构批二质量实测：拿真实语料库副本 + 真实 LLM 跑两段式管线，
/// 结果写入 /tmp/muse-real-extraction-*.md 供大梁老师亲自判质量。
/// 默认跳过；手动运行：MUSE_REAL_EXTRACTION=1 swift test --filter RealExtractionQualityTests
final class RealExtractionQualityTests: XCTestCase {

    func testRealExtractionOnLiveCorpus() async throws {
        guard ProcessInfo.processInfo.environment["MUSE_REAL_EXTRACTION"] == "1" else {
            throw XCTSkip("质量实测专用，MUSE_REAL_EXTRACTION=1 时才运行")
        }

        // 1. 复制真实语料库到临时目录（绝不碰真库；-wal 一并复制保最新数据可见）
        let fm = FileManager.default
        let sourceDB = NSHomeDirectory() + "/Library/Application Support/Muse/history.db"
        let tmpDir = fm.temporaryDirectory.appendingPathComponent("muse-real-extraction-\(UUID().uuidString)")
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let corpusCopy = tmpDir.appendingPathComponent("history.db").path
        try fm.copyItem(atPath: sourceDB, toPath: corpusCopy)
        for suffix in ["-wal", "-shm"] where fm.fileExists(atPath: sourceDB + suffix) {
            try? fm.copyItem(atPath: sourceDB + suffix, toPath: corpusCopy + suffix)
        }
        let assetDBPath = tmpDir.appendingPathComponent("assets.db").path

        let provider = KeychainService.selectedAssetExtractionLLMProvider
        let hasConfig = KeychainService.loadAssetExtractionLLMConfig() != nil
        print("[实测] LLM provider=\(provider.rawValue) configLoaded=\(hasConfig)")
        guard hasConfig else {
            XCTFail("测试进程读不到 LLM 凭证（keychain），无法实测")
            return
        }

        let historyStore = HistoryStore(path: corpusCopy)
        let assetStore = LanguageAssetStore(path: assetDBPath)
        let service = AssetExtractionService(historyStore: historyStore, assetStore: assetStore)

        var report = "# 语料资产两段式管线质量实测\n\n"
        report += "- 语料库: 真实 history.db 副本\n- Provider: \(provider.rawValue)\n- 范围: 近 30 天全量(分片扫描)\n\n"

        for recipeID in [
            ExtractionRecipe.quoteAssetsID,
        ] {
            let recipe = await assetStore.fetchRecipe(id: recipeID)
                ?? ExtractionRecipe.builtInRecipe(id: recipeID)!
            report += "\n---\n\n## 配方: \(recipe.name)\n\n"
            do {
                let start = Date()
                let result = try await service.extractRecipeResults(
                    configuration: AssetExtractionConfiguration
                        .last30Days()
                        .applying(recipeID: recipeID)
                )
                let elapsed = Int(Date().timeIntervalSince(start))
                let pending = await assetStore.fetchResults(runID: result.run.id, status: .pending)
                report += "- 用时: \(elapsed)s\n"
                report += "- 输入记录: \(result.run.sourceRecordCount) 条\n"
                report += "- run 摘要: \(result.run.summary ?? "无")\n"
                report += "- 待确认产物: \(pending.count) 条\n\n"
                for (index, item) in pending.enumerated() {
                    let score = item.score.map { String(Int($0)) } ?? "-"
                    report += "### \(index + 1). \(item.title)（评分 \(score)）\n\n"
                    report += "> 判决理由: \(item.reviewReason ?? "无")\n\n"
                    report += "\(item.content)\n\n"
                    if let summary = item.summary, !summary.isEmpty {
                        report += "摘要: \(summary)\n\n"
                    }
                }

                let rejected = await assetStore.fetchResults(runID: result.run.id, status: .rejected)
                report += "\n<details>严审砍掉 \(rejected.count) 条(按分数倒序,前 60 条)\n\n"
                for item in rejected.sorted(by: { ($0.score ?? 0) > ($1.score ?? 0) }).prefix(60) {
                    let score = item.score.map { String(Int($0)) } ?? "-"
                    report += "- [\(score)] \(item.title) — \(item.reviewReason ?? "")｜原文: \(String(item.content.prefix(60)))\n"
                }
                report += "</details>\n"
            } catch {
                report += "**失败**: \(String(describing: error))\n"
            }
        }

        // 附:严审砍掉的产物在 debug.log 里(临时 store 不共享,砍掉明细见 DebugFileLogger)
        let outPath = "/tmp/muse-real-extraction.md"
        try report.write(toFile: outPath, atomically: true, encoding: .utf8)
        print("[实测] 报告已写入 \(outPath)")
    }
}
