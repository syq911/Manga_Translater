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

    private var settings: AppSettings { environment.settings }

    var body: some View {
        NavigationStack {
            Form {
                accountSection
                sourcesSection
                translationSection
                readerSection
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

    private var readerSection: some View {
        Section(L("settings.section.reader")) {
            Picker(selection: Binding(
                get: { settings.readerMode },
                set: { settings.readerMode = $0 }
            )) {
                ForEach(ReaderMode.allCases, id: \.self) { mode in
                    Text(mode.localizedName).tag(mode)
                }
            } label: {
                Text(L("settings.reader.mode"))
            }

            Picker(selection: Binding(
                get: { settings.readerTheme },
                set: { settings.readerTheme = $0 }
            )) {
                ForEach(ReaderTheme.allCases, id: \.self) { theme in
                    Text(theme.localizedName).tag(theme)
                }
            } label: {
                Text(L("settings.reader.theme"))
            }

            Stepper(
                String(format: L("settings.reader.pageSpacing"), settings.readerPageSpacing),
                value: Binding(
                    get: { settings.readerPageSpacing },
                    set: { settings.readerPageSpacing = $0 }
                ),
                in: AppSettings.readerPageSpacingRange
            )

            Toggle(L("settings.reader.keepAwake"), isOn: Binding(
                get: { settings.keepsScreenAwake },
                set: { settings.keepsScreenAwake = $0 }
            ))

            Stepper(
                String(format: L("settings.reader.preload"), settings.preloadWindow),
                value: Binding(
                    get: { settings.preloadWindow },
                    set: { settings.preloadWindow = $0 }
                ),
                in: AppSettings.preloadWindowRange
            )

            Stepper(
                String(format: L("settings.reader.concurrency"), settings.maxConcurrentDownloads),
                value: Binding(
                    get: { settings.maxConcurrentDownloads },
                    set: { settings.maxConcurrentDownloads = $0 }
                ),
                in: AppSettings.maxConcurrentDownloadsRange
            )
        }
    }

    private var aboutSection: some View {
        Section(L("settings.section.about")) {
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
