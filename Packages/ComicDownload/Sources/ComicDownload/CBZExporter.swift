//
//  CBZExporter.swift
//  ComicDownload
//
//  把已下载的页打包成 CBZ（ZIP），用于导出到「文件」App、
//  分享给其他设备或备份。
//
//  命名规则：页序号 4 位零填充 + 扩展名（`0001.jpg`），
//  保证各种阅读器按字典序读到的顺序与阅读顺序一致。
//

import Foundation
import AppCore

/// 待打包的一页。
public struct CbzPage: Equatable, Sendable {
    public let index: Int
    public let data: Data
    public let fileExtension: String

    public init(index: Int, data: Data, fileExtension: String = "jpg") {
        self.index = index
        self.data = data
        self.fileExtension = fileExtension
    }
}

/// CBZ 导出错误。
public enum CbzExportError: Error, Equatable {
    case noPages
    case tooManyPages(Int)
    case invalidExtension(String)
    case invalidTitle(String)

    public var message: String {
        switch self {
        case .noPages: return "没有可导出的页"
        case let .tooManyPages(count): return "页数过多（\(count)）"
        case let .invalidExtension(ext): return "扩展名不合法：\(ext)"
        case let .invalidTitle(title): return "标题不合法：\(title)"
        }
    }
}

extension CbzExportError: LocalizedError {
    public var errorDescription: String? { message }
}

/// CBZ 导出器。
public struct CbzExporter {

    /// 单本 CBZ 页数上限（防御性）。
    public static let maxPages = 5_000
    /// 允许的图片扩展名。
    public static let allowedExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "avif"]

    private let maxPages: Int

    public init(maxPages: Int = CbzExporter.maxPages) {
        self.maxPages = max(1, maxPages)
    }

    /// 页文件名：`0001.jpg`（4 位零填充，超过 9999 页自动加宽）。
    public static func defaultPageName(index: Int) -> String {
        let width = index >= 10_000 ? 5 : 4
        return String(format: "%0\(width)d.jpg", index + 1)
    }

    /// 打包为 CBZ 数据。
    /// - Throws: `CbzExportError` / `ZipArchiveError`
    public func export(
        pages: [CbzPage],
        title: String?,
        date: Date = Date()
    ) throws -> Data {
        guard !pages.isEmpty else { throw CbzExportError.noPages }
        guard pages.count <= maxPages else { throw CbzExportError.tooManyPages(pages.count) }

        for page in pages {
            let ext = page.fileExtension.lowercased()
            guard CbzExporter.allowedExtensions.contains(ext) else {
                throw CbzExportError.invalidExtension(page.fileExtension)
            }
        }

        let sorted = pages.sorted { $0.index < $1.index }

        var writer = ZipArchiveWriter()
        if let title {
            let trimmed = ModelValidation.sanitizeTitle(title, maxLength: 200)
            guard !trimmed.isEmpty else { throw CbzExportError.invalidTitle(title) }
            let info = "title: \(trimmed)\npages: \(sorted.count)\n"
            try writer.addFile(name: "comicinfo.txt", data: Data(info.utf8), date: date)
        }

        for page in sorted {
            let name = CbzExporter.pageName(index: page.index, fileExtension: page.fileExtension)
            try writer.addFile(name: name, data: page.data, date: date)
        }

        return try writer.finalize()
    }

    /// 写入文件。
    public func export(
        pages: [CbzPage],
        title: String?,
        to url: URL,
        date: Date = Date()
    ) throws -> Int {
        let data = try export(pages: pages, title: title, date: date)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw AppError.normalize(error)
        }
        return data.count
    }

    /// 页名（含扩展名）。
    public static func pageName(index: Int, fileExtension: String) -> String {
        let ext = fileExtension.lowercased()
        let width = index >= 10_000 ? 5 : 4
        return String(format: "%0\(width)d.%@", index + 1, ext)
    }
}
