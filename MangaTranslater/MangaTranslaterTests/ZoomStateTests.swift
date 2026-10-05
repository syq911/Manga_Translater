//
//  ZoomStateTests.swift
//  MangaTranslaterTests
//
//  阅读器缩放 / 平移状态测试。
//
//  重点验证两条容易出错的规则：
//  1. 缩回 1 倍后位移必须归零（否则复原后画面会偏）；
//  2. 未放大时任何方向都不允许拖动（否则能把整页拖出屏幕）。
//

import Testing
import Foundation
import CoreGraphics
import AppCore

@Suite("阅读器缩放状态")
struct ZoomStateTests {

    // MARK: 初始化与钳制

    @Test("默认不放大、无位移")
    func defaults() {
        let state = ZoomState()
        #expect(state.scale == 1)
        #expect(state.offset == .zero)
        #expect(state.isZoomed == false)
    }

    @Test("初始缩放被钳制到合法范围", arguments: [
        (0.1, 1.0), (1.0, 1.0), (2.5, 2.5), (99.0, 4.0),
    ])
    func initClampsScale(input: Double, expected: Double) {
        let state = ZoomState(scale: CGFloat(input))
        #expect(state.scale == CGFloat(expected))
    }

    @Test("非有限缩放回退到 1", arguments: [Double.nan, .infinity, -.infinity])
    func initHandlesNonFinite(value: Double) {
        #expect(ZoomState(scale: CGFloat(value)).scale == 1)
        #expect(ZoomState.clampScale(CGFloat(value)) == 1)
    }

    @Test("初始为 1 倍时位移被忽略（避免残留偏移）")
    func initIgnoresOffsetAtUnitScale() {
        let state = ZoomState(scale: 1, offset: CGSize(width: 50, height: 50))
        #expect(state.offset == .zero)
    }

    @Test("初始已放大时保留位移")
    func initKeepsOffsetWhenZoomed() {
        let state = ZoomState(scale: 2, offset: CGSize(width: 10, height: -5))
        #expect(state.offset == CGSize(width: 10, height: -5))
    }

    // MARK: 变更

    @Test("setScale 越界被钳制")
    func setScaleClamps() {
        var state = ZoomState()
        state.setScale(CGFloat(10))
        #expect(state.scale == 4)
        state.setScale(CGFloat(0.2))
        #expect(state.scale == 1)
    }

    @Test("缩回 1 倍时位移归零")
    func shrinkingResetsOffset() {
        var state = ZoomState(scale: 3, offset: CGSize(width: 40, height: 40))
        #expect(state.offset != .zero)

        state.setScale(1)
        #expect(state.scale == 1)
        #expect(state.offset == .zero, "复原后不应残留偏移")
    }

    @Test("捏合：以手势起始刻度为基准")
    func pinchUsesBaseScale() {
        var state = ZoomState(scale: 1)
        state.applyPinch(baseScale: 1, factor: 2)
        #expect(state.scale == 2)

        // 捏合过程中从 2 倍基准再放大 3 倍 → 被钳制到 4
        state.applyPinch(baseScale: 2, factor: 3)
        #expect(state.scale == 4)

        // 缩小
        state.applyPinch(baseScale: 2, factor: 0.4)
        #expect(state.scale == 1)
    }

    @Test("双击在 1 与档位之间往返")
    func doubleTapToggles() {
        var state = ZoomState()

        let zoomedIn = state.toggleDoubleTap()
        #expect(zoomedIn == ZoomState.doubleTapScale)
        #expect(state.isZoomed)

        let zoomedOut = state.toggleDoubleTap()
        #expect(zoomedOut == 1)
        #expect(!state.isZoomed)
        #expect(state.offset == .zero)
    }

    @Test("双击时若已放大（哪怕是捏合出来的）则复原")
    func doubleTapResetsFromPinchZoom() {
        var state = ZoomState()
        state.applyPinch(baseScale: 1, factor: 3.2)
        #expect(state.isZoomed)

        state.toggleDoubleTap()
        #expect(state.scale == 1)
    }

    @Test("reset 复原缩放与位移")
    func resetClears() {
        var state = ZoomState(scale: 3.5, offset: CGSize(width: 20, height: 20))
        state.reset()
        #expect(state == ZoomState())
        #expect(state.offset == .zero)
    }

    // MARK: 适配尺寸

    @Test("竖图按高度适配")
    func fittedTall() {
        let size = ZoomState.fittedSize(
            imageSize: CGSize(width: 100, height: 200),
            containerSize: CGSize(width: 300, height: 400)
        )
        #expect(size == CGSize(width: 200, height: 400))
    }

    @Test("横图按宽度适配")
    func fittedWide() {
        let size = ZoomState.fittedSize(
            imageSize: CGSize(width: 400, height: 100),
            containerSize: CGSize(width: 300, height: 400)
        )
        #expect(size == CGSize(width: 300, height: 75))
    }

    @Test("非法尺寸返回 zero", arguments: [
        (0.0, 100.0, 100.0, 100.0),
        (100.0, 0.0, 100.0, 100.0),
        (100.0, 100.0, 0.0, 100.0),
        (100.0, 100.0, 100.0, 0.0),
    ])
    func fittedRejectsInvalid(imageWidth: Double, imageHeight: Double, containerWidth: Double, containerHeight: Double) {
        let size = ZoomState.fittedSize(
            imageSize: CGSize(width: imageWidth, height: imageHeight),
            containerSize: CGSize(width: containerWidth, height: containerHeight)
        )
        #expect(size == .zero)
    }

    // MARK: 平移钳制（核心）

    @Test("未放大时任何方向都不能拖动")
    func noPanWhenNotZoomed() {
        let offset = ZoomState.clampedOffset(
            CGSize(width: 999, height: -999),
            scale: 1,
            containerSize: CGSize(width: 300, height: 400),
            imageSize: CGSize(width: 100, height: 200)
        )
        #expect(offset == .zero)
    }

    @Test("放大后按超出容器的量钳制（横向）")
    func panClampedHorizontally() {
        // 图片适配后 200x400（正好填满高），放大 4 倍 → 800x1600
        // 容器 300x400 → 横向可移动 (800-300)/2 = 250；纵向 (1600-400)/2 = 600
        let imageSize = CGSize(width: 100, height: 200)
        let containerSize = CGSize(width: 300, height: 400)

        let within = ZoomState.clampedOffset(
            CGSize(width: 100, height: 100),
            scale: 4, containerSize: containerSize, imageSize: imageSize
        )
        #expect(within == CGSize(width: 100, height: 100), "范围内应原样保留")

        let beyond = ZoomState.clampedOffset(
            CGSize(width: 9999, height: -9999),
            scale: 4, containerSize: containerSize, imageSize: imageSize
        )
        #expect(beyond == CGSize(width: 250, height: -600))
    }

    @Test("放大但内容仍未超出容器的方向不可移动")
    func axisWithoutOverflowIsLocked() {
        // 竖条图：宽 10 高 1000，容器 300x400 → 适配后高 400，宽 4
        // 放大 2 倍 → 宽 8 < 300，仍不可横向移动；纵向可移动 (800-400)/2 = 200
        let offset = ZoomState.clampedOffset(
            CGSize(width: 100, height: 300),
            scale: 2,
            containerSize: CGSize(width: 300, height: 400),
            imageSize: CGSize(width: 10, height: 1000)
        )
        #expect(offset.width == 0)
        #expect(offset.height == 200)
    }

    @Test("非法平移输入按 0 处理")
    func panHandlesNonFinite() {
        let offset = ZoomState.clampedOffset(
            CGSize(width: .nan, height: .infinity),
            scale: 2,
            containerSize: CGSize(width: 300, height: 400),
            imageSize: CGSize(width: 100, height: 200)
        )
        #expect(offset == .zero)
    }

    @Test("尺寸非法时钳制结果为 0")
    func panWithInvalidSizes() {
        let offset = ZoomState.clampedOffset(
            CGSize(width: 50, height: 50),
            scale: 2,
            containerSize: .zero,
            imageSize: CGSize(width: 100, height: 100)
        )
        #expect(offset == .zero)
    }

    @Test("setOffset 走同一套钳制规则")
    func setOffsetClamps() {
        var state = ZoomState(scale: 2)
        state.setOffset(
            CGSize(width: 9999, height: 9999),
            containerSize: CGSize(width: 300, height: 400),
            imageSize: CGSize(width: 100, height: 200)
        )
        // 适配后 200x400，放大 2 倍 → 400x800 → 可移动 (400-300)/2=50, (800-400)/2=200
        #expect(state.offset == CGSize(width: 50, height: 200))
    }
}
