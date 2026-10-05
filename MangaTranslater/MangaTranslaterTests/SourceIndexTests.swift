//
//  SourceIndexTests.swift
//  MangaTranslaterTests
//
//  覆盖源仓库索引解析：正常条目、字段缺失 / 类型错误、重复 key、
//  路径穿越与非法文件名、体积与条目数上限、下载地址拼接。
//

import Testing
import Foundation
import AppCore
import SourceEngine

@Suite("源仓库索引")
struct SourceIndexTests {

    private func json(_ text: String) -> Data { Data(text.utf8) }

    // MARK: 正常路径

    @Test("解析合法索引")
    func parsesValidIndex() throws {
        let data = json("""
        [
          { "name": "示例源", "fileName": "example.js", "key": "example", "version": "1.0.0" },
          { "name": "另一个", "fileName": "other.js", "key": "other", "version": "2.1", "description": "说明" }
        ]
        """)

        let entries = try SourceIndexParser.parse(data: data)
        #expect(entries.count == 2)
        #expect(entries[0].key == "example")
        #expect(entries[0].description == nil)
        #expect(entries[1].description == "说明")
    }

    @Test("空描述被归一化为 nil")
    func emptyDescriptionBecomesNil() throws {
        let data = json("""
        [{ "name": "n", "fileName": "a.js", "key": "a", "version": "1", "description": "   " }]
        """)
        let entries = try SourceIndexParser.parse(data: data)
        #expect(entries[0].description == nil)
    }

    @Test("脚本下载地址按目录拼接")
    func buildsScriptURL() throws {
        let entry = SourceIndexEntry(name: "n", fileName: "a.js", key: "a", version: "1")
        let url = SourceIndexParser.scriptURL(
            for: entry,
            repositoryURL: "https://raw.githubusercontent.com/owner/repo/main/index.json"
        )
        #expect(url == "https://raw.githubusercontent.com/owner/repo/main/a.js")
    }

    @Test("非法仓库地址不产生下载地址")
    func rejectsNonHTTPRepository() {
        let entry = SourceIndexEntry(name: "n", fileName: "a.js", key: "a", version: "1")
        #expect(SourceIndexParser.scriptURL(for: entry, repositoryURL: "file:///tmp/index.json") == nil)
        #expect(SourceIndexParser.scriptURL(for: entry, repositoryURL: "no-slash") == nil)
    }

    // MARK: 异常分支

    @Test("非法 JSON 被拒绝")
    func rejectsInvalidJSON() {
        do {
            _ = try SourceIndexParser.parse(data: json("{ not json"))
            Issue.record("应当抛错")
        } catch let error as SourceIndexError {
            if case .invalidJSON = error { } else { Issue.record("错误类型不符：\(error)") }
        } catch {
            Issue.record("未预期错误：\(error)")
        }
    }

    @Test("根节点不是数组被拒绝")
    func rejectsNonArrayRoot() {
        do {
            _ = try SourceIndexParser.parse(data: json("{\"a\":1}"))
            Issue.record("应当抛错")
        } catch let error as SourceIndexError {
            if case .invalidJSON = error { } else { Issue.record("错误类型不符：\(error)") }
        } catch {
            Issue.record("未预期错误：\(error)")
        }
    }

    @Test("空数组被拒绝")
    func rejectsEmptyArray() {
        expectThrows(SourceIndexError.emptyIndex) {
            _ = try SourceIndexParser.parse(data: self.json("[]"))
        }
    }

    @Test("空数据被拒绝")
    func rejectsEmptyData() {
        do {
            _ = try SourceIndexParser.parse(data: Data())
            Issue.record("应当抛错")
        } catch let error as SourceIndexError {
            if case .invalidJSON = error { } else { Issue.record("错误类型不符：\(error)") }
        } catch {
            Issue.record("未预期错误：\(error)")
        }
    }

    @Test("字段缺失被拒绝", arguments: [
        "[{ \"fileName\": \"a.js\", \"key\": \"a\", \"version\": \"1\" }]",
        "[{ \"name\": \"n\", \"key\": \"a\", \"version\": \"1\" }]",
        "[{ \"name\": \"n\", \"fileName\": \"a.js\", \"version\": \"1\" }]",
        "[{ \"name\": \"n\", \"fileName\": \"a.js\", \"key\": \"a\" }]",
    ])
    func rejectsMissingFields(payload: String) {
        do {
            _ = try SourceIndexParser.parse(data: json(payload))
            Issue.record("应当抛错")
        } catch let error as SourceIndexError {
            if case .invalidEntry = error { } else { Issue.record("错误类型不符：\(error)") }
        } catch {
            Issue.record("未预期错误：\(error)")
        }
    }

    @Test("字段类型错误被拒绝")
    func rejectsWrongType() {
        let payload = "[{ \"name\": 123, \"fileName\": \"a.js\", \"key\": \"a\", \"version\": \"1\" }]"
        do {
            _ = try SourceIndexParser.parse(data: json(payload))
            Issue.record("应当抛错")
        } catch let error as SourceIndexError {
            if case .invalidEntry = error { } else { Issue.record("错误类型不符：\(error)") }
        } catch {
            Issue.record("未预期错误：\(error)")
        }
    }

    @Test("重复 key 被拒绝")
    func rejectsDuplicateKeys() {
        let payload = """
        [
          { "name": "n1", "fileName": "a.js", "key": "dup", "version": "1" },
          { "name": "n2", "fileName": "b.js", "key": "dup", "version": "1" }
        ]
        """
        expectThrows(SourceIndexError.duplicateKey("dup")) {
            _ = try SourceIndexParser.parse(data: self.json(payload))
        }
    }

    @Test("非法 key 被拒绝")
    func rejectsInvalidKey() {
        let payload = "[{ \"name\": \"n\", \"fileName\": \"a.js\", \"key\": \"Bad Key\", \"version\": \"1\" }]"
        do {
            _ = try SourceIndexParser.parse(data: json(payload))
            Issue.record("应当抛错")
        } catch let error as SourceIndexError {
            if case .invalidEntry = error { } else { Issue.record("错误类型不符：\(error)") }
        } catch {
            Issue.record("未预期错误：\(error)")
        }
    }

    @Test("非法版本号被拒绝")
    func rejectsInvalidVersion() {
        let payload = "[{ \"name\": \"n\", \"fileName\": \"a.js\", \"key\": \"a\", \"version\": \"v1\" }]"
        do {
            _ = try SourceIndexParser.parse(data: json(payload))
            Issue.record("应当抛错")
        } catch let error as SourceIndexError {
            if case .invalidEntry = error { } else { Issue.record("错误类型不符：\(error)") }
        } catch {
            Issue.record("未预期错误：\(error)")
        }
    }

    // MARK: 路径穿越

    @Test("危险文件名被拒绝", arguments: [
        "../../../evil.js",
        "sub/dir.js",
        "..\\evil.js",
        ".hidden.js",
        "script.txt",
        "script.js.txt",
        "no-extension",
        "",
    ])
    func rejectsUnsafeFileNames(fileName: String) {
        #expect(!SourceIndexParser.isSafeFileName(fileName))
    }

    @Test("索引中含路径穿越条目时整体被拒绝")
    func rejectsTraversalEntry() {
        let payload = """
        [{ "name": "evil", "fileName": "../../evil.js", "key": "evil", "version": "1" }]
        """
        do {
            _ = try SourceIndexParser.parse(data: json(payload))
            Issue.record("应当抛错")
        } catch let error as SourceIndexError {
            if case .unsafeFileName = error { } else { Issue.record("错误类型不符：\(error)") }
        } catch {
            Issue.record("未预期错误：\(error)")
        }
    }

    @Test("合法文件名通过", arguments: ["a.js", "my-source.js", "source_1.js", "A1.js"])
    func acceptsSafeFileNames(fileName: String) {
        #expect(SourceIndexParser.isSafeFileName(fileName))
    }

    // MARK: 上限

    @Test("条目数超过上限被拒绝")
    func rejectsTooManyEntries() {
        let items = (0..<(SourceIndexParser.maxEntries + 1))
            .map { "{ \"name\": \"n\($0)\", \"fileName\": \"a\($0).js\", \"key\": \"k\($0)\", \"version\": \"1\" }" }
            .joined(separator: ",")
        do {
            _ = try SourceIndexParser.parse(data: json("[\(items)]"))
            Issue.record("应当抛错")
        } catch let error as SourceIndexError {
            if case .tooManyEntries = error { } else { Issue.record("错误类型不符：\(error)") }
        } catch {
            Issue.record("未预期错误：\(error)")
        }
    }

    @Test("索引体积超过上限被拒绝")
    func rejectsOversizedIndex() {
        let padding = String(repeating: " ", count: SourceIndexParser.maxIndexBytes + 10)
        let payload = "[{ \"name\": \"n\", \"fileName\": \"a.js\", \"key\": \"a\", \"version\": \"1\" }]\(padding)"
        do {
            _ = try SourceIndexParser.parse(data: json(payload))
            Issue.record("应当抛错")
        } catch let error as SourceIndexError {
            if case .tooLarge = error { } else { Issue.record("错误类型不符：\(error)") }
        } catch {
            Issue.record("未预期错误：\(error)")
        }
    }

    @Test("边界：恰好达到条目上限时通过")
    func acceptsExactlyMaxEntries() throws {
        let items = (0..<SourceIndexParser.maxEntries)
            .map { "{ \"name\": \"n\($0)\", \"fileName\": \"a\($0).js\", \"key\": \"k\($0)\", \"version\": \"1\" }" }
            .joined(separator: ",")
        let entries = try SourceIndexParser.parse(data: json("[\(items)]"))
        #expect(entries.count == SourceIndexParser.maxEntries)
    }
}
