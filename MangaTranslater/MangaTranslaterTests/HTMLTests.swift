//
//  HTMLTests.swift
//  MangaTranslaterTests
//
//  HTML 解析器、CSS 选择器与文本/URL 工具的测试。
//
//  这些都是纯函数，可以不依赖网络与文件系统穷举边界；
//  真实源页面里最常见的结构（列表 + 链接 + 懒加载属性）也放进夹具验证。
//

import Testing
import Foundation
@testable import SourceEngine

@Suite("HTML 解析器")
struct HTMLParserTests {

    // MARK: 基本结构

    @Test("解析标签、属性与文本")
    func parsesBasicElement() throws {
        let document = HTMLParser.parse(#"<div id="main" class="a b"><p>hello</p></div>"#)
        let div = try #require(try document.selectFirst("div"))

        #expect(div.tag == "div")
        #expect(div.id == "main")
        #expect(div.classes == ["a", "b"])
        #expect(div.childElements.count == 1)
        #expect(div.textContent == "hello")
    }

    @Test("属性值的四种写法都能解析", arguments: [
        (#"<a href="x">t</a>"#, "x"),
        (#"<a href='x'>t</a>"#, "x"),
        ("<a href=x>t</a>", "x"),
        (#"<a href="">t</a>"#, ""),
    ])
    func parsesAttributeQuoting(html: String, expected: String) throws {
        let document = HTMLParser.parse(html)
        let anchor = try #require(try document.selectFirst("a"))
        #expect(anchor.attribute("href") == expected)
    }

    @Test("布尔属性解析为空串")
    func parsesBooleanAttribute() throws {
        let document = HTMLParser.parse("<input disabled type=\"text\">")
        let input = try #require(try document.selectFirst("input"))
        #expect(input.attribute("disabled") == "")
        #expect(input.attribute("type") == "text")
    }

    @Test("属性名大小写不敏感，标签名统一小写")
    func normalizesCase() throws {
        let document = HTMLParser.parse(#"<DIV CLASS="x" DATA-Id="7">t</DIV>"#)
        let div = try #require(try document.selectFirst("div"))
        #expect(div.tag == "div")
        #expect(div.attribute("data-id") == "7")
        #expect(div.classes == ["x"])
    }

    @Test("嵌套结构保持层级")
    func parsesNesting() throws {
        let document = HTMLParser.parse(
            "<ul><li>a</li><li>b<span>c</span></li></ul>"
        )
        let list = try #require(try document.selectFirst("ul"))
        #expect(list.childElements.count == 2)
        #expect(list.childElements[1].childElements.first?.tag == "span")
        // 元素之间没有空白字符，因此拼接结果里也不会凭空插入空格
        #expect(list.textContent == "abc")
    }

    // MARK: 容错

    @Test("void 标签不入栈（后面的兄弟标签是同级）")
    func handlesVoidTags() throws {
        let document = HTMLParser.parse("<div><br><img src=\"a.png\"><span>x</span></div>")
        let div = try #require(try document.selectFirst("div"))
        #expect(div.childElements.map(\.tag) == ["br", "img", "span"])
        #expect(div.textContent == "x")
    }

    @Test("自闭合写法的非 void 标签也不入栈")
    func handlesSelfClosingSyntax() throws {
        let document = HTMLParser.parse(#"<p/><span>after</span>"#)
        // p 立即闭合，span 成为根的直接子元素
        #expect(try document.select("p").count == 1)
        #expect(try document.selectFirst("span") != nil)
    }

    @Test("多余的结束标签被忽略，不破坏结构")
    func ignoresStrayClosingTag() throws {
        let document = HTMLParser.parse("<div><p>a</p></div></span>")
        #expect(try document.select("div").count == 1)
        #expect(try document.select("p").count == 1)
    }

    @Test("未闭合的标签在文档结束时自动闭合")
    func autoClosesAtEnd() throws {
        let document = HTMLParser.parse("<div><p>text")
        let div = try #require(try document.selectFirst("div"))
        #expect(div.childElements.first?.tag == "p")
        #expect(div.textContent == "text")
    }

    @Test("跨层级的结束标签会就地补闭合")
    func closesIntermediateTags() throws {
        // </div> 出现时 p 还没闭合：p 应自动闭合，div 也随之闭合
        let document = HTMLParser.parse("<div><p>a</div><section>b</section>")
        let div = try #require(try document.selectFirst("div"))
        #expect(div.childElements.first?.tag == "p")
        #expect(try document.select("section").count == 1)
    }

    @Test("注释与 DOCTYPE 被跳过")
    func skipsCommentsAndDoctype() throws {
        let document = HTMLParser.parse(
            "<!DOCTYPE html><!-- 注释 <div>不该出现</div> --><html><body>x</body></html>"
        )
        #expect(try document.select("div").isEmpty)
        #expect(try document.selectFirst("body")?.textContent == "x")
    }

    @Test("script / style 的内部内容不当作标签")
    func keepsRawTextContent() throws {
        let document = HTMLParser.parse(
            #"<div><script>var a = "<b>not a tag</b>";</script><style>.x{color:red}</style></div>"#
        )
        #expect(try document.select("b").isEmpty)
        let script = try #require(try document.selectFirst("script"))
        #expect(script.textContent.contains("not a tag"))
    }

    @Test("不合法的尖括号当作文本处理")
    func treatsStrayAngleBracketAsText() throws {
        let document = HTMLParser.parse("<p>a &lt; b and 3 < 4</p>")
        let paragraph = try #require(try document.selectFirst("p"))
        #expect(paragraph.textContent.contains("3 < 4"))
    }

    @Test("空输入与纯文本输入都不崩溃")
    func handlesEmptyAndPlainInput() throws {
        #expect(HTMLParser.parse("").root.children.isEmpty)
        let document = HTMLParser.parse("just text")
        #expect(document.root.textContent == "just text")
        #expect(try document.select("div").isEmpty)
    }

    @Test("未闭合的标签在输入中途被判为文本")
    func handlesUnterminatedTag() throws {
        // 没有 `>` 的 `<div` 会被当成普通文本
        let document = HTMLParser.parse("<div")
        #expect(try document.select("div").isEmpty)
    }

    // MARK: 文本与序列化

    @Test("文本内容递归拼接并折叠空白")
    func collapsesWhitespace() throws {
        let document = HTMLParser.parse("<p>\n  a   b\n  <b>c</b>\n</p>")
        #expect(try document.selectFirst("p")?.textContent == "a b c")
    }

    @Test("outerHTML 可往返解析出同样的结构")
    func outerHTMLRoundTrips() throws {
        let original = HTMLParser.parse(#"<div class="x"><a href="/m/1">标题</a></div>"#)
        let element = try #require(try original.selectFirst("div"))
        let reparsed = HTMLParser.parse(element.outerHTML)
        #expect(try reparsed.selectFirst("a")?.textContent == "标题")
        #expect(try reparsed.selectFirst("a")?.attribute("href") == "/m/1")
    }

    @Test("nodeID 在整棵树内唯一")
    func nodeIDsAreUnique() throws {
        let document = HTMLParser.parse("<div><p><span>a</span></p><p>b</p></div>")
        let all = document.root.descendantsAndSelf.map(\.nodeID)
        #expect(Set(all).count == all.count)
    }
}

@Suite("HTML 文本与 URL 工具")
struct HTMLTextTests {

    @Test("解码命名实体", arguments: [
        ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
        ("&quot;", "\""), ("&apos;", "'"), ("&nbsp;", " "),
        ("&hellip;", "…"), ("&COPY;", "©"),
    ])
    func decodesNamedEntities(input: String, expected: String) {
        #expect(HTMLText.decodeEntities(input) == expected)
    }

    @Test("解码数字实体（十进制与十六进制）")
    func decodesNumericEntities() {
        #expect(HTMLText.decodeEntities("&#65;&#66;") == "AB")
        #expect(HTMLText.decodeEntities("&#x41;&#X42;") == "AB")
        #expect(HTMLText.decodeEntities("&#x1F600;") == "😀")
    }

    @Test("未知与非法实体原样保留", arguments: [
        "&unknown;", "&#;", "&#x;", "&amp", "plain & text",
    ])
    func keepsUnknownEntities(input: String) {
        #expect(HTMLText.decodeEntities(input) == input)
    }

    @Test("解析时自动解码实体")
    func parserDecodesEntities() throws {
        let document = HTMLParser.parse(#"<a href="/m/1?a=1&amp;b=2">A &amp; B</a>"#)
        #expect(try document.selectFirst("a")?.attribute("href") == "/m/1?a=1&b=2")
        #expect(try document.selectFirst("a")?.textContent == "A & B")
    }

    @Test("collapseWhitespace 处理各种空白")
    func collapsesWhitespace() {
        #expect(HTMLText.collapseWhitespace("  a \n\t b  ") == "a b")
        #expect(HTMLText.collapseWhitespace("") == "")
        #expect(HTMLText.collapseWhitespace("   ") == "")
        #expect(HTMLText.collapseWhitespace("a") == "a")
    }

    @Test("escape 转义特殊字符")
    func escapes() {
        #expect(HTMLText.escape("<a & \"b\">") == "&lt;a &amp; &quot;b&quot;&gt;")
    }

    // MARK: URL

    @Test("absolute 处理四种相对形式", arguments: [
        ("/m/1", "https://example.com/list?p=2", "https://example.com/m/1"),
        ("chapter/1.html", "https://example.com/m/1/", "https://example.com/m/1/chapter/1.html"),
        ("//cdn.example.com/a.jpg", "https://example.com/", "https://cdn.example.com/a.jpg"),
        ("https://other.com/x", "https://example.com/", "https://other.com/x"),
    ])
    func resolvesAbsoluteURL(link: String, base: String, expected: String) {
        #expect(HTMLURL.absolute(link, base: base) == expected)
    }

    @Test("absolute 对空串与非法基地址返回 nil")
    func absoluteEdgeCases() {
        #expect(HTMLURL.absolute("", base: "https://example.com") == nil)
        #expect(HTMLURL.absolute("  ", base: "https://example.com") == nil)
        #expect(HTMLURL.absolute("/a", base: "not a url") == nil)
    }

    @Test("queryValue 取查询参数（含百分号解码）")
    func readsQueryValue() {
        let url = "https://example.com/s?q=%E7%81%AB%E5%BD%B1&page=2"
        #expect(HTMLURL.queryValue("page", in: url) == "2")
        #expect(HTMLURL.queryValue("q", in: url) == "火影")
        #expect(HTMLURL.queryValue("missing", in: url) == nil)
    }

    @Test("settingQuery 覆盖 / 追加 / 移除参数")
    func writesQueryValue() {
        let base = "https://example.com/s?q=a&page=1"
        #expect(HTMLURL.settingQuery(["page": "3"], in: base) == "https://example.com/s?q=a&page=3")
        #expect(HTMLURL.settingQuery(["new": "1"], in: base) == "https://example.com/s?q=a&page=1&new=1")
        #expect(HTMLURL.settingQuery(["page": nil], in: base) == "https://example.com/s?q=a")
        // 参数全被移除时不留下裸问号
        #expect(HTMLURL.settingQuery(["q": nil, "page": nil], in: base) == "https://example.com/s")
    }

    @Test("host 取小写主机名")
    func readsHost() {
        #expect(HTMLURL.host("https://Example.COM/a") == "example.com")
        #expect(HTMLURL.host("not a url") == nil)
    }

    @Test("unescapingSlashes 还原 JSON 里的转义斜杠")
    func unescapesSlashes() {
        #expect(HTMLURL.unescapingSlashes(#"https:\/\/example.com\/a"#) == "https://example.com/a")
    }
}
