//
//  SourceResponseDecoderTests.swift
//  MangaTranslaterTests
//
//  源响应解码的单测。
//
//  测试策略：这一层**不依赖 JavaScriptCore**——输入是 JSON 字符串、
//  输出是模型，因此可以用极小的夹具把「正常 / 异常 / 边界」全覆盖，
//  而且跑得飞快。真实脚本的端到端在 `SourceRunnerTests` 里。
//
//  覆盖重点（契约 §5.4、§9）：
//  - 相对地址补全、来源自定义标识、非法 scheme 拒绝；
//  - 字段缺失/类型不符时的容错与「丢弃计数」；
//  - 日期、状态、题材等弱类型字段的宽容解析；
//  - 整份结构不可用时抛 `invalidResponse`。
//

import Testing
import Foundation
import AppCore
@testable import SourceEngine

@Suite("源响应解码")
struct SourceResponseDecoderTests {

    // MARK: 工具

    private func decoder(baseURL: String? = "https://example.com") -> SourceResponseDecoder {
        SourceResponseDecoder(sourceID: SourceID("demo"), baseURL: baseURL)
    }

    /// 断言抛出 `invalidResponse`（消息内容不参与比较，只校验错误种类）。
    private func expectInvalidResponse(
        _ comment: Comment? = nil,
        _ body: () throws -> Void
    ) {
        do {
            try body()
            Issue.record(comment ?? "期望抛出 invalidResponse，但没有抛错")
        } catch let error as SourceRunnerError {
            guard case .invalidResponse = error else {
                Issue.record(comment ?? "错误类型不符：\(error)")
                return
            }
        } catch {
            Issue.record(comment ?? "错误类型不符：\(error)")
        }
    }

    // MARK: 列表

    @Test("作品列表：解析字段并补全相对地址")
    func decodesMangaList() throws {
        let json = """
        {"mangas":[{"title":"Alpha","url":"/m/1","coverUrl":"/c/1.jpg"}],"hasNextPage":true}
        """
        let outcome = try decoder().mangaList(from: json)
        #expect(outcome.skippedItems == 0)
        #expect(outcome.value.hasNextPage)
        #expect(outcome.value.items.count == 1)

        let manga = try #require(outcome.value.items.first)
        #expect(manga.title == "Alpha")
        #expect(manga.url == "https://example.com/m/1")
        #expect(manga.coverURL == "https://example.com/c/1.jpg")
        #expect(manga.id == "demo|https://example.com/m/1")
    }

    @Test("作品列表：丢弃缺 url 的条目并计数")
    func dropsEntriesWithoutURL() throws {
        let json = """
        {"mangas":[{"title":"A","url":"/m/1"},{"title":"B"},{"title":"C","url":""}],"hasNextPage":true}
        """
        let outcome = try decoder().mangaList(from: json)
        #expect(outcome.value.items.count == 1)
        #expect(outcome.skippedItems == 2)
        // 空列表不该宣称还有下一页（否则界面会翻出无限空页）
        let empty = try decoder().mangaList(from: #"{"mangas":[{"title":"B"}],"hasNextPage":true}"#)
        #expect(empty.value.items.isEmpty)
        #expect(empty.value.hasNextPage == false)
    }

    @Test("作品列表：缺 title 时用地址末段兜底")
    func derivesTitleFromURL() throws {
        let json = #"{"mangas":[{"url":"https://example.com/m/%E6%B5%8B%E8%AF%95"}]}"#
        let outcome = try decoder().mangaList(from: json)
        let manga = try #require(outcome.value.items.first)
        #expect(manga.title == "测试")
    }

    @Test("作品列表：裸数组与 null 都算合法输入")
    func acceptsArrayAndNull() throws {
        let array = try decoder().mangaList(from: #"[{"title":"A","url":"/m/1"}]"#)
        #expect(array.value.items.count == 1)
        #expect(array.value.hasNextPage == false)

        let null = try decoder().mangaList(from: "null")
        #expect(null.value.items.isEmpty)
        #expect(null.skippedItems == 0)
    }

    @Test("作品列表：hasNextPage 接受字符串与数字")
    func coercesHasNextPage() throws {
        let text = try decoder().mangaList(
            from: #"{"mangas":[{"url":"/m/1"}],"hasNextPage":"true"}"#
        )
        #expect(text.value.hasNextPage)

        let number = try decoder().mangaList(from: #"{"mangas":[{"url":"/m/1"}],"hasNextPage":1}"#)
        #expect(number.value.hasNextPage)

        let negative = try decoder().mangaList(from: #"{"mangas":[{"url":"/m/1"}],"hasNextPage":"no"}"#)
        #expect(negative.value.hasNextPage == false)
    }

    @Test("作品列表：非法 JSON / 非法结构都报 invalidResponse")
    func rejectsMalformedList() throws {
        expectInvalidResponse("非 JSON") {
            _ = try decoder().mangaList(from: "这不是 JSON")
        }
        expectInvalidResponse("空字符串") {
            _ = try decoder().mangaList(from: "   ")
        }
        expectInvalidResponse("顶层是数字") {
            _ = try decoder().mangaList(from: "42")
        }
    }

    @Test("作品列表：拒绝非 http(s) 的地址，但保留来源自定义标识")
    func rejectsUnsafeSchemes() throws {
        let json = """
        {"mangas":[{"title":"X","url":"javascript:alert(1)"},{"title":"Y","url":"series:123"}]}
        """
        let outcome = try decoder().mangaList(from: json)
        #expect(outcome.value.items.count == 1)
        #expect(outcome.skippedItems == 1)
        #expect(outcome.value.items.first?.url == "series:123")
    }

    @Test("作品列表：没有基地址时保留原始相对地址")
    func keepsRelativeURLWithoutBase() throws {
        let outcome = try decoder(baseURL: nil).mangaList(from: #"{"mangas":[{"title":"A","url":"/m/1"}]}"#)
        #expect(outcome.value.items.first?.url == "/m/1")
    }

    @Test("作品列表：coverUrl 为空值时不下发")
    func omitsEmptyCover() throws {
        let outcome = try decoder().mangaList(from: #"{"mangas":[{"title":"A","url":"/m/1","coverUrl":null}]}"#)
        #expect(outcome.value.items.first?.coverURL == nil)
    }

    // MARK: 详情

    @Test("作品详情：字段齐全")
    func decodesMangaDetails() throws {
        let json = """
        {
          "title": "Alpha",
          "author": "作者甲",
          "artist": "画师乙",
          "description": "摘要",
          "genres": ["冒险", "奇幻"],
          "status": "ongoing",
          "coverUrl": "/c/1.jpg"
        }
        """
        let manga = try decoder().mangaDetails(from: json, fallbackURL: "https://example.com/m/1")
        #expect(manga.title == "Alpha")
        #expect(manga.author == "作者甲")
        #expect(manga.artist == "画师乙")
        #expect(manga.summary == "摘要")
        #expect(manga.genres == ["冒险", "奇幻"])
        #expect(manga.status == .ongoing)
        #expect(manga.coverURL == "https://example.com/c/1.jpg")
        // 返回对象没带 url 时应回落到调用时传入的地址，主键才与列表里的条目一致
        #expect(manga.url == "https://example.com/m/1")
        #expect(manga.id == "demo|https://example.com/m/1")
    }

    @Test("作品详情：状态映射容错")
    func mapsStatusLeniently() throws {
        let cases: [(String, MangaStatus)] = [
            ("ongoing", .ongoing),
            ("FINISHED", .completed),
            ("Cancelled", .cancelled),
            ("hiatus", .hiatus),
            ("licensed", .licensed),
            ("完全不认识的值", .unknown),
        ]
        for (raw, expected) in cases {
            let json = "{\"title\":\"T\",\"url\":\"/m/1\",\"status\":\"\(raw)\"}"
            let manga = try decoder().mangaDetails(from: json, fallbackURL: "/m/1")
            #expect(manga.status == expected, "状态 \(raw) 应映射为 \(expected)")
        }
    }

    @Test("作品详情：题材接受单字符串与去重")
    func normalizesGenres() throws {
        let single = try decoder().mangaDetails(
            from: #"{"title":"T","url":"/m/1","genres":"冒险"}"#,
            fallbackURL: "/m/1"
        )
        #expect(single.genres == ["冒险"])

        let deduped = try decoder().mangaDetails(
            from: #"{"title":"T","url":"/m/1","genres":["冒险","冒险",""]}"#,
            fallbackURL: "/m/1"
        )
        #expect(deduped.genres == ["冒险"])
    }

    @Test("作品详情：非对象 / 无可用地址都报 invalidResponse")
    func rejectsBrokenDetails() throws {
        expectInvalidResponse("顶层是数组") {
            _ = try decoder().mangaDetails(from: "[]", fallbackURL: "https://example.com/m/1")
        }
        expectInvalidResponse("回落到空地址") {
            _ = try decoder(baseURL: nil).mangaDetails(from: #"{"title":"T"}"#, fallbackURL: "   ")
        }
    }

    // MARK: 章节

    @Test("章节列表：编号与日期容错")
    func decodesChapters() throws {
        let json = """
        [
          {"name":"第 1 话","url":"/c/1","chapterNumber":1,"dateUpload":"2024-01-02T03:04:05Z"},
          {"name":"","url":"/c/2","chapterNumber":"2.5","dateUpload":"不是日期"},
          {"url":"/c/3"}
        ]
        """
        let outcome = try decoder().chapters(from: json, mangaID: "manga-1", mangaURL: "https://example.com/m/1")
        #expect(outcome.skippedItems == 0)
        #expect(outcome.value.count == 3)

        let first = try #require(outcome.value.first)
        #expect(first.name == "第 1 话")
        #expect(first.chapterNumber == 1)
        #expect(first.dateUploaded != nil)
        #expect(first.id == "manga-1|https://example.com/c/1")

        let second = try #require(outcome.value.dropFirst().first)
        #expect(second.chapterNumber == 2.5)
        #expect(second.dateUploaded == nil)
        // 名称为空串时用地址末段兜底
        #expect(second.name == "2")

        let third = try #require(outcome.value.last)
        #expect(third.name == "3")
        #expect(third.chapterNumber == nil)
    }

    @Test("章节列表：丢弃缺 url 的条目并计数")
    func dropsChaptersWithoutURL() throws {
        let json = #"[{"name":"A"},{"name":"B","url":"/c/1"},42]"#
        let outcome = try decoder().chapters(from: json, mangaID: "m", mangaURL: nil)
        #expect(outcome.value.count == 1)
        #expect(outcome.skippedItems == 2)
    }

    @Test("章节列表：null 视为空，非数组报 invalidResponse")
    func rejectsBrokenChapterList() throws {
        let empty = try decoder().chapters(from: "null", mangaID: "m", mangaURL: nil)
        #expect(empty.value.isEmpty)
        expectInvalidResponse {
            _ = try decoder().chapters(from: #"{"chapters":[]}"#, mangaID: "m", mangaURL: nil)
        }
    }

    @Test("章节日期：支持 yyyy-MM-dd 与时间戳")
    func parsesFlexibleDates() throws {
        let json = """
        [{"url":"/c/1","dateUpload":"2024-03-04"},
         {"url":"/c/2","dateUpload":1700000000},
         {"url":"/c/3","dateUpload":"2024-03-04T05:06:07.890Z"}]
        """
        let outcome = try decoder().chapters(from: json, mangaID: "m", mangaURL: nil)
        #expect(outcome.value.count == 3)
        #expect(outcome.value[0].dateUploaded != nil)
        #expect(outcome.value[1].dateUploaded != nil)
        #expect(outcome.value[2].dateUploaded != nil)
    }

    @Test("可选字段回退：`null` 不应该吞掉备选字段")
    func fallsBackPastNull() throws {
        // `a ?? b` 只判 nil，而 JSON 的 null 会变成 NSNull（非 nil），
        // 早先的写法会让 `dateUpload: null` 白白盖掉 `dateUploaded`
        let json = #"[{"url":"/c/1","dateUpload":null,"dateUploaded":"2024-01-02T03:04:05Z"}]"#
        let outcome = try decoder().chapters(from: json, mangaID: "m", mangaURL: nil)
        #expect(outcome.value.first?.dateUploaded != nil)

        let details = try decoder().mangaDetails(
            from: #"{"title":"T","url":"/m/1","lastUpdated":null,"lastUpdatedAt":"2024-05-06T07:08:09Z"}"#,
            fallbackURL: "/m/1"
        )
        #expect(details.lastUpdated != nil)
    }

    // MARK: 页面

    @Test("页面列表：字符串与 PageRef 混用，序号连续")
    func decodesPages() throws {
        let json = """
        ["https://cdn.test/1.jpg",
         {"url":"https://cdn.test/2.jpg","headers":{"Referer":"https://example.com/"}},
         {"url":null},
         "javascript:alert(1)"]
        """
        let outcome = try decoder().pages(from: json, chapterURL: "https://example.com/c/1")
        #expect(outcome.skippedItems == 2)
        #expect(outcome.value.count == 2)
        #expect(outcome.value.map(\.index) == [0, 1])
        #expect(outcome.value[0].imageURL == "https://cdn.test/1.jpg")
        #expect(outcome.value[0].headers == nil)
        #expect(outcome.value[1].headers == ["Referer": "https://example.com/"])
    }

    @Test("页面列表：相对地址按章节地址补全")
    func resolvesPageURLs() throws {
        let json = #"["1.jpg","/img/2.jpg"]"#
        let outcome = try decoder().pages(from: json, chapterURL: "https://cdn.test/ch/9/")
        #expect(outcome.value.map(\.imageURL) == [
            "https://cdn.test/ch/9/1.jpg",
            "https://cdn.test/img/2.jpg",
        ])
    }

    @Test("页面列表：null 视为空，非数组报 invalidResponse")
    func rejectsBrokenPageList() throws {
        let empty = try decoder().pages(from: "null", chapterURL: nil)
        #expect(empty.value.isEmpty)
        expectInvalidResponse {
            _ = try decoder().pages(from: #"{"pages":[]}"#, chapterURL: nil)
        }
    }

    // MARK: 筛选项

    @Test("筛选项：四种类型与默认值")
    func decodesFilters() throws {
        let json = """
        [
          {"type":"text","key":"author","name":"作者"},
          {"type":"checkbox","key":"onlyComplete","name":"只看完结"},
          {"type":"select","key":"genre","name":"分类",
           "options":[{"label":"全部","value":""},{"label":"冒险","value":"adventure"}]},
          {"type":"sort","key":"sort","name":"排序","options":[{"label":"最新","value":"latest"}]}
        ]
        """
        let outcome = try decoder().filters(from: json)
        #expect(outcome.skippedItems == 0)
        #expect(outcome.value.count == 4)
        #expect(outcome.value.map(\.kind) == [.text, .checkbox, .select, .sort])
        #expect(outcome.value[0].defaultValue == "")
        #expect(outcome.value[2].options.count == 2)
        #expect(outcome.value[2].defaultValue == "")
        #expect(outcome.value[3].defaultValue == "latest")
        #expect(outcome.value.defaultValues()["sort"] == "latest")
        #expect(outcome.value.hasDuplicateKeys == false)
    }

    @Test("筛选项：丢弃不合法的条目并计数")
    func dropsBrokenFilters() throws {
        let json = """
        [
          {"type":"text","name":"没有 key"},
          {"type":"unknown","key":"k1","name":"未知类型"},
          {"type":"text","key":"dup","name":"第一个"},
          {"type":"text","key":"dup","name":"第二个"},
          {"type":"select","key":"empty","name":"没有候选项","options":[]},
          "不是对象"
        ]
        """
        let outcome = try decoder().filters(from: json)
        #expect(outcome.value.count == 1)
        #expect(outcome.value.first?.name == "第一个")
        #expect(outcome.skippedItems == 5)
    }

    @Test("筛选项：取值裁剪只保留已定义的键")
    func sanitizesFilterValues() throws {
        let json = #"[{"type":"text","key":"author","name":"作者"}]"#
        let filters = try decoder().filters(from: json).value
        let sanitized = filters.sanitize(["author": "某人", "已删除的筛选": "x"])
        #expect(sanitized == ["author": "某人"])
    }

    @Test("筛选项：null 视为无筛选，非数组报 invalidResponse")
    func rejectsBrokenFilters() throws {
        let empty = try decoder().filters(from: "null")
        #expect(empty.value.isEmpty)
        expectInvalidResponse {
            _ = try decoder().filters(from: #"{"filters":[]}"#)
        }
    }

    // MARK: 结果包装

    @Test("解码结果：变换后保留丢弃计数")
    func keepsSkippedCountWhenMapped() throws {
        let outcome = try decoder().mangaList(from: #"{"mangas":[{"title":"A"},{"title":"B","url":"/m/2"}]}"#)
        let mapped = outcome.map(\.items.count)
        #expect(mapped.value == 1)
        #expect(mapped.skippedItems == 1)
    }
}
