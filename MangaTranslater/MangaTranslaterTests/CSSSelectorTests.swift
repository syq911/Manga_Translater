//
//  CSSSelectorTests.swift
//  MangaTranslaterTests
//
//  CSS 选择器解析与匹配测试。
//
//  覆盖：四类简单选择器（类型/id/class/属性）、两种组合子、
//  结果去重与顺序、非法选择器报错，以及一段贴近真实源站点的页面结构。
//

import Testing
import Foundation
@testable import SourceEngine

@Suite("CSS 选择器")
struct CSSSelectorTests {

    /// 一段贴近漫画源列表页的夹具。
    static let listHTML = """
    <html><body>
      <div id="content">
        <div class="list">
          <div class="item">
            <a class="title" href="/m/1" data-id="1"><span>作品一</span></a>
            <img src="/c/1.jpg" data-src="/c/1-large.jpg">
            <span class="tag">连载中</span>
          </div>
          <div class="item">
            <a class="title" href="/m/2" data-id="2">作品二</a>
            <img src="/c/2.jpg" data-src="/c/2-large.jpg">
            <span class="tag">完结</span>
          </div>
        </div>
        <ul class="chapters">
          <li><a href="/c/1-1">第 1 话</a></li>
          <li><a href="/c/1-2">第 2 话</a></li>
        </ul>
      </div>
    </body></html>
    """

    static var document: HTMLDocument { HTMLParser.parse(listHTML) }

    // MARK: 简单选择器

    @Test("类型选择器")
    func selectByTag() throws {
        let items = try Self.document.select(".list > .item")
        #expect(items.count == 2)
        #expect(try Self.document.select("img").count == 2)
        #expect(try Self.document.select("nonexistent").isEmpty)
    }

    @Test("id 选择器")
    func selectByID() throws {
        let content = try Self.document.select("#content")
        #expect(content.count == 1)
        #expect(content.first?.tag == "div")
        #expect(try Self.document.select("#nope").isEmpty)

        // 类型 + id 组合：div#content 命中，a#content 不命中
        #expect(try Self.document.selectFirst("div#content")?.id == "content")
        #expect(try Self.document.selectFirst("a#content") == nil)
    }

    @Test("class 选择器（单个与多个）")
    func selectByClass() throws {
        #expect(try Self.document.select(".item").count == 2)
        #expect(try Self.document.select(".list").count == 1)
        #expect(try Self.document.select(".title").count == 2)
        // 多个 class 必须同时具备
        #expect(try Self.document.select(".item.title").isEmpty)
        #expect(try Self.document.select("a.title").count == 2)
    }

    @Test("通配选择器")
    func selectUniversal() throws {
        let all = try Self.document.select("*")
        #expect(all.count > 6)
        #expect(all.contains { $0.tag == "html" })
    }

    @Test("属性选择器：存在、相等、前缀、后缀、包含")
    func selectByAttribute() throws {
        #expect(try Self.document.select("[data-id]").count == 2)
        #expect(try Self.document.select("[data-id=\"2\"]").count == 1)
        #expect(try Self.document.select("[href^=\"/m/\"]").count == 2)
        #expect(try Self.document.select("[data-src$=\"-large.jpg\"]").count == 2)
        #expect(try Self.document.select("[href*=\"1-2\"]").count == 1)
        #expect(try Self.document.select("[data-id=\"9\"]").isEmpty)
    }

    @Test("属性选择器的引号可省略")
    func selectByAttributeWithoutQuotes() throws {
        #expect(try Self.document.select("[data-id=2]").count == 1)
        #expect(try Self.document.select("[class=title]").count == 2)
    }

    // MARK: 组合子

    @Test("后代组合子（可跨层级）")
    func selectsDescendants() throws {
        let anchors = try Self.document.select("#content a")
        #expect(anchors.count == 4)   // 2 个作品链接 + 2 个章节链接

        let spans = try Self.document.select("div span")
        #expect(spans.count == 3)     // 2 个 tag + 1 个标题内 span
    }

    @Test("直接子代组合子")
    func selectsChildren() throws {
        let direct = try Self.document.select(".list > .item")
        #expect(direct.count == 2)

        // img 不是 .list 的直接子代，因此不该命中
        #expect(try Self.document.select(".list > img").isEmpty)
        #expect(try Self.document.select(".list img").count == 2)
    }

    @Test("组合子两侧可以没有空格")
    func handlesCompactCombinator() throws {
        #expect(try Self.document.select(".list>.item").count == 2)
        #expect(try Self.document.select("#content>div").count == 1)
    }

    @Test("三步选择器")
    func selectsDeepChain() throws {
        let titles = try Self.document.select("html body #content .list .item a.title")
        #expect(titles.count == 2)
    }

    // MARK: 结果性质

    @Test("结果按文档顺序且不重复")
    func resultsAreOrderedAndUnique() throws {
        let anchors = try Self.document.select("a")
        #expect(anchors.count == 4)
        // 文档顺序：作品一、作品二、第 1 话、第 2 话
        #expect(anchors.map(\.textContent) == ["作品一", "作品二", "第 1 话", "第 2 话"])
        #expect(Set(anchors.map(\.nodeID)).count == 4)
    }

    @Test("多个 class 命中同一元素时只出现一次")
    func deduplicatesOverlappingMatches() throws {
        // `div div` 会让中间元素被多条路径匹配到
        let elements = try Self.document.select("div div")
        #expect(Set(elements.map(\.nodeID)).count == elements.count)
    }

    @Test("selectFirst 返回文档顺序中的第一个")
    func selectFirstReturnsFirst() throws {
        #expect(try Self.document.selectFirst(".item a")?.textContent == "作品一")
        #expect(try Self.document.selectFirst(".missing") == nil)
    }

    @Test("匹配范围限于给定子树")
    func scopesToSubtree() throws {
        let document = Self.document
        let list = try #require(try document.selectFirst(".list"))
        let scoped = try CSSSelectorEngine.select(".item", in: list)
        #expect(scoped.count == 2)

        // 子树里没有 ul.chapters
        #expect(try CSSSelectorEngine.select("ul", in: list).isEmpty)
    }

    // MARK: 文本与属性提取（源作者的实际用法）

    @Test("提取标题与链接（典型用法）")
    func extractsFields() throws {
        let document = Self.document
        let rows = try document.select(".item")
        let titles = try rows.map { try $0.selectFirst("a.title")?.textContent ?? "" }
        let links = try rows.map { try $0.selectFirst("a.title")?.attribute("href") ?? "" }
        let covers = try rows.map { try $0.selectFirst("img")?.attribute("data-src") ?? "" }

        #expect(titles == ["作品一", "作品二"])
        #expect(links == ["/m/1", "/m/2"])
        #expect(covers == ["/c/1-large.jpg", "/c/2-large.jpg"])
    }

    @Test("元素内继续查询")
    func queriesWithinElement() throws {
        let item = try #require(try Self.document.selectFirst(".item"))
        #expect(try item.select(".tag").count == 1)
        #expect(try item.selectFirst(".tag")?.textContent == "连载中")
        // 兄弟元素不在子树内
        #expect(try item.select(".chapters").isEmpty)
    }

    // MARK: 非法输入

    @Test("空选择器被拒绝", arguments: ["", "   ", "\n"])
    func rejectsEmptySelector(raw: String) {
        #expect(throws: CSSSelectorError.empty) {
            _ = try CSSSelectorParser.parse(raw)
        }
    }

    // 注意：`> .a` 不算悬空——第一步的组合子恒被视为「后代」，
    // 因此它等价于 `.a`（这是有意的容错）。
    @Test("悬空的组合子被拒绝", arguments: [">", ".a >"])
    func rejectsDanglingCombinator(raw: String) {
        #expect(throws: CSSSelectorError.danglingCombinator) {
            _ = try CSSSelectorParser.parse(raw)
        }
    }

    @Test("不完整的属性选择器被拒绝")
    func rejectsInvalidAttribute() {
        #expect(throws: CSSSelectorError.self) {
            _ = try CSSSelectorParser.parse("a[href")
        }
    }

    @Test("无法识别的片段被拒绝", arguments: ["#", ".", "a#", "a."])
    func rejectsInvalidSimpleSelector(raw: String) {
        #expect(throws: CSSSelectorError.self) {
            _ = try CSSSelectorParser.parse(raw)
        }
    }

    // MARK: 解析细节

    @Test("解析结果反映 type/id/class/attribute")
    func parsesSelectorShape() throws {
        let selector = try CSSSelectorParser.parse("div#main.a.b[href][data-x=\"1\"]")
        #expect(selector.steps.count == 1)
        let simple = try #require(selector.steps.first?.simple)
        #expect(simple.tag == "div")
        #expect(simple.id == "main")
        #expect(simple.classes == ["a", "b"])
        #expect(simple.attributes.count == 2)
        #expect(simple.attributes.contains { $0.name == "href" && $0.match == .exists })
        #expect(simple.attributes.contains { $0.name == "data-x" && $0.match == .equals("1") })
    }

    @Test("属性值里的 > 不被当作组合子")
    func doesNotSplitInsideAttribute() throws {
        let selector = try CSSSelectorParser.parse("a[href=\"a>b\"]")
        #expect(selector.steps.count == 1)
        #expect(selector.steps.first?.simple.attributes.first?.match == .equals("a>b"))
    }

    @Test("第一步的组合子恒为后代（相对上下文）")
    func firstStepIsDescendant() throws {
        let selector = try CSSSelectorParser.parse("> .item")
        #expect(selector.steps.first?.combinator == .descendant)
    }

    @Test("通配选择器被识别为无条件")
    func universalSelectorHasNoConditions() throws {
        let selector = try CSSSelectorParser.parse("*")
        #expect(selector.steps.first?.simple.isUniversal == true)
    }
}
