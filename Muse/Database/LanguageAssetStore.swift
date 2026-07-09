import Foundation
import SQLite3

extension Notification.Name {
    static let languageAssetStoreDidChange = Notification.Name("Muse.languageAssetStoreDidChange")
}

enum LanguageAssetStoreError: Error, LocalizedError {
    case databaseUnavailable
    case sqlite(String)

    var errorDescription: String? {
        switch self {
        case .databaseUnavailable:
            return L("资产数据库不可用", "Asset database unavailable")
        case .sqlite(let message):
            return message
        }
    }
}

actor LanguageAssetStore {
    /// ISO8601 编解码器复用（J15：原先查询/写入每次新分配，行级 decode 循环内尤其浪费）
    private let iso = ISO8601DateFormatter()
    private let codec = LanguageAssetStoreCodec()

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
            // 与识别主链路（HistoryStore 连接）并发读写同一个库文件：
            // WAL 允许读写并行，busy_timeout 让撞锁的写入等待而非立刻失败被静默吞掉
            sqlite3_busy_timeout(db, 3000)
            sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
            LanguageAssetStoreSchema.createTables(in: db)
            LanguageAssetStoreSchema.seedBuiltInRecipes(in: db)
        } else {
            AppLogger.log("[LanguageAssetStore] 打开数据库失败: \(dbPath)，资产读写将不可用")
            sqlite3_close(db)
            db = nil
        }
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Job

    func insert(job: AssetExtractionJob) {
        let sql = """
        INSERT OR REPLACE INTO asset_extraction_job
        (id, created_at, started_at, finished_at, range_type, range_payload, source_record_count, status, summary, error_message)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        SQL.bind(stmt, 1, job.id)
        SQL.bind(stmt, 2, iso.string(from: job.createdAt))
        SQL.bindOptional(stmt, 3, job.startedAt.map { iso.string(from: $0) })
        SQL.bindOptional(stmt, 4, job.finishedAt.map { iso.string(from: $0) })
        SQL.bind(stmt, 5, job.rangeType.rawValue)
        SQL.bindOptional(stmt, 6, job.rangePayload)
        sqlite3_bind_int(stmt, 7, Int32(job.sourceRecordCount))
        SQL.bind(stmt, 8, job.status.rawValue)
        SQL.bindOptional(stmt, 9, job.summary)
        SQL.bindOptional(stmt, 10, job.errorMessage)

        if stepSingleWrite(stmt) {
            postDidChangeNotification()
        }
    }

    func latestJob() -> AssetExtractionJob? {
        let sql = """
        SELECT id, created_at, started_at, finished_at, range_type, range_payload, source_record_count, status, summary, error_message
        FROM asset_extraction_job
        ORDER BY created_at DESC
        LIMIT 1;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return codec.decodeJob(from: stmt)
    }

    // MARK: - Recipe Architecture

    func saveRecipesOrThrow(_ recipes: [ExtractionRecipe]) throws {
        guard !recipes.isEmpty else { return }
        let db = try requireDB()

        try exec("BEGIN TRANSACTION;", in: db)
        var committed = false
        defer {
            if !committed {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            }
        }

        let sql = """
        INSERT OR REPLACE INTO extraction_recipe
        (id, created_at, updated_at, name, description, goal_prompt, output_kind, processing_strategy, source_policy, output_schema, quality_rules, save_rule, ignore_rule, destination, is_built_in, status)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """

        for recipe in recipes {
            var stmt: OpaquePointer?
            try prepare(sql, in: db, statement: &stmt)
            defer { sqlite3_finalize(stmt) }

            SQL.bind(stmt, 1, recipe.id)
            SQL.bind(stmt, 2, iso.string(from: recipe.createdAt))
            SQL.bind(stmt, 3, iso.string(from: recipe.updatedAt))
            SQL.bind(stmt, 4, recipe.name)
            SQL.bind(stmt, 5, recipe.recipeDescription)
            SQL.bind(stmt, 6, recipe.goalPrompt)
            SQL.bind(stmt, 7, recipe.outputKind.rawValue)
            SQL.bind(stmt, 8, recipe.processingStrategy.rawValue)
            SQL.bind(stmt, 9, recipe.sourcePolicy.rawValue)
            SQL.bind(stmt, 10, recipe.outputSchema)
            SQL.bind(stmt, 11, recipe.qualityRules)
            SQL.bind(stmt, 12, recipe.saveRule)
            SQL.bind(stmt, 13, recipe.ignoreRule)
            SQL.bind(stmt, 14, recipe.destination.rawValue)
            sqlite3_bind_int(stmt, 15, recipe.isBuiltIn ? 1 : 0)
            SQL.bind(stmt, 16, recipe.status.rawValue)
            try stepDone(stmt, in: db)
        }

        try exec("COMMIT;", in: db)
        committed = true
        postDidChangeNotification()
    }

    func fetchRecipes(status: ExtractionRecipeStatus = .active) -> [ExtractionRecipe] {
        let sql = """
        SELECT id, created_at, updated_at, name, description, goal_prompt, output_kind, processing_strategy, source_policy, output_schema, quality_rules, destination, is_built_in, status, save_rule, ignore_rule
        FROM extraction_recipe
        WHERE status = ?
        ORDER BY is_built_in DESC, updated_at DESC, created_at ASC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        SQL.bind(stmt, 1, status.rawValue)

        var recipes: [ExtractionRecipe] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let recipe = codec.decodeRecipe(from: stmt) {
                recipes.append(recipe)
            }
        }
        return recipes
    }

    func fetchRecipe(id: String) -> ExtractionRecipe? {
        let sql = """
        SELECT id, created_at, updated_at, name, description, goal_prompt, output_kind, processing_strategy, source_policy, output_schema, quality_rules, destination, is_built_in, status, save_rule, ignore_rule
        FROM extraction_recipe
        WHERE id = ?
        LIMIT 1;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        SQL.bind(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return codec.decodeRecipe(from: stmt)
    }

    func archiveRecipe(id: String) {
        // 2026-07 大梁老师：内置/自建一视同仁都可停用(seed 是 INSERT OR IGNORE,停用不会复活);
        // 配套「已停用」恢复区防止内置标准文本丢失
        setRecipeStatus(id: id, status: .archived)
    }

    func restoreRecipe(id: String) {
        setRecipeStatus(id: id, status: .active)
    }

    private func setRecipeStatus(id: String, status: ExtractionRecipeStatus) {
        let sql = """
        UPDATE extraction_recipe
        SET status = ?, updated_at = ?
        WHERE id = ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        SQL.bind(stmt, 1, status.rawValue)
        SQL.bind(stmt, 2, iso.string(from: Date()))
        SQL.bind(stmt, 3, id)

        if stepSingleWrite(stmt) {
            postDidChangeNotification()
        }
    }

    func insert(run: ExtractionRun) {
        let sql = """
        INSERT OR REPLACE INTO extraction_run
        (id, recipe_id, recipe_name, created_at, started_at, finished_at, range_type, range_payload, source_record_count, status, result_count, summary, error_message)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        SQL.bind(stmt, 1, run.id)
        SQL.bind(stmt, 2, run.recipeID)
        SQL.bind(stmt, 3, run.recipeName)
        SQL.bind(stmt, 4, iso.string(from: run.createdAt))
        SQL.bindOptional(stmt, 5, run.startedAt.map { iso.string(from: $0) })
        SQL.bindOptional(stmt, 6, run.finishedAt.map { iso.string(from: $0) })
        SQL.bind(stmt, 7, run.rangeType.rawValue)
        SQL.bindOptional(stmt, 8, run.rangePayload)
        sqlite3_bind_int(stmt, 9, Int32(run.sourceRecordCount))
        SQL.bind(stmt, 10, run.status.rawValue)
        sqlite3_bind_int(stmt, 11, Int32(run.resultCount))
        SQL.bindOptional(stmt, 12, run.summary)
        SQL.bindOptional(stmt, 13, run.errorMessage)

        if stepSingleWrite(stmt) {
            postDidChangeNotification()
        }
    }

    /// 删除一条提炼批次记录（仅删 run 行；其产物独立存在于待确认/资产库不受影响）
    func deleteRun(id: String) {
        let sql = "DELETE FROM extraction_run WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        SQL.bind(stmt, 1, id)
        if stepSingleWrite(stmt) {
            postDidChangeNotification()
        }
    }

    /// 最近提炼批次列表（提炼页历史 + 待确认页分组头用，2026-07 重构批三）
    func fetchRuns(limit: Int = 20) -> [ExtractionRun] {
        let sql = """
        SELECT id, recipe_id, recipe_name, created_at, started_at, finished_at, range_type, range_payload, source_record_count, status, result_count, summary, error_message
        FROM extraction_run
        ORDER BY created_at DESC
        LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(limit))

        var runs: [ExtractionRun] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let run = codec.decodeRun(from: stmt) {
                runs.append(run)
            }
        }
        return runs
    }

    func latestRun() -> ExtractionRun? {
        let sql = """
        SELECT id, recipe_id, recipe_name, created_at, started_at, finished_at, range_type, range_payload, source_record_count, status, result_count, summary, error_message
        FROM extraction_run
        ORDER BY created_at DESC
        LIMIT 1;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return codec.decodeRun(from: stmt)
    }

    func saveResultsOrThrow(_ results: [ExtractionResult]) throws {
        guard !results.isEmpty else { return }
        let db = try requireDB()

        try exec("BEGIN TRANSACTION;", in: db)
        var committed = false
        defer {
            if !committed {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            }
        }

        let sql = """
        INSERT OR REPLACE INTO extraction_result
        (id, run_id, recipe_id, created_at, updated_at, output_kind, title, content, summary, payload_json, source_record_ids_json, source_record_count, status, score, review_reason, is_favorite)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        for result in results {
            var stmt: OpaquePointer?
            try prepare(sql, in: db, statement: &stmt)
            defer { sqlite3_finalize(stmt) }

            SQL.bind(stmt, 1, result.id)
            SQL.bind(stmt, 2, result.runID)
            SQL.bind(stmt, 3, result.recipeID)
            SQL.bind(stmt, 4, iso.string(from: result.createdAt))
            SQL.bind(stmt, 5, iso.string(from: result.updatedAt))
            SQL.bind(stmt, 6, result.outputKind.rawValue)
            SQL.bind(stmt, 7, result.title)
            SQL.bind(stmt, 8, result.content)
            SQL.bindOptional(stmt, 9, result.summary)
            SQL.bind(stmt, 10, result.payloadJSON)
            SQL.bind(stmt, 11, codec.encodeJSONString(result.sourceRecordIDs, encoder: encoder))
            sqlite3_bind_int(stmt, 12, Int32(result.sourceRecordCount))
            SQL.bind(stmt, 13, result.status.rawValue)
            if let score = result.score {
                sqlite3_bind_double(stmt, 14, score)
            } else {
                sqlite3_bind_null(stmt, 14)
            }
            SQL.bindOptional(stmt, 15, result.reviewReason)
            sqlite3_bind_int(stmt, 16, result.isFavorite ? 1 : 0)
            try stepDone(stmt, in: db)
        }

        try exec("COMMIT;", in: db)
        committed = true
        postDidChangeNotification()
    }

    func fetchResults(
        runID: String? = nil,
        status: ExtractionResultStatus = .active
    ) -> [ExtractionResult] {
        let sql: String
        if runID == nil {
            sql = """
            SELECT id, run_id, recipe_id, created_at, updated_at, output_kind, title, content, summary, payload_json, source_record_ids_json, source_record_count, status, score, review_reason, is_favorite
            FROM extraction_result
            WHERE status = ?
            ORDER BY created_at DESC;
            """
        } else {
            sql = """
            SELECT id, run_id, recipe_id, created_at, updated_at, output_kind, title, content, summary, payload_json, source_record_ids_json, source_record_count, status, score, review_reason, is_favorite
            FROM extraction_result
            WHERE status = ? AND run_id = ?
            ORDER BY created_at DESC;
            """
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        SQL.bind(stmt, 1, status.rawValue)
        if let runID {
            SQL.bind(stmt, 2, runID)
        }

        var results: [ExtractionResult] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let result = codec.decodeResult(from: stmt) {
                results.append(result)
            }
        }
        return results
    }

    /// 待确认产物的拍板：入库(saved)或抛弃(discarded)。2026-07 重构统一处置入口
    func updateResultStatus(id: String, to status: ExtractionResultStatus) {
        let sql = """
        UPDATE extraction_result
        SET status = ?, updated_at = ?
        WHERE id = ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        SQL.bind(stmt, 1, status.rawValue)
        SQL.bind(stmt, 2, iso.string(from: Date()))
        SQL.bind(stmt, 3, id)

        if stepSingleWrite(stmt) {
            postDidChangeNotification()
        }
    }

    func setResultFavorite(id: String, isFavorite: Bool) {
        let sql = """
        UPDATE extraction_result
        SET is_favorite = ?, updated_at = ?
        WHERE id = ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, isFavorite ? 1 : 0)
        SQL.bind(stmt, 2, iso.string(from: Date()))
        SQL.bind(stmt, 3, id)

        if stepSingleWrite(stmt) {
            postDidChangeNotification()
        }
    }

    /// 各状态产物计数（待确认角标等）
    func countResults(status: ExtractionResultStatus) -> Int {
        let sql = "SELECT COUNT(*) FROM extraction_result WHERE status = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }

        SQL.bind(stmt, 1, status.rawValue)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    func logAction(
        assetID: String? = nil,
        actionType: LanguageAssetActionType,
        detail: String? = nil
    ) {
        let sql = """
        INSERT INTO language_asset_action_log
        (id, created_at, asset_id, action_type, detail)
        VALUES (?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        let log = LanguageAssetActionLog(
            id: UUID().uuidString,
            createdAt: Date(),
            assetID: assetID,
            actionType: actionType,
            detail: detail
        )
        SQL.bind(stmt, 1, log.id)
        SQL.bind(stmt, 2, iso.string(from: log.createdAt))
        SQL.bindOptional(stmt, 3, log.assetID)
        SQL.bind(stmt, 4, log.actionType.rawValue)
        SQL.bindOptional(stmt, 5, log.detail)

        stepSingleWrite(stmt)
    }

    // MARK: - Asset

    func saveAssets(_ assets: [LanguageAsset]) {
        do {
            try saveAssetsOrThrow(assets)
        } catch {
            AppLogger.log("[LanguageAssetStore] 保存资产失败: \(error.localizedDescription)")
        }
    }

    func saveAssetsOrThrow(_ assets: [LanguageAsset]) throws {
        guard !assets.isEmpty else { return }
        let db = try requireDB()

        try exec("BEGIN TRANSACTION;", in: db)
        var committed = false
        defer {
            if !committed {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            }
        }

        let sql = """
        INSERT OR REPLACE INTO language_asset
        (id, created_at, updated_at, asset_type, grade, title, content, summary, reason, scenes_json, audiences_json, rule_hit, keywords_json, source_record_ids_json, source_record_count, extraction_job_id, is_favorite, status)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        for asset in assets {
            var stmt: OpaquePointer?
            try prepare(sql, in: db, statement: &stmt)
            defer { sqlite3_finalize(stmt) }

            SQL.bind(stmt, 1, asset.id)
            SQL.bind(stmt, 2, iso.string(from: asset.createdAt))
            SQL.bind(stmt, 3, iso.string(from: asset.updatedAt))
            SQL.bind(stmt, 4, asset.assetType.rawValue)
            SQL.bindOptional(stmt, 5, asset.grade?.rawValue)
            SQL.bindOptional(stmt, 6, asset.title)
            SQL.bind(stmt, 7, asset.content)
            SQL.bindOptional(stmt, 8, asset.summary)
            SQL.bindOptional(stmt, 9, asset.reason)
            SQL.bind(stmt, 10, codec.encodeJSONString(asset.scenes, encoder: encoder))
            SQL.bind(stmt, 11, codec.encodeJSONString(asset.audiences, encoder: encoder))
            SQL.bindOptional(stmt, 12, asset.ruleHit)
            SQL.bind(stmt, 13, codec.encodeJSONString(asset.keywords, encoder: encoder))
            SQL.bind(stmt, 14, codec.encodeJSONString(asset.sourceRecordIDs, encoder: encoder))
            sqlite3_bind_int(stmt, 15, Int32(asset.sourceRecordCount))
            SQL.bindOptional(stmt, 16, asset.extractionJobID)
            sqlite3_bind_int(stmt, 17, asset.isFavorite ? 1 : 0)
            SQL.bind(stmt, 18, asset.status.rawValue)

            try stepDone(stmt, in: db)
        }

        try exec("COMMIT;", in: db)
        committed = true
        postDidChangeNotification()
    }

    func fetchAll(status: LanguageAssetStatus = .active) -> [LanguageAsset] {
        let sql = """
        SELECT id, created_at, updated_at, asset_type, grade, title, content, summary, reason, scenes_json, audiences_json, rule_hit, keywords_json, source_record_ids_json, source_record_count, extraction_job_id, is_favorite, status
        FROM language_asset
        WHERE status = ?
        ORDER BY created_at DESC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        SQL.bind(stmt, 1, status.rawValue)

        var assets: [LanguageAsset] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let asset = codec.decodeAsset(from: stmt) {
                assets.append(asset)
            }
        }
        return assets
    }

    func setFavorite(id: String, isFavorite: Bool) {
        let sql = """
        UPDATE language_asset
        SET is_favorite = ?, updated_at = ?
        WHERE id = ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, isFavorite ? 1 : 0)
        SQL.bind(stmt, 2, iso.string(from: Date()))
        SQL.bind(stmt, 3, id)

        if stepSingleWrite(stmt) {
            postDidChangeNotification()
        }
    }

    func softDelete(id: String) {
        let sql = """
        UPDATE language_asset
        SET status = ?, updated_at = ?
        WHERE id = ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        SQL.bind(stmt, 1, LanguageAssetStatus.deleted.rawValue)
        SQL.bind(stmt, 2, iso.string(from: Date()))
        SQL.bind(stmt, 3, id)

        if stepSingleWrite(stmt) {
            postDidChangeNotification()
        }
    }

    // MARK: - Candidate

    func saveCandidates(_ candidates: [LanguageAssetCandidateRecord]) {
        do {
            try saveCandidatesOrThrow(candidates)
        } catch {
            AppLogger.log("[LanguageAssetStore] 保存候选资产失败: \(error.localizedDescription)")
        }
    }

    func saveCandidatesOrThrow(_ candidates: [LanguageAssetCandidateRecord]) throws {
        guard !candidates.isEmpty else { return }
        let db = try requireDB()

        try exec("BEGIN TRANSACTION;", in: db)
        var committed = false
        defer {
            if !committed {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            }
        }

        let sql = """
        INSERT OR REPLACE INTO language_asset_candidate
        (id, created_at, updated_at, asset_type, grade, title, content, summary, reason, scenes_json, audiences_json, rule_hit, source_record_ids_json, source_record_count, extraction_job_id, status)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        for candidate in candidates {
            var stmt: OpaquePointer?
            try prepare(sql, in: db, statement: &stmt)
            defer { sqlite3_finalize(stmt) }

            SQL.bind(stmt, 1, candidate.id)
            SQL.bind(stmt, 2, iso.string(from: candidate.createdAt))
            SQL.bind(stmt, 3, iso.string(from: candidate.updatedAt))
            SQL.bind(stmt, 4, candidate.assetType.rawValue)
            SQL.bind(stmt, 5, candidate.grade.rawValue)
            SQL.bind(stmt, 6, candidate.title)
            SQL.bind(stmt, 7, candidate.content)
            SQL.bindOptional(stmt, 8, candidate.summary)
            SQL.bind(stmt, 9, candidate.reason)
            SQL.bind(stmt, 10, codec.encodeJSONString(candidate.scenes, encoder: encoder))
            SQL.bind(stmt, 11, codec.encodeJSONString(candidate.audiences, encoder: encoder))
            SQL.bindOptional(stmt, 12, candidate.ruleHit)
            SQL.bind(stmt, 13, codec.encodeJSONString(candidate.sourceRecordIDs, encoder: encoder))
            sqlite3_bind_int(stmt, 14, Int32(candidate.sourceRecordCount))
            SQL.bindOptional(stmt, 15, candidate.extractionJobID)
            SQL.bind(stmt, 16, candidate.status.rawValue)

            try stepDone(stmt, in: db)
        }

        try exec("COMMIT;", in: db)
        committed = true
        postDidChangeNotification()
    }

    func fetchCandidates(status: LanguageAssetCandidateStatus = .pending) -> [LanguageAssetCandidateRecord] {
        let sql = """
        SELECT id, created_at, updated_at, asset_type, grade, title, content, summary, reason, scenes_json, audiences_json, rule_hit, source_record_ids_json, source_record_count, extraction_job_id, status
        FROM language_asset_candidate
        WHERE status = ?
        ORDER BY created_at DESC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        SQL.bind(stmt, 1, status.rawValue)

        var candidates: [LanguageAssetCandidateRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let candidate = codec.decodeCandidate(from: stmt) {
                candidates.append(candidate)
            }
        }
        return candidates
    }

    @discardableResult
    func clearCandidates(status: LanguageAssetCandidateStatus = .pending) -> Int {
        do {
            return try clearCandidatesOrThrow(status: status)
        } catch {
            AppLogger.log("[LanguageAssetStore] 清空候选失败 \(status.rawValue): \(error.localizedDescription)")
            return 0
        }
    }

    @discardableResult
    func clearCandidatesOrThrow(status: LanguageAssetCandidateStatus = .pending) throws -> Int {
        let db = try requireDB()
        let sql = "DELETE FROM language_asset_candidate WHERE status = ?;"
        var stmt: OpaquePointer?
        try prepare(sql, in: db, statement: &stmt)
        defer { sqlite3_finalize(stmt) }

        SQL.bind(stmt, 1, status.rawValue)

        try stepDone(stmt, in: db)
        let deletedCount = Int(sqlite3_changes(db))
        if deletedCount > 0 {
            postDidChangeNotification()
        }
        return deletedCount
    }

    func saveCandidateAsAsset(id: String) -> LanguageAsset? {
        guard let candidate = fetchCandidate(id: id) else { return nil }
        let now = Date()
        let asset = LanguageAsset(
            id: UUID().uuidString,
            createdAt: now,
            updatedAt: now,
            assetType: candidate.assetType,
            grade: candidate.grade,
            title: candidate.title,
            content: candidate.content,
            summary: candidate.summary,
            reason: candidate.reason,
            scenes: candidate.scenes,
            audiences: candidate.audiences,
            ruleHit: candidate.ruleHit,
            keywords: codec.unique(candidate.scenes + candidate.audiences),
            sourceRecordIDs: candidate.sourceRecordIDs,
            sourceRecordCount: candidate.sourceRecordCount,
            extractionJobID: candidate.extractionJobID,
            isFavorite: false,
            status: .active
        )
        do {
            try saveAssetsOrThrow([asset])
            try updateCandidateStatusOrThrow(id: id, status: .saved)
        } catch {
            AppLogger.log("[LanguageAssetStore] 候选入库失败 \(id): \(error.localizedDescription)")
            return nil
        }
        logAction(
            assetID: asset.id,
            actionType: .candidateSaved,
            detail: L("候选已确认入库", "Candidate saved to assets")
        )
        return asset
    }

    func saveEditedCandidateAsAsset(_ candidate: LanguageAssetCandidateRecord) -> LanguageAsset? {
        do {
            try saveCandidatesOrThrow([candidate])
        } catch {
            AppLogger.log("[LanguageAssetStore] 保存编辑后的候选失败 \(candidate.id): \(error.localizedDescription)")
            return nil
        }
        return saveCandidateAsAsset(id: candidate.id)
    }

    func ignoreCandidate(id: String) {
        updateCandidateStatus(id: id, status: .ignored)
        logAction(
            assetID: nil,
            actionType: .candidateIgnored,
            detail: L("已忽略 1 条候选资产", "Ignored 1 candidate")
        )
    }

    private func updateCandidateStatus(id: String, status: LanguageAssetCandidateStatus) {
        do {
            try updateCandidateStatusOrThrow(id: id, status: status)
        } catch {
            AppLogger.log("[LanguageAssetStore] 更新候选状态失败 \(id): \(error.localizedDescription)")
        }
    }

    private func updateCandidateStatusOrThrow(id: String, status: LanguageAssetCandidateStatus) throws {
        let db = try requireDB()
        let sql = """
        UPDATE language_asset_candidate
        SET status = ?, updated_at = ?
        WHERE id = ?;
        """
        var stmt: OpaquePointer?
        try prepare(sql, in: db, statement: &stmt)
        defer { sqlite3_finalize(stmt) }

        SQL.bind(stmt, 1, status.rawValue)
        SQL.bind(stmt, 2, iso.string(from: Date()))
        SQL.bind(stmt, 3, id)

        try stepDone(stmt, in: db)
        postDidChangeNotification()
    }

    // MARK: - 资产生命周期（2026-06-11 改造方案 #4）

    /// 资产条数（改造方案 #11：概览页计数不再全表加载）
    func count(status: LanguageAssetStatus = .active) -> Int {
        let sql = "SELECT COUNT(*) FROM language_asset WHERE status = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        SQL.bind(stmt, 1, status.rawValue)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    /// 已忽略候选恢复为待审（改造方案 #5：忽略可反悔）
    func restoreCandidate(id: String) {
        updateCandidateStatus(id: id, status: .pending)
        logAction(actionType: .candidateRestored, detail: L("候选已恢复待审", "Candidate restored to pending"))
        postDidChangeNotification()
    }

    /// 候选保留策略（改造方案 #14）：已处理（saved/ignored）候选超 90 天或
    /// 总量超 1000 条时裁剪最旧的，待审候选永不动
    func pruneFinishedCandidates(olderThanDays: Int = 90, keepingAtMost: Int = 1000) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -olderThanDays, to: Date()) ?? Date()
        let cutoffString = iso.string(from: cutoff)
        // REPAIR_PLAN J3：裁剪失败留痕——静默失败会让候选表无限增长且无迹可查
        if sqlite3_exec(
            db,
            "DELETE FROM language_asset_candidate WHERE status != 'pending' AND created_at < '\(cutoffString)';",
            nil, nil, nil
        ) != SQLITE_OK {
            AppLogger.log("[LanguageAssetStore] 候选按时间裁剪失败: \(String(cString: sqlite3_errmsg(db)))")
        }
        if sqlite3_exec(
            db,
            """
            DELETE FROM language_asset_candidate WHERE status != 'pending' AND id NOT IN (
                SELECT id FROM language_asset_candidate WHERE status != 'pending'
                ORDER BY created_at DESC LIMIT \(keepingAtMost)
            );
            """,
            nil, nil, nil
        ) != SQLITE_OK {
            AppLogger.log("[LanguageAssetStore] 候选按数量裁剪失败: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    // MARK: - 跨任务防重（2026-06-11 改造方案 #1）

    /// 已被任何候选（含已忽略/已入库）或正式资产引用过的识别记录 id 集合。
    /// 提炼取数阶段据此排除，避免同一条输入反复被提炼成新候选。
    func referencedSourceRecordIDs() -> Set<String> {
        var ids = Set<String>()
        for table in ["language_asset_candidate", "language_asset"] {
            let sql = "SELECT source_record_ids_json FROM \(table);"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let parsed = codec.decodeJSONString([String].self, from: SQL.column(stmt, 0)) {
                    ids.formUnion(parsed)
                }
            }
        }
        return ids
    }

    /// 库内已有候选与资产的内容去重键（type|title|content 小写），
    /// 规范化阶段据此剔除与既有内容重复的新候选。
    func existingDedupeKeys() -> Set<String> {
        var keys = Set<String>()
        for table in ["language_asset_candidate", "language_asset"] {
            let sql = "SELECT asset_type, COALESCE(title, ''), content FROM \(table);"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let type = SQL.column(stmt, 0)
                let title = SQL.column(stmt, 1)
                let content = SQL.column(stmt, 2)
                keys.insert("\(type)|\(title.lowercased())|\(content.lowercased())")
            }
        }
        return keys
    }

    private func fetchCandidate(id: String) -> LanguageAssetCandidateRecord? {
        let sql = """
        SELECT id, created_at, updated_at, asset_type, grade, title, content, summary, reason, scenes_json, audiences_json, rule_hit, source_record_ids_json, source_record_count, extraction_job_id, status
        FROM language_asset_candidate
        WHERE id = ?
        LIMIT 1;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        SQL.bind(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return codec.decodeCandidate(from: stmt)
    }

    // MARK: - Testing Helpers

    func deleteAll() {
        let assetDeleted = sqlite3_exec(db, "DELETE FROM language_asset;", nil, nil, nil) == SQLITE_OK
        let candidateDeleted = sqlite3_exec(db, "DELETE FROM language_asset_candidate;", nil, nil, nil) == SQLITE_OK
        let jobDeleted = sqlite3_exec(db, "DELETE FROM asset_extraction_job;", nil, nil, nil) == SQLITE_OK
        let runDeleted = sqlite3_exec(db, "DELETE FROM extraction_run;", nil, nil, nil) == SQLITE_OK
        let resultDeleted = sqlite3_exec(db, "DELETE FROM extraction_result;", nil, nil, nil) == SQLITE_OK
        let logDeleted = sqlite3_exec(db, "DELETE FROM language_asset_action_log;", nil, nil, nil) == SQLITE_OK
        if assetDeleted || candidateDeleted || jobDeleted || runDeleted || resultDeleted || logDeleted {
            postDidChangeNotification()
        }
    }

    // MARK: - Private

    private func requireDB() throws -> OpaquePointer {
        guard let db else { throw LanguageAssetStoreError.databaseUnavailable }
        return db
    }

    private func exec(_ sql: String, in db: OpaquePointer) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw LanguageAssetStoreError.sqlite(sqliteMessage(in: db))
        }
    }

    private func prepare(_ sql: String, in db: OpaquePointer, statement: inout OpaquePointer?) throws {
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw LanguageAssetStoreError.sqlite(sqliteMessage(in: db))
        }
    }

    private func stepDone(_ statement: OpaquePointer?, in db: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw LanguageAssetStoreError.sqlite(sqliteMessage(in: db))
        }
    }

    private func sqliteMessage(in db: OpaquePointer) -> String {
        sqlite3_errmsg(db).map { String(cString: $0) } ?? L("SQLite 操作失败", "SQLite operation failed")
    }

    /// REPAIR_PLAN J3：单行写不再静默失败——busy_timeout(3s) 超时仍 BUSY、磁盘满等
    /// step 失败必须留痕，否则任务/结果/资产状态无声丢失、上层无感知。
    /// 日志记 sqlite3_sql 模板（含 ? 占位符、不含绑定值），不泄漏用户文本。
    @discardableResult
    private func stepSingleWrite(_ stmt: OpaquePointer?) -> Bool {
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            let sql = sqlite3_sql(stmt).map { String(cString: $0) } ?? "unknown"
            AppLogger.log("[LanguageAssetStore] 单行写失败: \(String(cString: sqlite3_errmsg(db))) — \(sql.prefix(80))")
            return false
        }
        return true
    }

    private func postDidChangeNotification() {
        Task { @MainActor in
            NotificationCenter.default.post(name: .languageAssetStoreDidChange, object: nil)
        }
    }
}
