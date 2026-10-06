//
//  TranslationCoreTests.swift
//  MangaTranslaterTests
//
//  翻译核心回归：
//  - 纯逻辑：竖排判定（含页面纵横比修正）、竖排布局、坐标映射、合并去重、
//    译文 JSON 解析、分块顺序；
//  - 请求行为：缺 Key、HTTP 错误映射、5xx 重试、分块后顺序不变；
//  - 真实 Vision：合成密集页召回、竖排方向判定、**金标准**夹具比对；
//  - 排版：合成后尺寸不变、空输入回退原图。
//
//  金标准夹具（`Tests/Fixtures/`）由 `tools/make_ocr_fixture.py` 生成：
//  图上**先知道印了什么**，因此基准文本是权威值，比对完全由程序完成。
//

import Foundation
import Testing
import CoreGraphics
import CoreText
import ImageIO
import UIKit
import AppCore
import ComicNet
@testable import MangaTranslater

@Suite("翻译核心")
struct TranslationCoreTests {

    // MARK: 夹具

    private static func fixtureDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MangaTranslaterTests
            .deletingLastPathComponent()   // MangaTranslater
            .deletingLastPathComponent()   // 仓库根
            .appendingPathComponent("Tests/Fixtures", isDirectory: true)
    }

    /// 合成一页：白底黑字。
    private static func makePage(size: CGSize, draw: (CGContext, CGSize) -> Void) -> UIImage? {
        let width = Int(size.width)
        let height = Int(size.height)
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.textMatrix = .identity
        draw(ctx, size)
        guard let cgImage = ctx.makeImage() else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// 在页面上画一段文字（`x`/`y` 以左上角为原点，`y` 向下）。
    private static func drawText(
        _ text: String,
        in ctx: CGContext,
        x: CGFloat,
        y: CGFloat,
        fontSize: CGFloat,
        vertical: Bool,
        pageHeight: CGFloat
    ) {
        let baseFont = CTFontCreateUIFontForLanguage(.system, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let font = CTFontCreateForString(baseFont, text as CFString, CFRangeMake(0, text.utf16.count))
        let attributes: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ]

        if vertical {
            var cursorY = pageHeight - y
            for character in text {
                let line = CTLineCreateWithAttributedString(
                    NSAttributedString(string: String(character), attributes: attributes)
                )
                let bounds = CTLineGetBoundsWithOptions(line, [])
                ctx.textPosition = CGPoint(x: x, y: cursorY - bounds.height)
                CTLineDraw(line, ctx)
                cursorY -= fontSize * 1.12
            }
        } else {
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: text, attributes: attributes)
            )
            let bounds = CTLineGetBoundsWithOptions(line, [])
            ctx.textPosition = CGPoint(x: x, y: pageHeight - y - bounds.height)
            CTLineDraw(line, ctx)
        }
    }

    private static func makeDensePage() -> UIImage? {
        makePage(size: CGSize(width: 1248, height: 1824)) { ctx, size in
            drawText("おはようございます", in: ctx, x: 90, y: 220, fontSize: 46, vertical: false, pageHeight: size.height)
            drawText("今日はいい天気ですね", in: ctx, x: 140, y: 540, fontSize: 42, vertical: false, pageHeight: size.height)
            drawText("ちょっと待ってください", in: ctx, x: 700, y: 860, fontSize: 38, vertical: false, pageHeight: size.height)
            drawText("ありがとうございました", in: ctx, x: 160, y: 1180, fontSize: 44, vertical: false, pageHeight: size.height)
            drawText("そうなんだ", in: ctx, x: 660, y: 1480, fontSize: 46, vertical: false, pageHeight: size.height)
            drawText("どこに行くの", in: ctx, x: 220, y: 1700, fontSize: 42, vertical: false, pageHeight: size.height)
        }
    }

    private static func makeVerticalPage() -> UIImage? {
        makePage(size: CGSize(width: 500, height: 1500)) { ctx, size in
            drawText("こんにちはありがとうございます", in: ctx, x: 340, y: 80, fontSize: 52, vertical: true, pageHeight: size.height)
            drawText("よろしくおねがいします", in: ctx, x: 150, y: 420, fontSize: 50, vertical: true, pageHeight: size.height)
        }
    }

    // MARK: 竖排判定

    @Test func verticalDetection() {
        // 高窄框 + 多字符 → 竖排
        #expect(VisionTextRecognizer.isVertical(
            box: CGRect(x: 0, y: 0, width: 0.05, height: 0.30),
            text: "こんにちは"
        ))
        // 宽扁框 → 横排
        #expect(!VisionTextRecognizer.isVertical(
            box: CGRect(x: 0, y: 0, width: 0.30, height: 0.05),
            text: "Hello"
        ))
        // 单字符无法判断方向 → 按横排
        #expect(!VisionTextRecognizer.isVertical(
            box: CGRect(x: 0, y: 0, width: 0.05, height: 0.30),
            text: "あ"
        ))
        // 零尺寸框不崩、判横排
        #expect(!VisionTextRecognizer.isVertical(
            box: CGRect(x: 0, y: 0, width: 0, height: 0),
            text: "あいう"
        ))
    }

    @Test func verticalDetectionUsesPageAspect() {
        // 归一化盒子在方页下接近正方；但竖长页（W/H=0.5）实际像素更高 → 应判为竖排
        let box = CGRect(x: 0, y: 0, width: 0.10, height: 0.09)
        #expect(VisionTextRecognizer.isVertical(box: box, text: "かな", pageAspect: 0.5))
        #expect(!VisionTextRecognizer.isVertical(box: box, text: "かな", pageAspect: 1.0))
    }

    // MARK: 竖排布局

    @Test func verticalLayoutFitsWidth() {
        let layout = MangaTypesetter.verticalLayout(
            charCount: 20,
            boxSize: CGSize(width: 100, height: 200),
            scale: 1.0
        )
        #expect(layout.columns >= 1)
        #expect(layout.charsPerColumn >= 1)
        #expect(CGFloat(layout.columns) * layout.fontSize <= 102)
        #expect(layout.charsPerColumn * layout.columns >= 20)
    }

    @Test func verticalLayoutNeverBelowMinFont() {
        let layout = MangaTypesetter.verticalLayout(
            charCount: 500,
            boxSize: CGSize(width: 20, height: 20),
            scale: 1.0
        )
        #expect(layout.fontSize >= 9)
        #expect(layout.columns >= 1)
    }

    @Test func verticalLayoutHandlesDegenerateInput() {
        let empty = MangaTypesetter.verticalLayout(
            charCount: 0,
            boxSize: CGSize(width: 100, height: 100),
            scale: 1
        )
        #expect(empty.columns == 1)
        let zeroBox = MangaTypesetter.verticalLayout(
            charCount: 5,
            boxSize: .zero,
            scale: 1
        )
        #expect(zeroBox.charsPerColumn >= 1)
    }

    // MARK: 坐标映射（归一化原点左下 → 像素原点左下）

    @Test func pixelRectMapping() {
        let rect = MangaTypesetter.pixelRect(
            from: CGRect(x: 0.25, y: 0.50, width: 0.50, height: 0.25),
            pageSize: CGSize(width: 400, height: 800)
        )
        #expect(rect.minX == 100)
        #expect(rect.minY == 400)
        #expect(rect.width == 200)
        #expect(rect.height == 200)
    }

    // MARK: 合并去重（纯逻辑）

    @Test func mergeDeduplicatesOverlappingLines() {
        let box = CGRect(x: 0.10, y: 0.10, width: 0.20, height: 0.05)
        let low = MangaTextLine(text: "こんにちは", boundingBox: box, isVertical: false, confidence: 0.5)
        let high = MangaTextLine(
            text: "こんにちは。",
            boundingBox: box.offsetBy(dx: 0.004, dy: 0.003),
            isVertical: false,
            confidence: 0.9
        )
        let other = MangaTextLine(
            text: "さようなら",
            boundingBox: CGRect(x: 0.6, y: 0.6, width: 0.2, height: 0.05),
            isVertical: false,
            confidence: 0.8
        )
        let merged = VisionTextRecognizer.merge([[low, other], [high]])
        #expect(merged.count == 2)
        #expect(merged.contains { $0.text == "こんにちは。" })   // 置信度高者胜
        #expect(merged.contains { $0.text == "さようなら" })
    }

    @Test func mergePrefersLongerTextOnEqualConfidence() {
        let box = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.05)
        let short = MangaTextLine(text: "あい", boundingBox: box, isVertical: false, confidence: 0.7)
        let long = MangaTextLine(text: "あいうえ", boundingBox: box, isVertical: false, confidence: 0.7)
        let merged = VisionTextRecognizer.merge([[short], [long]])
        #expect(merged.count == 1)
        #expect(merged.first?.text == "あいうえ")
    }

    @Test func mergeOfNothingIsEmpty() {
        #expect(VisionTextRecognizer.merge([]).isEmpty)
        #expect(VisionTextRecognizer.merge([[], []]).isEmpty)
    }

    @Test func iouOfIdenticalBoxesIsOne() {
        let box = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        #expect(abs(VisionTextRecognizer.iou(box, box) - 1) < 0.001)
        #expect(VisionTextRecognizer.iou(box, CGRect(x: 0.9, y: 0.9, width: 0.05, height: 0.05)) == 0)
        // 退化框（宽或高为 0）不参与合并
        #expect(VisionTextRecognizer.iou(box, CGRect(x: 0.1, y: 0.1, width: 0, height: 0.2)) == 0)
    }

    // MARK: 译文 JSON 解析

    @Test func parseTranslationsPlain() throws {
        let out = try DeepSeekTranslator.parseTranslations("[\"你好\",\"世界\"]", expected: 2)
        #expect(out == ["你好", "世界"])
    }

    @Test func parseTranslationsWithCodeFence() throws {
        let out = try DeepSeekTranslator.parseTranslations("```json\n[\"a\",\"b\"]\n```", expected: 2)
        #expect(out == ["a", "b"])
    }

    @Test func parseTranslationsWithSurroundingProse() throws {
        let out = try DeepSeekTranslator.parseTranslations("好的，译文如下：\n[\"甲\",\"乙\"]\n希望有帮助。", expected: 2)
        #expect(out == ["甲", "乙"])
    }

    @Test func parseTranslationsCoercesNonStrings() throws {
        let out = try DeepSeekTranslator.parseTranslations("[1, \"b\"]", expected: 2)
        #expect(out.count == 2)
        #expect(out[1] == "b")
    }

    @Test func parseTranslationsCountMismatch() {
        #expect(throws: TranslationError.self) {
            _ = try DeepSeekTranslator.parseTranslations("[\"a\"]", expected: 2)
        }
    }

    @Test func parseTranslationsWithoutArrayFails() {
        #expect(throws: TranslationError.self) {
            _ = try DeepSeekTranslator.parseTranslations("抱歉，我无法翻译。", expected: 1)
        }
    }

    @Test func stripCodeFencesHandlesPlainText() {
        #expect(DeepSeekTranslator.stripCodeFences("  [\"a\"]  ") == "[\"a\"]")
        #expect(DeepSeekTranslator.stripCodeFences("```\n[\"a\"]\n```") == "[\"a\"]")
    }

    // MARK: 分块

    @Test func chunksSplitsWithoutLosingOrder() {
        let texts = (0..<7).map { "t\($0)" }
        let chunks = DeepSeekTranslator.chunks(of: texts, size: 3)
        #expect(chunks.count == 3)
        #expect(chunks[0] == ["t0", "t1", "t2"])
        #expect(chunks[1] == ["t3", "t4", "t5"])
        #expect(chunks[2] == ["t6"])
        #expect(chunks.flatMap { $0 } == texts)
    }

    @Test func chunksOfEmptyInputIsEmpty() {
        #expect(DeepSeekTranslator.chunks(of: [], size: 3).isEmpty)
        #expect(DeepSeekTranslator.chunks(of: ["a"], size: 0) == [["a"]])
    }

    // MARK: 请求行为

    private static func completionBody(_ arrayJSON: String) -> Data {
        let payload: [String: Any] = [
            "choices": [
                ["message": ["content": arrayJSON]]
            ]
        ]
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    }

    private static func okOutcome(_ arrayJSON: String) -> StubTransport.Outcome {
        .success(
            data: completionBody(arrayJSON),
            statusCode: 200,
            headers: ["Content-Type": "application/json"]
        )
    }

    private static func translator(
        transport: StubTransport,
        chunkSize: Int = 40,
        maxAttempts: Int = 2
    ) -> DeepSeekTranslator {
        DeepSeekTranslator(
            apiKey: "demo-key",
            baseURL: "https://api.example.com",
            model: "deepseek-v4-flash",
            transport: transport,
            sleeper: { _ in },
            chunkSize: chunkSize,
            maxAttempts: maxAttempts
        )
    }

    @Test func translateRejectsMissingKey() async {
        let translator = DeepSeekTranslator(
            apiKey: "   ",
            baseURL: "https://api.example.com",
            model: "m",
            transport: StubTransport(data: Data()),
            sleeper: { _ in }
        )
        await expectThrowsAsync(TranslationError.missingAPIKey) {
            _ = try await translator.translate(["a"], source: .japanese, target: .simplifiedChinese)
        }
    }

    @Test func translateEmptyInputReturnsEmpty() async throws {
        let translator = Self.translator(transport: StubTransport(data: Data()))
        let out = try await translator.translate([], source: .auto, target: .english)
        #expect(out.isEmpty)
    }

    @Test func translateSendsBearerAndParsesResult() async throws {
        let transport = StubTransport(outcomes: [Self.okOutcome("[\"你好\",\"世界\"]")])
        let translator = Self.translator(transport: transport)
        let out = try await translator.translate(
            ["こんにちは", "世界"],
            source: .japanese,
            target: .simplifiedChinese
        )
        #expect(out == ["你好", "世界"])

        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://api.example.com/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer demo-key")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        // 用户提示词必须是纯 JSON 数组，模型才不会自作主张加解释
        let body = try #require(request.httpBody)
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.contains("deepseek-v4-flash"))
        #expect(text.contains("[\"こんにちは\",\"世界\"]"))
    }

    @Test func translateTrailingSlashBaseURLIsHandled() async throws {
        let transport = StubTransport(outcomes: [Self.okOutcome("[\"ok\"]")])
        let translator = DeepSeekTranslator(
            apiKey: "demo-key",
            baseURL: "https://api.example.com/",
            model: "m",
            transport: transport,
            sleeper: { _ in }
        )
        _ = try await translator.translate(["a"], source: .auto, target: .english)
        #expect(transport.requests.first?.url?.absoluteString == "https://api.example.com/chat/completions")
    }

    @Test func translateMapsHTTPError() async {
        let transport = StubTransport(outcomes: [
            .success(data: Data("unauthorized".utf8), statusCode: 401, headers: [:])
        ])
        let translator = Self.translator(transport: transport)
        await expectThrowsAsync(TranslationError.http(status: 401, body: "unauthorized")) {
            _ = try await translator.translate(["a"], source: .auto, target: .english)
        }
        // 4xx 不该重试
        #expect(transport.requestCount == 1)
    }

    @Test func translateRetriesOnServerError() async throws {
        let transport = StubTransport(outcomes: [
            .success(data: Data("boom".utf8), statusCode: 503, headers: [:]),
            Self.okOutcome("[\"恢复\"]"),
        ])
        let translator = Self.translator(transport: transport)
        let out = try await translator.translate(["a"], source: .auto, target: .simplifiedChinese)
        #expect(out == ["恢复"])
        #expect(transport.requestCount == 2)
    }

    @Test func translateDoesNotRetryBeyondLimit() async {
        let transport = StubTransport(outcomes: [
            .success(data: Data("boom".utf8), statusCode: 500, headers: [:]),
            .success(data: Data("boom".utf8), statusCode: 500, headers: [:]),
        ])
        let translator = Self.translator(transport: transport)
        await expectThrowsAsync(TranslationError.http(status: 500, body: "boom")) {
            _ = try await translator.translate(["a"], source: .auto, target: .english)
        }
        #expect(transport.requestCount == 2)
    }

    @Test func translateChunksPreserveOrder() async throws {
        // 5 条文本、每块 2 条 → 3 次请求，且最终顺序必须与输入一致
        let responses = ["[\"a0\",\"a1\"]", "[\"a2\",\"a3\"]", "[\"a4\"]"]
        let transport = StubTransport(outcomes: responses.map { Self.okOutcome($0) })
        let translator = Self.translator(transport: transport, chunkSize: 2)
        let out = try await translator.translate(
            ["t0", "t1", "t2", "t3", "t4"],
            source: .auto,
            target: .english
        )
        #expect(out == ["a0", "a1", "a2", "a3", "a4"])
        #expect(transport.requestCount == 3)
    }

    @Test func translateChunkMismatchFails() async {
        let transport = StubTransport(outcomes: [Self.okOutcome("[\"只有一个\"]")])
        let translator = Self.translator(transport: transport, chunkSize: 3)
        await expectThrowsAsync(TranslationError.countMismatch(expected: 3, got: 1)) {
            _ = try await translator.translate(["a", "b", "c"], source: .auto, target: .english)
        }
    }

    @Test func translateMapsInvalidBaseURL() async {
        let translator = DeepSeekTranslator(
            apiKey: "demo-key",
            baseURL: "   ",
            model: "m",
            transport: StubTransport(data: Data()),
            sleeper: { _ in }
        )
        await expectThrowsAsync(TranslationError.badURL) {
            _ = try await translator.translate(["a"], source: .auto, target: .english)
        }
    }

    // MARK: 提示词

    @Test func systemPromptMentionsTargetLanguage() {
        let prompt = DeepSeekTranslator.systemPrompt(source: .japanese, target: .simplifiedChinese)
        #expect(prompt.contains("简体中文"))
        #expect(prompt.contains("日文"))
        let auto = DeepSeekTranslator.systemPrompt(source: .auto, target: .english)
        #expect(auto.contains("英文"))
    }

    @Test func userPromptIsJSONArray() {
        #expect(DeepSeekTranslator.userPrompt(texts: ["a", "b"]) == "[\"a\",\"b\"]")
        #expect(DeepSeekTranslator.userPrompt(texts: []) == "[]")
    }

    // MARK: 排版

    @Test func renderKeepsPageSize() throws {
        let page = try #require(Self.makeDensePage())
        let cgImage = try #require(MangaTypesetter.cgImage(of: page))
        let lines = [
            MangaTranslatedLine(
                source: "おはようございます",
                translated: "早上好",
                boundingBox: CGRect(x: 0.08, y: 0.84, width: 0.35, height: 0.06),
                isVertical: false
            ),
            MangaTranslatedLine(
                source: "こんにちは",
                translated: "你好",
                boundingBox: CGRect(x: 0.60, y: 0.30, width: 0.20, height: 0.20),
                isVertical: true
            ),
        ]
        let rendered = MangaTypesetter.render(
            original: page,
            lines: lines,
            options: MangaTypesetter.Options()
        )
        let renderedCG = try #require(MangaTypesetter.cgImage(of: rendered))
        #expect(renderedCG.width == cgImage.width)
        #expect(renderedCG.height == cgImage.height)
    }

    @Test func renderWithNoLinesReturnsOriginal() throws {
        let page = try #require(Self.makeDensePage())
        let rendered = MangaTypesetter.render(original: page, lines: [], options: MangaTypesetter.Options())
        #expect(MangaTypesetter.cgImage(of: rendered) != nil)
    }

    @Test func renderWithWhiteBackgroundOptionWorks() throws {
        let page = try #require(Self.makeDensePage())
        let lines = [
            MangaTranslatedLine(
                source: "テスト",
                translated: "测试",
                boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.08),
                isVertical: false
            )
        ]
        let rendered = MangaTypesetter.render(
            original: page,
            lines: lines,
            options: MangaTypesetter.Options(
                useSampledBackground: false,
                showOriginalText: true,
                fontScale: 1.2
            )
        )
        #expect(MangaTypesetter.cgImage(of: rendered) != nil)
    }

    // MARK: 金标准：真实页图 OCR 必须匹配夹具基准文本

    @Test func ocrMatchesGoldenFixture() async throws {
        let fixtures = Self.fixtureDirectory()
        let imageURL = fixtures.appendingPathComponent("ocr_fixture_page.jpg")
        let expectedURL = fixtures.appendingPathComponent("ocr_fixture_expected.txt")

        let expected = try String(contentsOf: expectedURL, encoding: .utf8)
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            Issue.record("无法加载金标准测试图片：\(imageURL.path)")
            return
        }

        let lines = try await VisionTextRecognizer(languages: ["ja-JP"]).recognize(in: cgImage)
        let ocr = lines.map(\.text).joined(separator: "\n")

        let ratio = Self.lcsRecall(reference: expected, hypothesis: ocr)
        #expect(lines.count >= 3, "识别行数过少（\(lines.count)）。OCR=\(ocr)")
        #expect(ratio >= 0.60, "与基准文本字符召回率过低（\(String(format: "%.3f", ratio))）。OCR=\(ocr)")
    }

    // MARK: 真实 Vision OCR 召回（合成密集页面）

    @Test func ocrRecoversMostLinesOnDensePage() async throws {
        let page = try #require(Self.makeDensePage())
        let cgImage = try #require(MangaTypesetter.cgImage(of: page))
        let lines = try await VisionTextRecognizer(languages: ["ja-JP"]).recognize(in: cgImage)

        let joined = lines.map(\.text).joined().replacingOccurrences(of: " ", with: "")
        let phrases = ["おはよう", "天気", "待って", "ありがとう", "そうなん", "どこに"]
        let hits = phrases.filter { joined.contains($0) }.count
        #expect(hits >= 5, "仅召回 \(hits)/6 句；识别文本=\(joined)")
    }

    /// 竖排页面：合成竖排图在不同系统/模拟器上的可识别性不一，
    /// 因此这里只在「识别到内容」时强制校验方向判定。
    @Test func ocrVerticalPageClassifiesDirectionWhenRecognized() async throws {
        let page = try #require(Self.makeVerticalPage())
        let cgImage = try #require(MangaTypesetter.cgImage(of: page))
        let lines = try await VisionTextRecognizer(languages: ["ja-JP"]).recognize(in: cgImage)
        for line in lines where line.text.count > 1 {
            #expect(line.isVertical, "竖排被误判为横排：\(line.text)")
        }
    }

    // MARK: 比对工具

    /// 归一化：只保留字母/数字（含 CJK、假名），去掉空白与标点。
    static func normalized(_ text: String) -> [Character] {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// 以基准文本为参照的字符召回率 = LCS(基准, 识别) / len(基准)。
    static func lcsRecall(reference: String, hypothesis: String) -> Double {
        let a = normalized(reference)
        let b = normalized(hypothesis)
        guard !a.isEmpty, !b.isEmpty else { return 0 }

        var previous = [Int](repeating: 0, count: b.count + 1)
        var current = previous
        for i in 1...a.count {
            for j in 1...b.count {
                current[j] = a[i - 1] == b[j - 1]
                    ? previous[j - 1] + 1
                    : max(previous[j], current[j - 1])
            }
            previous = current
        }
        return Double(previous[b.count]) / Double(a.count)
    }
}
