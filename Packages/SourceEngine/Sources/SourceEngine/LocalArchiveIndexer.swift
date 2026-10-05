//
//  LocalArchiveIndexer.swift
//  SourceEngine
//
//  本地归档（CBZ / ZIP）的**纯函数**索引逻辑：噪音过滤、分章、自然排序。
//
//  单独抽出来是为了可测试：这些规则（哪些条目算图片、怎样算一章、页序怎么排）
//  决定了用户的阅读体验，必须能脱离文件系统与归档解析单独验证。
//

import Foundation
import AppCore

/// 一章的描述。
public struct LocalChapterDescriptor: Hashable, Sendable {
    /// 显示名。
    public let name: String
    /// 归档内目录路径（空串表示根目录）。
    public let path: String
    /// 该章的图片条目名（已按自然顺序排序）。
    public let pageEntries: [String]

    public init(name: String, path: String, pageEntries: [String]) {
        self.name = name
        self.path = path
        self.pageEntries = pageEntries
    }
}

/// 本地归档索引结果。
public struct LocalBookIndex: Hashable, Sendable {
    public let chapters: [LocalChapterDescriptor]

    public init(chapters: [LocalChapterDescriptor]) {
        self.chapters = chapters
    }

    public var pageCount: Int {
        chapters.reduce(0) { $0 + $1.pageEntries.count }
    }
}

/// 归档索引器（纯函数，无副作用）。
public enum LocalArchiveIndexer {

    /// 视为图片的扩展名。
    public static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "webp", "gif", "avif", "bmp", "heic", "tif", "tiff",
    ]

    /// 需要忽略的噪音条目：
    /// - `__MACOSX/`：macOS 压缩时写入的资源叉；
    /// - `._` 前缀：AppleDouble 资源叉文件；
    /// - 以 `.` 开头：`.DS_Store` 等系统文件；
    /// - `Thumbs.db`：Windows 缩略图缓存。
    public static func isNoiseEntry(_ entryName: String) -> Bool {
        let name = entryName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return true }
        if name.hasPrefix("__MACOSX/") || name.contains("/__MACOSX/") { return true }
        if name.hasSuffix("/") { return true }  // 目录本身

        let lastComponent = name.split(separator: "/").last.map(String.init) ?? name
        if lastComponent.hasPrefix(".") { return true }
        if lastComponent == "Thumbs.db" { return true }
        if lastComponent.hasPrefix("._") { return true }
        return false
    }

    /// 是否是图片条目（已排除噪音）。
    public static func isImageEntry(_ entryName: String) -> Bool {
        guard !isNoiseEntry(entryName) else { return false }
        let ext = (entryName as NSString).pathExtension.lowercased()
        return imageExtensions.contains(ext)
    }

    /// 由归档条目名推导章节结构。
    ///
    /// 规则（贴合真实 CBZ 的常见组织方式）：
    /// 1. 先过滤噪音与非图片条目；
    /// 2. 若**所有**图片都在目录内：
    ///    - 顶层目录 ≥2 个 → 每个顶层目录一章，按自然序排列；
    ///    - 顶层目录恰好 1 个 → 单章，章名取该目录名；
    /// 3. 若存在位于根目录的图片（混合情况）→ 视为单章，章名取书名。
    public static func index(entryNames: [String], bookTitle: String) -> LocalBookIndex {
        let images = entryNames.filter(isImageEntry)
        guard !images.isEmpty else {
            return LocalBookIndex(chapters: [])
        }

        let hasRootLevelImage = images.contains { !$0.contains("/") }
        var directories: [String: [String]] = [:]
        for entry in images {
            guard let slash = entry.firstIndex(of: "/") else { continue }
            let directory = String(entry[entry.startIndex..<slash])
            directories[directory, default: []].append(entry)
        }

        if !hasRootLevelImage, directories.count >= 2 {
            let chapters = directories.keys
                .sorted { naturalCompare($0, $1) == .orderedAscending }
                .map { directory in
                    LocalChapterDescriptor(
                        name: directory,
                        path: directory,
                        pageEntries: directories[directory]!.sorted { naturalCompare($0, $1) == .orderedAscending }
                    )
                }
            return LocalBookIndex(chapters: chapters)
        }

        if !hasRootLevelImage, let only = directories.keys.first {
            let entries = directories[only]!.sorted { naturalCompare($0, $1) == .orderedAscending }
            return LocalBookIndex(
                chapters: [LocalChapterDescriptor(name: only, path: only, pageEntries: entries)]
            )
        }

        // 根目录图片，或目录 + 根目录混合：整体作为一章
        let entries = images.sorted { naturalCompare($0, $1) == .orderedAscending }
        return LocalBookIndex(
            chapters: [LocalChapterDescriptor(name: bookTitle, path: "", pageEntries: entries)]
        )
    }

    /// 自然排序：把连续的十进制数字当作整数比较，其余部分忽略大小写。
    ///
    /// 例：`1.jpg` < `2.jpg` < `10.jpg`（字典序会得到 1, 10, 2 —— 阅读顺序就错了）。
    public static func naturalCompare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = Array(lhs.lowercased())
        let right = Array(rhs.lowercased())
        var i = 0
        var j = 0

        while i < left.count, j < right.count {
            let leftIsDigit = left[i].isNumber
            let rightIsDigit = right[j].isNumber

            if leftIsDigit, rightIsDigit {
                // 把数字段当**字符串**比较：先去前导零，再比长度、最后比字典序。
                // 这样任意长度（几十位）都正确且不会整数溢出 ——
                // 早先用「截断到上限」的办法会让超长数字无法区分。
                var leftDigits = ""
                var rightDigits = ""
                while i < left.count, left[i].isNumber {
                    leftDigits.append(left[i])
                    i += 1
                }
                while j < right.count, right[j].isNumber {
                    rightDigits.append(right[j])
                    j += 1
                }
                let leftTrimmed = leftDigits.drop { $0 == "0" }
                let rightTrimmed = rightDigits.drop { $0 == "0" }

                if leftTrimmed.count != rightTrimmed.count {
                    return leftTrimmed.count < rightTrimmed.count ? .orderedAscending : .orderedDescending
                }
                if leftTrimmed != rightTrimmed {
                    return leftTrimmed.lexicographicallyPrecedes(rightTrimmed) ? .orderedAscending : .orderedDescending
                }
                continue   // 数值相等（前导零不同），继续比较后续字符
            }

            if left[i] != right[j] {
                return left[i] < right[j] ? .orderedAscending : .orderedDescending
            }
            i += 1
            j += 1
        }

        if i == left.count, j == right.count { return .orderedSame }
        return i == left.count ? .orderedAscending : .orderedDescending
    }
}
