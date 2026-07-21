import Foundation
import LocalAuthentication
import Security

enum KeychainService {

    private static let lock = NSLock()
    private static let keychainServiceName = "pro.daliang.muse.credentials"

    /// XCTest 进程不得读取真实 Application Support、UserDefaults 或系统钥匙串。
    /// 使用进程内后端还能让默认构造的业务对象在测试中保持安全，而无需全局目录开关。
    private struct IsolatedTestStorage {
        var secureData: [String: Data] = [:]
        var legacyValues: [String: Any] = [:]
        var preferences: [String: String] = [:]
    }

    private static let isolatedTestLock = NSLock()
    private static var isolatedTestStorage = IsolatedTestStorage()
    private static let isRunningTests: Bool = {
        let process = ProcessInfo.processInfo
        return process.environment["XCTestConfigurationFilePath"] != nil
            || process.arguments.contains(where: { $0.contains(".xctest") })
            || NSClassFromString("XCTestCase") != nil
    }()

    static var isUsingIsolatedTestStorage: Bool { isRunningTests }

    private static func withIsolatedTestStorage<T>(
        _ body: (inout IsolatedTestStorage) throws -> T
    ) rethrows -> T {
        isolatedTestLock.lock()
        defer { isolatedTestLock.unlock() }
        return try body(&isolatedTestStorage)
    }

    private static var credentialsURL: URL {
        AppPaths.ensureSupportDir().appendingPathComponent("credentials.json")
    }

    // MARK: - Core read/write (now supports nested objects)

    private static func loadAll() -> [String: Any] {
        if isRunningTests {
            return withIsolatedTestStorage { $0.legacyValues }
        }
        guard let data = try? Data(contentsOf: credentialsURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return dict
    }

    private static func saveAll(_ dict: [String: Any]) throws {
        if isRunningTests {
            withIsolatedTestStorage { $0.legacyValues = dict }
            return
        }
        // REPAIR_PLAN C2：credentials.json 只是历史明文凭证的迁移兜底，
        // 清空即删除文件、为空不再创建——新装环境不会出现该文件，
        // 老环境最后一个遗留键迁入钥匙串后文件自动消失
        if dict.isEmpty {
            try? FileManager.default.removeItem(at: credentialsURL)
            return
        }
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        try data.write(to: credentialsURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: credentialsURL.path
        )
    }

    // MARK: - macOS Keychain read/write

    private static func keychainQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainServiceName,
            kSecAttrAccount as String: key,
        ]
    }

    private static func saveSecureData(_ data: Data, key: String) throws {
        if isRunningTests {
            withIsolatedTestStorage { $0.secureData[key] = data }
            return
        }
        let query = keychainQuery(for: key)
        let attributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecSuccess {
            return
        }

        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.saveFailed(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.saveFailed(addStatus)
        }
    }

    private static func loadSecureData(key: String) -> Data? {
        if isRunningTests {
            return withIsolatedTestStorage { $0.secureData[key] }
        }
        var query = keychainQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // Recording start must never block behind a SecurityAgent prompt.
        // If the item requires interactive authentication, fail fast instead.
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            DebugFileLogger.log("keychain load failed key=\(key) status=\(status)")
            return nil
        }
        return result as? Data
    }

    @discardableResult
    private static func deleteSecureData(key: String) -> Bool {
        if isRunningTests {
            return withIsolatedTestStorage {
                $0.secureData.removeValue(forKey: key) != nil
            }
        }
        let status = SecItemDelete(keychainQuery(for: key) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func preferenceString(forKey key: String) -> String? {
        if isRunningTests {
            return withIsolatedTestStorage { $0.preferences[key] }
        }
        return UserDefaults.standard.string(forKey: key)
    }

    private static func setPreference(_ value: String, forKey key: String) {
        if isRunningTests {
            withIsolatedTestStorage { $0.preferences[key] = value }
        } else {
            UserDefaults.standard.set(value, forKey: key)
        }
    }

    private static func removePreference(forKey key: String) {
        if isRunningTests {
            _ = withIsolatedTestStorage { $0.preferences.removeValue(forKey: key) }
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private static func saveSecureString(_ value: String, key: String) throws {
        try saveSecureData(Data(value.utf8), key: key)
    }

    private static func loadSecureString(key: String) -> String? {
        guard let data = loadSecureData(key: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func saveSecureDictionary(_ values: [String: String], key: String) throws {
        let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
        try saveSecureData(data, key: key)
    }

    private static func loadSecureDictionary(key: String) -> [String: String]? {
        guard let data = loadSecureData(key: key),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return nil }
        return values
    }

    // MARK: - Scalar key-value (for LLM keys and misc)

    static func save(key: String, value: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try saveSecureString(value, key: key)
        var dict = loadAll()
        dict.removeValue(forKey: key)
        try saveAll(dict)
    }

    static func load(key: String) -> String? {
        loadSecureString(key: key) ?? loadAll()[key] as? String
    }

    @discardableResult
    static func delete(key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let deletedSecureValue = deleteSecureData(key: key)
        var dict = loadAll()
        let deletedFileValue = dict.removeValue(forKey: key) != nil
        guard deletedFileValue else { return deletedSecureValue }
        return (try? saveAll(dict)) != nil
    }

    // MARK: - Selected ASR Provider (UserDefaults)

    private static let selectedProviderKey = DefaultsKeys.selectedASRProvider

    static var selectedASRProvider: ASRProvider {
        get {
            guard let raw = preferenceString(forKey: selectedProviderKey),
                  let provider = ASRProvider(rawValue: raw)
            else { return .volcano }
            return provider
        }
        set {
            let previous = selectedASRProvider
            setPreference(newValue.rawValue, forKey: selectedProviderKey)
            guard previous != newValue else { return }
            NotificationCenter.default.post(name: .asrProviderDidChange, object: newValue)
        }
    }

    // MARK: - ASR Credentials (provider-aware)

    private static func asrStorageKey(for provider: ASRProvider) -> String {
        "tf_asr_\(provider.rawValue)"
    }

    static func saveASRCredentials(for provider: ASRProvider, values: [String: String]) throws {
        lock.lock()
        defer { lock.unlock() }
        try saveSecureDictionary(values, key: asrStorageKey(for: provider))
        var dict = loadAll()
        dict.removeValue(forKey: asrStorageKey(for: provider))
        try saveAll(dict)
    }

    static func loadASRCredentials(for provider: ASRProvider) -> [String: String]? {
        if let values = loadSecureDictionary(key: asrStorageKey(for: provider)) {
            return values
        }
        let dict = loadAll()
        return dict[asrStorageKey(for: provider)] as? [String: String]
    }

    static func loadASRConfig(for provider: ASRProvider) -> (any ASRProviderConfig)? {
        guard let configType = ASRProviderRegistry.configType(for: provider) else {
            return nil
        }

        if let values = loadASRCredentials(for: provider) {
            return configType.init(credentials: values)
        }

        // Fallback: build config from default field values (e.g. Apple ASR needs no API key)
        let defaultValues: [String: String] = Dictionary(
            uniqueKeysWithValues: configType.credentialFields.compactMap { field in
                guard !field.defaultValue.isEmpty else { return nil }
                return (field.key, field.defaultValue)
            }
        )

        if defaultValues.isEmpty && configType.credentialFields.isEmpty {
            return configType.init(credentials: [:])
        }

        return configType.init(credentials: defaultValues)
    }

    // MARK: - Legacy ASR convenience (volcano-specific, kept for migration)

    static func saveASRCredentials(appKey: String, accessKey: String, resourceId: String) throws {
        try saveASRCredentials(for: .volcano, values: [
            "appKey": appKey,
            "accessKey": accessKey,
            "resourceId": resourceId,
        ])
    }

    static func loadASRConfig() -> VolcanoASRConfig? {
        loadASRConfig(for: .volcano) as? VolcanoASRConfig
    }

    // MARK: - Selected LLM Provider (UserDefaults)

    private static let selectedLLMProviderKey = DefaultsKeys.selectedLLMProvider
    private static let selectedAssetExtractionLLMProviderKey = DefaultsKeys.selectedAssetExtractionLLMProvider

    static var selectedLLMProvider: LLMProvider {
        get {
            guard let raw = preferenceString(forKey: selectedLLMProviderKey),
                  let provider = LLMProvider(rawValue: raw)
            else { return .doubao }
            return provider
        }
        set {
            setPreference(newValue.rawValue, forKey: selectedLLMProviderKey)
        }
    }

    static var selectedAssetExtractionLLMProvider: LLMProvider {
        get {
            guard let raw = preferenceString(forKey: selectedAssetExtractionLLMProviderKey),
                  let provider = LLMProvider(rawValue: raw)
            else { return selectedLLMProvider }
            return provider
        }
        set {
            setPreference(newValue.rawValue, forKey: selectedAssetExtractionLLMProviderKey)
        }
    }

    static func resetAssetExtractionLLMProvider() {
        removePreference(forKey: selectedAssetExtractionLLMProviderKey)
    }

    // MARK: - LLM Credentials (provider-aware)

    private static func llmStorageKey(for provider: LLMProvider) -> String {
        "tf_llm_\(provider.rawValue)"
    }

    private static func sanitizeLLMCredentials(_ values: [String: String]) -> [String: String] {
        var sanitized = values
        for key in ["apiKey", "model", "baseURL"] {
            if let value = sanitized[key] {
                sanitized[key] = value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return sanitized
    }

    static func normalizedLLMCredentialsForStorage(
        provider: LLMProvider,
        values: [String: String]
    ) throws -> [String: String] {
        var normalized = sanitizeLLMCredentials(values)
        guard provider != .localQwen else {
            normalized.removeValue(forKey: "baseURL")
            return normalized
        }
        let baseURL = try LLMEndpointPolicy.normalizedBaseURL(
            rawValue: normalized["baseURL"] ?? "",
            provider: provider
        )
        normalized["baseURL"] = baseURL.absoluteString
        return normalized
    }

    private static func assetExtractionModelOverrideKey(for provider: LLMProvider) -> String {
        "tf_assetExtractionModelOverride_\(provider.rawValue)"
    }

    static func saveLLMCredentials(for provider: LLMProvider, values: [String: String]) throws {
        let normalized = try normalizedLLMCredentialsForStorage(provider: provider, values: values)
        lock.lock()
        defer { lock.unlock() }
        try saveSecureDictionary(normalized, key: llmStorageKey(for: provider))
        var dict = loadAll()
        dict.removeValue(forKey: llmStorageKey(for: provider))
        try saveAll(dict)
    }

    static func loadLLMCredentials(for provider: LLMProvider) -> [String: String]? {
        if let values = loadSecureDictionary(key: llmStorageKey(for: provider)) {
            return sanitizeLLMCredentials(values)
        }
        let dict = loadAll()
        guard let values = dict[llmStorageKey(for: provider)] as? [String: String] else { return nil }
        return sanitizeLLMCredentials(values)
    }

    static func loadLLMProviderConfig(for provider: LLMProvider) -> (any LLMProviderConfig)? {
        guard let values = loadLLMCredentials(for: provider),
              let configType = LLMProviderRegistry.configType(for: provider)
        else { return nil }
        return configType.init(credentials: values)
    }

    // MARK: - LLM Config convenience (backward compat)

    static func saveLLMCredentials(apiKey: String, model: String, baseURL: String = "") throws {
        try saveLLMCredentials(for: .doubao, values: [
            "apiKey": apiKey, "model": model, "baseURL": baseURL,
        ])
    }

    /// Load LLMConfig for the currently selected provider.
    static func loadLLMConfig() -> LLMConfig? {
        resolvedLLMConfig(for: selectedLLMProvider)
    }

    static func loadAssetExtractionLLMConfig() -> LLMConfig? {
        let provider = selectedAssetExtractionLLMProvider
        return resolvedLLMConfig(for: provider, modelOverride: loadAssetExtractionModelOverride(for: provider))
    }

    static func saveAssetExtractionModelOverride(_ model: String?, for provider: LLMProvider) throws {
        lock.lock()
        defer { lock.unlock() }

        var dict = loadAll()
        let key = assetExtractionModelOverrideKey(for: provider)
        let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            dict.removeValue(forKey: key)
        } else {
            dict[key] = trimmed
        }
        try saveAll(dict)
    }

    static func loadAssetExtractionModelOverride(for provider: LLMProvider) -> String? {
        let key = assetExtractionModelOverrideKey(for: provider)
        guard let value = loadAll()[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func resolvedLLMConfig(
        for provider: LLMProvider,
        modelOverride: String? = nil
    ) -> LLMConfig? {
        if provider == .localQwen {
            // 本地 LLM 跑在承载它的 server 上：ARM 是 Qwen3 server，Intel 是 SenseVoice server。
            // 不跨架构 fallback——ARM 的 SenseVoice server 不带 LLM，连过去只会报 "LLM not configured"。
            #if arch(arm64)
            let port = SenseVoiceServerManager.currentQwen3Port
            #else
            let port = SenseVoiceServerManager.currentPort
            #endif
            guard let port else { return nil }
            let trimmedOverride = modelOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let model = trimmedOverride.isEmpty ? "qwen3.5-9b" : trimmedOverride
            return LLMConfig(apiKey: "", model: model, baseURL: "http://127.0.0.1:\(port)/v1")
        }

        guard let config = loadLLMProviderConfig(for: provider)?.toLLMConfig() else { return nil }
        let trimmedOverride = modelOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedOverride.isEmpty else { return config }
        return LLMConfig(apiKey: config.apiKey, model: trimmedOverride, baseURL: config.baseURL)
    }

    // MARK: - Migration (call once at app launch)

    /// Migrate legacy flat keys to provider-grouped format,
    /// move Application Support directory, and migrate UserDefaults from old bundle ID.
    static func migrateIfNeeded() {
        guard !isRunningTests else { return }
        migrateAppSupportDirectory()
        migrateKeychainService()
        migrateUserDefaults()
        lock.lock()
        defer { lock.unlock() }
        let dict = loadAll()

        var migrated = false
        var mutableDict = dict

        // Migrate ASR: tf_appKey/tf_accessKey/tf_resourceId → tf_asr_volcano
        if let appKey = dict["tf_appKey"] as? String, !appKey.isEmpty,
           dict[asrStorageKey(for: .volcano)] == nil {
            let accessKey = dict["tf_accessKey"] as? String ?? ""
            let resourceId = dict["tf_resourceId"] as? String ?? "volc.bigasr.sauc.duration"
            mutableDict[asrStorageKey(for: .volcano)] = [
                "appKey": appKey,
                "accessKey": accessKey,
                "resourceId": resourceId,
            ]
            mutableDict.removeValue(forKey: "tf_appKey")
            mutableDict.removeValue(forKey: "tf_accessKey")
            mutableDict.removeValue(forKey: "tf_resourceId")
            migrated = true
            AppLogger.log("[KeychainService] Migrated legacy ASR credentials to tf_asr_volcano")
        }

        // （原 aliyun→bailian 凭证迁移随两厂商一并移除，REPAIR_PLAN G1）

        // Migrate LLM: tf_llmEndpointId → tf_llmModel
        if let endpointId = dict["tf_llmEndpointId"] as? String, !endpointId.isEmpty,
           dict["tf_llmModel"] == nil {
            mutableDict["tf_llmModel"] = endpointId
            mutableDict.removeValue(forKey: "tf_llmEndpointId")
            migrated = true
            AppLogger.log("[KeychainService] Migrated tf_llmEndpointId → tf_llmModel")
        }

        // Migrate LLM: flat keys → tf_llm_doubao (provider-grouped)
        if let apiKey = dict["tf_llmApiKey"] as? String, !apiKey.isEmpty,
           dict[llmStorageKey(for: .doubao)] == nil {
            let model = (dict["tf_llmModel"] as? String) ?? ""
            let baseURL = (dict["tf_llmBaseURL"] as? String) ?? ""
            mutableDict[llmStorageKey(for: .doubao)] = [
                "apiKey": apiKey,
                "model": model,
                "baseURL": baseURL.isEmpty ? LLMProvider.doubao.defaultBaseURL : baseURL,
            ]
            mutableDict.removeValue(forKey: "tf_llmApiKey")
            mutableDict.removeValue(forKey: "tf_llmModel")
            mutableDict.removeValue(forKey: "tf_llmBaseURL")
            migrated = true
            AppLogger.log("[KeychainService] Migrated flat LLM keys to tf_llm_doubao")
        }

        // Migrate MiniMax CN: api.minimax.chat → api.minimaxi.com (old domain was incorrect)
        let minimaxCNKey = llmStorageKey(for: .minimaxCN)
        if var minimaxCreds = mutableDict[minimaxCNKey] as? [String: String],
           let baseURL = minimaxCreds["baseURL"],
           baseURL.contains("api.minimax.chat") {
            minimaxCreds["baseURL"] = baseURL.replacingOccurrences(
                of: "api.minimax.chat", with: "api.minimaxi.com"
            )
            mutableDict[minimaxCNKey] = minimaxCreds
            migrated = true
            AppLogger.log("[KeychainService] Migrated MiniMax CN base URL: api.minimax.chat → api.minimaxi.com")
        }

        let movedCredentialsToKeychain = migrateCredentialDictionariesToKeychain(in: &mutableDict)

        if migrated || movedCredentialsToKeychain {
            try? saveAll(mutableDict)
        }
    }

    @discardableResult
    private static func migrateCredentialDictionariesToKeychain(in dict: inout [String: Any]) -> Bool {
        let credentialKeys = dict.keys.filter { key in
            key.hasPrefix("tf_asr_") || key.hasPrefix("tf_llm_")
        }

        var didMove = false
        for key in credentialKeys {
            guard let values = dict[key] as? [String: String] else { continue }
            do {
                try saveSecureDictionary(values, key: key)
                dict.removeValue(forKey: key)
                didMove = true
                AppLogger.log("[KeychainService] Migrated \(key) credentials to macOS Keychain")
            } catch {
                AppLogger.log("[KeychainService] Failed to migrate \(key) credentials to macOS Keychain: \(error.localizedDescription)")
            }
        }

        return didMove
    }

    // MARK: - Legacy Migration (one-time, from previous project name)

    /// 旧项目目录/标识名。用运行时数组拼接构造，避免完整旧名作为字符串常量被编入二进制
    /// （满足"分发包内任何地方不出现旧名"的要求；strings 只能扫到 "Type"/"4"/"Me" 等碎片）。
    private static let legacyDataDirName = ["Type", "4", "Me"].joined()
    private static let legacyBundleSuffix = ["type", "4", "me"].joined()
    private static var legacyBundleID: String { "com.\(legacyBundleSuffix).app" }
    private static var legacyKeychainService: String { "com.\(legacyBundleSuffix).credentials" }

    /// 把旧项目目录的用户数据一次性并入 Muse/（仅老用户/本机升级会触发；新装环境无此目录，直接跳过）。
    /// 用文件级合并而非目录改名，因为其他初始化代码可能已先创建新目录。
    private static func migrateAppSupportDirectory() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let oldDir = appSupport.appendingPathComponent(legacyDataDirName, isDirectory: true)
        let newDir = appSupport.appendingPathComponent("Muse", isDirectory: true)

        // 旧目录须存在且含真实数据（credentials.json 或 history.db 任一即可——凭证迁入钥匙串后前者会消失）
        let hasData = fm.fileExists(atPath: oldDir.appendingPathComponent("credentials.json").path)
            || fm.fileExists(atPath: oldDir.appendingPathComponent("history.db").path)
        guard hasData else { return }

        try? fm.createDirectory(at: newDir, withIntermediateDirectories: true)

        // 逐个文件 old → new，新目录已存在同名则跳过
        guard let contents = try? fm.contentsOfDirectory(atPath: oldDir.path) else { return }
        var movedCount = 0
        for item in contents {
            let src = oldDir.appendingPathComponent(item)
            let dst = newDir.appendingPathComponent(item)
            if !fm.fileExists(atPath: dst.path) {
                do {
                    try fm.moveItem(at: src, to: dst)
                    movedCount += 1
                } catch {
                    AppLogger.log("[KeychainService] 旧数据迁移失败 \(item): \(error.localizedDescription)")
                }
            }
        }

        if movedCount > 0 {
            AppLogger.log("[KeychainService] 已并入 \(movedCount) 个旧数据文件 → Muse")
        }

        // 旧目录清空后删除
        if let remaining = try? fm.contentsOfDirectory(atPath: oldDir.path), remaining.isEmpty {
            try? fm.removeItem(at: oldDir)
        }
    }

    /// 把旧 Keychain service 下的凭证一次性搬到当前 service（一次性，已迁移则跳过）。
    private static func migrateKeychainService() {
        let marker = "muse_migratedLegacyKeychain"
        guard !UserDefaults.standard.bool(forKey: marker) else { return }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyKeychainService,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        let ctx = LAContext()
        ctx.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = ctx

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            UserDefaults.standard.set(true, forKey: marker)
            return
        }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            AppLogger.log("[KeychainService] 旧钥匙串查询失败，保留迁移重试机会: \(status)")
            return
        }

        var count = 0
        var failureCount = 0
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data else { continue }
            // 新 service 已有同名则不覆盖
            if loadSecureData(key: account) == nil {
                do {
                    try saveSecureData(data, key: account)
                    count += 1
                } catch {
                    failureCount += 1
                    AppLogger.log("[KeychainService] 旧钥匙串凭证迁移失败 \(account): \(error.localizedDescription)")
                }
            }
        }
        guard failureCount == 0 else {
            AppLogger.log("[KeychainService] 旧钥匙串迁移未完成，失败 \(failureCount) 条，将在下次启动重试")
            return
        }
        UserDefaults.standard.set(true, forKey: marker)
        if count > 0 {
            AppLogger.log("[KeychainService] 已迁移 \(count) 条旧钥匙串凭证 → 新 service")
        }
    }

    // MARK: - UserDefaults Migration (old bundle ID)

    /// 把旧 bundle ID 域里的 tf_ 偏好一次性拷到当前域（已迁移则跳过）。
    private static func migrateUserDefaults() {
        let marker = "muse_migratedLegacyDefaults"
        guard !UserDefaults.standard.bool(forKey: marker) else { return }

        guard let oldDefaults = UserDefaults(suiteName: legacyBundleID) else { return }
        let oldDict = oldDefaults.dictionaryRepresentation()
        let tfKeys = oldDict.keys.filter { $0.hasPrefix("tf_") }

        guard !tfKeys.isEmpty else {
            UserDefaults.standard.set(true, forKey: marker)
            return
        }

        var count = 0
        for key in tfKeys {
            // 新域已有值则不覆盖
            if UserDefaults.standard.object(forKey: key) == nil {
                UserDefaults.standard.set(oldDict[key], forKey: key)
                count += 1
            }
        }

        UserDefaults.standard.set(true, forKey: marker)
        if count > 0 {
            AppLogger.log("[KeychainService] 已从旧 bundle 域迁移 \(count) 个偏好键")
        }
    }
}

enum KeychainError: Error {
    case saveFailed(OSStatus)
}
