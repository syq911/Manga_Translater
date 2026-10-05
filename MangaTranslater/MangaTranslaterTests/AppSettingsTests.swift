//
//  AppSettingsTests.swift
//  MangaTranslaterTests
//
//  覆盖设置读写、范围钳制、非法输入回退、NSFW 年龄门槛、快照往返与重置。
//

import Testing
import Foundation
import AppCore

@Suite("应用设置")
struct AppSettingsTests {

    private func makeSettings() throws -> (AppSettings, UserDefaults, String) {
        let suiteName = "MangaTranslaterTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (AppSettings(defaults: defaults), defaults, suiteName)
    }

    // MARK: 默认值

    @Test("默认值符合产品约定")
    func defaults() throws {
        let (settings, defaults, suite) = try makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(settings.fontScale == 1.0)
        #expect(settings.preloadWindow == 10)
        #expect(settings.maxConcurrentDownloads == 3)
        #expect(settings.requestTimeoutSeconds == 15)
        #expect(settings.translationBackend == .bringYourOwnKey)
        #expect(settings.sourceLanguage == .auto)
        #expect(settings.targetLanguage == .simplifiedChinese)
        #expect(settings.usesLineDropFallback == true)
        #expect(settings.showsNSFWSources == false)
        #expect(settings.hasConfirmedAdultContent == false)
        #expect(settings.deepSeekModel == "deepseek-v4-flash")
        #expect(settings.deepSeekBaseURL == "https://api.deepseek.com")
        #expect(settings.preferredLanguages == ["zh-Hans", "en"])
    }

    @Test("默认模型不是已弃用的 deepseek-chat")
    func defaultModelIsNotDeprecatedAlias() throws {
        let (settings, defaults, suite) = try makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(settings.deepSeekModel != "deepseek-chat")
    }

    // MARK: 边界钳制

    @Test("字号低于下限被钳制")
    func clampsFontScaleLowerBound() throws {
        let (settings, defaults, suite) = try makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        settings.fontScale = 0.01
        #expect(settings.fontScale == AppSettings.fontScaleRange.lowerBound)
    }

    @Test("字号高于上限被钳制")
    func clampsFontScaleUpperBound() throws {
        let (settings, defaults, suite) = try makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        settings.fontScale = 99
        #expect(settings.fontScale == AppSettings.fontScaleRange.upperBound)
    }

    @Test("非有限字号回退到 1.0", arguments: [Double.nan, .infinity, -.infinity])
    func nonFiniteFontScaleFallsBack(value: Double) throws {
        let (settings, defaults, suite) = try makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        settings.fontScale = value
        #expect(settings.fontScale == 1.0)
    }

    @Test("预加载窗口越界被钳制")
    func clampsPreloadWindow() throws {
        let (settings, defaults, suite) = try makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        settings.preloadWindow = 0
        #expect(settings.preloadWindow == AppSettings.preloadWindowRange.lowerBound)
        settings.preloadWindow = 999
        #expect(settings.preloadWindow == AppSettings.preloadWindowRange.upperBound)
    }

    @Test("下载并发与超时被钳制")
    func clampsConcurrencyAndTimeout() throws {
        let (settings, defaults, suite) = try makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        settings.maxConcurrentDownloads = -5
        #expect(settings.maxConcurrentDownloads == AppSettings.maxConcurrentDownloadsRange.lowerBound)
        settings.requestTimeoutSeconds = 1
        #expect(settings.requestTimeoutSeconds == AppSettings.requestTimeoutRange.lowerBound)
        settings.requestTimeoutSeconds = 600
        #expect(settings.requestTimeoutSeconds == AppSettings.requestTimeoutRange.upperBound)
    }

    // MARK: 非法输入回退

    @Test("非法服务地址回退到默认值")
    func invalidBaseURLFallsBack() throws {
        let (settings, defaults, suite) = try makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        settings.deepSeekBaseURL = "not a url"
        #expect(settings.deepSeekBaseURL == AppSettings.defaultDeepSeekBaseURL)
        settings.deepSeekBaseURL = "https://api.example.com"
        #expect(settings.deepSeekBaseURL == "https://api.example.com")
    }

    @Test("非法模型名回退到默认模型")
    func invalidModelFallsBack() throws {
        let (settings, defaults, suite) = try makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        settings.deepSeekModel = "model with space"
        #expect(settings.deepSeekModel == AppSettings.defaultDeepSeekModel)
        settings.deepSeekModel = ""
        #expect(settings.deepSeekModel == AppSettings.defaultDeepSeekModel)
        settings.deepSeekModel = "deepseek-v4-pro"
        #expect(settings.deepSeekModel == "deepseek-v4-pro")
    }

    @Test("超长模型名被拒绝")
    func tooLongModelRejected() throws {
        let (settings, defaults, suite) = try makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        settings.deepSeekModel = String(repeating: "a", count: 129)
        #expect(settings.deepSeekModel == AppSettings.defaultDeepSeekModel)
    }

    @Test("空语言偏好回退到默认值")
    func emptyLanguagesFallBack() throws {
        let (settings, defaults, suite) = try makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        settings.preferredLanguages = ["", "   "]
        #expect(settings.preferredLanguages == ["zh-Hans", "en"])
    }

    // MARK: NSFW 门槛

    @Test("未确认年龄时无法开启 NSFW 源")
    func cannotEnableNSFWWithoutAgeConfirmation() throws {
        let (settings, defaults, suite) = try makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }

        let result = settings.setShowsNSFWSources(true)
        #expect(result == false)
        #expect(settings.showsNSFWSources == false)
    }

    @Test("确认年龄后可开启，再次关闭可直接生效")
    func enableAfterConfirmation() throws {
        let (settings, defaults, suite) = try makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }

        settings.hasConfirmedAdultContent = true
        #expect(settings.setShowsNSFWSources(true))
        #expect(settings.showsNSFWSources)

        #expect(settings.setShowsNSFWSources(false))
        #expect(settings.showsNSFWSources == false)
    }

    @Test("存储被外部写脏时仍然受年龄门槛约束")
    func dirtyStorageStillGated() throws {
        let (settings, defaults, suite) = try makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }

        // 绕过 API 直接把开关写成 true
        defaults.set(true, forKey: AppSettings.storageKeyPrefix + "showsNSFWSources")
        #expect(settings.showsNSFWSources == false)

        settings.hasConfirmedAdultContent = true
        #expect(settings.showsNSFWSources == true)
    }

    // MARK: 快照

    @Test("快照往返保持一致")
    func snapshotRoundTrip() throws {
        let (settings, defaults, suite) = try makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }

        settings.fontScale = 1.5
        settings.preloadWindow = 20
        settings.readerMode = .continuousVertical
        settings.translationBackend = .cloudService
        settings.hasConfirmedAdultContent = true
        settings.setShowsNSFWSources(true)

        let snapshot = settings.snapshot()
        settings.resetToDefaults()
        #expect(settings.fontScale == 1.0)
        #expect(settings.readerMode == .pagedRightToLeft)

        settings.apply(snapshot)
        #expect(settings.fontScale == 1.5)
        #expect(settings.preloadWindow == 20)
        #expect(settings.readerMode == .continuousVertical)
        #expect(settings.translationBackend == .cloudService)
        #expect(settings.showsNSFWSources)
    }

    @Test("恢复非法快照时忽略越界值而不崩溃")
    func applyInvalidSnapshotIsSafe() throws {
        let (settings, defaults, suite) = try makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }

        var bad = SettingsSnapshot()
        bad.fontScale = 1000
        bad.preloadWindow = -3
        bad.deepSeekModel = ""
        bad.showsNSFWSources = true
        bad.hasConfirmedAdultContent = false

        settings.apply(bad)

        #expect(settings.fontScale == AppSettings.fontScaleRange.upperBound)
        #expect(settings.preloadWindow == AppSettings.preloadWindowRange.lowerBound)
        #expect(settings.deepSeekModel == AppSettings.defaultDeepSeekModel)
        #expect(settings.showsNSFWSources == false)
    }

    @Test("重置回默认值")
    func resetToDefaults() throws {
        let (settings, defaults, suite) = try makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }

        settings.preloadWindow = 42
        settings.readerMode = .doublePage
        settings.resetToDefaults()

        #expect(settings.preloadWindow == 10)
        #expect(settings.readerMode == .pagedRightToLeft)
    }

    // MARK: 并发

    @Test("并发读写设置不崩溃且最终值确定")
    func concurrentAccessIsSafe() async throws {
        let (settings, defaults, suite) = try makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<50 {
                group.addTask {
                    settings.preloadWindow = index
                    _ = settings.preloadWindow
                }
                group.addTask {
                    settings.fontScale = 0.5 + Double(index % 10) / 10
                    _ = settings.fontScale
                }
            }
        }

        // 最终值必然落在合法范围内
        #expect(AppSettings.preloadWindowRange.contains(settings.preloadWindow))
        #expect(AppSettings.fontScaleRange.contains(settings.fontScale))
    }

    // MARK: 翻译语言

    @Test("语言映射到 Vision 语言列表")
    func visionLanguages() {
        #expect(TranslationLanguage.japanese.visionLanguages == ["ja-JP"])
        #expect(TranslationLanguage.auto.visionLanguages.count == 4)
        #expect(TranslationLanguage.simplifiedChinese.visionLanguages == ["zh-Hans"])
    }
}
