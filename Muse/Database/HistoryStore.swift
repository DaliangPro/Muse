import Foundation
import SQLite3

extension Notification.Name {
    static let historyStoreDidChange = Notification.Name("Muse.historyStoreDidChange")
}

actor HistoryStore {

    static let baselineTypingCharactersPerMinute: Double = 50

    private var db: OpaquePointer?

    init(path: String? = nil) {
        let dbPath: String
        if let path {
            dbPath = path
        } else {
            AppPaths.ensureSupportDir()
            dbPath = AppPaths.historyDBPath
        }

        if sqlite3_open(dbPath, &db) == SQLITE_OK {
            let sql = """
            CREATE TABLE IF NOT EXISTS recognition_history (
                id TEXT PRIMARY KEY,
                created_at TEXT NOT NULL,
                duration_seconds REAL,
                raw_text TEXT NOT NULL,
                processing_mode TEXT,
                processed_text TEXT,
                final_text TEXT NOT NULL,
                status TEXT NOT NULL,
                character_count INTEGER,
                token_count INTEGER
            );
            """
            sqlite3_exec(db, sql, nil, nil, nil)

            // Migration: add character_count column if it doesn't exist (for existing databases)
            sqlite3_exec(db, "ALTER TABLE recognition_history ADD COLUMN character_count INTEGER;", nil, nil, nil)
            sqlite3_exec(db, "ALTER TABLE recognition_history ADD COLUMN token_count INTEGER;", nil, nil, nil)

            // REPAIR_PLAN B5：WAL 降低写阻塞；created_at 建索引，
            // 列表按时间倒序查询不再随数据量增长全表排序。
            // busy_timeout：与 LanguageAssetStore 连接并发写同库，撞锁等待而非立刻失败
            sqlite3_busy_timeout(db, 3000)
            sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
            sqlite3_exec(
                db,
                "CREATE INDEX IF NOT EXISTS idx_history_created_at ON recognition_history(created_at);",
                nil, nil, nil
            )
        } else {
            // REPAIR_PLAN B5：打开失败不再静默——之后所有读写都会变 no-op，
            // 必须留下可诊断的痕迹并允许上层感知
            let message = String(cString: sqlite3_errmsg(db))
            AppLogger.log("[HistoryStore] 数据库打开失败，历史记录将不可用: \(message)（路径: \(dbPath)）")
            DebugFileLogger.log("HistoryStore open FAILED: \(message)")
            sqlite3_close(db)
            db = nil
        }
    }

    // 关闭连接，防止每次 new HistoryStore() 泄漏 sqlite 连接（2026-06-24 修：GeneralSettingsTab/
    // AssetLibraryTab 每次重建都 new，泄漏连接的读锁会钉住 WAL 不 checkpoint → 越用越卡，对齐 LanguageAssetStore）
    deinit {
        sqlite3_close(db)
    }

    /// 数据库是否可用（打开失败时为 false，上层可据此提示用户）
    var isHealthy: Bool { db != nil }

    /// 测试与诊断用：指定名称的索引是否存在
    func hasIndex(named name: String) -> Bool {
        let sql = "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name=?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        SQL.bind(stmt, 1, name)
        return sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_int(stmt, 0) > 0
    }

    // MARK: - CRUD

    func insert(_ record: HistoryRecord) {
        let sql = """
        INSERT OR REPLACE INTO recognition_history
        (id, created_at, duration_seconds, raw_text, processing_mode, processed_text, final_text, status, character_count, token_count)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        let iso = ISO8601DateFormatter()
        SQL.bind(stmt, 1, record.id)
        SQL.bind(stmt, 2, iso.string(from: record.createdAt))
        sqlite3_bind_double(stmt, 3, record.durationSeconds)
        SQL.bind(stmt, 4, record.rawText)
        SQL.bindOptional(stmt, 5, record.processingMode)
        SQL.bindOptional(stmt, 6, record.processedText)
        SQL.bind(stmt, 7, record.finalText)
        SQL.bind(stmt, 8, record.status)
        if let count = record.characterCount {
            sqlite3_bind_int(stmt, 9, Int32(count))
        } else {
            sqlite3_bind_null(stmt, 9)
        }
        if let count = record.tokenCount {
            sqlite3_bind_int(stmt, 10, Int32(count))
        } else {
            sqlite3_bind_null(stmt, 10)
        }
        if stepSingleWrite(stmt) {
            postDidChangeNotification()
        }
    }

    func fetchAll(limit: Int? = nil, offset: Int = 0) -> [HistoryRecord] {
        let sql: String
        if let limit {
            sql = "SELECT * FROM recognition_history ORDER BY created_at DESC LIMIT \(limit) OFFSET \(offset);"
        } else {
            sql = "SELECT * FROM recognition_history ORDER BY created_at DESC;"
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var records: [HistoryRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            records.append(decodeRecord(from: stmt))
        }
        return records
    }

    func fetchRecent(limit: Int) -> [HistoryRecord] {
        fetchAll(limit: limit)
    }

    func fetchBetween(start: Date, end: Date) -> [HistoryRecord] {
        let sql = """
        SELECT * FROM recognition_history
        WHERE created_at >= ? AND created_at < ?
        ORDER BY created_at DESC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        let iso = ISO8601DateFormatter()
        SQL.bind(stmt, 1, iso.string(from: start))
        SQL.bind(stmt, 2, iso.string(from: end))

        var records: [HistoryRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            records.append(decodeRecord(from: stmt))
        }
        return records
    }

    func fetch(ids: [String]) -> [HistoryRecord] {
        guard !ids.isEmpty else { return [] }

        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let sql = """
        SELECT * FROM recognition_history
        WHERE id IN (\(placeholders))
        ORDER BY created_at DESC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        for (index, id) in ids.enumerated() {
            SQL.bind(stmt, Int32(index + 1), id)
        }

        var records: [HistoryRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            records.append(decodeRecord(from: stmt))
        }
        return records
    }

    func count(from start: Date? = nil, to end: Date? = nil) -> Int {
        var sql = "SELECT COUNT(*) FROM recognition_history"
        let iso = ISO8601DateFormatter()
        if let start, let end {
            sql += " WHERE created_at >= '\(iso.string(from: start))' AND created_at < '\(iso.string(from: end))'"
        }
        sql += ";"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    func delete(id: String) {
        let sql = "DELETE FROM recognition_history WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        SQL.bind(stmt, 1, id)
        if stepSingleWrite(stmt) {
            postDidChangeNotification()
        }
    }

    /// 历史保留上限的默认值（REPAIR_PLAN C1），可经 defaults 写
    /// tf_historyRetentionLimit 调整
    static let defaultRetentionLimit = 10000

    /// 只保留最近 limit 条，更早的删除（REPAIR_PLAN C1）
    func prune(keepingMostRecent limit: Int) {
        guard limit > 0 else { return }
        let sql = """
        DELETE FROM recognition_history WHERE id NOT IN (
            SELECT id FROM recognition_history ORDER BY created_at DESC LIMIT ?
        );
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        if stepSingleWrite(stmt), sqlite3_changes(db) > 0 {
            AppLogger.log("[HistoryStore] 已按上限 \(limit) 裁剪 \(sqlite3_changes(db)) 条旧记录")
            postDidChangeNotification()
        }
    }

    func deleteAll() {
        if sqlite3_exec(db, "DELETE FROM recognition_history;", nil, nil, nil) == SQLITE_OK {
            postDidChangeNotification()
        } else {
            AppLogger.log("[HistoryStore] 清空历史失败: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    // MARK: - Migration

    /// 为旧记录计算并保存文本统计指标。应在应用启动时调用一次。
    func migrateTextMetrics() async {
        let sql = """
        SELECT id, final_text, character_count, token_count FROM recognition_history
        WHERE character_count IS NULL OR token_count IS NULL;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        var updates: [(id: String, characterCount: Int?, tokenCount: Int?)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = SQL.column(stmt, 0)
            let text = SQL.column(stmt, 1)
            let characterCount = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? text.count : nil
            let tokenCount = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? EstimatedTokenCounter.count(in: text) : nil
            updates.append((id: id, characterCount: characterCount, tokenCount: tokenCount))
        }

        guard !updates.isEmpty else { return }

        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
        var stepFailed = false
        for update in updates {
            let updateSQL = """
            UPDATE recognition_history
            SET character_count = COALESCE(?, character_count),
                token_count = COALESCE(?, token_count)
            WHERE id = ?;
            """
            var updateStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, updateSQL, -1, &updateStmt, nil) == SQLITE_OK {
                if let count = update.characterCount {
                    sqlite3_bind_int(updateStmt, 1, Int32(count))
                } else {
                    sqlite3_bind_null(updateStmt, 1)
                }
                if let count = update.tokenCount {
                    sqlite3_bind_int(updateStmt, 2, Int32(count))
                } else {
                    sqlite3_bind_null(updateStmt, 2)
                }
                SQL.bind(updateStmt, 3, update.id)
                // REPAIR_PLAN J3：迁移事务不再忽略 step 结果——失败即回滚，下次启动重跑
                if sqlite3_step(updateStmt) != SQLITE_DONE {
                    stepFailed = true
                }
                sqlite3_finalize(updateStmt)
                if stepFailed { break }
            }
        }
        if stepFailed {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            AppLogger.log("[HistoryStore] 文本指标迁移失败已回滚: \(String(cString: sqlite3_errmsg(db)))")
            return
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        AppLogger.log("[HistoryStore] Migrated \(updates.count) records with text metrics")
    }

    func migrateCharacterCounts() async {
        await migrateTextMetrics()
    }

    // MARK: - Statistics

    struct Statistics: Sendable {
        let totalDuration: Double
        let totalCharacters: Int
        let totalTokens: Int
        let recordCount: Int
        let timeSavedSeconds: Double

        init(
            totalDuration: Double,
            totalCharacters: Int,
            totalTokens: Int = 0,
            recordCount: Int,
            timeSavedSeconds: Double
        ) {
            self.totalDuration = totalDuration
            self.totalCharacters = totalCharacters
            self.totalTokens = totalTokens
            self.recordCount = recordCount
            self.timeSavedSeconds = timeSavedSeconds
        }

        var averageSpeed: Double {
            guard totalDuration > 0 else { return 0 }
            return Double(totalTokens) / totalDuration * 60
        }
    }

    /// 获取全部记录的统计信息（使用数据库聚合查询，高效）
    /// 可提炼语料计数：与提炼管线输入口径一致(status=completed 且有正文)——
    /// 语料池卡片显示这个数才「准确」，全表 COUNT 会把失败/中断记录也算进去（2026-07）
    func extractableRecordCount(since: Date? = nil) -> Int {
        var sql = "SELECT COUNT(*) FROM recognition_history WHERE status = 'completed' AND TRIM(final_text) != ''"
        if since != nil {
            sql += " AND created_at >= ?"
        }
        sql += ";"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }

        if let since {
            SQL.bind(stmt, 1, ISO8601DateFormatter().string(from: since))
        }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    func getStatistics() async -> Statistics {
        // Only sum duration for rows that have token_count, so averageSpeed
        // is accurate even if some legacy rows haven't been migrated yet.
        let sql = """
        SELECT
            COALESCE(SUM(CASE WHEN token_count IS NOT NULL THEN duration_seconds ELSE 0 END), 0),
            COALESCE(SUM(character_count), 0),
            COALESCE(SUM(token_count), 0),
            COUNT(*),
            COALESCE(SUM(
                CASE
                    WHEN character_count IS NOT NULL THEN
                        MAX(
                            (CAST(character_count AS REAL) / \(Self.baselineTypingCharactersPerMinute) * 60.0)
                            - COALESCE(duration_seconds, 0),
                            0
                        )
                    ELSE 0
                END
            ), 0)
        FROM recognition_history;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return Statistics(totalDuration: 0, totalCharacters: 0, recordCount: 0, timeSavedSeconds: 0)
        }
        defer { sqlite3_finalize(stmt) }

        if sqlite3_step(stmt) == SQLITE_ROW {
            let duration = sqlite3_column_double(stmt, 0)
            let chars = Int(sqlite3_column_int(stmt, 1))
            let tokens = Int(sqlite3_column_int(stmt, 2))
            let count = Int(sqlite3_column_int(stmt, 3))
            let timeSaved = sqlite3_column_double(stmt, 4)
            return Statistics(
                totalDuration: duration,
                totalCharacters: chars,
                totalTokens: tokens,
                recordCount: count,
                timeSavedSeconds: timeSaved
            )
        }
        return Statistics(totalDuration: 0, totalCharacters: 0, recordCount: 0, timeSavedSeconds: 0)
    }

    // MARK: - SQLite Helpers

    private func decodeRecord(from stmt: OpaquePointer?) -> HistoryRecord {
        let iso = ISO8601DateFormatter()
        return HistoryRecord(
            id: SQL.column(stmt, 0),
            createdAt: iso.date(from: SQL.column(stmt, 1)) ?? Date(),
            durationSeconds: sqlite3_column_double(stmt, 2),
            rawText: SQL.column(stmt, 3),
            processingMode: SQL.optionalColumn(stmt, 4),
            processedText: SQL.optionalColumn(stmt, 5),
            finalText: SQL.column(stmt, 6),
            status: SQL.column(stmt, 7),
            characterCount: sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 8)),
            tokenCount: sqlite3_column_type(stmt, 9) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 9))
        )
    }

    /// REPAIR_PLAN J3：单行写不再静默失败——busy_timeout(3s) 超时仍 BUSY、磁盘满等
    /// step 失败必须留痕，否则识别记录无声丢失、上层与用户均无感知。
    /// 日志记 sqlite3_sql 模板（含 ? 占位符、不含绑定值），不泄漏用户文本。
    @discardableResult
    private func stepSingleWrite(_ stmt: OpaquePointer?) -> Bool {
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            let sql = sqlite3_sql(stmt).map { String(cString: $0) } ?? "unknown"
            AppLogger.log("[HistoryStore] 单行写失败: \(String(cString: sqlite3_errmsg(db))) — \(sql.prefix(80))")
            return false
        }
        return true
    }

    private func postDidChangeNotification() {
        Task { @MainActor in
            NotificationCenter.default.post(name: .historyStoreDidChange, object: nil)
        }
    }
}
