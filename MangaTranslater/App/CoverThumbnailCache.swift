//
//  CoverThumbnailCache.swift
//  MangaTranslater
//
//  书架封面缩略图缓存。
//
//  为什么放在 App 层而不是包里：缩放依赖 UIKit / CoreGraphics，
//  而 `AppCore`、`SourceEngine` 都要求纯 Foundation（便于跑在无 UI 的测试里）。
//  因此职责切成两段：
//  - `LocalSource.coverData(for:)` 只负责「取出首页的原始字节」（可单测）；
//  - 本类负责「缩放成缩略图 + 落盘缓存」（依赖平台图形框架）。
//
//  缓存策略：内存 → 磁盘 → 重新生成。文件名由作品 ID 哈希派生，
//  因此不需要清理逻辑也能保证同一作品只占一个文件；写入用原子替换。
//

import Foundation
import UIKit
import CryptoKit
import AppCore

/// 封面缩略图缓存（线程安全）。
final class CoverThumbnailCache: @unchecked Sendable {

    /// 缩略图最长边（像素）。512 在 3x 屏上够书架大网格用，单文件约几十 KB。
    static let defaultMaxPixel = 512
    /// JPEG 压缩质量。
    static let compressionQuality: CGFloat = 0.8

    let directory: URL
    private let fileManager: FileManager
    private let maxPixel: CGFloat
    private let lock = NSLock()
    private var memory: [String: Data] = [:]

    init(
        dataDirectory: URL,
        maxPixel: CGFloat = CGFloat(CoverThumbnailCache.defaultMaxPixel),
        fileManager: FileManager = .default
    ) {
        self.directory = dataDirectory.appendingPathComponent("Covers", isDirectory: true)
        self.maxPixel = maxPixel
        self.fileManager = fileManager
    }

    // MARK: 读取

    /// 取缩略图。命中内存或磁盘直接返回；否则调用 `load` 取原图生成。
    ///
    /// - Parameter load: 返回封面原图数据（如 `LocalSource.coverData(for:)`）。
    /// - Returns: 缩略图 JPEG 数据；原图缺失或不是有效图片时返回 nil（不抛错）。
    func thumbnail(mangaID: String, load: () throws -> Data?) -> Data? {
        if let cached = memoryThumbnail(mangaID: mangaID) { return cached }
        if let onDisk = diskThumbnail(mangaID: mangaID) {
            storeInMemory(onDisk, mangaID: mangaID)
            return onDisk
        }
        // 注意：Swift 5 起 `try?` 会**折叠**嵌套 Optional，
        // 所以 `try? load()` 的类型是 `Data?` 而不是 `Data??` —— 只解一层。
        guard let original = try? load(), !original.isEmpty else { return nil }
        guard let generated = Self.makeThumbnail(from: original, maxPixel: maxPixel) else {
            diag("CoverThumbnailCache: 封面不是有效图片，跳过 —— \(mangaID)")
            return nil
        }
        storeInMemory(generated, mangaID: mangaID)
        writeToDisk(generated, mangaID: mangaID)
        return generated
    }

    /// 已在内存 / 磁盘缓存里的缩略图（不触发生成）。
    func cachedThumbnail(mangaID: String) -> Data? {
        memoryThumbnail(mangaID: mangaID) ?? diskThumbnail(mangaID: mangaID)
    }

    /// 清空内存与磁盘缓存。
    @discardableResult
    func removeAll() -> Int {
        lock.lock()
        let count = memory.count
        memory.removeAll()
        lock.unlock()

        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return count }
        var removed = 0
        for name in names {
            let url = directory.appendingPathComponent(name, isDirectory: false)
            if (try? fileManager.removeItem(at: url)) != nil { removed += 1 }
        }
        diag("CoverThumbnailCache: 清空缓存（内存 \(count) 项 / 磁盘 \(removed) 项）")
        return count + removed
    }

    // MARK: 内存

    private func memoryThumbnail(mangaID: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return memory[mangaID]
    }

    private func storeInMemory(_ data: Data, mangaID: String) {
        lock.lock()
        memory[mangaID] = data
        lock.unlock()
    }

    // MARK: 磁盘

    /// 缩略图磁盘路径。
    func fileURL(mangaID: String) -> URL {
        directory.appendingPathComponent(Self.fileName(for: mangaID), isDirectory: false)
    }

    private func diskThumbnail(mangaID: String) -> Data? {
        let url = fileURL(mangaID: mangaID)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return data
    }

    private func writeToDisk(_ data: Data, mangaID: String) {
        do {
            if !fileManager.fileExists(atPath: directory.path) {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            try data.write(to: fileURL(mangaID: mangaID), options: .atomic)
        } catch {
            // 缓存写失败不影响阅读，只记日志
            diag("CoverThumbnailCache: 写入缓存失败 —— \(error.localizedDescription)")
        }
    }

    // MARK: 纯函数

    /// 由作品 ID 派生缓存文件名。
    ///
    /// 作品 ID 形如 `local|LocalLibrary/book-abcd1234.cbz`，含 `/`、`|` 与中文，
    /// 不能直接当文件名，因此取 SHA256 前 16 位十六进制。
    static func fileName(for mangaID: String) -> String {
        let digest = SHA256.hash(data: Data(mangaID.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined().prefix(16)
        return "\(hex).jpg"
    }

    /// 等比缩放到最长边不超过 `maxPixel` 的尺寸。
    ///
    /// 规则：
    /// - 宽高都 ≤ maxPixel 时**不放大**（返回原尺寸），避免小图被拉糊；
    /// - 保持宽高比；
    /// - 非法尺寸（0 或负数）返回 `.zero`；
    /// - 结果至少 1×1（避免出现 0 宽的图片）。
    static func thumbnailSize(forPixelSize size: CGSize, maxPixel: CGFloat) -> CGSize {
        guard size.width > 0, size.height > 0, maxPixel > 0 else { return .zero }
        let longest = max(size.width, size.height)
        guard longest > maxPixel else { return size }

        let scale = maxPixel / longest
        return CGSize(
            width: max(1, (size.width * scale).rounded()),
            height: max(1, (size.height * scale).rounded())
        )
    }

    /// 生成缩略图 JPEG。数据不是有效图片时返回 nil。
    static func makeThumbnail(from data: Data, maxPixel: CGFloat) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let target = thumbnailSize(forPixelSize: image.size, maxPixel: maxPixel)
        guard target != .zero else { return nil }

        // 已经足够小：直接重新编码（统一成 JPEG，便于磁盘缓存与后续解码）
        if target == image.size {
            return image.jpegData(compressionQuality: compressionQuality)
        }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: compressionQuality)
    }
}
