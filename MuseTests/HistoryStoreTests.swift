import XCTest
import SQLite3
@testable import Muse

final class HistoryStoreTests: XCTestCase {

    private var store: HistoryStore!
    private var testPath: String!

    override func setUp() async throws {
        testPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("muse-test-\(UUID().uuidString).db").path
        store = HistoryStore(path: testPath)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(atPath: testPath)
    }

    func testInsertAndFetchAll() async {
        let record = HistoryRecord(
            id: UUID().uuidString, createdAt: Date(), durationSeconds: 3.5,
            rawText: "测试文本", processingMode: nil, processedText: nil,
            finalText: "测试文本", status: "completed", characterCount: 4,
            tokenCount: 4
        )
        await store.insert(record)
        let all = await store.fetchAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.rawText, "测试文本")
        XCTAssertEqual(all.first?.durationSeconds ?? 0, 3.5, accuracy: 0.01)
        XCTAssertEqual(all.first?.characterCount, 4)
        XCTAssertEqual(all.first?.tokenCount, 4)
    }

    func testInsertWithProcessedText() async {
        let record = HistoryRecord(
            id: UUID().uuidString, createdAt: Date(), durationSeconds: 2.0,
            rawText: "原始文本", processingMode: "润色",
            processedText: "润色后的文本", finalText: "润色后的文本", status: "completed",
            characterCount: 6,
            tokenCount: 6
        )
        await store.insert(record)
        let all = await store.fetchAll()
        XCTAssertEqual(all.first?.processingMode, "润色")
        XCTAssertEqual(all.first?.processedText, "润色后的文本")
        XCTAssertEqual(all.first?.characterCount, 6)
        XCTAssertEqual(all.first?.tokenCount, 6)
    }

    func testDelete() async {
        let id = UUID().uuidString
        let record = HistoryRecord(
            id: id, createdAt: Date(), durationSeconds: 1.0,
            rawText: "to delete", processingMode: nil, processedText: nil,
            finalText: "to delete", status: "completed", characterCount: 9
        )
        await store.insert(record)
        await store.delete(id: id)
        let all = await store.fetchAll()
        XCTAssertTrue(all.isEmpty)
    }

    func testFetchAllOrderedByDate() async {
        let old = HistoryRecord(
            id: "1", createdAt: Date(timeIntervalSinceNow: -100), durationSeconds: 1,
            rawText: "old", processingMode: nil, processedText: nil,
            finalText: "old", status: "completed", characterCount: 3
        )
        let recent = HistoryRecord(
            id: "2", createdAt: Date(), durationSeconds: 1,
            rawText: "recent", processingMode: nil, processedText: nil,
            finalText: "recent", status: "completed", characterCount: 6
        )
        await store.insert(old)
        await store.insert(recent)
        let all = await store.fetchAll()
        XCTAssertEqual(all.first?.rawText, "recent")
        XCTAssertEqual(all.last?.rawText, "old")
    }

    func testDeleteAll() async {
        for i in 0..<3 {
            await store.insert(HistoryRecord(
                id: "\(i)", createdAt: Date(), durationSeconds: 1,
                rawText: "text\(i)", processingMode: nil, processedText: nil,
                finalText: "text\(i)", status: "completed", characterCount: 5 + i
            ))
        }
        await store.deleteAll()
        let all = await store.fetchAll()
        XCTAssertTrue(all.isEmpty)
    }

    func testFetchRecentReturnsLimitedNewestRecords() async {
        await store.insert(HistoryRecord(
            id: "1", createdAt: Date(timeIntervalSinceNow: -100), durationSeconds: 1,
            rawText: "old", processingMode: nil, processedText: nil,
            finalText: "old", status: "completed", characterCount: 3
        ))
        await store.insert(HistoryRecord(
            id: "2", createdAt: Date(), durationSeconds: 1,
            rawText: "new", processingMode: nil, processedText: nil,
            finalText: "new", status: "completed", characterCount: 3
        ))

        let recent = await store.fetchRecent(limit: 1)
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent.first?.id, "2")
    }

    func testFetchBetweenFiltersByDateRange() async {
        let olderDate = Date(timeIntervalSinceNow: -3600)
        let inRangeDate = Date(timeIntervalSinceNow: -300)

        await store.insert(HistoryRecord(
            id: "old", createdAt: olderDate, durationSeconds: 1,
            rawText: "old", processingMode: nil, processedText: nil,
            finalText: "old", status: "completed", characterCount: 3
        ))
        await store.insert(HistoryRecord(
            id: "in-range", createdAt: inRangeDate, durationSeconds: 1,
            rawText: "new", processingMode: nil, processedText: nil,
            finalText: "new", status: "completed", characterCount: 3
        ))

        let records = await store.fetchBetween(
            start: Date(timeIntervalSinceNow: -600),
            end: Date()
        )
        XCTAssertEqual(records.map(\.id), ["in-range"])
    }

    func testFetchIDsReturnsOnlyMatchingRecords() async {
        await store.insert(HistoryRecord(
            id: "a", createdAt: Date(timeIntervalSinceNow: -60), durationSeconds: 1,
            rawText: "a", processingMode: nil, processedText: nil,
            finalText: "a", status: "completed", characterCount: 1
        ))
        await store.insert(HistoryRecord(
            id: "b", createdAt: Date(), durationSeconds: 1,
            rawText: "b", processingMode: nil, processedText: nil,
            finalText: "b", status: "completed", characterCount: 1
        ))

        let records = await store.fetch(ids: ["a"])
        XCTAssertEqual(records.map(\.id), ["a"])
    }

    func testInsertPostsHistoryDidChangeNotification() async {
        let notification = expectation(forNotification: .historyStoreDidChange, object: nil)
        let record = HistoryRecord(
            id: UUID().uuidString, createdAt: Date(), durationSeconds: 1.2,
            rawText: "notify", processingMode: "智能模式", processedText: "notify",
            finalText: "notify", status: "completed", characterCount: 6
        )

        await store.insert(record)

        await fulfillment(of: [notification], timeout: 1.0)
    }

    func testStatisticsCalculatesTimeSavedPerRecord() async {
        await store.insert(HistoryRecord(
            id: "fast-dictation",
            createdAt: Date(timeIntervalSinceNow: -60),
            durationSeconds: 30,
            rawText: "一二三四五六七八九十",
            processingMode: nil,
            processedText: nil,
            finalText: "一二三四五六七八九十",
            status: "completed",
            characterCount: 100,
            tokenCount: 50
        ))
        await store.insert(HistoryRecord(
            id: "slow-dictation",
            createdAt: Date(),
            durationSeconds: 30,
            rawText: "短句",
            processingMode: nil,
            processedText: nil,
            finalText: "短句",
            status: "completed",
            characterCount: 10,
            tokenCount: 5
        ))

        let statistics = await store.getStatistics()

        XCTAssertEqual(statistics.totalDuration, 60, accuracy: 0.01)
        XCTAssertEqual(statistics.totalCharacters, 110)
        XCTAssertEqual(statistics.totalTokens, 55)
        XCTAssertEqual(statistics.averageSpeed, 55, accuracy: 0.01)
        XCTAssertEqual(statistics.recordCount, 2)
        XCTAssertEqual(statistics.timeSavedSeconds, 90, accuracy: 0.01)
    }

    func testStatisticsIgnoreDurationForRowsWithoutTokenCount() async {
        await store.insert(HistoryRecord(
            id: "legacy-null-count",
            createdAt: Date(timeIntervalSinceNow: -60),
            durationSeconds: 99,
            rawText: "legacy",
            processingMode: nil,
            processedText: nil,
            finalText: "legacy",
            status: "completed",
            characterCount: nil,
            tokenCount: nil
        ))
        await store.insert(HistoryRecord(
            id: "counted",
            createdAt: Date(),
            durationSeconds: 12,
            rawText: "一二三四五六七八九十",
            processingMode: nil,
            processedText: nil,
            finalText: "一二三四五六七八九十",
            status: "completed",
            characterCount: 10,
            tokenCount: 7
        ))

        let statistics = await store.getStatistics()

        XCTAssertEqual(statistics.recordCount, 2)
        XCTAssertEqual(statistics.totalDuration, 12, accuracy: 0.01)
        XCTAssertEqual(statistics.totalCharacters, 10)
        XCTAssertEqual(statistics.totalTokens, 7)
        XCTAssertEqual(statistics.averageSpeed, 35, accuracy: 0.01)
    }

    func testStatisticsUsesTokenCountForAverageSpeed() async {
        await store.insert(HistoryRecord(
            id: "token-speed",
            createdAt: Date(),
            durationSeconds: 15,
            rawText: "这是一个更长的句子",
            processingMode: nil,
            processedText: nil,
            finalText: "这是一个更长的句子",
            status: "completed",
            characterCount: 100,
            tokenCount: 25
        ))

        let statistics = await store.getStatistics()

        XCTAssertEqual(statistics.totalCharacters, 100)
        XCTAssertEqual(statistics.totalTokens, 25)
        XCTAssertEqual(statistics.averageSpeed, 100, accuracy: 0.01)
    }

    func testMigratesLegacyDatabaseWithoutCharacterCountColumn() async throws {
        let legacyPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("muse-legacy-\(UUID().uuidString).db").path
        defer { try? FileManager.default.removeItem(atPath: legacyPath) }
        try createLegacyHistoryDatabase(at: legacyPath)
        let legacyStore = HistoryStore(path: legacyPath)

        var records = await legacyStore.fetchAll()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.id, "legacy-row")
        XCTAssertNil(records.first?.characterCount)
        XCTAssertNil(records.first?.tokenCount)

        await legacyStore.migrateTextMetrics()

        records = await legacyStore.fetchAll()
        XCTAssertEqual(records.first?.characterCount, 3)
        XCTAssertEqual(records.first?.tokenCount, 3)
        let statistics = await legacyStore.getStatistics()
        XCTAssertEqual(statistics.totalCharacters, 3)
        XCTAssertEqual(statistics.totalTokens, 3)
        XCTAssertEqual(statistics.totalDuration, 2.5, accuracy: 0.01)
    }

    private func createLegacyHistoryDatabase(at path: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }

        let sql = """
        CREATE TABLE recognition_history (
            id TEXT PRIMARY KEY,
            created_at TEXT NOT NULL,
            duration_seconds REAL,
            raw_text TEXT NOT NULL,
            processing_mode TEXT,
            processed_text TEXT,
            final_text TEXT NOT NULL,
            status TEXT NOT NULL
        );
        INSERT INTO recognition_history
        (id, created_at, duration_seconds, raw_text, processing_mode, processed_text, final_text, status)
        VALUES
        ('legacy-row', '2026-01-02T03:04:05Z', 2.5, '旧记录', NULL, NULL, '旧记录', 'completed');
        """

        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }

    // MARK: - REPAIR_PLAN B5

    func testCreatedAtIndexExists() async {
        let exists = await store.hasIndex(named: "idx_history_created_at")
        XCTAssertTrue(exists, "created_at 索引应在建库时创建")
    }

    func testFreshStoreIsHealthy() async {
        let healthy = await store.isHealthy
        XCTAssertTrue(healthy)
    }

    func testOpenFailureIsUnhealthyAndSilentNoOp() async {
        // 指向一个不可能创建数据库的路径（不存在的目录）
        let badPath = "/nonexistent-\(UUID().uuidString)/h.db"
        let broken = HistoryStore(path: badPath)
        let healthy = await broken.isHealthy
        XCTAssertFalse(healthy)
        // 读写退化为 no-op 而不是崩溃
        let all = await broken.fetchAll()
        XCTAssertTrue(all.isEmpty)
    }

    func testPruneKeepsMostRecent() async {
        for i in 0..<10 {
            let record = HistoryRecord(
                id: "prune-\(i)",
                createdAt: Date(timeIntervalSince1970: Double(1000 + i)),
                durationSeconds: 1,
                rawText: "第\(i)条", processingMode: nil, processedText: nil,
                finalText: "第\(i)条", status: "completed", characterCount: 3
            )
            await store.insert(record)
        }
        await store.prune(keepingMostRecent: 3)
        let remaining = await store.fetchAll()
        XCTAssertEqual(remaining.count, 3)
        XCTAssertEqual(remaining.map(\.id), ["prune-9", "prune-8", "prune-7"])
    }

    func testPruneWithNonPositiveLimitIsNoOp() async {
        let record = HistoryRecord(
            id: "keep", createdAt: Date(), durationSeconds: 1,
            rawText: "在", processingMode: nil, processedText: nil,
            finalText: "在", status: "completed", characterCount: 1
        )
        await store.insert(record)
        await store.prune(keepingMostRecent: 0)
        let remaining = await store.fetchAll()
        XCTAssertEqual(remaining.count, 1)
    }
}
