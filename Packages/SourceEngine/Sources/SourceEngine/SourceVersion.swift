//
//  SourceVersion.swift
//  SourceEngine
//
//  来源版本号（契约 §3.2 / §4.1 的 `version` 字段）的解析与比较。
//
//  为什么需要单独一个类型：宿主要靠它判断「仓库里的版本是不是比本地新」，
//  进而提示用户更新。字符串直接比大小是错的（`"1.10" < "1.9"` 为真），
//  而引入完整 SemVer 库又不值当——本项目的版本号规则本来就窄
//  （`^[0-9]+(\.[0-9]+){0,2}(-[0-9A-Za-z.-]+)?$`，由 `ModelValidation` 保证）。
//
//  比较规则（与 SemVer 一致的部分）：
//  1. 逐段比较数字，缺段按 0 处理：`1.2` == `1.2.0`；
//  2. 数字段全相等时，**不带预发布后缀的更新**：`1.0.0` > `1.0.0-beta`；
//  3. 两边都有预发布后缀时按字符串比较（不实现 SemVer 的
//     「纯数字标识符比字母小」细则——社区的版本号里几乎用不到，
//     与其猜不如保持可预期的确定性）。
//

import Foundation
import AppCore

/// 来源版本号。
public struct SourceVersion: Equatable, Hashable, Comparable, Sendable, CustomStringConvertible {

    /// 原始文本。
    public let raw: String
    /// 数字段（如 `1.2.3` → `[1, 2, 3]`）。
    public let components: [Int]
    /// 预发布后缀（不含 `-`），无则 nil。
    public let preRelease: String?

    /// 解析版本号；不符合规则时返回 nil。
    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ModelValidation.isValidVersionString(trimmed) else { return nil }

        var core = trimmed
        var preRelease: String?
        if let dash = trimmed.firstIndex(of: "-") {
            core = String(trimmed[trimmed.startIndex..<dash])
            preRelease = String(trimmed[trimmed.index(after: dash)...])
        }
        // 正则已保证核心部分是点分数字
        let components = core.split(separator: ".").compactMap { Int($0) }
        guard !components.isEmpty else { return nil }

        self.raw = trimmed
        self.components = components
        self.preRelease = preRelease
    }

    public var description: String { raw }

    /// 比较用：把两侧补到同样长度再逐段比。
    private static func padded(_ lhs: [Int], _ rhs: [Int]) -> ([Int], [Int]) {
        let count = max(lhs.count, rhs.count)
        return (
            lhs + Array(repeating: 0, count: count - lhs.count),
            rhs + Array(repeating: 0, count: count - rhs.count)
        )
    }

    /// 相等按**语义**判定：`1.2` 与 `1.2.0` 是同一个版本，
    /// 尽管原始文本不同。`==` 与 `hash` 必须同时按这个口径，否则
    /// 放进 `Set` / `Dictionary` 会出现「相等却分桶不同」的诡异行为。
    public static func == (lhs: SourceVersion, rhs: SourceVersion) -> Bool {
        let (left, right) = padded(lhs.components, rhs.components)
        return left == right && lhs.preRelease == rhs.preRelease
    }

    public func hash(into hasher: inout Hasher) {
        // 版本号规则限定最多三段（`^[0-9]+(\.[0-9]+){0,2}…`），
        // 因此补到三段就是唯一的规范形式，与 `==` 的口径一致。
        var normalized = components
        while normalized.count < 3 { normalized.append(0) }
        hasher.combine(normalized)
        hasher.combine(preRelease)
    }

    public static func < (lhs: SourceVersion, rhs: SourceVersion) -> Bool {
        let (left, right) = padded(lhs.components, rhs.components)
        for index in 0..<left.count where left[index] != right[index] {
            return left[index] < right[index]
        }
        switch (lhs.preRelease, rhs.preRelease) {
        case (nil, nil):
            return false
        case (nil, _?):
            return false        // 正式版 > 预发布
        case (_?, nil):
            return true
        case let (left?, right?):
            return left < right
        }
    }

    /// 判断 `candidate` 是否比 `installed` 新。
    ///
    /// 任一侧无法解析时返回 false（**不提示更新**比误报更新安全：
    /// 误报会让用户反复看到「有新版本」却装不上）。
    public static func isNewer(_ candidate: String, than installed: String) -> Bool {
        guard let new = SourceVersion(candidate), let old = SourceVersion(installed) else {
            return false
        }
        return new > old
    }
}
