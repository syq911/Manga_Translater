//
//  ZoomState.swift
//  AppCore
//
//  阅读器的缩放 / 平移状态（**纯逻辑**，无 UI）。
//
//  为什么单独抽出来：缩放档位、捏合时的刻度基准、放大后允许的平移范围
//  （尤其是「图片比容器小就不该能拖动」这条）都是容易出错的地方，
//  放在 SwiftUI 手势回调里几乎无法验证。抽成值类型后可以逐条断言。
//
//  坐标系约定：`scale` 是相对「已按比例适配容器后的尺寸」的倍数，
//  因此 scale = 1 就是「完整显示整页」；`offset` 是相对容器的位移（点）。
//
//  注意：必须先 `import CoreGraphics`。`CGSize` 类型本身经 Foundation 可见，
//  但 `.zero` 与 `Equatable` 一致性定义在 CoreGraphics 模块里 —— 不 import 时
//  会报 "type 'CGSize' has no member 'zero'"。CoreGraphics 是纯几何基础库，
//  不含 UI，仍满足「包可跑在无 UI 的测试环境」这一约束。
//

import Foundation
import CoreGraphics

public struct ZoomState: Equatable, Sendable {

    /// 最小缩放（1 = 完整显示整页，不再允许缩小）。
    public static let minScale: CGFloat = 1
    /// 最大缩放。
    public static let maxScale: CGFloat = 4
    /// 双击放大的档位。
    public static let doubleTapScale: CGFloat = 2.5
    /// 判定「是否已放大」的容差，避免浮点比较抖动。
    static let zoomEpsilon: CGFloat = 0.0001

    public private(set) var scale: CGFloat
    public private(set) var offset: CGSize

    public init(scale: CGFloat = 1, offset: CGSize = .zero) {
        self.scale = Self.clampScale(scale)
        self.offset = self.scale > 1 + Self.zoomEpsilon ? offset : .zero
    }

    /// 是否处于放大状态。
    public var isZoomed: Bool { scale > 1 + Self.zoomEpsilon }

    /// 把任意输入钳制到合法缩放范围；`NaN` / 无穷大回退到 1。
    public static func clampScale(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return minScale }
        return min(max(value, minScale), maxScale)
    }

    // MARK: 变更

    /// 直接设置缩放（例如滑杆）。缩回 1 时自动归零位移。
    public mutating func setScale(_ value: CGFloat) {
        scale = Self.clampScale(value)
        if !isZoomed { offset = .zero }
    }

    /// 捏合进行中：以手势开始时的刻度为基准乘以缩放因子。
    /// - Parameters:
    ///   - baseScale: 手势开始时的 scale。
    ///   - factor: 当前捏合倍率（相对手势开始）。
    public mutating func applyPinch(baseScale: CGFloat, factor: CGFloat) {
        setScale(baseScale * factor)
    }

    /// 双击：已放大则复原到 1，否则放大到 `doubleTapScale`。
    /// - Returns: 变更后的缩放值（便于 UI 做动画）。
    @discardableResult
    public mutating func toggleDoubleTap() -> CGFloat {
        scale = isZoomed ? Self.minScale : Self.doubleTapScale
        if !isZoomed { offset = .zero }
        return scale
    }

    /// 复原。
    public mutating func reset() {
        scale = Self.minScale
        offset = .zero
    }

    /// 设置平移量，并按容器 / 图片尺寸钳制（放大后才有可拖动空间）。
    public mutating func setOffset(_ proposed: CGSize, containerSize: CGSize, imageSize: CGSize) {
        offset = Self.clampedOffset(
            proposed,
            scale: scale,
            containerSize: containerSize,
            imageSize: imageSize
        )
    }

    // MARK: 几何（纯函数）

    /// 图片按 `aspectFit` 适配容器后的显示尺寸。任一尺寸非法时返回 `.zero`。
    public static func fittedSize(imageSize: CGSize, containerSize: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0,
              containerSize.width > 0, containerSize.height > 0 else { return .zero }
        let ratio = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
        return CGSize(width: imageSize.width * ratio, height: imageSize.height * ratio)
    }

    /// 钳制平移量。
    ///
    /// 规则：放大后的内容超出容器多少，就允许向对应方向移动多少；
    /// 内容仍小于容器时该方向位移恒为 0（避免把整页拖出屏幕）。
    public static func clampedOffset(
        _ proposed: CGSize,
        scale: CGFloat,
        containerSize: CGSize,
        imageSize: CGSize
    ) -> CGSize {
        let fitted = fittedSize(imageSize: imageSize, containerSize: containerSize)
        guard fitted != .zero else { return .zero }
        let clampedScale = clampScale(scale)
        let scaledWidth = fitted.width * clampedScale
        let scaledHeight = fitted.height * clampedScale

        let maxX = max(0, (scaledWidth - containerSize.width) / 2)
        let maxY = max(0, (scaledHeight - containerSize.height) / 2)

        let x = proposed.width.isFinite ? proposed.width : 0
        let y = proposed.height.isFinite ? proposed.height : 0
        return CGSize(
            width: min(max(-maxX, x), maxX),
            height: min(max(-maxY, y), maxY)
        )
    }
}
