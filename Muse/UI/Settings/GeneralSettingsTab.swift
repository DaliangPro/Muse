import AppKit
import SwiftUI
import AVFoundation
import ApplicationServices

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - General Settings Tab
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

struct GeneralSettingsTab: View {
    // MARK: - Global

    @State private var hasMic = false
    @State private var hasAccessibility = false
    // 内存缓存：切走再切回概览页时 SwiftUI 会销毁重建本 view、@State 归零，
    // 导致数据先显示 0 再异步加载出来（用户感知的「先为零等一下」）。用 static 跨重建保留上次结果，
    // 切回时 body 立即显示上次值、再后台刷新，消除闪烁（2026-06-25）
    @State private var statistics: HistoryStore.Statistics? = GeneralSettingsTab.cachedStatistics
    @State private var recentRecords: [HistoryRecord] = GeneralSettingsTab.cachedRecords
    @State private var languageAssetCount = GeneralSettingsTab.cachedAssetCount
    @State private var historyDatabaseErrorMessage: String?
    @State private var assetDatabaseErrorMessage: String?
    @State private var copiedRecentRecordId: String?
    @State private var selectedDayKey = GeneralRecentHistorySection.dayKey(for: Date())

    private static var cachedStatistics: HistoryStore.Statistics?
    private static var cachedRecords: [HistoryRecord] = []
    private static var cachedAssetCount = 0

    private var databaseErrorMessage: String? {
        let messages = [historyDatabaseErrorMessage, assetDatabaseErrorMessage].compactMap { $0 }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    private let historyStore = HistoryStore()
    private let assetStore = LanguageAssetStore()
    private var currentStatistics: HistoryStore.Statistics {
        statistics ?? HistoryStore.Statistics(totalDuration: 0, totalCharacters: 0, recordCount: 0, timeSavedSeconds: 0)
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let databaseErrorMessage {
                databaseFailureBanner(databaseErrorMessage)
                    .padding(.bottom, 10)
            }

            GeneralOverviewSection(
                stats: currentStatistics,
                hasMicrophonePermission: hasMic,
                hasAccessibilityPermission: hasAccessibility,
                languageAssetCount: languageAssetCount
            )

            GeneralRecentHistorySection(
                records: recentRecords,
                copiedRecordId: copiedRecentRecordId,
                selectedDayKey: $selectedDayKey,
                onCopy: copyRecentRecord,
                onDelete: deleteRecentRecord
            )
                .padding(.top, GeneralSettingsStyle.overviewHistoryTopSpacing)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            checkPermissions()
            await reloadHistoryData()
        }
        .onReceive(NotificationCenter.default.publisher(for: .historyStoreDidChange)) { _ in
            Task { await reloadHistoryData() }
        }
        .onChange(of: selectedDayKey) { _, _ in
            Task { await reloadHistoryData() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .languageAssetStoreDidChange)) { _ in
            Task { await reloadAssetCount() }
        }
    }

    private func reloadHistoryData() async {
        do {
            let stats = try await historyStore.getStatisticsOrThrow()
            // 按所选日期取全天记录（2026-06-12 用户拍板：日期选择器替代固定最近 N 条）
            let day = GeneralRecentHistorySection.day(fromKey: selectedDayKey)
                ?? Calendar.current.startOfDay(for: Date())
            let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day
            let records = try await historyStore.fetchBetweenOrThrow(start: day, end: nextDay)
            let sortedRecords = records.sorted { $0.createdAt > $1.createdAt }
            await MainActor.run {
                statistics = stats
                recentRecords = sortedRecords
                historyDatabaseErrorMessage = nil
                Self.cachedStatistics = stats
                Self.cachedRecords = sortedRecords
            }
        } catch {
            await MainActor.run {
                // 保留上次成功数据；错误不能伪装成 0 条。
                historyDatabaseErrorMessage = error.localizedDescription
            }
        }
        await reloadAssetCount()
    }

    private func reloadAssetCount() async {
        do {
            let assetCount = try await assetStore.countOrThrow()
            await MainActor.run {
                languageAssetCount = assetCount
                assetDatabaseErrorMessage = nil
                Self.cachedAssetCount = assetCount
            }
        } catch {
            await MainActor.run {
                assetDatabaseErrorMessage = error.localizedDescription
            }
        }
    }

    private func databaseFailureBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "externaldrive.badge.exclamationmark")
            Text(message)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button(L("重试", "Retry")) {
                Task { await reloadHistoryData() }
            }
            .buttonStyle(.borderless)
        }
        .font(TF.settingsFontCaption)
        .foregroundStyle(.red)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func copyRecentRecord(_ record: HistoryRecord) {
        ClipboardLeaseCoordinator.shared.writeTextPermanently(record.finalText)
        copiedRecentRecordId = record.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedRecentRecordId == record.id {
                copiedRecentRecordId = nil
            }
        }
    }

    private func deleteRecentRecord(_ record: HistoryRecord) {
        Task {
            await historyStore.delete(id: record.id)
            await reloadHistoryData()
        }
    }

    // MARK: - Permissions

    private func checkPermissions() {
        hasMic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        hasAccessibility = AXIsProcessTrusted()
    }
}
