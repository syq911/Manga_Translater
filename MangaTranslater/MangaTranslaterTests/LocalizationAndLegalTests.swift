//
//  LocalizationAndLegalTests.swift
//  MangaTranslaterTests
//
//  M5「中英双语文案复核」的验收用例。
//
//  这类缺陷的特点是**编译器完全看不见**：
//
//  1. `Localizable.strings` 里少了一条 key → 界面上直接显示 key 字符串；
//  2. 包层文案表没被打进 App（`Bundle.module` 找不到资源）→ 全部退化成 key；
//  3. 两种语言的 key 集合不一致 → 某个语言缺文案；
//  4. 隐私政策 / 使用条款的**设备端副本与正式文本分叉** →
//     用户在 App 里看到的那一份与官网上不是同一份（法务文本上这属于误导）。
//
//  Python 侧（`tools/check_localization.py`、`tools/check_legal_sync.py`）已经能在
//  推送前拦下这些问题；这里再钉一遍，是为了让**CI 也有一道**：
//  Python 工具只在本地预检里跑，而 CI 只跑 Swift 测试。
//

import Foundation
import Testing
import AppCore
@testable import MangaTranslater

@Suite("本地化与法务文案")
struct LocalizationAndLegalTests {

    // MARK: 仓库内文件的定位

    /// 仓库根目录（由本文件路径反推）。
    ///
    /// 测试在 CI 上也是从仓库里跑的，所以按路径读源码文件是可行的；
    /// 这也是本项目既有的做法（`DemoCorpus` / `SourceAPIDocTests` 同理）。
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MangaTranslaterTests
            .deletingLastPathComponent()   // MangaTranslater
            .deletingLastPathComponent()   // 仓库根
    }

    private static let appTableDir = "MangaTranslater/Resources"
    private static let packageTableDir = "Packages/AppCore/Sources/AppCore/Resources"
    private static let languages = ["en", "zh-Hans"]

    /// 极简 `.strings` 解析：本项目只用 `"key" = "value";` 这一种形式。
    private static func strings(at path: String) throws -> [String: String] {
        let url = repositoryRoot.appendingPathComponent(path)
        let text = try String(contentsOf: url, encoding: .utf8)
        var entries: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\""), trimmed.hasSuffix(";") else { continue }
            let parts = trimmed.split(separator: "\"", omittingEmptySubsequences: false)
            // ["", key, " = ", value, ";"]
            guard parts.count >= 4 else { continue }
            entries[String(parts[1])] = String(parts[3])
        }
        return entries
    }

    private static func tables(in directory: String) throws -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        for language in languages {
            result[language] = try strings(at: "\(directory)/\(language).lproj/Localizable.strings")
        }
        return result
    }

    private static func check(_ directory: String, label: String) throws {
        let tables = try tables(in: directory)
        let reference = try #require(tables["en"])
        for (language, entries) in tables {
            let missing = Set(reference.keys).subtracting(entries.keys).sorted()
            let extra = Set(entries.keys).subtracting(reference.keys).sorted()
            #expect(entries.count > 100, "\(label)/\(language) 的文案条数异常：\(entries.count)")
            #expect(missing.isEmpty, "\(label)/\(language) 缺少：\(missing.prefix(5))")
            #expect(extra.isEmpty, "\(label)/\(language) 多出：\(extra.prefix(5))")
        }
        for (key, value) in reference {
            #expect(!value.isEmpty, "\(label)/en 的 \(key) 是空的")
        }
    }

    // MARK: 两张文案表

    @Test("App 表两种语言的 key 集合一致且都有值")
    func appTableIsConsistent() throws {
        try Self.check(Self.appTableDir, label: "App 表")
    }

    @Test("包层表两种语言的 key 集合一致且都有值")
    func packageTableIsConsistent() throws {
        try Self.check(Self.packageTableDir, label: "包层表")
    }

    @Test("两张表不得重名（取错表的表现是界面上冒出一串 key）")
    func tablesDoNotOverlap() throws {
        let app = try #require(try Self.tables(in: Self.appTableDir)["en"])
        let package = try #require(try Self.tables(in: Self.packageTableDir)["en"])
        #expect(Set(app.keys).isDisjoint(with: Set(package.keys)))
    }

    @Test("包层文案真的解析到了内容（资源包被装进 App）")
    func packageCopyResolves() {
        // 资源包缺失时会回落到 key 本身；这条断言就是钉住「回落没有发生」。
        for key in ["error.runner.cancelled", "error.app.cancelled", "error.zip.emptyArchive"] {
            let value = Copy.text(key)
            #expect(!value.isEmpty)
            #expect(value != key, "\(key) 没有解析到文案（资源包是否漏打包？）")
        }
    }

    @Test("带占位符的包层文案会被正确格式化")
    func packageCopyFormatsArguments() {
        let message = Copy.format("error.runner.timeout", 30)
        // 无论中英，秒数都必须在结果里出现（占位符没被吃掉）。
        #expect(message.contains("30"))
    }

    // MARK: 法务文案

    /// 三份文档 ×（正式文本 ↔ App 内置副本）。
    private static let legalPairs = [
        ("privacy", LegalText.privacyEnglish, "privacy.en.md"),
        ("privacy", LegalText.privacyChinese, "privacy.zh-Hans.md"),
        ("terms", LegalText.termsEnglish, "terms.en.md"),
        ("terms", LegalText.termsChinese, "terms.zh-Hans.md"),
        ("licenses", LegalText.licensesEnglish, "licenses.en.md"),
        ("licenses", LegalText.licensesChinese, "licenses.zh-Hans.md"),
    ]

    @Test("App 内置的法务文本与 docs/legal 逐字一致")
    func legalCopiesMatchDocumentation() throws {
        for (name, embedded, fileName) in Self.legalPairs {
            let url = Self.repositoryRoot.appendingPathComponent("docs/legal/\(fileName)")
            let source = try String(contentsOf: url, encoding: .utf8)
            let expected = source
                .replacingOccurrences(of: "\r\n", with: "\n")
                .trimmingCharacters(in: .newlines)
            let actual = embedded.trimmingCharacters(in: .newlines)
            #expect(
                actual == expected,
                "\(name)/\(fileName) 与 App 内置副本不一致；以 docs/legal 为准，运行 tools/check_legal_sync.py --emit"
            )
        }
    }

    @Test("法务文本覆盖了必须写进去的承诺")
    func legalTextsCoverRequiredPoints() {
        // 手册第 10.3 条要求的几件事，逐条都必须在正文里能查到。
        let privacy = LegalText.privacyEnglish + LegalText.privacyChinese
        #expect(privacy.contains("18"))                       // 年龄条款
        #expect(privacy.lowercased().contains("delete"))      // 账号注销（英文）
        #expect(privacy.contains("注销"))                      // 账号注销（中文）
        #expect(privacy.lowercased().contains("retention") || privacy.contains("保留"))

        let terms = LegalText.termsEnglish + LegalText.termsChinese
        #expect(terms.contains("18"))
        #expect(terms.lowercased().contains("adult") || terms.contains("成人"))
        #expect(terms.lowercased().contains("lemon squeezy"))  // 收款方具名
        #expect(terms.contains("Apache"))                      // 开源许可

        #expect(LegalText.licensesEnglish.contains("Apache"))
        #expect(LegalText.licensesChinese.contains("Apache"))
    }

    @Test("法务文本能被渲染器解析出标题、小节与表格")
    func legalMarkdownParses() {
        for (name, embedded, _) in Self.legalPairs {
            let blocks = LegalMarkdown.parse(embedded)
            #expect(blocks.count > 10, "\(name) 解析出的块太少：\(blocks.count)")
            var titles = 0
            var headings = 0
            var rows = 0
            var bullets = 0
            for block in blocks {
                switch block {
                case .title: titles += 1
                case .heading: headings += 1
                case .row: rows += 1
                case .bullet: bullets += 1
                default: break
                }
            }
            #expect(titles == 1, "\(name) 应有且仅有一个大标题")
            // 各文档的小节数不同（开源许可比隐私政策短），这里只要求「结构成篇」。
            #expect(headings >= 3, "\(name) 的小节太少：\(headings)")
            // 隐私政策与条款用列表，开源许可主要用表格——两者至少有一种。
            #expect(bullets + rows > 0, "\(name) 既没有列表也没有表格")
        }
    }

    @Test("渲染器会去掉行内标记，不留 Markdown 记号给用户看")
    func markdownPlainStripsInlineMarkup() {
        let plain = LegalMarkdown.plain("**粗体** 与 `代码` 与 [链接](https://example.com)")
        #expect(!plain.contains("**"))
        #expect(!plain.contains("`"))
        #expect(plain.contains("粗体"))
        #expect(plain.contains("https://example.com"))
    }
}
