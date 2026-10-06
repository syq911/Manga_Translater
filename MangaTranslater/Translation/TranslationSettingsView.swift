//
//  TranslationSettingsView.swift
//  MangaTranslater
//
//  翻译设置：后端 / 语言 / 识别 / 排版 / 自备密钥 / 缓存维护。
//
//  为什么用局部 `@State` 而不是直接绑到 `AppSettings` 的计算属性：
//  `AppSettings` 刻意不是 `@Observable`（它是一个带锁的普通类，测试里可注入
//  独立 UserDefaults）。因此这里沿用「局部状态 + 写回」的写法：
//  控件改的是局部状态，同一处顺手写回设置，语义清晰且不会出现
//  「界面显示旧值、实际已是新值」的错位。
//

import SwiftUI
import AppCore

struct TranslationSettingsView: View {

    @Environment(AppEnvironment.self) private var environment

    @State private var backend: TranslationBackend
    @State private var source: TranslationLanguage
    @State private var target: TranslationLanguage
    @State private var prefetchWindow: Int
    @State private var lineDropFallback: Bool
    @State private var baseURL: String
    @State private var model: String
    @State private var apiKey: String
    @State private var sampledBackground: Bool
    @State private var showOriginalText: Bool
    @State private var fontScale: Double
    @State private var statusMessage: String?
    @State private var cacheSize: String

    init(settings: AppSettings) {
        _backend = State(initialValue: settings.translationBackend)
        _source = State(initialValue: settings.sourceLanguage)
        _target = State(initialValue: settings.targetLanguage)
        _prefetchWindow = State(initialValue: settings.translationPrefetchWindow)
        _lineDropFallback = State(initialValue: settings.usesLineDropFallback)
        _baseURL = State(initialValue: settings.deepSeekBaseURL)
        _model = State(initialValue: settings.deepSeekModel)
        _apiKey = State(initialValue: SecureValueStore.string(forKey: SecureValueStore.Key.translationAPIKey) ?? "")
        _sampledBackground = State(initialValue: settings.translationUsesSampledBackground)
        _showOriginalText = State(initialValue: settings.translationShowsOriginalText)
        _fontScale = State(initialValue: settings.fontScale)
        _cacheSize = State(initialValue: "")
    }

    private var settings: AppSettings { environment.settings }

    var body: some View {
        Form {
            backendSection
            languageSection
            recognitionSection

            if backend == .bringYourOwnKey {
                byokSection
            } else if backend == .cloudService {
                cloudSection
            } else {
                onDeviceSection
            }

            layoutSection
            cacheSection
        }
        .navigationTitle(L("translation.settings.title"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refreshCacheSize() }
        .alert(L("common.notice"), isPresented: Binding(
            get: { statusMessage != nil },
            set: { if !$0 { statusMessage = nil } }
        )) {
            Button(L("common.ok"), role: .cancel) { statusMessage = nil }
        } message: {
            Text(statusMessage ?? "")
        }
    }

    // MARK: 后端

    private var backendSection: some View {
        Section {
            Picker(L("translation.settings.backend"), selection: Binding(
                get: { backend },
                set: { backend = $0; settings.translationBackend = $0 }
            )) {
                ForEach(TranslationBackend.allCases, id: \.self) { item in
                    Text(item.displayName).tag(item)
                }
            }
            .pickerStyle(.inline)
        } header: {
            Text(L("translation.settings.backend"))
        } footer: {
            Text(L("translation.settings.backendFooter"))
        }
    }

    // MARK: 语言

    private var languageSection: some View {
        Section(L("translation.settings.language")) {
            Picker(L("translation.settings.source"), selection: Binding(
                get: { source },
                set: { source = $0; settings.sourceLanguage = $0 }
            )) {
                ForEach(TranslationLanguage.allCases, id: \.self) { item in
                    Text(item.displayName).tag(item)
                }
            }

            Picker(L("translation.settings.target"), selection: Binding(
                get: { target },
                set: { target = $0; settings.targetLanguage = $0 }
            )) {
                // `auto` 只能当原文语言，译文语言必须是具体语言
                ForEach(TranslationLanguage.targetChoices, id: \.self) { item in
                    Text(item.displayName).tag(item)
                }
            }

            Stepper(
                value: Binding(
                    get: { prefetchWindow },
                    set: { prefetchWindow = $0; settings.translationPrefetchWindow = $0 }
                ),
                in: AppSettings.translationPrefetchWindowRange
            ) {
                Text(String(format: L("translation.settings.prefetch"), prefetchWindow))
            }
        }
    }

    // MARK: 识别

    private var recognitionSection: some View {
        Section {
            Toggle(L("translation.settings.lineDropFallback"), isOn: Binding(
                get: { lineDropFallback },
                set: { lineDropFallback = $0; settings.usesLineDropFallback = $0 }
            ))
        } header: {
            Text(L("translation.settings.recognition"))
        } footer: {
            Text(L("translation.settings.lineDropFallbackFooter"))
        }
    }

    // MARK: 自备密钥

    private var byokSection: some View {
        Section {
            TextField(L("translation.settings.baseURL"), text: Binding(
                get: { baseURL },
                set: { baseURL = $0; settings.deepSeekBaseURL = $0 }
            ))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)

            TextField(L("translation.settings.model"), text: Binding(
                get: { model },
                set: { model = $0; settings.deepSeekModel = $0 }
            ))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()

            SecureField(L("translation.settings.apiKey"), text: Binding(
                get: { apiKey },
                set: { apiKey = $0; SecureValueStore.set($0, forKey: SecureValueStore.Key.translationAPIKey) }
            ))
        } header: {
            Text(L("translation.settings.byok"))
        } footer: {
            Text(L("translation.settings.byokFooter"))
        }
    }

    // MARK: 云服务

    private var cloudSection: some View {
        Section {
            NavigationLink {
                CloudAccountView()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("cloud.entry"))
                    Text(environment.cloud.isSignedIn
                         ? environment.cloud.quotaSummary
                         : L("cloud.status.signedOut"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(L("cloud.section.account"))
        } footer: {
            Text(L("cloud.footer"))
        }
    }

    // MARK: 端上翻译

    private var onDeviceSection: some View {
        Section {
            Text(L("translation.settings.onDeviceDetail"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text(L("translation.settings.onDevice"))
        } footer: {
            Text(L("translation.settings.onDeviceFooter"))
        }
    }

    // MARK: 排版

    private var layoutSection: some View {
        Section(L("translation.settings.layout")) {
            Toggle(L("translation.settings.sampledBackground"), isOn: Binding(
                get: { sampledBackground },
                set: { sampledBackground = $0; settings.translationUsesSampledBackground = $0 }
            ))

            Toggle(L("translation.settings.showOriginal"), isOn: Binding(
                get: { showOriginalText },
                set: { showOriginalText = $0; settings.translationShowsOriginalText = $0 }
            ))

            VStack(alignment: .leading) {
                HStack {
                    Text(L("translation.settings.fontScale"))
                    Spacer()
                    Text(String(format: "%.2f×", fontScale))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { fontScale },
                        set: { fontScale = $0; settings.fontScale = $0 }
                    ),
                    in: AppSettings.fontScaleRange,
                    step: 0.05
                )
            }
        }
    }

    // MARK: 缓存

    private var cacheSection: some View {
        Section {
            HStack {
                Text(L("translation.settings.cacheSize"))
                Spacer()
                Text(cacheSize)
                    .foregroundStyle(.secondary)
            }

            Button(L("translation.settings.clearCache"), role: .destructive) {
                let removed = environment.translationStore.removeAll()
                refreshCacheSize()
                statusMessage = String(format: L("translation.settings.clearCacheDone"), removed)
            }
        } header: {
            Text(L("translation.settings.cache"))
        } footer: {
            Text(L("translation.settings.cacheFooter"))
        }
    }

    private func refreshCacheSize() {
        let bytes = environment.translationStore.diskUsageBytes()
        cacheSize = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
