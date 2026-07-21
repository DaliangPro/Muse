import Foundation
import SQLite3
@testable import Muse
import XCTest

final class AssetExtractionCommitTests: XCTestCase {
    private var store: LanguageAssetStore!
    private var testPath: String!
    private var notificationCenter: NotificationCenter!

    override func setUp() async throws {
        testPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("muse-extraction-commit-\(UUID().uuidString).db")
            .path
        notificationCenter = NotificationCenter()
        store = LanguageAssetStore(
            path: testPath,
            notificationCenter: notificationCenter
        )
    }

    override func tearDown() async throws {
        await store.deleteAll()
        store = nil
        notificationCenter = nil
        try? FileManager.default.removeItem(atPath: testPath)
        testPath = nil
    }

    func testSecondResultFailureRollsBackFirstResultCandidateAndFinishedStates() async throws {
        let runningJob = makeJob(status: .running)
        let runningRun = makeRun(id: runningJob.id, status: .running)
        try await store.commitExtraction(
            candidates: [],
            results: [],
            job: runningJob,
            run: runningRun,
            actionType: .extractionStarted,
            actionDetail: "开始事务测试"
        )
        try executeSQL("""
        CREATE TRIGGER force_second_result_failure
        BEFORE INSERT ON extraction_result
        WHEN NEW.id = 'result-second'
        BEGIN
            SELECT RAISE(ABORT, 'forced second result failure');
        END;
        """)

        let candidate = makeCandidate(id: "candidate-commit", jobID: runningJob.id)
        let results = [
            makeResult(id: "result-first", runID: runningRun.id, status: .active),
            makeResult(id: "result-second", runID: runningRun.id, status: .active),
        ]
        let finishedJob = makeJob(id: runningJob.id, status: .succeeded)
        let finishedRun = makeRun(id: runningRun.id, status: .succeeded, resultCount: 2)

        let error = await captureError {
            try await self.store.commitExtraction(
                candidates: [candidate],
                results: results,
                job: finishedJob,
                run: finishedRun,
                actionType: .extractionSucceeded,
                actionDetail: "不应提交"
            )
        }

        assertSQLiteError(error, contains: "forced second result failure")
        let candidates = await store.fetchCandidates(status: .pending)
        let savedResults = await store.fetchResults(runID: runningRun.id, status: .active)
        let latestJob = await store.latestJob()
        let latestRun = await store.latestRun()
        XCTAssertTrue(candidates.isEmpty)
        XCTAssertTrue(savedResults.isEmpty)
        XCTAssertEqual(latestJob?.status, .running)
        XCTAssertEqual(latestRun?.status, .running)
        XCTAssertEqual(actionCount(.extractionStarted), 1)
        XCTAssertEqual(actionCount(.extractionSucceeded), 0)
    }

    func testFinishedRunFailureRollsBackDataAndServiceCommitsFailedStateSeparately() async throws {
        let historyStore = HistoryStore(path: testPath)
        let record = HistoryRecord(
            id: "history-transaction",
            createdAt: Date(),
            durationSeconds: 2,
            rawText: "原始文本",
            processingMode: nil,
            processedText: nil,
            finalText: "真正能复用的判断，必须经得起事务失败。",
            status: "completed",
            characterCount: 21
        )
        await historyStore.insert(record)
        try executeSQL("""
        CREATE TRIGGER force_finished_run_failure
        BEFORE INSERT ON extraction_run
        WHEN NEW.status = 'succeeded'
        BEGIN
            SELECT RAISE(ABORT, 'forced finished run failure');
        END;
        """)
        let service = AssetExtractionService(
            historyStore: historyStore,
            assetStore: store,
            provider: SuccessfulAssetProvider()
        )

        let error = await captureError {
            _ = try await service.extractAssets(configuration: .recent(limit: 10))
        }

        assertSQLiteError(error, contains: "forced finished run failure")
        let latestJob = await store.latestJob()
        let latestRun = await store.latestRun()
        let candidates = await store.fetchCandidates(status: .pending)
        let results = await store.fetchResults(runID: latestRun?.id, status: .active)
        XCTAssertEqual(latestJob?.status, .failed)
        XCTAssertEqual(latestRun?.status, .failed)
        XCTAssertEqual(latestRun?.resultCount, 0)
        XCTAssertTrue(candidates.isEmpty)
        XCTAssertTrue(results.isEmpty)
        XCTAssertEqual(actionCount(.extractionSucceeded), 0)
        XCTAssertEqual(actionCount(.extractionFailed), 1)
    }

    func testQueuedCommitFailureStillCommitsFailedJobAndRunSeparately() async throws {
        let historyStore = HistoryStore(path: testPath)
        try executeSQL("""
        CREATE TRIGGER force_queued_run_failure
        BEFORE INSERT ON extraction_run
        WHEN NEW.status = 'queued'
        BEGIN
            SELECT RAISE(ABORT, 'forced queued run failure');
        END;
        """)
        let service = AssetExtractionService(
            historyStore: historyStore,
            assetStore: store,
            provider: SuccessfulAssetProvider()
        )

        let error = await captureError {
            _ = try await service.extractAssets(configuration: .recent(limit: 10))
        }

        assertSQLiteError(error, contains: "forced queued run failure")
        let latestJob = await store.latestJob()
        let latestRun = await store.latestRun()
        XCTAssertEqual(latestJob?.status, .failed)
        XCTAssertEqual(latestRun?.status, .failed)
        XCTAssertEqual(actionCount(.extractionFailed), 1)
        XCTAssertEqual(actionCount(.extractionSucceeded), 0)
    }

    func testFailureStateFallsBackWithoutActionLogWhenLogWriteIsUnavailable() async throws {
        let historyStore = HistoryStore(path: testPath)
        try executeSQL("DROP TABLE language_asset_action_log;")
        let service = AssetExtractionService(
            historyStore: historyStore,
            assetStore: store,
            provider: SuccessfulAssetProvider()
        )

        let error = await captureError {
            _ = try await service.extractAssets(configuration: .recent(limit: 10))
        }

        assertSQLiteError(error, contains: "no such table")
        let latestJob = await store.latestJob()
        let latestRun = await store.latestRun()
        let candidates = await store.fetchCandidates(status: .pending)
        let results = await store.fetchResults(runID: latestRun?.id, status: .active)
        XCTAssertEqual(latestJob?.status, .failed)
        XCTAssertEqual(latestRun?.status, .failed)
        XCTAssertTrue(candidates.isEmpty)
        XCTAssertTrue(results.isEmpty)
    }

    func testRecipeCommitSavesKeptRejectedFinishedRunAndActionTogether() async throws {
        let runningRun = makeRun(
            id: "recipe-run",
            recipeID: ExtractionRecipe.todayTodosID,
            recipeName: "待办",
            status: .running
        )
        try await store.commitExtraction(
            candidates: [],
            results: [],
            job: nil,
            run: runningRun,
            actionType: .extractionStarted,
            actionDetail: "开始配方提炼"
        )
        let kept = makeResult(
            id: "recipe-kept",
            runID: runningRun.id,
            recipeID: runningRun.recipeID,
            status: .pending
        )
        let rejected = makeResult(
            id: "recipe-rejected",
            runID: runningRun.id,
            recipeID: runningRun.recipeID,
            status: .rejected
        )
        let finishedRun = makeRun(
            id: runningRun.id,
            recipeID: runningRun.recipeID,
            recipeName: runningRun.recipeName,
            status: .succeeded,
            resultCount: 1
        )

        try await store.commitExtraction(
            candidates: [],
            results: [kept, rejected],
            job: nil,
            run: finishedRun,
            actionType: .extractionSucceeded,
            actionDetail: "配方提炼完成"
        )

        let pending = await store.fetchResults(runID: runningRun.id, status: .pending)
        let dropped = await store.fetchResults(runID: runningRun.id, status: .rejected)
        let latestRun = await store.latestRun()
        XCTAssertEqual(pending.map(\.id), [kept.id])
        XCTAssertEqual(dropped.map(\.id), [rejected.id])
        XCTAssertEqual(latestRun?.status, .succeeded)
        XCTAssertEqual(latestRun?.resultCount, 1)
        XCTAssertEqual(actionCount(.extractionSucceeded), 1)
    }

    func testActionLogPrepareFailureRollsBackResultAndFinishedRun() async throws {
        let runningRun = makeRun(
            id: "prepare-failure-run",
            recipeID: ExtractionRecipe.dailyReportID,
            recipeName: "工作日报",
            status: .running
        )
        try await store.commitExtraction(
            candidates: [],
            results: [],
            job: nil,
            run: runningRun,
            actionType: nil,
            actionDetail: nil
        )
        try executeSQL("DROP TABLE language_asset_action_log;")
        let result = makeResult(
            id: "prepare-failure-result",
            runID: runningRun.id,
            recipeID: runningRun.recipeID,
            status: .pending
        )
        let finishedRun = makeRun(
            id: runningRun.id,
            recipeID: runningRun.recipeID,
            recipeName: runningRun.recipeName,
            status: .succeeded,
            resultCount: 1
        )

        let error = await captureError {
            try await self.store.commitExtraction(
                candidates: [],
                results: [result],
                job: nil,
                run: finishedRun,
                actionType: .extractionSucceeded,
                actionDetail: "应因日志表缺失而回滚"
            )
        }

        assertSQLiteError(error, contains: "no such table")
        let results = await store.fetchResults(runID: runningRun.id, status: .pending)
        let latestRun = await store.latestRun()
        XCTAssertTrue(results.isEmpty)
        XCTAssertEqual(latestRun?.status, .running)
    }

    private struct SuccessfulAssetProvider: AssetExtractionProvider {
        func extractAssets(
            from records: [HistoryRecord],
            configuration: AssetExtractionConfiguration
        ) async throws -> AssetExtractionResult {
            AssetExtractionResult(
                assets: [
                    AssetExtractionCandidate(
                        type: .quote,
                        grade: .a,
                        title: "事务判断",
                        content: "真正能复用的判断，必须经得起事务失败。",
                        summary: nil,
                        reason: "原文可复用",
                        keywords: [],
                        sourceRecordIDs: [records.first?.id ?? ""]
                    )
                ]
            )
        }
    }

    private func makeJob(
        id: String = "legacy-run",
        status: AssetExtractionJobStatus
    ) -> AssetExtractionJob {
        AssetExtractionJob(
            id: id,
            createdAt: Date(timeIntervalSince1970: 1_720_100_000),
            startedAt: Date(timeIntervalSince1970: 1_720_100_001),
            finishedAt: status == .running ? nil : Date(timeIntervalSince1970: 1_720_100_002),
            rangeType: .lastNRecords,
            rangePayload: "limit=10",
            sourceRecordCount: 1,
            status: status,
            summary: status == .succeeded ? "完成" : nil,
            errorMessage: status == .failed ? "失败" : nil
        )
    }

    private func makeRun(
        id: String,
        recipeID: String = ExtractionRecipe.contentCreatorAssetsID,
        recipeName: String = "内容创作素材",
        status: ExtractionRunStatus,
        resultCount: Int = 0
    ) -> ExtractionRun {
        ExtractionRun(
            id: id,
            recipeID: recipeID,
            recipeName: recipeName,
            createdAt: Date(timeIntervalSince1970: 1_720_100_000),
            startedAt: Date(timeIntervalSince1970: 1_720_100_001),
            finishedAt: status == .running ? nil : Date(timeIntervalSince1970: 1_720_100_002),
            rangeType: .lastNRecords,
            rangePayload: "limit=10",
            sourceRecordCount: 1,
            status: status,
            resultCount: resultCount,
            summary: status == .succeeded ? "完成" : nil,
            errorMessage: status == .failed ? "失败" : nil
        )
    }

    private func makeCandidate(id: String, jobID: String) -> LanguageAssetCandidateRecord {
        LanguageAssetCandidateRecord(
            id: id,
            createdAt: Date(timeIntervalSince1970: 1_720_100_001),
            updatedAt: Date(timeIntervalSince1970: 1_720_100_001),
            assetType: .quote,
            grade: .a,
            title: "候选",
            content: "事务候选正文",
            summary: nil,
            reason: "事务测试",
            scenes: ["复盘"],
            audiences: ["创作者"],
            ruleHit: nil,
            sourceRecordIDs: ["source-transaction"],
            sourceRecordCount: 1,
            extractionJobID: jobID,
            status: .pending
        )
    }

    private func makeResult(
        id: String,
        runID: String,
        recipeID: String = ExtractionRecipe.contentCreatorAssetsID,
        status: ExtractionResultStatus
    ) -> ExtractionResult {
        ExtractionResult(
            id: id,
            runID: runID,
            recipeID: recipeID,
            createdAt: Date(timeIntervalSince1970: 1_720_100_001),
            updatedAt: Date(timeIntervalSince1970: 1_720_100_001),
            outputKind: .assetCandidates,
            title: id,
            content: "结果 \(id)",
            summary: nil,
            payloadJSON: "{}",
            sourceRecordIDs: ["source-transaction"],
            sourceRecordCount: 1,
            status: status,
            score: status == .rejected ? 20 : 90,
            reviewReason: status == .rejected ? "未达标" : "达标"
        )
    }

    private func captureError(
        _ operation: () async throws -> Void
    ) async -> Error? {
        do {
            try await operation()
            return nil
        } catch {
            return error
        }
    }

    private func assertSQLiteError(
        _ error: Error?,
        contains expectedMessage: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case LanguageAssetStoreError.sqlite(let message)? = error else {
            return XCTFail("应透传 SQLite 错误，实际为 \(String(describing: error))", file: file, line: line)
        }
        XCTAssertTrue(
            message.contains(expectedMessage),
            "SQLite 错误应包含 '\(expectedMessage)'，实际为 '\(message)'",
            file: file,
            line: line
        )
    }

    private func actionCount(_ actionType: LanguageAssetActionType) -> Int {
        scalarInt("""
        SELECT COUNT(*)
        FROM language_asset_action_log
        WHERE action_type = '\(actionType.rawValue)';
        """)
    }

    private func scalarInt(_ sql: String) -> Int {
        var db: OpaquePointer?
        guard sqlite3_open(testPath, &db) == SQLITE_OK else {
            XCTFail("无法打开测试数据库")
            return -1
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            XCTFail("无法准备计数 SQL: \(String(cString: sqlite3_errmsg(db)))")
            return -1
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            XCTFail("无法执行计数 SQL: \(String(cString: sqlite3_errmsg(db)))")
            return -1
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func executeSQL(_ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(testPath, &db) == SQLITE_OK else {
            throw CommitTestDatabaseError.sqlite("无法打开测试数据库")
        }
        defer { sqlite3_close(db) }

        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw CommitTestDatabaseError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }
}

private enum CommitTestDatabaseError: Error {
    case sqlite(String)
}
