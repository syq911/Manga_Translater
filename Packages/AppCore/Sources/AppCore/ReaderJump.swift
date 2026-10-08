//
//  ReaderJump.swift
//  AppCore
//
//  阅读器的「跳到第 N 页 / 跳到某章」。
//
//  单独成文件的原因不是它复杂，而是它**容易做错且不容易被发现**：
//  「输入框里打了个 999，而这一章只有 48 页」这种情况，做错的表现是
//  「点了没反应」——用户只会以为按钮坏了。
//
//  所以这里把「输入的解析」与「越界怎么办」写成明确的返回值：
//
//  - 解析不出来 → `.invalid`（界面提示「请输入页码」，而不是静默什么都不做）
//  - 越界 → `.outOfRange(clampedIndex:)`（**钳制到边界并告知**，不是拒绝）
//
//  选择「钳制」而不是「拒绝」的理由：用户打错一位数字时，
//  「跳到最后一页」比「弹个错然后什么都不做」更接近他的意图，
//  而且他马上能看出跳错了。
//

import Foundation

/// 页码输入的结果。
public enum PageJumpResult: Equatable, Sendable {
    /// 跳到这一页（0 基下标）。
    case jump(toIndex: Int)
    /// 页码越界，已钳制到边界（0 基下标）。界面应当说明「跳到了第一/最后一页」。
    case outOfRange(clampedIndex: Int)
    /// 输入无法解析成页码。
    case invalid
}

public enum ReaderJump {

    /// 解析「跳到第几页」的输入。
    ///
    /// 容忍三种真实输入形态，都会在测试里钉住：
    ///
    /// - `"12"` —— 直接输入；
    /// - `"12 / 48"`、`"12/48"` —— 从底栏那行页码标签复制过来的；
    /// - `"１２"` —— 中文输入法的**全角数字**（不处理的话用户会以为输入框坏了）。
    ///
    /// 页码是**1 基**（用户看到的是「12/48」），返回值是 0 基下标——
    /// 转换只在这一处发生，避免每个调用方各减一次 1。
    public static func resolvePage(input: String, pageCount: Int) -> PageJumpResult {
        guard pageCount > 0 else { return .invalid }
        guard let value = pageNumber(from: input) else { return .invalid }
        if value < 1 { return .outOfRange(clampedIndex: 0) }
        if value > pageCount { return .outOfRange(clampedIndex: pageCount - 1) }
        return .jump(toIndex: value - 1)
    }

    /// 从输入里取出页码（1 基）。取不出来返回 nil。
    public static func pageNumber(from input: String) -> Int? {
        let normalized = normalizedDigits(input)
        guard !normalized.isEmpty else { return nil }
        // 允许 "12 / 48" 这种「当前页 / 总页数」的形态：取斜杠前的那半
        let head = normalized
            .split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? normalized
        let digits = head.trimmingCharacters(in: .whitespaces)
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber), let value = Int(digits) else { return nil }
        return value
    }

    /// 去掉空白、把全角数字与全角斜杠换成半角。
    ///
    /// 只做「看起来一样」的替换：全角数字 `０-９`（U+FF10–U+FF19）、
    /// 全角斜杠 `／`（U+FF0F）。不做更激进的清洗——输入框里出现别的字符时，
    /// 报「请输入页码」比猜用户想输入什么更好。
    public static func normalizedDigits(_ input: String) -> String {
        var result = ""
        for scalar in input.unicodeScalars {
            switch scalar.value {
            case 0xFF10...0xFF19:
                // 全角数字 → 半角
                result.unicodeScalars.append(Unicode.Scalar(scalar.value - 0xFF10 + 0x30)!)
            case 0xFF0F:
                result.append("/")
            case 0x3000:
                // 全角空格
                result.append(" ")
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
