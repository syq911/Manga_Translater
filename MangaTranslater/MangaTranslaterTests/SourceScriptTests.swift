//
//  SourceScriptTests.swift
//  MangaTranslaterTests
//
//  覆盖源脚本静态校验：元信息提取、必需字段、非法值、体积与内容防御、
//  以及契约方法预检。
//

import Testing
import Foundation
import AppCore
import SourceEngine

@Suite("源脚本静态校验")
struct SourceScriptTests {

    private let validScript = """
    // 示例源（仅用于测试，不含任何真实站点）
    const source = {
      id: "demo",
      name: "示例源",
      lang: "zh",
      baseUrl: "https://example.com",
      nsfw: false,
      version: "1.0.0",
      rateLimitMs: 500,
      loginUrl: "https://example.com/login"
    };

    async function getPopularManga(page) { return { mangas: [], hasNextPage: false }; }
    async function getSearchManga(page, query, filters) { return { mangas: [], hasNextPage: false }; }
    async function getMangaDetails(mangaUrl) { return { title: "t" }; }
    async function getChapterList(mangaUrl) { return []; }
    async function getPageList(chapterUrl) { return []; }
    """

    // MARK: 正常路径

    @Test("合法脚本可提取全部元信息")
    func validatesCompleteScript() throws {
        let meta = try SourceScriptValidator.validate(validScript)

        #expect(meta.id == SourceID("demo"))
        #expect(meta.name == "示例源")
        #expect(meta.language == "zh")
        #expect(meta.baseURL == "https://example.com")
        #expect(meta.isNSFW == false)
        #expect(meta.version == "1.0.0")
        #expect(meta.rateLimitMilliseconds == 500)
        #expect(meta.loginURL == "https://example.com/login")
    }

    @Test("nsfw 可识别多种写法", arguments: ["true", "TRUE", "1", "yes"])
    func parsesNSFWTrue(value: String) throws {
        let script = """
        const source = { id: "s", name: "n", nsfw: \(value) };
        """
        #expect(try SourceScriptValidator.validate(script).isNSFW)
    }

    @Test("nsfw 缺省或 false 视为非成人源", arguments: ["false", "0", "no"])
    func parsesNSFWFalse(value: String) throws {
        let script = "const source = { id: \"s\", name: \"n\", nsfw: \(value) };"
        #expect(try SourceScriptValidator.validate(script).isNSFW == false)
    }

    @Test("缺省字段使用安全默认值")
    func defaultsForOptionalFields() throws {
        let script = "const source = { id: \"minimal\", name: \"Minimal\" };"
        let meta = try SourceScriptValidator.validate(script)

        #expect(meta.language == "all")
        #expect(meta.baseURL == nil)
        #expect(meta.version == nil)
        #expect(meta.rateLimitMilliseconds == 0)
        #expect(meta.loginURL == nil)
        #expect(meta.isNSFW == false)
    }

    @Test("未被引号包裹的值也能解析")
    func parsesUnquotedValues() throws {
        let script = "const source = { id: 'single', name: `tick`, version: 2.1 };"
        let meta = try SourceScriptValidator.validate(script)
        #expect(meta.id == SourceID("single"))
        #expect(meta.name == "tick")
        #expect(meta.version == "2.1")
    }

    // MARK: 异常分支

    @Test("空脚本被拒绝", arguments: ["", "   ", "\n\t"])
    func rejectsEmpty(script: String) {
        expectThrows(SourceScriptValidationError.emptyScript) {
            _ = try SourceScriptValidator.validate(script)
        }
    }

    @Test("缺少元信息块被拒绝")
    func rejectsMissingMetadata() {
        expectThrows(SourceScriptValidationError.missingMetadataBlock) {
            _ = try SourceScriptValidator.validate("function getPageList() { return []; }")
        }
    }

    @Test("缺少 id / name 被拒绝")
    func rejectsMissingRequiredFields() {
        expectThrows(SourceScriptValidationError.missingField("id")) {
            _ = try SourceScriptValidator.validate("const source = { name: \"n\" };")
        }
        expectThrows(SourceScriptValidationError.missingField("name")) {
            _ = try SourceScriptValidator.validate("const source = { id: \"x\" };")
        }
    }

    @Test("非法 id 被拒绝")
    func rejectsInvalidID() {
        do {
            _ = try SourceScriptValidator.validate("const source = { id: \"Bad-ID\", name: \"n\" };")
            Issue.record("应当抛错")
        } catch let error as SourceScriptValidationError {
            if case let .invalidField(name, _) = error {
                #expect(name == "id")
            } else {
                Issue.record("错误类型不符：\(error)")
            }
        } catch {
            Issue.record("未预期错误：\(error)")
        }
    }

    @Test("非法 baseUrl 被拒绝")
    func rejectsInvalidBaseURL() {
        do {
            _ = try SourceScriptValidator.validate("const source = { id: \"a\", name: \"n\", baseUrl: \"http://evil.example.com\" };")
            Issue.record("应当抛错")
        } catch let error as SourceScriptValidationError {
            if case let .invalidField(name, _) = error {
                #expect(name == "baseUrl")
            } else {
                Issue.record("错误类型不符：\(error)")
            }
        } catch {
            Issue.record("未预期错误：\(error)")
        }
    }

    @Test("非法版本号被拒绝")
    func rejectsInvalidVersion() {
        do {
            _ = try SourceScriptValidator.validate("const source = { id: \"a\", name: \"n\", version: \"v1\" };")
            Issue.record("应当抛错")
        } catch let error as SourceScriptValidationError {
            if case let .invalidField(name, _) = error {
                #expect(name == "version")
            } else {
                Issue.record("错误类型不符：\(error)")
            }
        } catch {
            Issue.record("未预期错误：\(error)")
        }
    }

    @Test("rateLimitMs 边界：非法值被拒绝", arguments: ["-1", "abc", "60001", "1.5"])
    func rejectsInvalidRateLimit(value: String) {
        do {
            _ = try SourceScriptValidator.validate("const source = { id: \"a\", name: \"n\", rateLimitMs: \(value) };")
            Issue.record("应当抛错")
        } catch let error as SourceScriptValidationError {
            if case let .invalidField(name, _) = error {
                #expect(name == "rateLimitMs")
            } else {
                Issue.record("错误类型不符：\(error)")
            }
        } catch {
            Issue.record("未预期错误：\(error)")
        }
    }

    @Test("边界：rateLimitMs 允许 0 与上限值", arguments: ["0", "60000"])
    func acceptsRateLimitBoundaries(value: String) throws {
        let script = "const source = { id: \"a\", name: \"n\", rateLimitMs: \(value) };"
        let meta = try SourceScriptValidator.validate(script)
        #expect(meta.rateLimitMilliseconds == Int(value))
    }

    // MARK: 内容防御

    @Test("超过体积上限的脚本被拒绝")
    func rejectsTooLarge() {
        let huge = "const source = { id: \"a\", name: \"n\" };\n" + String(repeating: "// padding\n", count: 50_000)
        do {
            _ = try SourceScriptValidator.validate(huge)
            Issue.record("应当抛错")
        } catch let error as SourceScriptValidationError {
            if case .tooLarge = error {
                // 预期
            } else {
                Issue.record("错误类型不符：\(error)")
            }
        } catch {
            Issue.record("未预期错误：\(error)")
        }
    }

    @Test("包含空字节的脚本被拒绝")
    func rejectsNullByte() {
        let script = "const source = { id: \"a\", name: \"n\" };\u{0}"
        expectThrows(SourceScriptValidationError.containsNullByte) {
            _ = try SourceScriptValidator.validate(script)
        }
    }

    @Test("动态求值与模块系统被拒绝", arguments: ["eval(", "Function(", "WebAssembly", "import(", "require("])
    func rejectsForbiddenAPIs(api: String) {
        let script = "const source = { id: \"a\", name: \"n\" };\n\(api)\"x\")"
        do {
            _ = try SourceScriptValidator.validate(script)
            Issue.record("应当抛错：\(api)")
        } catch let error as SourceScriptValidationError {
            if case .forbiddenAPI = error {
                // 预期
            } else {
                Issue.record("错误类型不符：\(error)")
            }
        } catch {
            Issue.record("未预期错误：\(error)")
        }
    }

    @Test("超长名称被拒绝")
    func rejectsTooLongName() {
        let longName = String(repeating: "あ", count: 201)
        do {
            _ = try SourceScriptValidator.validate("const source = { id: \"a\", name: \"\(longName)\" };")
            Issue.record("应当抛错")
        } catch let error as SourceScriptValidationError {
            if case let .invalidField(name, _) = error {
                #expect(name == "name")
            } else {
                Issue.record("错误类型不符：\(error)")
            }
        } catch {
            Issue.record("未预期错误：\(error)")
        }
    }

    // MARK: 解析细节

    @Test("花括号配平可跨越嵌套对象")
    func metadataBlockHandlesNestedBraces() throws {
        let script = """
        const source = {
          id: "nested",
          name: "嵌套",
          extra: { a: { b: 1 } }
        };
        """
        let meta = try SourceScriptValidator.validate(script)
        #expect(meta.id == SourceID("nested"))
    }

    @Test("字符串中的花括号不影响解析")
    func metadataBlockIgnoresBracesInStrings() throws {
        let script = "const source = { id: \"s\", name: \"a { b } c\" };"
        let meta = try SourceScriptValidator.validate(script)
        #expect(meta.name == "a { b } c")
    }

    @Test("可识别声明的能力开关")
    func detectsCapabilities() throws {
        let script = """
        const source = { id: "cap", name: "c", login: "https://example.com/login", filters: [] };
        function getPopularManga() {}
        """
        let meta = try SourceScriptValidator.validate(script)
        #expect(meta.declaredCapabilities.contains("login"))
        #expect(meta.declaredCapabilities.contains("filters"))
    }

    // MARK: 契约预检

    @Test("完整实现五个必需方法时契约通过")
    func contractComplete() {
        #expect(SourceAPIContract.isComplete(validScript))
        #expect(SourceAPIContract.missingMethods(in: validScript).isEmpty)
    }

    @Test("缺少必需方法时能列出缺失项")
    func contractMissing() {
        let script = "const source = { id: \"x\", name: \"n\" }; function getPopularManga() {}"
        let missing = SourceAPIContract.missingMethods(in: script).map(\.rawValue)
        #expect(missing.contains("getSearchManga"))
        #expect(missing.contains("getMangaDetails"))
        #expect(!missing.contains("getPopularManga"))
    }

    @Test("契约版本与必需方法集合稳定")
    func contractShape() {
        #expect(SourceAPIContract.version == "1.0")
        #expect(SourceAPIContract.requiredMethods.count == 5)
        #expect(SourceAPIContract.optionalMethods.count == 2)
    }
}
