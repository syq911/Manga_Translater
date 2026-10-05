//
//  SourceAPIDocTests.swift
//  MangaTranslaterTests
//
//  守护 docs/source-api.md 里的「契约示例源」：
//  - 示例必须能通过静态校验（§4 的规则一条都不能踩）；
//  - 示例必须实现全部必需方法（§5.1）；
//  - 示例解析出的元信息必须与文档表格一致。
//
//  本文件里的示例字符串与文档中标记 `canonical-example` 的代码块**逐字一致**，
//  由 tools/check_docs_sync.py 在推送前比对。改文档就要同步改这里，反之亦然。
//

import Testing
import Foundation
import AppCore
import SourceEngine

@Suite("契约文档示例")
struct SourceAPIDocTests {

    /// 与 docs/source-api.md 中 `canonical-example` 代码块逐字一致。
    /// 结束定界符与其缩进必须与该块保持一致，Swift 才会剥掉这层缩进。
    static let canonicalExample = """
        // canonical-example：与测试夹具逐字一致，勿单独修改
        const source = {
          id: "demo",
          name: "Demo Source",
          lang: "all",
          baseUrl: "https://example.com",
          nsfw: false,
          version: "1.0.0",
          rateLimitMs: 500,
          loginUrl: "https://example.com/login"
        };

        async function getPopularManga(page) {
          const response = await net.get(source.baseUrl + "/popular?page=" + page);
          const doc = html.parse(response.body);
          const mangas = doc.select("div.item").map(function (node) {
            return {
              title: node.select("a.title").text(),
              coverUrl: node.select("img").attr("src"),
              url: node.select("a.title").attr("href")
            };
          });
          return { mangas: mangas, hasNextPage: doc.select("a.next").length > 0 };
        }

        async function getLatestUpdates(page) {
          const response = await net.get(source.baseUrl + "/latest?page=" + page);
          const doc = html.parse(response.body);
          const mangas = doc.select("div.item").map(function (node) {
            return {
              title: node.select("a.title").text(),
              coverUrl: node.select("img").attr("src"),
              url: node.select("a.title").attr("href")
            };
          });
          return { mangas: mangas, hasNextPage: doc.select("a.next").length > 0 };
        }

        async function getSearchManga(page, query, filters) {
          const url = source.baseUrl + "/search?q=" + encodeURIComponent(query) + "&page=" + page;
          const response = await net.get(url);
          const doc = html.parse(response.body);
          const mangas = doc.select("div.item").map(function (node) {
            return {
              title: node.select("a.title").text(),
              coverUrl: node.select("img").attr("src"),
              url: node.select("a.title").attr("href")
            };
          });
          return { mangas: mangas, hasNextPage: false };
        }

        async function getMangaDetails(mangaUrl) {
          const response = await net.get(mangaUrl);
          const doc = html.parse(response.body);
          return {
            title: doc.select("h1.title").text(),
            url: mangaUrl,
            author: doc.select("span.author").text(),
            description: doc.select("div.summary").text(),
            genres: [doc.select("span.genre").text()],
            status: "ongoing",
            coverUrl: doc.select("img.cover").attr("src")
          };
        }

        async function getChapterList(mangaUrl) {
          const response = await net.get(mangaUrl);
          const doc = html.parse(response.body);
          return doc.select("ul.chapters li").map(function (node) {
            return {
              name: node.select("a").text(),
              url: node.select("a").attr("href"),
              chapterNumber: 0,
              dateUpload: node.attr("data-date")
            };
          });
        }

        async function getPageList(chapterUrl) {
          const response = await net.get(chapterUrl);
          const doc = html.parse(response.body);
          return doc.select("div.page img").map(function (node) {
            return node.attr("data-src");
          });
        }

        function getFilters() {
          return [
            { type: "text", key: "author", name: "作者" },
            { type: "select", key: "genre", name: "分类", options: [{ label: "全部", value: "" }] },
            { type: "sort", key: "sort", name: "排序", options: [{ label: "最新", value: "latest" }] }
          ];
        }
        """

    @Test("示例通过静态校验")
    func examplePassesValidation() throws {
        let meta = try SourceScriptValidator.validate(Self.canonicalExample)

        #expect(meta.id == SourceID("demo"))
        #expect(meta.name == "Demo Source")
        #expect(meta.language == "all")
        #expect(meta.baseURL == "https://example.com")
        #expect(meta.isNSFW == false)
        #expect(meta.version == "1.0.0")
        #expect(meta.rateLimitMilliseconds == 500)
        #expect(meta.loginURL == "https://example.com/login")
    }

    @Test("示例实现全部必需方法")
    func exampleIsComplete() {
        #expect(SourceAPIContract.isComplete(Self.canonicalExample))
        #expect(SourceAPIContract.missingMethods(in: Self.canonicalExample).isEmpty)
    }

    @Test("示例同时提供两个可选方法")
    func exampleProvidesOptionalMethods() {
        let script = Self.canonicalExample
        for method in SourceAPIContract.optionalMethods {
            let implemented = method.functionPatterns.contains { script.contains($0) }
            #expect(implemented, "示例应实现可选方法 \(method.rawValue)")
        }
    }

    @Test("示例不含任何被禁用的 API", arguments: SourceScriptValidator.forbiddenAPIs)
    func exampleContainsNoForbiddenAPI(api: String) {
        #expect(!Self.canonicalExample.contains(api))
    }

    @Test("示例体积远低于上限")
    func exampleIsSmall() {
        #expect(Self.canonicalExample.utf8.count < SourceScriptValidator.maxScriptBytes)
    }

    @Test("文档声明的必需方法集合与实现一致")
    func documentedMethodSetMatchesImplementation() {
        let documented = ["getPopularManga", "getSearchManga", "getMangaDetails", "getChapterList", "getPageList"]
        #expect(SourceAPIContract.requiredMethods.map(\.rawValue).sorted() == documented.sorted())
        #expect(SourceAPIContract.version == "1.0")
    }

    @Test("示例用真实语法而非伪代码")
    func exampleUsesRealSyntax() {
        let script = Self.canonicalExample
        #expect(script.contains("const source = {"))
        #expect(script.contains("async function getPageList("))
        #expect(!script.contains("..."))
        #expect(!script.hasPrefix(" "), "多行字符串不应残留缩进")
    }
}
