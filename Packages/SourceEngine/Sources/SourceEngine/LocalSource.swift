//
//  LocalSource.swift
//  SourceEngine
//
//  本地文件源：把用户导入的 CBZ / ZIP 变成可阅读的作品。
//
//  设计要点：
//  - **导入即复制**到 App 沙盒（`LocalLibrary/<slug>-<hash8>.cbz`），
//    这样用户把原文件删了/移走了也不影响阅读，且作品地址稳定；
//  - **幂等**：同名 = 同指纹（内容+大小派生），重复导入同一文件不会产生第二份；
//  - **原子写**：先写 `.importing` 临时文件再 move，中途失败清理临时文件，
//    不会留下半个归档；
//  - **路径穿越防护**：作品地址只允许「根目录名 / 单层文件名」这一种形态，
//    `../` 之类的输入直接拒绝；
//  - 归档按需打开并做小容量缓存：一话几 MB~几十 MB，避免每次翻页重复读盘。
//
//  依赖方向：AppCore（模型）、ComicDownload（ZIP 读取）。
//

import Foundation
import CryptoKit
import AppCore
import ComicDownload

/// 本地源错误。
public enum LocalSourceError: Error, Equatable {
    /// 只接受 .cbz / .zip。
    case unsupportedExtension(String)
    /// 源文件不存在。
    case sourceFileMissing(String)
    /// 不是合法的 ZIP（损坏或根本不是归档）。
    case notAZipArchive(String)
    /// 归档里没有图片。
    case noImages(String)
    /// 复制 / 写入失败。
    case importFailed(String)
    /// 作品地址不合法（含路径穿越尝试）。
    case invalidRelativePath(String)
    /// 找不到作品。
    case bookNotFound(String)
    /// 归档里找不到该页。
    case pageNotFound(String)
    /// 页码越界。
    case pageOutOfRange(index: Int, count: Int)

    public var message: String {
        switch self {
        case let .unsupportedExtension(ext): return "不支持的文件类型：.\(ext)（只接受 cbz / zip）"
        case let .sourceFileMissing(name): return "文件不存在：\(name)"
        case let .notAZipArchive(name): return "不是有效的 cbz/zip 归档：\(name)"
        case let .noImages(name): return "归档里没有图片：\(name)"
        case let .importFailed(reason): return "导入失败：\(reason)"
        case let .invalidRelativePath(path): return "作品地址不合法：\(path)"
        case let .bookNotFound(id): return "找不到本地作品：\(id)"
        case let .pageNotFound(name): return "归档里找不到页：\(name)"
        case let .pageOutOfRange(index, count): return "页码越界：\(index) / 共 \(count) 页"
        }
    }

    public var toAppError: AppError {
        switch self {
        case .unsupportedExtension, .noImages:
            return .invalidInput(message)
        case .sourceFileMissing, .bookNotFound, .pageNotFound:
            return .notFound(message)
        case .notAZipArchive, .importFailed:
            return .fileSystem(message)
        case .invalidRelativePath:
            return .invalidInput(message)
        case .pageOutOfRange:
            return .invalidInput(message)
        }
    }
}

extension LocalSourceError: LocalizedError {
    public var errorDescription: String? { message }
}

/// 作品侧车元数据（与归档同目录，`<归档名>.meta.json`）。
///
/// 为什么要它：归档文件名是「slug-指纹」（slug 里空格已被替换），
/// 直接拿文件名当标题会失真；侧车文件保存用户看到的原始标题。
struct LocalBookMeta: Codable, Equatable, Sendable {
    var title: String
    var importedAt: Date
    var chapterCount: Int
    var pageCount: Int
    var originalFileName: String
    /// 内容指纹。用于**按内容去重**：同名不同内容、或同内容不同名都能正确处理。
    var fingerprint: String?
}

/// 本地文件源。
public final class LocalSource: @unchecked Sendable {

    /// 归档目录（App 沙盒内）。
    public let rootDirectory: URL

    private let fileManager: FileManager
    /// 归档缓存锁。
    private let lock = NSLock()
    /// 导入临界区锁。**必须与 `lock` 分开**：临界区内会调用 `store(reader:)`，
    /// 而它同样要拿 `lock`，用同一把非递归锁会自锁死。
    private let importLock = NSLock()
    /// 归档缓存：key = 作品相对地址。容量小，避免同时持有多个大文件。
    private var readerCache: [(key: String, reader: ZipArchiveReader)] = []
    private let readerCacheCapacity = 2

    public init(rootDirectory: URL, fileManager: FileManager = .default) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
    }

    // MARK: 路径

    /// 归档目录名（作品地址的第一段）。
    public var rootComponent: String { rootDirectory.lastPathComponent }

    /// 由文件名构造作品相对地址。
    public func relativePath(forFileName fileName: String) -> String {
        "\(rootComponent)/\(fileName)"
    }

    /// 由作品相对地址解析磁盘路径。只接受「根目录名/单层文件名」形态。
    public func fileURL(forRelativePath path: String) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2,
              parts[0] == rootComponent,
              !parts[1].isEmpty,
              !parts[1].contains(".."),
              !parts[1].hasPrefix("."),
              !parts[1].hasSuffix("/") else {
            throw LocalSourceError.invalidRelativePath(path)
        }
        return rootDirectory.appendingPathComponent(parts[1], isDirectory: false)
    }

    private func metaURL(forArchiveAt url: URL) -> URL {
        url.appendingPathExtension("meta.json")
    }

    /// 由归档索引构造章节列表（导入与复用路径共用）。
    private func makeChapters(for bookPath: String, index: LocalBookIndex) -> [Chapter] {
        index.chapters.map { descriptor in
            Chapter(
                mangaID: Manga.makeID(sourceID: .local, url: bookPath),
                url: Self.chapterURL(bookPath: bookPath, chapterPath: descriptor.path),
                name: descriptor.name
            )
        }
    }

    /// 在已有归档里按内容指纹查找（用于导入幂等）。找不到返回 nil。
    private func existingArchive(matchingFingerprint fingerprint: String) throws -> URL? {
        guard fileManager.fileExists(atPath: rootDirectory.path) else { return nil }
        let names = (try? fileManager.contentsOfDirectory(atPath: rootDirectory.path)) ?? []
        for name in names where Self.supportedExtensions.contains((name as NSString).pathExtension.lowercased()) {
            let url = rootDirectory.appendingPathComponent(name, isDirectory: false)
            if readMeta(forArchiveAt: url)?.fingerprint == fingerprint {
                return url
            }
        }
        return nil
    }

    // MARK: 导入

    /// 导入一个 CBZ / ZIP。
    /// - Parameters:
    ///   - sourceURL: 用户选择的文件地址（可能来自「文件」App，需要已获得安全作用域访问）。
    ///   - now: 导入时间（可注入，便于测试）。
    /// - Returns: 作品与章节列表。
    /// - Throws: `LocalSourceError`
    @discardableResult
    public func importBook(from sourceURL: URL, now: Date = Date()) throws -> (manga: Manga, chapters: [Chapter]) {
        let fileExtension = sourceURL.pathExtension.lowercased()
        guard Self.supportedExtensions.contains(fileExtension) else {
            throw LocalSourceError.unsupportedExtension(fileExtension)
        }
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw LocalSourceError.sourceFileMissing(sourceURL.lastPathComponent)
        }

        let data: Data
        do {
            data = try Data(contentsOf: sourceURL)
        } catch {
            throw LocalSourceError.importFailed(error.localizedDescription)
        }

        // 先解析归档：既能校验格式，又能拿到章节结构
        let reader: ZipArchiveReader
        do {
            reader = try ZipArchiveReader(data: data)
        } catch {
            throw LocalSourceError.notAZipArchive(sourceURL.lastPathComponent)
        }

        let originalName = sourceURL.deletingPathExtension().lastPathComponent
        let title = Self.displayTitle(from: originalName)
        let index = LocalArchiveIndexer.index(entryNames: reader.entryNames, bookTitle: title)
        guard !index.chapters.isEmpty else {
            throw LocalSourceError.noImages(sourceURL.lastPathComponent)
        }

        // 指纹由「大小 + 首尾各 64KB」派生，兼顾稳定性与速度
        let fingerprint = Self.fingerprint(data)
        let fileName = Self.archiveFileName(slug: Self.slug(from: title), fingerprint: fingerprint, fileExtension: fileExtension)
        let destination = rootDirectory.appendingPathComponent(fileName, isDirectory: false)

        try ensureRootDirectory()

        // 幂等判据是**内容指纹**而不是文件名：同一份文件用不同名字导入时，
        // 直接复用已存在的那份，不产生第二份副本。
        // 整段「查重 + 落盘 + 写侧车」放进同一把锁，避免并发导入同内容时各写一份。
        let resolvedURL: URL
        importLock.lock()
        defer { importLock.unlock() }

        if let existing = try? existingArchive(matchingFingerprint: fingerprint) {
            resolvedURL = existing
            store(reader: reader, forKey: relativePath(forFileName: existing.lastPathComponent))
            diag("LocalSource: 内容已存在（指纹 \(fingerprint.prefix(8))），复用 \(existing.lastPathComponent)")
            let manga = Manga(
                sourceID: .local,
                url: relativePath(forFileName: existing.lastPathComponent),
                title: readMeta(forArchiveAt: existing)?.title ?? title
            )
            return (manga, makeChapters(for: manga.url, index: index))
        }

        if !fileManager.fileExists(atPath: destination.path) {
            let temporary = rootDirectory.appendingPathComponent("\(fileName).importing", isDirectory: false)
            do {
                try data.write(to: temporary, options: .atomic)
                try fileManager.moveItem(at: temporary, to: destination)
            } catch {
                try? fileManager.removeItem(at: temporary)
                throw LocalSourceError.importFailed(error.localizedDescription)
            }
        }
        resolvedURL = destination

        let meta = LocalBookMeta(
            title: title,
            importedAt: now,
            chapterCount: index.chapters.count,
            pageCount: index.pageCount,
            originalFileName: sourceURL.lastPathComponent,
            fingerprint: fingerprint
        )
        try? writeMeta(meta, forArchiveAt: destination)

        // 归档已落盘：把刚解析过的 reader 放进缓存，导入后立刻阅读无需重读
        store(reader: reader, forKey: relativePath(forFileName: resolvedURL.lastPathComponent))

        let manga = Manga(
            sourceID: .local,
            url: relativePath(forFileName: resolvedURL.lastPathComponent),
            title: title
        )
        let chapters = makeChapters(for: manga.url, index: index)
        diag("LocalSource: 导入 \(sourceURL.lastPathComponent) → \(resolvedURL.lastPathComponent)，\(chapters.count) 章 / \(index.pageCount) 页")
        return (manga, chapters)
    }

    /// 删除作品（归档 + 侧车）。
    @discardableResult
    public func removeBook(mangaID: String) throws -> Bool {
        guard let path = Self.relativePath(fromMangaID: mangaID) else {
            throw LocalSourceError.invalidRelativePath(mangaID)
        }
        let url = try fileURL(forRelativePath: path)
        guard fileManager.fileExists(atPath: url.path) else { return false }
        try fileManager.removeItem(at: url)
        try? fileManager.removeItem(at: metaURL(forArchiveAt: url))
        discardReader(forKey: path)
        diag("LocalSource: 删除本地作品 \(path)")
        return true
    }

    // MARK: 查询

    /// 列出归档目录里的全部作品（文件系统是本地作品的事实来源）。
    public func books() throws -> [Manga] {
        guard fileManager.fileExists(atPath: rootDirectory.path) else { return [] }
        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(atPath: rootDirectory.path)
        } catch {
            throw LocalSourceError.importFailed(error.localizedDescription)
        }

        let archives = names.filter { name in
            Self.supportedExtensions.contains((name as NSString).pathExtension.lowercased())
        }
        return archives
            .sorted { LocalArchiveIndexer.naturalCompare($0, $1) == .orderedAscending }
            .map { name in
                let path = relativePath(forFileName: name)
                let url = rootDirectory.appendingPathComponent(name, isDirectory: false)
                let title = readMeta(forArchiveAt: url)?.title ?? Self.displayTitle(from: Self.strippingFingerprint(name))
                return Manga(sourceID: .local, url: path, title: title)
            }
    }

    /// 重新推导某作品的章节列表（不依赖数据库）。
    public func chapters(for manga: Manga) throws -> [Chapter] {
        let url = try fileURL(forRelativePath: manga.url)
        guard fileManager.fileExists(atPath: url.path) else {
            throw LocalSourceError.bookNotFound(manga.id)
        }
        let reader = try openReader(for: manga.url, at: url)
        let title = readMeta(forArchiveAt: url)?.title ?? manga.title
        let index = LocalArchiveIndexer.index(entryNames: reader.entryNames, bookTitle: title)
        guard !index.chapters.isEmpty else {
            throw LocalSourceError.noImages(url.lastPathComponent)
        }
        return index.chapters.map { descriptor in
            Chapter(
                mangaID: manga.id,
                url: Self.chapterURL(bookPath: manga.url, chapterPath: descriptor.path),
                name: descriptor.name
            )
        }
    }

    /// 某章节的页列表。
    public func pages(for chapter: Chapter, manga: Manga) throws -> [ComicPage] {
        guard let chapterPath = Self.chapterPath(fromChapterURL: chapter.url) else {
            throw LocalSourceError.invalidRelativePath(chapter.url)
        }
        let url = try fileURL(forRelativePath: manga.url)
        guard fileManager.fileExists(atPath: url.path) else {
            throw LocalSourceError.bookNotFound(manga.id)
        }
        let reader = try openReader(for: manga.url, at: url)
        let title = readMeta(forArchiveAt: url)?.title ?? manga.title
        let index = LocalArchiveIndexer.index(entryNames: reader.entryNames, bookTitle: title)

        let descriptor: LocalChapterDescriptor?
        if chapterPath.isEmpty {
            descriptor = index.chapters.first { $0.path.isEmpty }
                ?? (index.chapters.count == 1 ? index.chapters[0] : nil)
        } else {
            descriptor = index.chapters.first { $0.path == chapterPath }
        }
        guard let descriptor else {
            throw LocalSourceError.bookNotFound("\(manga.id) 的章节 \(chapterPath)")
        }
        return descriptor.pageEntries.enumerated().map { offset, entry in
            ComicPage(index: offset, imageURL: entry)
        }
    }

    /// 取出某页的图片数据（同步核心）。
    public func imageDataSync(for page: ComicPage, manga: Manga) throws -> Data {
        let url = try fileURL(forRelativePath: manga.url)
        guard fileManager.fileExists(atPath: url.path) else {
            throw LocalSourceError.bookNotFound(manga.id)
        }
        let reader = try openReader(for: manga.url, at: url)
        do {
            return try reader.data(for: page.imageURL)
        } catch let error as ZipArchiveError {
            switch error {
            case let .entryNotFound(name):
                throw LocalSourceError.pageNotFound(name)
            default:
                throw LocalSourceError.notAZipArchive("\(url.lastPathComponent)：\(error.message)")
            }
        }
    }

    /// 本地作品数量（含未导入数据库的）。
    public func bookCount() throws -> Int {
        try books().count
    }

    // MARK: 归档缓存

    private func openReader(for key: String, at url: URL) throws -> ZipArchiveReader {
        lock.lock()
        if let cached = readerCache.first(where: { $0.key == key }) {
            lock.unlock()
            return cached.reader
        }
        lock.unlock()

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LocalSourceError.importFailed(error.localizedDescription)
        }
        do {
            let reader = try ZipArchiveReader(data: data)
            store(reader: reader, forKey: key)
            return reader
        } catch {
            throw LocalSourceError.notAZipArchive(url.lastPathComponent)
        }
    }

    private func store(reader: ZipArchiveReader, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        readerCache.removeAll { $0.key == key }
        readerCache.append((key: key, reader: reader))
        if readerCache.count > readerCacheCapacity {
            readerCache.removeFirst(readerCache.count - readerCacheCapacity)
        }
    }

    private func discardReader(forKey key: String) {
        lock.lock()
        readerCache.removeAll { $0.key == key }
        lock.unlock()
    }

    // MARK: 侧车

    private func writeMeta(_ meta: LocalBookMeta, forArchiveAt url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(meta).write(to: metaURL(forArchiveAt: url), options: .atomic)
        } catch {
            throw LocalSourceError.importFailed(error.localizedDescription)
        }
    }

    private func readMeta(forArchiveAt url: URL) -> LocalBookMeta? {
        let metaURL = metaURL(forArchiveAt: url)
        guard let data = try? Data(contentsOf: metaURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LocalBookMeta.self, from: data)
    }

    private func ensureRootDirectory() throws {
        do {
            if !fileManager.fileExists(atPath: rootDirectory.path) {
                try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
            }
        } catch {
            throw LocalSourceError.importFailed(error.localizedDescription)
        }
    }

    // MARK: 纯函数工具

    /// 支持的扩展名。
    public static let supportedExtensions: Set<String> = ["cbz", "zip"]

    /// 章节地址格式：`<作品地址>#<章节目录路径>`（路径为空表示整本一章）。
    public static func chapterURL(bookPath: String, chapterPath: String) -> String {
        "\(bookPath)#\(chapterPath)"
    }

    /// 从章节地址里取章节目录路径；格式不合法返回 nil。
    public static func chapterPath(fromChapterURL url: String) -> String? {
        guard let hashIndex = url.lastIndex(of: "#") else { return nil }
        let bookPath = String(url[url.startIndex..<hashIndex])
        // 井号只允许出现一次，且作品地址必须是「根目录/文件名」
        guard !bookPath.contains("#") else { return nil }
        guard bookPath.split(separator: "/", omittingEmptySubsequences: false).count == 2,
              !bookPath.hasSuffix("/") else { return nil }
        let chapterPath = String(url[url.index(after: hashIndex)...])
        guard !chapterPath.contains("#") else { return nil }
        return chapterPath
    }

    /// 从作品 ID（`local|<相对地址>`）取相对地址。
    public static func relativePath(fromMangaID mangaID: String) -> String? {
        guard let separator = mangaID.firstIndex(of: "|") else { return nil }
        let path = String(mangaID[mangaID.index(after: separator)...])
        return path.isEmpty ? nil : path
    }

    /// 归档文件名：`<slug>-<指纹前 8 位>.<ext>`。
    public static func archiveFileName(slug: String, fingerprint: String, fileExtension: String) -> String {
        let safeSlug = slug.isEmpty ? "book" : slug
        return "\(safeSlug)-\(fingerprint.prefix(8)).\(fileExtension)"
    }

    /// 由原始文件名得到展示标题：去掉常见发布组后缀与多余空白。
    public static func displayTitle(from fileName: String) -> String {
        var title = fileName
        // 去掉结尾的方括号/圆括号标记（常见于发布组、版本、分辨率标注）
        for pattern in [#"\s*[\[\(][^\]\)]*[\]\)]\s*$"#, #"\s+$"#] {
            if let range = title.range(of: pattern, options: .regularExpression) {
                title = String(title[title.startIndex..<range.lowerBound])
            }
        }
        let collapsed = title
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.isEmpty ? fileName : collapsed
    }

    /// 去掉文件名里的 `-<8位十六进制>` 指纹后缀。
    public static func strippingFingerprint(_ fileName: String) -> String {
        let base = (fileName as NSString).deletingPathExtension
        guard let range = base.range(of: #"-[0-9a-f]{8}$"#, options: .regularExpression) else {
            return base
        }
        return String(base[base.startIndex..<range.lowerBound])
    }

    /// 由标题生成文件名用的 slug：保留字母/数字/CJK，其余折叠为 `-`。
    public static func slug(from title: String, maxLength: Int = 40) -> String {
        var output = ""
        var lastWasDash = false
        for scalar in title.unicodeScalars {
            let isAllowed = CharacterSet.alphanumerics.contains(scalar)
            if isAllowed {
                output.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                output.append("-")
                lastWasDash = true
            }
            if output.count >= maxLength { break }
        }
        let trimmed = output.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "book" : trimmed
    }

    /// 内容指纹：大小 + 首尾各 64 KB（稳定且不必读整个大文件）。
    public static func fingerprint(_ data: Data) -> String {
        var sample = Data()
        withUnsafeBytes(of: UInt64(data.count).littleEndian) { sample.append(contentsOf: $0) }
        let window = 64 * 1024
        if data.count <= window * 2 {
            sample.append(data)
        } else {
            sample.append(data.prefix(window))
            sample.append(data.suffix(window))
        }
        let digest = SHA256.hash(data: sample)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - PageDataProviding

extension LocalSource: PageDataProviding {
    /// 阅读器统一入口：本地页直接同步读取（数据在沙盒内，无需网络）。
    public func imageData(for page: ComicPage, manga: Manga, chapter: Chapter) async throws -> Data {
        // 章节目录路径已在 page.imageURL 里体现（条目名含目录），无需再用 chapter
        _ = chapter
        return try imageDataSync(for: page, manga: manga)
    }
}
