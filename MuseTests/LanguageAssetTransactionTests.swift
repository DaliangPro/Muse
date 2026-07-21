import Foundation
import SQLite3
@testable import Muse
import XCTest

final class LanguageAssetTransactionTests: XCTestCase {
    private var store: LanguageAssetStore!
    private var testPath: String!
    private var notificationCenter: NotificationCenter!

    override func setUp() async throws {
        testPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("muse-asset-transaction-\(UUID().uuidString).db")
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

    func testCandidateFirstSaveUsesCandidateIDAndCommitsStatusAssetAndLog() async throws {
        let candidate = makeCandidate(id: "candidate-first-save")
        try await store.saveCandidatesOrThrow([candidate])

        let savedAsset = try await store.saveCandidateAsAsset(id: candidate.id)
        let asset = try XCTUnwrap(savedAsset)
        let assetIDs = await store.fetchAll().map(\.id)
        let savedCandidateIDs = await store.fetchCandidates(status: .saved).map(\.id)

        XCTAssertEqual(asset.id, candidate.id)
        XCTAssertEqual(asset.content, candidate.content)
        XCTAssertEqual(assetIDs, [candidate.id])
        XCTAssertEqual(savedCandidateIDs, [candidate.id])
        XCTAssertEqual(actionCount(.candidateSaved, assetID: candidate.id), 1)
    }

    func testCandidateRetryReturnsSameAssetWithoutDuplicateAssetOrLog() async throws {
        let candidate = makeCandidate(id: "candidate-idempotent")
        try await store.saveCandidatesOrThrow([candidate])

        let firstSave = try await store.saveCandidateAsAsset(id: candidate.id)
        let first = try XCTUnwrap(firstSave)
        let secondSave = try await store.saveCandidateAsAsset(id: candidate.id)
        let second = try XCTUnwrap(secondSave)
        let assetIDs = await store.fetchAll().map(\.id)

        XCTAssertEqual(first.id, candidate.id)
        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(second.createdAt, first.createdAt)
        XCTAssertEqual(assetIDs, [candidate.id])
        XCTAssertEqual(actionCount(.candidateSaved, assetID: candidate.id), 1)
    }

    func testCandidateStatusFailureRollsBackInsertedAssetAndActionLog() async throws {
        let candidate = makeCandidate(id: "candidate-rollback")
        try await store.saveCandidatesOrThrow([candidate])
        try executeSQL("""
        CREATE TRIGGER force_candidate_status_failure
        BEFORE UPDATE OF status ON language_asset_candidate
        WHEN NEW.id = 'candidate-rollback' AND NEW.status = 'saved'
        BEGIN
            SELECT RAISE(ABORT, 'forced candidate update failure');
        END;
        """)

        let error = await captureError {
            _ = try await self.store.saveCandidateAsAsset(id: candidate.id)
        }

        assertSQLiteError(error, contains: "forced candidate update failure")
        let assets = await store.fetchAll()
        let pendingCandidateIDs = await store.fetchCandidates(status: .pending).map(\.id)
        let savedCandidates = await store.fetchCandidates(status: .saved)
        XCTAssertTrue(assets.isEmpty)
        XCTAssertEqual(pendingCandidateIDs, [candidate.id])
        XCTAssertTrue(savedCandidates.isEmpty)
        XCTAssertEqual(actionCount(.candidateSaved, assetID: candidate.id), 0)
    }

    func testEditedCandidateAssetStatusAndLogCommitTogether() async throws {
        let original = makeCandidate(id: "candidate-edited")
        try await store.saveCandidatesOrThrow([original])
        let edited = makeCandidate(
            id: original.id,
            title: "编辑后的标题",
            content: "编辑后的正式资产正文",
            status: .pending
        )
        try executeSQL("""
        CREATE TRIGGER force_edited_asset_failure
        BEFORE INSERT ON language_asset
        WHEN NEW.id = 'candidate-edited'
        BEGIN
            SELECT RAISE(ABORT, 'forced edited asset failure');
        END;
        """)

        let error = await captureError {
            _ = try await self.store.saveEditedCandidateAsAsset(edited)
        }

        assertSQLiteError(error, contains: "forced edited asset failure")
        let rolledBackCandidateTitle = await store.fetchCandidates(status: .pending).first?.title
        let rolledBackAssets = await store.fetchAll()
        XCTAssertEqual(
            rolledBackCandidateTitle,
            original.title,
            "资产插入失败时，编辑后的候选也必须回滚"
        )
        XCTAssertTrue(rolledBackAssets.isEmpty)
        XCTAssertEqual(actionCount(.candidateSaved, assetID: original.id), 0)

        try executeSQL("DROP TRIGGER force_edited_asset_failure;")
        let savedAsset = try await store.saveEditedCandidateAsAsset(edited)
        let asset = try XCTUnwrap(savedAsset)
        let savedCandidateTitle = await store.fetchCandidates(status: .saved).first?.title

        XCTAssertEqual(asset.id, original.id)
        XCTAssertEqual(asset.title, edited.title)
        XCTAssertEqual(asset.content, edited.content)
        XCTAssertEqual(savedCandidateTitle, edited.title)
        XCTAssertEqual(actionCount(.candidateSaved, assetID: original.id), 1)
    }

    func testNotificationIsSentOnceOnlyAfterSuccessfulCandidateCommit() async throws {
        let candidate = makeCandidate(id: "candidate-notification")
        let seedNotification = expectation(description: "seed candidate committed")
        let seedToken = notificationCenter.addObserver(
            forName: .languageAssetStoreDidChange,
            object: nil,
            queue: .main
        ) { _ in
            seedNotification.fulfill()
        }
        try await store.saveCandidatesOrThrow([candidate])
        await fulfillment(of: [seedNotification], timeout: 1)
        notificationCenter.removeObserver(seedToken)

        try executeSQL("""
        CREATE TRIGGER force_notification_rollback
        BEFORE UPDATE OF status ON language_asset_candidate
        WHEN NEW.id = 'candidate-notification' AND NEW.status = 'saved'
        BEGIN
            SELECT RAISE(ABORT, 'forced notification rollback');
        END;
        """)
        let failedNotification = expectation(description: "rolled back transaction sends no notification")
        failedNotification.isInverted = true
        let failedToken = notificationCenter.addObserver(
            forName: .languageAssetStoreDidChange,
            object: nil,
            queue: .main
        ) { _ in
            failedNotification.fulfill()
        }

        _ = await captureError {
            _ = try await self.store.saveCandidateAsAsset(id: candidate.id)
        }
        await fulfillment(of: [failedNotification], timeout: 0.15)
        notificationCenter.removeObserver(failedToken)

        try executeSQL("DROP TRIGGER force_notification_rollback;")
        let successNotification = expectation(description: "committed transaction sends one notification")
        successNotification.assertForOverFulfill = true
        let successToken = notificationCenter.addObserver(
            forName: .languageAssetStoreDidChange,
            object: nil,
            queue: .main
        ) { _ in
            successNotification.fulfill()
        }

        _ = try await store.saveCandidateAsAsset(id: candidate.id)
        await fulfillment(of: [successNotification], timeout: 1)
        notificationCenter.removeObserver(successToken)

        let assetIDs = await store.fetchAll().map(\.id)
        let savedCandidateIDs = await store.fetchCandidates(status: .saved).map(\.id)
        XCTAssertEqual(assetIDs, [candidate.id])
        XCTAssertEqual(savedCandidateIDs, [candidate.id])
    }

    func testCommitFailureIsPropagatedAndRollsBackCandidateTransaction() async throws {
        let candidate = makeCandidate(id: "candidate-commit-failure")
        try await store.saveCandidatesOrThrow([candidate])
        try executeSQL("""
        CREATE TABLE deferred_parent (
            id TEXT PRIMARY KEY
        );
        CREATE TABLE deferred_child (
            parent_id TEXT,
            FOREIGN KEY(parent_id) REFERENCES deferred_parent(id)
                DEFERRABLE INITIALLY DEFERRED
        );
        CREATE TRIGGER force_candidate_commit_failure
        AFTER INSERT ON language_asset
        WHEN NEW.id = 'candidate-commit-failure'
        BEGIN
            INSERT INTO deferred_child(parent_id) VALUES ('missing-parent');
        END;
        """)

        let error = await captureError {
            _ = try await self.store.saveCandidateAsAsset(id: candidate.id)
        }

        assertSQLiteError(error, contains: "FOREIGN KEY constraint failed")
        let assets = await store.fetchAll()
        let pendingCandidateIDs = await store.fetchCandidates(status: .pending).map(\.id)
        XCTAssertTrue(assets.isEmpty)
        XCTAssertEqual(pendingCandidateIDs, [candidate.id])
        XCTAssertEqual(actionCount(.candidateSaved, assetID: candidate.id), 0)
        XCTAssertEqual(scalarInt("SELECT COUNT(*) FROM deferred_child;"), 0)
    }

    private func makeCandidate(
        id: String,
        title: String = "事务候选",
        content: String = "候选正文需要原子提交。",
        status: LanguageAssetCandidateStatus = .pending
    ) -> LanguageAssetCandidateRecord {
        LanguageAssetCandidateRecord(
            id: id,
            createdAt: Date(timeIntervalSince1970: 1_720_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_720_000_001),
            assetType: .viewpoint,
            grade: .a,
            title: title,
            content: content,
            summary: "事务摘要",
            reason: "必须避免部分提交",
            scenes: ["复盘"],
            audiences: ["创作者"],
            ruleHit: "事务规则",
            sourceRecordIDs: ["source-1"],
            sourceRecordCount: 1,
            extractionJobID: "job-transaction",
            status: status
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

    private func actionCount(
        _ actionType: LanguageAssetActionType,
        assetID: String? = nil
    ) -> Int {
        let assetPredicate = assetID.map { "asset_id = '\($0)'" } ?? "asset_id IS NULL"
        return scalarInt("""
        SELECT COUNT(*)
        FROM language_asset_action_log
        WHERE action_type = '\(actionType.rawValue)' AND \(assetPredicate);
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
            throw TestDatabaseError.sqlite("无法打开测试数据库")
        }
        defer { sqlite3_close(db) }

        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw TestDatabaseError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }
}

private enum TestDatabaseError: Error {
    case sqlite(String)
}
