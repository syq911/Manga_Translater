//
//  SettingsView.swift
//  MangaTranslater
//
//  设置：账号与云服务 / 翻译 / 阅读器 / 源 / 关于。
//
//  合规要点（勿改）：
//  - 「显示成人（18+）源」默认关闭，且开启前必须通过年龄确认弹窗；
//    最终开关状态由 `AppSettings.setShowsNSFWSources` 裁决（未确认则拒绝开启）。
//  - 「云翻译服务」是 App 内唯一的付费入口，点击后跳转外部网页完成付款，
//    App 内不接入任何支付 SDK、不出现收银台。
//

import SwiftUI
import AppCore

struct SettingsView: View {

    @Environment(AppEnvironment.self) private var environment

    @State private var showsAgeConfirmation = false
    @State private var statusMessage: String?
    /// 待导出的备份（非 nil 即弹系统文件面板）。
    @State private var exportDocument: BackupDocument?
    /// 待确认的恢复包（非 nil 即弹确认：恢复会覆盖设置）。
    @State private var pendingRestore: BackupBundle?
    @State private var showsRestorePicker = false
    @State private var isBackupBusy = false

    private var settings: AppSettings { environment.settings }

    var body: some View {
        NavigationStack {
            Form {
                accountSection
                sourcesSection
                translationSection
                readerSection
                backupSection
                aboutSection
            }
            .navigationTitle(L("tab.settings"))
            .alert(L("settings.nsfw.confirm.title"), isPresented: $showsAgeConfirmation) {
                Button(L("common.cancel"), role: .cancel) {}
                Button(L("settings.nsfw.confirm.action")) {
                    settings.hasConfirmedAdultContent = true
                    settings.setShowsNSFWSources(true)
                }
            } message: {
                Text(L("settings.nsfw.confirm.body"))
            }
            .alert(L("common.notice"), isPresented: Binding(
                get: { statusMessage != nil },
                set: { if !$0 { statusMessage = nil } }
            )) {
                Button(L("common.ok"), role: .cancel) { statusMessage = nil }
            } message: {
                Text(statusMessage ?? "")
            }
            .fileExporter(
                isPresented: Binding(
                    get: { exportDocument != nil },
                    set: { if !$0 { exportDocument = nil } }
                ),
                document: exportDocument,
                contentType: .json,
                defaultFilename: Self.backupFileName()
            ) { result in
                exportDocument = nil
                if case let .failure(error) = result {
                    statusMessage = String(format: L("backup.exportFailed"), error.localizedDescription)
                }
            }
            .fileImporter(
                isPresented: $showsRestorePicker,
                allowedContentTypes: [.json]
            ) { result in
                handleRestoreSelection(result)
            }
            .confirmationDialog(
                L("backup.confirm.title"),
                isPresented: Binding(
                    get: { pendingRestore != nil },
                    set: { if !$0 { pendingRestore = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button(L("backup.confirm.action")) { applyRestore() }
                Button(L("common.cancel"), role: .cancel) { pendingRestore = nil }
            } message: {
                Text(restorePrompt)
            }
        }
    }

    // MARK: 备份 / 恢复

    private var backupSection: some View {
        Section {
            Button {
                exportBackup()
            } label: {
                Label(L("backup.export"), systemImage: "square.and.arrow.up")
            }
            .disabled(isBackupBusy)

            Button {
                showsRestorePicker = true
            } label: {
                Label(L("backup.restore"), systemImage: "square.and.arrow.down")
            }
            .disabled(isBackupBusy)
        } header: {
            Text(L("settings.section.backup"))
        } footer: {
            Text(L("backup.footer"))
        }
    }

    /// 导出用的文件名：带日期，方便同一天导多次也不互相覆盖。
    private static func backupFileName(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "MangaTranslater-\(formatter.string(from: now))"
    }

    private var restorePrompt: String {
        guard let bundle = pendingRestore else { return "" }
        let summary = bundle.summary
        return String(
            format: L("backup.confirm.message"),
            summary.categories,
            summary.libraryEntries,
            summary.repositories,
            summary.servers
        )
    }

    private func exportBackup() {
        isBackupBusy = true
        defer { isBackupBusy = false }
        do {
            let bundle = try environment.makeBackupBundle()
            exportDocument = BackupDocument(data: try bundle.encoded())
        } catch {
            statusMessage = String(format: L("backup.exportFailed"), error.localizedDescription)
        }
    }

    private func handleRestoreSelection(_ result: Result<URL, Error>) {
        switch result {
        case let .success(url):
            let needsScope = url.startAccessingSecurityScopedResource()
            defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let bundle = try BackupBundle.decoded(from: data)
                // 先确认再动手：恢复会覆盖设置（`DestructiveActionPolicy(.restoreBackup)`）
                if DestructiveActionPolicy.requiresConfirmation(.restoreBackup) {
                    pendingRestore = bundle
                } else {
                    applyRestore(bundle)
                }
            } catch {
                statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        case let .failure(error):
            statusMessage = String(format: L("backup.importFailed"), error.localizedDescription)
        }
    }

    private func applyRestore() {
        guard let bundle = pendingRestore else { return }
        pendingRestore = nil
        applyRestore(bundle)
    }

    private func applyRestore(_ bundle: BackupBundle) {
        isBackupBusy = true
        defer { isBackupBusy = false }
        do {
            let report = try environment.restore(from: bundle)
            statusMessage = report.changedAnything
                ? String(
                    format: L("backup.done"),
                    report.categoriesCreated,
                    report.entriesAdded,
                    report.serversAdded
                )
                : L("backup.nothingNew")
        } catch {
            statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: 各分区

    private var accountSection: some View {
        Section(L("settings.section.account")) {
            NavigationLink {
                CloudAccountView()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("settings.cloud.entry"))
                    Text(cloudSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// 账号入口的一句话状态：未登录说清楚「能干什么」，已登录显示额度。
    private var cloudSubtitle: String {
        let cloud = environment.cloud
        guard cloud.isSignedIn else { return L("settings.cloud.subtitle") }
        return "\(cloud.planName) · \(cloud.quotaSummary)"
    }

    private var sourcesSection: some View {
        Section {
            Toggle(L("settings.nsfw"), isOn: nsfwBinding)
        } header: {
            Text(L("settings.section.sources"))
        } footer: {
            Text(L("settings.nsfw.footer"))
        }
    }

    private var translationSection: some View {
        Section {
            NavigationLink {
                TranslationSettingsView(settings: settings)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("translation.settings.title"))
                    Text(translationSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(L("settings.section.translation"))
        } footer: {
            Text(L("settings.translation.footer"))
        }
    }

    /// 一句话概括当前翻译配置，省得每次都要点进去确认。
    private var translationSubtitle: String {
        let backend = settings.translationBackend.localizedName
        let pair = "\(settings.sourceLanguage.localizedName) → \(settings.targetLanguage.localizedName)"
        return "\(backend) · \(pair)"
    }

    /// 阅读器设置。**实现只有一份**（`ReaderSettingsSections`），
    /// 阅读器内的 ⚙ 弹窗用的是同一个视图，因此两处不会分叉。
    private var readerSection: some View {
        ReaderSettingsSections(settings: settings)
    }

    private var aboutSection: some View {
        Section {
            HStack {
                Text(L("settings.about.version"))
                Spacer()
                Text(Self.appVersion)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(L("settings.diagnostics.export"))
                Text(L("settings.diagnostics.subtitle"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(environment.diagnostics.byteCount) B")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Button(L("settings.diagnostics.clear"), role: .destructive) {
                environment.diagnostics.clear()
            }

            Button(L("settings.cache.clearCover")) {
                let removed = environment.coverCache.removeAll()
                statusMessage = removed > 0
                    ? String(format: L("settings.cache.coverCleared"), removed)
                    : L("settings.cache.coverEmpty")
            }

            ForEach(LegalDocumentKind.allCases) { kind in
                NavigationLink {
                    LegalDocumentView(kind: kind)
                } label: {
                    Text(kind.title)
                }
            }
        } header: {
            Text(L("settings.section.about"))
        } footer: {
            // 这两个清理都没加确认（都不丢用户数据），但**各自的性质必须写出来**：
            // 封面缓存会自动重建；日志清了就没了——排查问题时它往往是唯一的线索。
            Text(L("settings.about.clearsFooter"))
        }
    }

    // MARK: 绑定

    private var nsfwBinding: Binding<Bool> {
        Binding(
            get: { settings.showsNSFWSources },
            set: { newValue in
                if newValue, !settings.hasConfirmedAdultContent {
                    showsAgeConfirmation = true
                } else {
                    settings.setShowsNSFWSources(newValue)
                }
            }
        )
    }

    private static var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

#Preview {
    SettingsView()
        .environment(AppEnvironment.makeDefault())
}
