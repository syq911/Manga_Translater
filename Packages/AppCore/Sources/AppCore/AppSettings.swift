//
//  AppSettings.swift
//  AppCore
//
//  应用设置。全部取值都经过范围钳制与合法性检查，非法输入不会写入。
//
//  设计要点：
//  - `UserDefaults` 可注入，测试用独立 suite，互不干扰。
//  - 读写加锁，保证并发调用安全（设置可能被多个任务同时读写）。
//  - `snapshot()` / `apply(_:)` 支持备份与恢复，恢复时忽略非法值而不是整体失败。
//

import Foundation

/// 翻译后端。
public enum TranslationBackend: String, Codable, Sendable, CaseIterable {
    /// 用户自备 API Key（免费，额度由用户自己的账号承担）。
    case bringYourOwnKey
    /// 官方云服务（免配置，按额度计费）。
    case cloudService
    /// 系统端上翻译（设备能力受限）。
    case appleOnDevice

    // 界面文案刻意**不在这里**：本包拿不到 App 目标的 `L()`，
    // 留一个中文 `displayName` 就等于把「英文界面显示中文」固化下来。
    // 展示名见 App 层 `Localization+Names.swift`（`localizedName`）。
}

/// 阅读模式。
public enum ReaderMode: String, Codable, Sendable, CaseIterable {
    case pagedLeftToRight
    case pagedRightToLeft
    case continuousVertical
    case doublePage
}

/// 阅读器外观主题（阅读区背景）。
///
/// `system` 表示跟随系统深浅色；其余为固定背景，用于长时间阅读时减少眩光。
public enum ReaderTheme: String, Codable, Sendable, CaseIterable {
    case system
    case light
    case sepia
    case dark
    case black
}

/// 翻译语言。`visionLanguages` 用于 OCR 语言提示，`isSource` 决定能否作为原文语言。
public enum TranslationLanguage: String, Codable, Sendable, CaseIterable {
    case auto
    case japanese = "ja"
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case korean = "ko"

    /// 传给 Vision 的语言列表；`auto` 表示交由系统自动检测。
    public var visionLanguages: [String] {
        switch self {
        case .auto: return ["ja-JP", "zh-Hans", "zh-Hant", "en-US"]
        case .japanese: return ["ja-JP"]
        case .english: return ["en-US"]
        case .simplifiedChinese: return ["zh-Hans"]
        case .traditionalChinese: return ["zh-Hant"]
        case .korean: return ["ko-KR"]
        }
    }

    /// 写进翻译提示词的语言名。`auto` 留空，交给模型自行判断源语言。
    ///
    /// 这**不是**界面文案，而是「给模型看的、与设备语言无关的固定词表」：
    /// 它必须稳定——同一页在两台语言不同的设备上要产生同样的请求，
    /// 否则「同一话翻译结果不一样」这类问题根本无从复现。
    /// 正因为如此，这里的字面量不应改走本地化（`// i18n-exempt`）。
    public var promptName: String {
        switch self {
        case .auto: return ""
        case .japanese: return "日文"      // i18n-exempt：模型侧固定词表，不随界面语言变化
        case .english: return "英文"       // i18n-exempt
        case .simplifiedChinese: return "简体中文"  // i18n-exempt
        case .traditionalChinese: return "繁体中文" // i18n-exempt
        case .korean: return "韩文"        // i18n-exempt
        }
    }

    /// 可作为「译文语言」的取值：`auto` 只能是原文语言。
    public static var targetChoices: [TranslationLanguage] {
        allCases.filter { $0 != .auto }
    }
}

/// 备份 / 恢复用的设置快照。
///
/// **向后兼容**：解码走 `decodeIfPresent + 默认值`，因此旧版本导出的备份
/// （缺少后加的字段）恢复时不会失败，缺失项按当前默认值处理。
public struct SettingsSnapshot: Codable, Equatable, Sendable {
    public var readerMode: ReaderMode
    public var readerTheme: ReaderTheme
    public var fontScale: Double
    public var preloadWindow: Int
    public var readerPageSpacing: Int
    public var keepsScreenAwake: Bool
    public var maxConcurrentDownloads: Int
    public var requestTimeoutSeconds: Int
    public var translationBackend: TranslationBackend
    public var sourceLanguage: TranslationLanguage
    public var targetLanguage: TranslationLanguage
    public var usesLineDropFallback: Bool
    public var showsNSFWSources: Bool
    public var hasConfirmedAdultContent: Bool
    public var deepSeekBaseURL: String
    public var deepSeekModel: String
    public var translationUsesSampledBackground: Bool
    public var translationShowsOriginalText: Bool
    public var translationPrefetchWindow: Int
    public var cloudServiceBaseURL: String
    public var cloudUpgradeURL: String
    public var preferredLanguages: [String]

    public init(
        readerMode: ReaderMode = .pagedRightToLeft,
        readerTheme: ReaderTheme = .system,
        fontScale: Double = AppSettings.defaultFontScale,
        preloadWindow: Int = AppSettings.defaultPreloadWindow,
        readerPageSpacing: Int = AppSettings.defaultReaderPageSpacing,
        keepsScreenAwake: Bool = true,
        maxConcurrentDownloads: Int = AppSettings.defaultMaxConcurrentDownloads,
        requestTimeoutSeconds: Int = AppSettings.defaultRequestTimeoutSeconds,
        translationBackend: TranslationBackend = .bringYourOwnKey,
        sourceLanguage: TranslationLanguage = .auto,
        targetLanguage: TranslationLanguage = .simplifiedChinese,
        usesLineDropFallback: Bool = true,
        showsNSFWSources: Bool = false,
        hasConfirmedAdultContent: Bool = false,
        deepSeekBaseURL: String = AppSettings.defaultDeepSeekBaseURL,
        deepSeekModel: String = AppSettings.defaultDeepSeekModel,
        translationUsesSampledBackground: Bool = true,
        translationShowsOriginalText: Bool = false,
        translationPrefetchWindow: Int = AppSettings.defaultTranslationPrefetchWindow,
        cloudServiceBaseURL: String = AppSettings.defaultCloudServiceBaseURL,
        cloudUpgradeURL: String = AppSettings.defaultCloudUpgradeURL,
        preferredLanguages: [String] = ["zh-Hans", "en"]
    ) {
        self.readerMode = readerMode
        self.readerTheme = readerTheme
        self.fontScale = fontScale
        self.preloadWindow = preloadWindow
        self.readerPageSpacing = readerPageSpacing
        self.keepsScreenAwake = keepsScreenAwake
        self.maxConcurrentDownloads = maxConcurrentDownloads
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.translationBackend = translationBackend
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.usesLineDropFallback = usesLineDropFallback
        self.showsNSFWSources = showsNSFWSources
        self.hasConfirmedAdultContent = hasConfirmedAdultContent
        self.deepSeekBaseURL = deepSeekBaseURL
        self.deepSeekModel = deepSeekModel
        self.translationUsesSampledBackground = translationUsesSampledBackground
        self.translationShowsOriginalText = translationShowsOriginalText
        self.translationPrefetchWindow = translationPrefetchWindow
        self.cloudServiceBaseURL = cloudServiceBaseURL
        self.cloudUpgradeURL = cloudUpgradeURL
        self.preferredLanguages = preferredLanguages
    }

    private enum CodingKeys: String, CodingKey {
        case readerMode, readerTheme, fontScale, preloadWindow, readerPageSpacing, keepsScreenAwake
        case maxConcurrentDownloads, requestTimeoutSeconds
        case translationBackend, sourceLanguage, targetLanguage, usesLineDropFallback
        case showsNSFWSources, hasConfirmedAdultContent
        case deepSeekBaseURL, deepSeekModel, preferredLanguages
        case translationUsesSampledBackground, translationShowsOriginalText
        case translationPrefetchWindow
        case cloudServiceBaseURL, cloudUpgradeURL
    }

    /// 容错解码：缺失 / 类型不符的字段一律回退到默认值。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = SettingsSnapshot()

        /// 逐字段取值：`decodeIfPresent` 对「键不存在」与「值为 null」都返回 nil，
        /// 类型不符则抛错 —— 后者也应当被吞掉，所以整体再兜一层 try?。
        func value<T: Decodable>(_ type: T.Type, _ key: CodingKeys, _ fallbackValue: T) -> T {
            (try? container.decodeIfPresent(type, forKey: key)) ?? fallbackValue
        }
        func rawValue<T: RawRepresentable>(_ type: T.Type, _ key: CodingKeys, _ fallbackValue: T) -> T
        where T.RawValue == String {
            guard let raw = try? container.decodeIfPresent(String.self, forKey: key) else { return fallbackValue }
            return T(rawValue: raw) ?? fallbackValue
        }

        self.readerMode = rawValue(ReaderMode.self, .readerMode, fallback.readerMode)
        self.readerTheme = rawValue(ReaderTheme.self, .readerTheme, fallback.readerTheme)
        self.fontScale = value(Double.self, .fontScale, fallback.fontScale)
        self.preloadWindow = value(Int.self, .preloadWindow, fallback.preloadWindow)
        self.readerPageSpacing = value(Int.self, .readerPageSpacing, fallback.readerPageSpacing)
        self.keepsScreenAwake = value(Bool.self, .keepsScreenAwake, fallback.keepsScreenAwake)
        self.maxConcurrentDownloads = value(Int.self, .maxConcurrentDownloads, fallback.maxConcurrentDownloads)
        self.requestTimeoutSeconds = value(Int.self, .requestTimeoutSeconds, fallback.requestTimeoutSeconds)
        self.translationBackend = rawValue(TranslationBackend.self, .translationBackend, fallback.translationBackend)
        self.sourceLanguage = rawValue(TranslationLanguage.self, .sourceLanguage, fallback.sourceLanguage)
        self.targetLanguage = rawValue(TranslationLanguage.self, .targetLanguage, fallback.targetLanguage)
        self.usesLineDropFallback = value(Bool.self, .usesLineDropFallback, fallback.usesLineDropFallback)
        self.showsNSFWSources = value(Bool.self, .showsNSFWSources, fallback.showsNSFWSources)
        self.hasConfirmedAdultContent = value(Bool.self, .hasConfirmedAdultContent, fallback.hasConfirmedAdultContent)
        self.deepSeekBaseURL = value(String.self, .deepSeekBaseURL, fallback.deepSeekBaseURL)
        self.deepSeekModel = value(String.self, .deepSeekModel, fallback.deepSeekModel)
        self.translationUsesSampledBackground = value(
            Bool.self,
            .translationUsesSampledBackground,
            fallback.translationUsesSampledBackground
        )
        self.translationShowsOriginalText = value(
            Bool.self,
            .translationShowsOriginalText,
            fallback.translationShowsOriginalText
        )
        self.translationPrefetchWindow = value(
            Int.self,
            .translationPrefetchWindow,
            fallback.translationPrefetchWindow
        )
        self.cloudServiceBaseURL = value(String.self, .cloudServiceBaseURL, fallback.cloudServiceBaseURL)
        self.cloudUpgradeURL = value(String.self, .cloudUpgradeURL, fallback.cloudUpgradeURL)
        self.preferredLanguages = value([String].self, .preferredLanguages, fallback.preferredLanguages)
    }
}

/// 应用设置存取。
public final class AppSettings: @unchecked Sendable {

    // MARK: 默认值与范围

    /// 默认云端翻译服务地址（OpenAI 兼容）。
    public static let defaultDeepSeekBaseURL = "https://api.deepseek.com"
    /// 默认模型。注意：`deepseek-chat` 别名已由官方弃用，不要回退到它。
    public static let defaultDeepSeekModel = "deepseek-v4-flash"
    /// 默认云服务端点（官方托管的翻译代理 / 账号 / 额度接口）。
    ///
    /// 这只是**默认值**：自建部署的用户可以在设置里改到自己的地址。
    /// 客户端与服务端的契约见 `docs/cloud-api.md`。
    public static let defaultCloudServiceBaseURL = "https://api.mangatranslater.com"
    /// 官网根地址。App 里的法务文本（隐私政策 / 使用条款 / 开源许可）
    /// 会带一个「在官网查看」的入口指向它的对应页面；
    /// 官网页面由 `tools/build_website.py` 从 `docs/legal/*.md` 生成。
    public static let defaultWebsiteURL = "https://mangatranslater.com"
    /// 默认的「升级 Pro」落地页（官网购买页，在浏览器里打开）。
    public static let defaultCloudUpgradeURL = defaultWebsiteURL + "/upgrade"
    /// 翻译预取窗口默认值（当前页前后各 N 页）。
    ///
    /// 刻意远小于阅读器的**图片**预加载窗口（默认 10）：看图是免费的，
    /// 翻译是按页计费/耗额度的，默认值必须保守；想连着往后看更远的用户
    /// 可以在设置里调大，代价是额度消耗更快。
    public static let defaultTranslationPrefetchWindow = 2
    /// 翻译预取窗口范围。
    public static let translationPrefetchWindowRange: ClosedRange<Int> = 0...10

    /// 字号缩放范围。
    public static let fontScaleRange: ClosedRange<Double> = 0.5...2.0
    /// 字号缩放默认值（1.0 = 原尺寸）。
    public static let defaultFontScale: Double = 1.0
    /// 条漫模式下页与页之间的间距默认值（点）。
    public static let defaultReaderPageSpacing = 0
    /// 页间距范围（点）。
    public static let readerPageSpacingRange: ClosedRange<Int> = 0...60
    /// 预加载窗口默认值。
    public static let defaultPreloadWindow = 10
    /// 下载并发默认值。
    public static let defaultMaxConcurrentDownloads = 3
    /// 请求超时默认值（秒）。
    public static let defaultRequestTimeoutSeconds = 15
    /// 预加载窗口范围（当前页前后各 N 页）。
    public static let preloadWindowRange: ClosedRange<Int> = 1...50
    /// 下载并发上限。来源可能进一步限制（规范建议单来源 ≤3）。
    public static let maxConcurrentDownloadsRange: ClosedRange<Int> = 1...4
    /// 请求超时范围（秒）。
    public static let requestTimeoutRange: ClosedRange<Int> = 5...60

    private enum Key {
        static let prefix = "mangatranslater."
        static let readerMode = prefix + "readerMode"
        static let readerTheme = prefix + "readerTheme"
        static let readerPageSpacing = prefix + "readerPageSpacing"
        static let keepsScreenAwake = prefix + "keepsScreenAwake"
        static let fontScale = prefix + "fontScale"
        static let preloadWindow = prefix + "preloadWindow"
        static let maxConcurrentDownloads = prefix + "maxConcurrentDownloads"
        static let requestTimeoutSeconds = prefix + "requestTimeoutSeconds"
        static let translationBackend = prefix + "translationBackend"
        static let sourceLanguage = prefix + "sourceLanguage"
        static let targetLanguage = prefix + "targetLanguage"
        static let usesLineDropFallback = prefix + "usesLineDropFallback"
        static let showsNSFWSources = prefix + "showsNSFWSources"
        static let hasConfirmedAdultContent = prefix + "hasConfirmedAdultContent"
        static let deepSeekBaseURL = prefix + "deepSeekBaseURL"
        static let deepSeekModel = prefix + "deepSeekModel"
        static let translationUsesSampledBackground = prefix + "translationUsesSampledBackground"
        static let translationShowsOriginalText = prefix + "translationShowsOriginalText"
        static let translationPrefetchWindow = prefix + "translationPrefetchWindow"
        static let cloudServiceBaseURL = prefix + "cloudServiceBaseURL"
        static let cloudUpgradeURL = prefix + "cloudUpgradeURL"
        static let preferredLanguages = prefix + "preferredLanguages"
    }

    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 存储键前缀，供备份 / 迁移使用。
    public static var storageKeyPrefix: String { Key.prefix }

    // MARK: 读取 / 写入

    private func read<T>(_ key: String, fallback: T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return defaults.object(forKey: key) as? T ?? fallback
    }

    private func write(_ value: Any, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        defaults.set(value, forKey: key)
    }

    // MARK: 阅读器

    public var readerMode: ReaderMode {
        get {
            let stored: String = read(Key.readerMode, fallback: ReaderMode.pagedRightToLeft.rawValue)
            return ReaderMode(rawValue: stored) ?? .pagedRightToLeft
        }
        set { write(newValue.rawValue, for: Key.readerMode) }
    }

    /// 阅读区外观主题。
    public var readerTheme: ReaderTheme {
        get {
            let stored: String = read(Key.readerTheme, fallback: ReaderTheme.system.rawValue)
            return ReaderTheme(rawValue: stored) ?? .system
        }
        set { write(newValue.rawValue, for: Key.readerTheme) }
    }

    /// 条漫模式下页与页之间的间距（点），自动钳制到 `readerPageSpacingRange`。
    public var readerPageSpacing: Int {
        get { Self.clamp(read(Key.readerPageSpacing, fallback: AppSettings.defaultReaderPageSpacing), to: Self.readerPageSpacingRange) }
        set { write(Self.clamp(newValue, to: Self.readerPageSpacingRange), for: Key.readerPageSpacing) }
    }

    /// 阅读时是否保持屏幕常亮。
    public var keepsScreenAwake: Bool {
        get { read(Key.keepsScreenAwake, fallback: true) }
        set { write(newValue, for: Key.keepsScreenAwake) }
    }

    /// 字号缩放，取值自动钳制到 `fontScaleRange`。`NaN` / 无穷大回退到 1.0。
    public var fontScale: Double {
        get {
            let stored = read(Key.fontScale, fallback: AppSettings.defaultFontScale)
            return Self.clampFontScale(stored)
        }
        set { write(Self.clampFontScale(newValue), for: Key.fontScale) }
    }

    /// 预加载窗口，自动钳制到 `preloadWindowRange`。
    public var preloadWindow: Int {
        get { Self.clamp(read(Key.preloadWindow, fallback: AppSettings.defaultPreloadWindow), to: Self.preloadWindowRange) }
        set { write(Self.clamp(newValue, to: Self.preloadWindowRange), for: Key.preloadWindow) }
    }

    /// 下载并发数，自动钳制到 `maxConcurrentDownloadsRange`。
    public var maxConcurrentDownloads: Int {
        get { Self.clamp(read(Key.maxConcurrentDownloads, fallback: AppSettings.defaultMaxConcurrentDownloads), to: Self.maxConcurrentDownloadsRange) }
        set { write(Self.clamp(newValue, to: Self.maxConcurrentDownloadsRange), for: Key.maxConcurrentDownloads) }
    }

    /// 单次请求超时（秒），自动钳制到 `requestTimeoutRange`。
    public var requestTimeoutSeconds: Int {
        get { Self.clamp(read(Key.requestTimeoutSeconds, fallback: AppSettings.defaultRequestTimeoutSeconds), to: Self.requestTimeoutRange) }
        set { write(Self.clamp(newValue, to: Self.requestTimeoutRange), for: Key.requestTimeoutSeconds) }
    }

    // MARK: 翻译

    public var translationBackend: TranslationBackend {
        get {
            let stored: String = read(Key.translationBackend, fallback: TranslationBackend.bringYourOwnKey.rawValue)
            return TranslationBackend(rawValue: stored) ?? .bringYourOwnKey
        }
        set { write(newValue.rawValue, for: Key.translationBackend) }
    }

    public var sourceLanguage: TranslationLanguage {
        get {
            let stored: String = read(Key.sourceLanguage, fallback: TranslationLanguage.auto.rawValue)
            return TranslationLanguage(rawValue: stored) ?? .auto
        }
        set { write(newValue.rawValue, for: Key.sourceLanguage) }
    }

    public var targetLanguage: TranslationLanguage {
        get {
            let stored: String = read(Key.targetLanguage, fallback: TranslationLanguage.simplifiedChinese.rawValue)
            return TranslationLanguage(rawValue: stored) ?? .simplifiedChinese
        }
        set { write(newValue.rawValue, for: Key.targetLanguage) }
    }

    /// 漏行兜底（针对已知系统 OCR 漏行问题的兼容手段），默认开启。
    public var usesLineDropFallback: Bool {
        get { read(Key.usesLineDropFallback, fallback: true) }
        set { write(newValue, for: Key.usesLineDropFallback) }
    }

    /// 自备密钥模式下的服务地址。空值或非法地址回退到默认值。
    public var deepSeekBaseURL: String {
        get {
            let stored = read(Key.deepSeekBaseURL, fallback: Self.defaultDeepSeekBaseURL)
            return ModelValidation.isValidURLString(stored) ? stored : Self.defaultDeepSeekBaseURL
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            write(ModelValidation.isValidURLString(trimmed) ? trimmed : Self.defaultDeepSeekBaseURL, for: Key.deepSeekBaseURL)
        }
    }

    /// 自备密钥模式下的模型名。空值回退到默认模型。
    public var deepSeekModel: String {
        get {
            let stored = read(Key.deepSeekModel, fallback: Self.defaultDeepSeekModel)
            return Self.isValidModelName(stored) ? stored : Self.defaultDeepSeekModel
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            write(Self.isValidModelName(trimmed) ? trimmed : Self.defaultDeepSeekModel, for: Key.deepSeekModel)
        }
    }

    /// 排版：盖住原文框时是否取样周边底色（关闭则用纯白）。
    public var translationUsesSampledBackground: Bool {
        get { read(Key.translationUsesSampledBackground, fallback: true) }
        set { write(newValue, for: Key.translationUsesSampledBackground) }
    }

    /// 排版：是否在译文旁额外标注一行小号原文。
    public var translationShowsOriginalText: Bool {
        get { read(Key.translationShowsOriginalText, fallback: false) }
        set { write(newValue, for: Key.translationShowsOriginalText) }
    }

    /// 翻译预取窗口，自动钳制到 `translationPrefetchWindowRange`。
    public var translationPrefetchWindow: Int {
        get {
            Self.clamp(
                read(Key.translationPrefetchWindow, fallback: Self.defaultTranslationPrefetchWindow),
                to: Self.translationPrefetchWindowRange
            )
        }
        set { write(Self.clamp(newValue, to: Self.translationPrefetchWindowRange), for: Key.translationPrefetchWindow) }
    }

    /// 云服务端点。非法地址回退到默认值（否则会让「云服务」入口永久不可用）。
    public var cloudServiceBaseURL: String {
        get {
            let stored = read(Key.cloudServiceBaseURL, fallback: Self.defaultCloudServiceBaseURL)
            return ModelValidation.isValidURLString(stored) ? stored : Self.defaultCloudServiceBaseURL
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            write(
                ModelValidation.isValidURLString(trimmed) ? trimmed : Self.defaultCloudServiceBaseURL,
                for: Key.cloudServiceBaseURL
            )
        }
    }

    /// 「升级 Pro」跳转的官网地址。非法地址回退到默认值。
    public var cloudUpgradeURL: String {
        get {
            let stored = read(Key.cloudUpgradeURL, fallback: Self.defaultCloudUpgradeURL)
            return ModelValidation.isValidURLString(stored) ? stored : Self.defaultCloudUpgradeURL
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            write(
                ModelValidation.isValidURLString(trimmed) ? trimmed : Self.defaultCloudUpgradeURL,
                for: Key.cloudUpgradeURL
            )
        }
    }

    /// 界面语言偏好顺序。
    public var preferredLanguages: [String] {
        get {
            let stored = read(Key.preferredLanguages, fallback: ["zh-Hans", "en"])
            return stored.isEmpty ? ["zh-Hans", "en"] : stored
        }
        set {
            let cleaned = newValue
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            write(cleaned.isEmpty ? ["zh-Hans", "en"] : cleaned, for: Key.preferredLanguages)
        }
    }

    // MARK: 成人内容门槛

    /// 用户是否已确认年满 18 岁。开启 NSFW 源的前提。
    public var hasConfirmedAdultContent: Bool {
        get { read(Key.hasConfirmedAdultContent, fallback: false) }
        set { write(newValue, for: Key.hasConfirmedAdultContent) }
    }

    /// 是否显示 NSFW 源。**未确认年龄时无法打开**（写入被拒绝）。
    /// - Returns: 是否成功设置为目标值。
    @discardableResult
    public func setShowsNSFWSources(_ enabled: Bool) -> Bool {
        guard enabled else {
            write(false, for: Key.showsNSFWSources)
            return true
        }
        guard hasConfirmedAdultContent else {
            write(false, for: Key.showsNSFWSources)
            return false
        }
        write(true, for: Key.showsNSFWSources)
        return true
    }

    public var showsNSFWSources: Bool {
        // 即使存储被外部写脏，也必须同时满足「已确认年龄」，否则一律视为关闭。
        read(Key.showsNSFWSources, fallback: false) && hasConfirmedAdultContent
    }

    // MARK: 快照

    public func snapshot() -> SettingsSnapshot {
        SettingsSnapshot(
            readerMode: readerMode,
            readerTheme: readerTheme,
            fontScale: fontScale,
            preloadWindow: preloadWindow,
            readerPageSpacing: readerPageSpacing,
            keepsScreenAwake: keepsScreenAwake,
            maxConcurrentDownloads: maxConcurrentDownloads,
            requestTimeoutSeconds: requestTimeoutSeconds,
            translationBackend: translationBackend,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            usesLineDropFallback: usesLineDropFallback,
            showsNSFWSources: showsNSFWSources,
            hasConfirmedAdultContent: hasConfirmedAdultContent,
            deepSeekBaseURL: deepSeekBaseURL,
            deepSeekModel: deepSeekModel,
            translationUsesSampledBackground: translationUsesSampledBackground,
            translationShowsOriginalText: translationShowsOriginalText,
            translationPrefetchWindow: translationPrefetchWindow,
            cloudServiceBaseURL: cloudServiceBaseURL,
            cloudUpgradeURL: cloudUpgradeURL,
            preferredLanguages: preferredLanguages
        )
    }

    /// 应用快照。非法值被忽略（保留当前值），不抛错——恢复备份不应导致 App 不可用。
    public func apply(_ snapshot: SettingsSnapshot) {
        fontScale = snapshot.fontScale
        readerTheme = snapshot.readerTheme
        readerPageSpacing = snapshot.readerPageSpacing
        keepsScreenAwake = snapshot.keepsScreenAwake
        preloadWindow = snapshot.preloadWindow
        maxConcurrentDownloads = snapshot.maxConcurrentDownloads
        requestTimeoutSeconds = snapshot.requestTimeoutSeconds
        readerMode = snapshot.readerMode
        translationBackend = snapshot.translationBackend
        sourceLanguage = snapshot.sourceLanguage
        targetLanguage = snapshot.targetLanguage
        usesLineDropFallback = snapshot.usesLineDropFallback
        hasConfirmedAdultContent = snapshot.hasConfirmedAdultContent
        deepSeekBaseURL = snapshot.deepSeekBaseURL
        deepSeekModel = snapshot.deepSeekModel
        translationUsesSampledBackground = snapshot.translationUsesSampledBackground
        translationShowsOriginalText = snapshot.translationShowsOriginalText
        translationPrefetchWindow = snapshot.translationPrefetchWindow
        cloudServiceBaseURL = snapshot.cloudServiceBaseURL
        cloudUpgradeURL = snapshot.cloudUpgradeURL
        preferredLanguages = snapshot.preferredLanguages
        // NSFW 开关最后处理：它依赖年龄确认，且写入可能被拒绝。
        setShowsNSFWSources(snapshot.showsNSFWSources)
    }

    /// 恢复出厂设置。
    public func resetToDefaults() {
        apply(SettingsSnapshot())
    }

    // MARK: 工具

    static func clamp<T: Comparable>(_ value: T, to range: ClosedRange<T>) -> T {
        if value < range.lowerBound { return range.lowerBound }
        if value > range.upperBound { return range.upperBound }
        return value
    }

    static func clampFontScale(_ value: Double) -> Double {
        guard value.isFinite else { return AppSettings.defaultFontScale }
        return clamp(value, to: fontScaleRange)
    }

    /// 模型名只允许字母、数字、`.` `-` `_` `/`，长度 1...128。
    static func isValidModelName(_ value: String) -> Bool {
        guard (1...128).contains(value.count) else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_/")
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
