import Foundation
import SQLite3

enum LanguageAssetStoreSchema {
    static func createTables(in db: OpaquePointer?) {
        let jobSQL = """
        CREATE TABLE IF NOT EXISTS asset_extraction_job (
            id TEXT PRIMARY KEY,
            created_at TEXT NOT NULL,
            started_at TEXT,
            finished_at TEXT,
            range_type TEXT NOT NULL,
            range_payload TEXT,
            source_record_count INTEGER NOT NULL DEFAULT 0,
            status TEXT NOT NULL,
            summary TEXT,
            error_message TEXT
        );
        """

        let assetSQL = """
        CREATE TABLE IF NOT EXISTS language_asset (
            id TEXT PRIMARY KEY,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            asset_type TEXT NOT NULL,
            grade TEXT,
            title TEXT,
            content TEXT NOT NULL,
            summary TEXT,
            reason TEXT,
            scenes_json TEXT NOT NULL DEFAULT '[]',
            audiences_json TEXT NOT NULL DEFAULT '[]',
            rule_hit TEXT,
            keywords_json TEXT NOT NULL,
            source_record_ids_json TEXT NOT NULL,
            source_record_count INTEGER NOT NULL DEFAULT 0,
            extraction_job_id TEXT,
            is_favorite INTEGER NOT NULL DEFAULT 0,
            status TEXT NOT NULL DEFAULT 'active'
        );
        """

        let candidateSQL = """
        CREATE TABLE IF NOT EXISTS language_asset_candidate (
            id TEXT PRIMARY KEY,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            asset_type TEXT NOT NULL,
            grade TEXT NOT NULL,
            title TEXT NOT NULL,
            content TEXT NOT NULL,
            summary TEXT,
            reason TEXT NOT NULL,
            scenes_json TEXT NOT NULL DEFAULT '[]',
            audiences_json TEXT NOT NULL DEFAULT '[]',
            rule_hit TEXT,
            source_record_ids_json TEXT NOT NULL,
            source_record_count INTEGER NOT NULL DEFAULT 0,
            extraction_job_id TEXT,
            status TEXT NOT NULL DEFAULT 'pending'
        );
        """

        let actionLogSQL = """
        CREATE TABLE IF NOT EXISTS language_asset_action_log (
            id TEXT PRIMARY KEY,
            created_at TEXT NOT NULL,
            asset_id TEXT,
            action_type TEXT NOT NULL,
            detail TEXT
        );
        """

        let recipeSQL = """
        CREATE TABLE IF NOT EXISTS extraction_recipe (
            id TEXT PRIMARY KEY,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            name TEXT NOT NULL,
            description TEXT NOT NULL,
            goal_prompt TEXT NOT NULL,
            output_kind TEXT NOT NULL,
            processing_strategy TEXT NOT NULL,
            source_policy TEXT NOT NULL,
            output_schema TEXT NOT NULL,
            quality_rules TEXT NOT NULL,
            save_rule TEXT NOT NULL DEFAULT '',
            ignore_rule TEXT NOT NULL DEFAULT '',
            destination TEXT NOT NULL,
            is_built_in INTEGER NOT NULL DEFAULT 0,
            status TEXT NOT NULL DEFAULT 'active'
        );
        """

        let runSQL = """
        CREATE TABLE IF NOT EXISTS extraction_run (
            id TEXT PRIMARY KEY,
            recipe_id TEXT NOT NULL,
            recipe_name TEXT NOT NULL,
            created_at TEXT NOT NULL,
            started_at TEXT,
            finished_at TEXT,
            range_type TEXT NOT NULL,
            range_payload TEXT,
            source_record_count INTEGER NOT NULL DEFAULT 0,
            status TEXT NOT NULL,
            result_count INTEGER NOT NULL DEFAULT 0,
            summary TEXT,
            error_message TEXT
        );
        """

        let resultSQL = """
        CREATE TABLE IF NOT EXISTS extraction_result (
            id TEXT PRIMARY KEY,
            run_id TEXT NOT NULL,
            recipe_id TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            output_kind TEXT NOT NULL,
            title TEXT NOT NULL,
            content TEXT NOT NULL,
            summary TEXT,
            payload_json TEXT NOT NULL DEFAULT '{}',
            source_record_ids_json TEXT NOT NULL DEFAULT '[]',
            source_record_count INTEGER NOT NULL DEFAULT 0,
            status TEXT NOT NULL DEFAULT 'active',
            score REAL,
            review_reason TEXT,
            is_favorite INTEGER NOT NULL DEFAULT 0
        );
        """

        sqlite3_exec(db, jobSQL, nil, nil, nil)
        sqlite3_exec(db, assetSQL, nil, nil, nil)
        sqlite3_exec(db, candidateSQL, nil, nil, nil)
        sqlite3_exec(db, actionLogSQL, nil, nil, nil)
        sqlite3_exec(db, recipeSQL, nil, nil, nil)
        sqlite3_exec(db, runSQL, nil, nil, nil)
        sqlite3_exec(db, resultSQL, nil, nil, nil)
        sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_asset_status_created ON language_asset(status, created_at);", nil, nil, nil)
        sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_candidate_status_created ON language_asset_candidate(status, created_at);", nil, nil, nil)
        sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_action_log_created ON language_asset_action_log(created_at);", nil, nil, nil)
        sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_extraction_recipe_status ON extraction_recipe(status, is_built_in);", nil, nil, nil)
        sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_extraction_run_created ON extraction_run(created_at);", nil, nil, nil)
        sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_extraction_result_run ON extraction_result(run_id, status);", nil, nil, nil)
        addColumnIfNeeded(db, table: "language_asset", column: "grade", definition: "TEXT")
        addColumnIfNeeded(db, table: "language_asset", column: "reason", definition: "TEXT")
        addColumnIfNeeded(db, table: "language_asset", column: "scenes_json", definition: "TEXT NOT NULL DEFAULT '[]'")
        addColumnIfNeeded(db, table: "language_asset", column: "audiences_json", definition: "TEXT NOT NULL DEFAULT '[]'")
        addColumnIfNeeded(db, table: "language_asset", column: "rule_hit", definition: "TEXT")
        // 2026-07 语料资产重构：配方吸收入库/忽略标准；产物带评审信息与收藏
        addColumnIfNeeded(db, table: "extraction_recipe", column: "save_rule", definition: "TEXT NOT NULL DEFAULT ''")
        addColumnIfNeeded(db, table: "extraction_recipe", column: "ignore_rule", definition: "TEXT NOT NULL DEFAULT ''")
        addColumnIfNeeded(db, table: "extraction_result", column: "score", definition: "REAL")
        addColumnIfNeeded(db, table: "extraction_result", column: "review_reason", definition: "TEXT")
        addColumnIfNeeded(db, table: "extraction_result", column: "is_favorite", definition: "INTEGER NOT NULL DEFAULT 0")
    }

    static func seedBuiltInRecipes(in db: OpaquePointer?) {
        let sql = """
        INSERT OR IGNORE INTO extraction_recipe
        (id, created_at, updated_at, name, description, goal_prompt, output_kind, processing_strategy, source_policy, output_schema, quality_rules, save_rule, ignore_rule, destination, is_built_in, status)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        // 旧库升级回填：已 seed 过的内置配方新列为空时补默认标准；用户改过则不覆盖
        let backfillSQL = """
        UPDATE extraction_recipe
        SET save_rule = ?, ignore_rule = ?
        WHERE id = ? AND is_built_in = 1
          AND (save_rule IS NULL OR save_rule = '')
          AND (ignore_rule IS NULL OR ignore_rule = '');
        """
        // 内置配方旧名去「今日」（提炼范围用户自选，不限当天）；仅旧名未被用户改过时更新
        sqlite3_exec(db, "UPDATE extraction_recipe SET name = '待办' WHERE id = 'builtin.today_todos' AND name = '今日待办';", nil, nil, nil)
        let iso = ISO8601DateFormatter()
        for recipe in ExtractionRecipe.builtInRecipes() {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
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
            sqlite3_step(stmt)

            var backfillStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, backfillSQL, -1, &backfillStmt, nil) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(backfillStmt) }
            SQL.bind(backfillStmt, 1, recipe.saveRule)
            SQL.bind(backfillStmt, 2, recipe.ignoreRule)
            SQL.bind(backfillStmt, 3, recipe.id)
            sqlite3_step(backfillStmt)
        }
    }

    private static func addColumnIfNeeded(
        _ db: OpaquePointer?,
        table: String,
        column: String,
        definition: String
    ) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmt, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(stmt) }

        var existingColumns = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let text = sqlite3_column_text(stmt, 1) {
                existingColumns.insert(String(cString: text))
            }
        }

        guard !existingColumns.contains(column) else { return }
        sqlite3_exec(db, "ALTER TABLE \(table) ADD COLUMN \(column) \(definition);", nil, nil, nil)
    }
}
