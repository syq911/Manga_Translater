//
//  MangaTypesetter.swift
//  MangaTranslater
//
//  排版合成 —— 在原图文字框上盖底色框，再把译文按方向 / 字号排回去。
//
//  设计要点（沿用已验证实现）：
//  - 坐标系：Vision 的归一化坐标原点在**左下**，`CGContext` 的位图坐标原点也在左下，
//    因此像素映射是纯缩放，不需要翻转。这是最容易写错的一处，
//    单独抽成 `pixelRect(from:pageSize:)` 以便断言。
//  - 底色：默认取文字框**外圈**的平均色（避开框内的文字像素），
//    得到「纸面颜色」，比纯白更贴合原图；取样失败回退白底。
//  - 文字颜色按底色亮度自动选黑/白，避免深色底上出现黑字看不见。
//  - 横排自动换行 + 逐级缩小字号直到能塞进框；竖排逐字竖排、必要时分列、从右往左。
//

import Foundation
import CoreGraphics
import CoreText
import UIKit

enum MangaTypesetter {

    struct Options {
        /// 盖框底色：true = 取样原文框周边底色；false = 纯白。
        var useSampledBackground: Bool = true
        /// 是否额外标注一行小号原文。
        var showOriginalText: Bool = false
        /// 字号缩放 0.6~1.4。
        var fontScale: CGFloat = 1.0
    }

    /// 把译文渲染回原图，返回带译文的整页图（失败时返回原图）。
    static func render(
        original: PlatformImage,
        lines: [MangaTranslatedLine],
        options: Options
    ) -> PlatformImage {
        guard !lines.isEmpty, let sourceCG = cgImage(of: original) else { return original }
        let width = sourceCG.width
        let height = sourceCG.height
        guard width > 0, height > 0 else { return original }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return original }

        // 先画原图（CGContext 原点左下，与原图位图一致）
        ctx.draw(sourceCG, in: CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)

        let pageSize = CGSize(width: width, height: height)
        for line in lines {
            draw(line: line, in: ctx, pageSize: pageSize, sourceCG: sourceCG, options: options)
        }

        guard let outCG = ctx.makeImage() else { return original }
        return makeImage(outCG, size: original.size)
    }

    // MARK: - 单条渲染

    private static func draw(
        line: MangaTranslatedLine,
        in ctx: CGContext,
        pageSize: CGSize,
        sourceCG: CGImage,
        options: Options
    ) {
        let box = pixelRect(from: line.boundingBox, pageSize: pageSize)
        guard box.width > 2, box.height > 2 else { return }
        let padded = box.insetBy(dx: -max(2, box.width * 0.08), dy: -max(2, box.height * 0.06))

        let background: CGColor
        if options.useSampledBackground {
            background = borderAverageColor(cgImage: sourceCG, box: box)
        } else {
            background = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        }

        // 盖框
        let path = CGPath(
            roundedRect: padded,
            cornerWidth: min(6, padded.width * 0.15),
            cornerHeight: min(6, padded.height * 0.15),
            transform: nil
        )
        ctx.addPath(path)
        ctx.setFillColor(background)
        ctx.fillPath()

        // 文字颜色跟随底色明暗
        let textColor = luminance(of: background) > 0.6
            ? CGColor(red: 0, green: 0, blue: 0, alpha: 1)
            : CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        let scale = max(0.3, min(1.5, options.fontScale))

        if line.isVertical {
            drawVertical(text: line.translated, in: ctx, box: padded, color: textColor, scale: scale)
        } else {
            drawHorizontal(text: line.translated, in: ctx, box: padded, color: textColor, scale: scale)
        }

        if options.showOriginalText, !line.source.isEmpty {
            drawOriginalAnnotation(text: line.source, in: ctx, box: padded, color: textColor, scale: scale)
        }
    }

    // MARK: - 横排（自动换行 + 垂直居中）

    private static func drawHorizontal(
        text: String,
        in ctx: CGContext,
        box: CGRect,
        color: CGColor,
        scale: CGFloat
    ) {
        guard !text.isEmpty else { return }
        var fontSize = horizontalInitialFontSize(boxHeight: box.height, scale: scale)

        var lines = wrap(attributedString(text, fontSize: fontSize, color: color), width: box.width)
        var lh = lineHeight(of: attributedString(text, fontSize: fontSize, color: color))
        var guardCount = 0
        while (CGFloat(lines.count) * lh > box.height || totalWidthOverflow(lines, maxWidth: box.width)),
              fontSize > 8, guardCount < 24 {
            fontSize -= 1
            let attributed = attributedString(text, fontSize: fontSize, color: color)
            lh = lineHeight(of: attributed)
            lines = wrap(attributed, width: box.width)
            guardCount += 1
        }

        let blockHeight = CGFloat(lines.count) * lh
        var baseline = box.midY + blockHeight / 2 - lh + (lh * 0.25)
        for line in lines {
            let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let x = box.midX - lineWidth / 2
            ctx.textPosition = CGPoint(x: x, y: baseline)
            CTLineDraw(line, ctx)
            baseline -= lh
        }
    }

    // MARK: - 竖排（逐字竖排，必要时分列，从右往左）

    private static func drawVertical(
        text: String,
        in ctx: CGContext,
        box: CGRect,
        color: CGColor,
        scale: CGFloat
    ) {
        let characters = Array(text).map { String($0) }
        guard !characters.isEmpty else { return }

        let layout = verticalLayout(charCount: characters.count, boxSize: box.size, scale: scale)
        let fontSize = max(8, layout.fontSize)
        let lineHeight = fontSize * 1.06

        for column in 0..<layout.columns {
            let start = column * layout.charsPerColumn
            let end = min(start + layout.charsPerColumn, characters.count)
            guard start < end else { break }
            let columnChars = Array(characters[start..<end])

            let columnWidth = box.width / CGFloat(max(1, layout.columns))
            let columnCenterX = box.maxX - (CGFloat(column) + 0.5) * columnWidth
            let columnHeight = CGFloat(columnChars.count) * lineHeight
            var top = box.midY + columnHeight / 2
            for character in columnChars {
                let line = CTLineCreateWithAttributedString(
                    attributedString(character, fontSize: fontSize, color: color)
                )
                let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                let baseline = top - lineHeight + lineHeight * 0.2
                ctx.textPosition = CGPoint(x: columnCenterX - width / 2, y: baseline)
                CTLineDraw(line, ctx)
                top -= lineHeight
            }
        }
    }

    // MARK: - 原文小注（可选）

    private static func drawOriginalAnnotation(
        text: String,
        in ctx: CGContext,
        box: CGRect,
        color: CGColor,
        scale: CGFloat
    ) {
        let fontSize = max(7, box.height * 0.14 * scale)
        let attributed = attributedString(text, fontSize: fontSize, color: color.copy(alpha: 0.55) ?? color)
        let line = CTLineCreateWithAttributedString(attributed)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        ctx.textPosition = CGPoint(x: box.midX - width / 2, y: box.minY + 2)
        CTLineDraw(line, ctx)
    }

    // MARK: - 纯逻辑（可单测）

    /// 竖排布局：尽量让字号贴合框宽，列数不超过能塞进框宽的列数。
    static func verticalLayout(
        charCount: Int,
        boxSize: CGSize,
        scale: CGFloat
    ) -> (fontSize: CGFloat, charsPerColumn: Int, columns: Int) {
        guard charCount > 0, boxSize.width > 0, boxSize.height > 0 else {
            return (12, max(1, charCount), 1)
        }
        var fontSize = min(boxSize.width, boxSize.height) * scale
        fontSize = max(9, min(fontSize, 200))

        var charsPerColumn = 1
        var columns = 1
        for _ in 0..<12 {
            charsPerColumn = max(1, Int(floor(boxSize.height / (fontSize * 1.06))))
            columns = Int(ceil(Double(charCount) / Double(charsPerColumn)))
            let neededWidth = CGFloat(columns) * fontSize * 1.02
            if neededWidth <= boxSize.width || fontSize <= 9 { break }
            // 需要更多列 → 缩小字号
            fontSize = max(9, fontSize * (boxSize.width / neededWidth))
        }
        return (fontSize, max(1, charsPerColumn), max(1, columns))
    }

    /// 横排初始字号（后续再按实际换行收缩）。
    static func horizontalInitialFontSize(boxHeight: CGFloat, scale: CGFloat) -> CGFloat {
        max(8, boxHeight * scale)
    }

    // MARK: - 颜色采样

    /// 取文字框「外圈」的平均色作为底色（避开框内的文字像素）。
    private static func borderAverageColor(cgImage: CGImage, box: CGRect) -> CGColor {
        let pageBounds = CGRect(x: 0, y: 0, width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
        let outer = box.insetBy(dx: -3, dy: -3).intersection(pageBounds)
        guard outer.width > 2, outer.height > 2 else {
            return CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        }

        let side = 24
        let bytesPerRow = side * 4
        var buffer = [UInt8](repeating: 0, count: side * side * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        var sumR = 0.0
        var sumG = 0.0
        var sumB = 0.0
        var count = 0.0
        buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let small = CGContext(
                      data: base,
                      width: side,
                      height: side,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: colorSpace,
                      bitmapInfo: bitmapInfo
                  ) else { return }

            small.interpolationQuality = .high
            small.draw(cgImage, in: CGRect(
                x: -outer.minX * CGFloat(side) / outer.width,
                y: -outer.minY * CGFloat(side) / outer.height,
                width: CGFloat(cgImage.width) * CGFloat(side) / outer.width,
                height: CGFloat(cgImage.height) * CGFloat(side) / outer.height
            ))

            let pixels = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<side {
                for x in 0..<side {
                    // 只取外圈 3 像素
                    guard x < 3 || y < 3 || x >= side - 3 || y >= side - 3 else { continue }
                    let idx = (y * side + x) * 4
                    sumR += Double(pixels[idx]) / 255.0
                    sumG += Double(pixels[idx + 1]) / 255.0
                    sumB += Double(pixels[idx + 2]) / 255.0
                    count += 1
                }
            }
        }
        guard count > 0 else { return CGColor(red: 1, green: 1, blue: 1, alpha: 1) }
        return CGColor(red: sumR / count, green: sumG / count, blue: sumB / count, alpha: 1)
    }

    // MARK: - 工具

    /// 归一化坐标（原点左下）→ 像素坐标（CGContext 原点左下，直接对应）。
    static func pixelRect(from normalized: CGRect, pageSize: CGSize) -> CGRect {
        CGRect(
            x: normalized.minX * pageSize.width,
            y: normalized.minY * pageSize.height,
            width: normalized.width * pageSize.width,
            height: normalized.height * pageSize.height
        )
    }

    private static func luminance(of color: CGColor) -> CGFloat {
        let components = color.components ?? [1, 1, 1, 1]
        guard components.count >= 3 else { return 1 }
        return 0.299 * components[0] + 0.587 * components[1] + 0.114 * components[2]
    }

    private static func attributedString(_ text: String, fontSize: CGFloat, color: CGColor) -> NSAttributedString {
        let font = systemCTFont(size: fontSize)
        let attributes: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: color,
        ]
        return NSAttributedString(string: text, attributes: attributes)
    }

    private static func systemCTFont(size: CGFloat) -> CTFont {
        CTFontCreateUIFontForLanguage(.system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    private static func lineHeight(of attributed: NSAttributedString) -> CGFloat {
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        return ascent + descent + leading
    }

    private static func totalWidthOverflow(_ lines: [CTLine], maxWidth: CGFloat) -> Bool {
        for line in lines where CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) > maxWidth {
            return true
        }
        return false
    }

    /// 用 CTTypesetter 做断行。
    private static func wrap(_ attributed: NSAttributedString, width: CGFloat) -> [CTLine] {
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let length = attributed.length
        var lines: [CTLine] = []
        var start = 0
        while start < length {
            let count = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
            if count <= 0 { break }
            let line = CTTypesetterCreateLine(typesetter, CFRangeMake(start, count))
            lines.append(line)
            start += count
        }
        if lines.isEmpty { lines = [CTLineCreateWithAttributedString(attributed)] }
        return lines
    }

    // MARK: - 平台桥接

    static func cgImage(of image: PlatformImage) -> CGImage? {
        image.cgImage
    }

    private static func makeImage(_ cgImage: CGImage, size: CGSize) -> PlatformImage {
        _ = size
        return UIImage(cgImage: cgImage)
    }
}
