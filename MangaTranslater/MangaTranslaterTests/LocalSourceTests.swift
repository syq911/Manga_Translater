//
//  LocalSourceTests.swift
//  MangaTranslaterTests
//
//  本地文件源（CBZ / ZIP）测试：归档索引规则、导入幂等与原子性、章节与页、
//  路径穿越防护、缓存、删除与并发。
//
//  夹具由**外部实现**（Python zipfile）生成并以 base64 内联：
//  - 多章归档：两个目录各 3 页，混入 __MACOSX / .DS_Store / 非图片噪音；
//  - 根目录归档：1.jpg / 2.jpg / 10.jpg —— 专门验证自然排序（字典序会排成 1,10,2）；
//  - 单目录归档：Chapter A/01.png、02.png；
//  - 无图片归档：只有文本。
//

import Testing
import Foundation
import AppCore
import ComicDownload
import SourceEngine

@Suite("本地文件源")
struct LocalSourceTests {

    /// 两话各 3 页，含 __MACOSX/.DS_Store/非图片噪音；共 1134 字节（外部实现 Python zipfile 生成）。
    static let multiChapterArchive = Data(
        base64Encoded: """
        UEsDBBQAAAgIAAAAIVzkEfQhEgAAAJMAAAAPAAAA56ysMeivnS8wMDEuanBn+3/jv7OHoa6B
        gaFeVkH6oKAAUEsDBBQAAAgIAAAAIVx87gYbEgAAAJMAAAAPAAAA56ysMeivnS8wMDIuanBn
        +3/jv7OHoa6BgZFeVkH6oKAAUEsDBBQAAAgIAAAAIVz0RFcNEgAAAJMAAAAPAAAA56ysMeiv
        nS8wMDMuanBn+3/jv7OHoa6BgbFeVkH6oKAAUEsDBBQAAAgIAAAAIVxdaUzZEgAAAJMAAAAP
        AAAA56ysMuivnS8wMDEuanBn+3/jv7OHka6BgaFeVkH6oKAAUEsDBBQAAAgIAAAAIVzFlr7j
        EgAAAJMAAAAPAAAA56ysMuivnS8wMDIuanBn+3/jv7OHka6BgZFeVkH6oKAAUEsDBBQAAAgI
        AAAAIVxtmWgsEgAAAJMAAAAPAAAA56ysMuivnS8wMTAuanBn+3/jv7OHka6BoYFeVkH6oKAA
        UEsDBBQAAAgIAAAAIVyBt/7/DQAAAAsAAAAaAAAAX19NQUNPU1gv56ysMeivnS8uXzAwMS5q
        cGfLTUzOL9bNy88sTgUAUEsDBBQAAAAIAAAAIVwplqn9BwAAAAUAAAAJAAAALkRTX1N0b3Jl
        y8vPLE4FAFBLAwQUAAAICAAAACFcL92yxw4AAAAMAAAAEgAAAOesrDHor50vcmVhZG1lLnR4
        dMvLL1FIzFPIzE1MTwUAUEsBAhQAFAAACAgAAAAhXOQR9CESAAAAkwAAAA8AAAAAAAAAAAAA
        AIABAAAAAOesrDHor50vMDAxLmpwZ1BLAQIUABQAAAgIAAAAIVx87gYbEgAAAJMAAAAPAAAA
        AAAAAAAAAACAAT8AAADnrKwx6K+dLzAwMi5qcGdQSwECFAAUAAAICAAAACFc9ERXDRIAAACT
        AAAADwAAAAAAAAAAAAAAgAF+AAAA56ysMeivnS8wMDMuanBnUEsBAhQAFAAACAgAAAAhXF1p
        TNkSAAAAkwAAAA8AAAAAAAAAAAAAAIABvQAAAOesrDLor50vMDAxLmpwZ1BLAQIUABQAAAgI
        AAAAIVzFlr7jEgAAAJMAAAAPAAAAAAAAAAAAAACAAfwAAADnrKwy6K+dLzAwMi5qcGdQSwEC
        FAAUAAAICAAAACFcbZloLBIAAACTAAAADwAAAAAAAAAAAAAAgAE7AQAA56ysMuivnS8wMTAu
        anBnUEsBAhQAFAAACAgAAAAhXIG3/v8NAAAACwAAABoAAAAAAAAAAAAAAIABegEAAF9fTUFD
        T1NYL+esrDHor50vLl8wMDEuanBnUEsBAhQAFAAAAAgAAAAhXCmWqf0HAAAABQAAAAkAAAAA
        AAAAAAAAAIABvwEAAC5EU19TdG9yZVBLAQIUABQAAAgIAAAAIVwv3bLHDgAAAAwAAAASAAAA
        AAAAAAAAAACAAe0BAADnrKwx6K+dL3JlYWRtZS50eHRQSwUGAAAAAAkACQAtAgAAKwIAAAAA
        """,
        options: .ignoreUnknownCharacters
    )!

    /// 图片全在根目录：1.jpg/2.jpg/10.jpg（验证自然排序）；共 334 字节（外部实现 Python zipfile 生成）。
    static let singleChapterRootArchive = Data(
        base64Encoded: """
        UEsDBBQAAAAIAAAAIVwUv0CjEQAAADoAAAAFAAAAMS5qcGf7f+N/kL9/iK6hXlZBOkkEAFBL
        AwQUAAAACAAAACFcaRbJCREAAAA6AAAABQAAADIuanBn+3/jf5C/f4iukV5WQTpJBABQSwME
        FAAAAAgAAAAhXHRU484SAAAARAAAAAYAAAAxMC5qcGf7f+N/kL9/iK6hgV5WQTp5JABQSwEC
        FAAUAAAACAAAACFcFL9AoxEAAAA6AAAABQAAAAAAAAAAAAAAgAEAAAAAMS5qcGdQSwECFAAU
        AAAACAAAACFcaRbJCREAAAA6AAAABQAAAAAAAAAAAAAAgAE0AAAAMi5qcGdQSwECFAAUAAAA
        CAAAACFcdFTjzhIAAABEAAAABgAAAAAAAAAAAAAAgAFoAAAAMTAuanBnUEsFBgAAAAADAAMA
        mgAAAJ4AAAAAAA==
        """,
        options: .ignoreUnknownCharacters
    )!

    /// 图片全在一个目录：Chapter A/01.png、02.png；共 288 字节（外部实现 Python zipfile 生成）。
    static let singleFolderArchive = Data(
        base64Encoded: """
        UEsDBBQAAAAIAAAAIVwJjkJ3GQAAAEsAAAAQAAAAQ2hhcHRlciBBLzAxLnBuZ+sM8HPn5ZLi
        Cvb0c/dx1TUw1CvISyePBABQSwMEFAAAAAgAAAAhXMnR28IZAAAASwAAABAAAABDaGFwdGVy
        IEEvMDIucG5n6wzwc+flkuIK9vRz93HVNTDSK8hLJ48EAFBLAQIUABQAAAAIAAAAIVwJjkJ3
        GQAAAEsAAAAQAAAAAAAAAAAAAACAAQAAAABDaGFwdGVyIEEvMDEucG5nUEsBAhQAFAAAAAgA
        AAAhXMnR28IZAAAASwAAABAAAAAAAAAAAAAAAIABRwAAAENoYXB0ZXIgQS8wMi5wbmdQSwUG
        AAAAAAIAAgB8AAAAjgAAAAAA
        """,
        options: .ignoreUnknownCharacters
    )!

    /// 只有文本，没有图片；共 130 字节（外部实现 Python zipfile 生成）。
    static let noImagesArchive = Data(
        base64Encoded: """
        UEsDBBQAAAAAAAAAIVyT2cExDAAAAAwAAAAKAAAAcmVhZG1lLnR4dG5vdGhpbmcgaGVyZVBL
        AQIUABQAAAAAAAAAIVyT2cExDAAAAAwAAAAKAAAAAAAAAAAAAACAAQAAAAByZWFkbWUudHh0
        UEsFBgAAAAABAAEAOAAAADQAAAAAAA==
        """,
        options: .ignoreUnknownCharacters
    )!

    // MARK: 夹具

    /// 把内联归档写成临时文件，模拟用户从「文件」App 选中的文件。
    private func writeTemporaryArchive(
        _ data: Data,
        fileName: String,
        in directory: URL
    ) throws -> URL {
        let url = directory.appendingPathComponent(fileName, isDirectory: false)
        try data.write(to: url, options: .atomic)
        return url
    }

    private func makeSource() throws -> (LocalSource, URL) {
        let root = try TestFileSystem.makeTemporaryDirectory()
        let library = root.appendingPathComponent("LocalLibrary", isDirectory: true)
        return (LocalSource(rootDirectory: library), root)
    }

    // MARK: 索引纯函数：噪音与图片判定

    @Test("噪音条目被识别", arguments: [
        "__MACOSX/第1话/._001.jpg",
        "第1话/._001.jpg",
        ".DS_Store",
        "第1话/.hidden.jpg",
        "Thumbs.db",
        "第1话/",
        "",
    ])
    func detectsNoise(entry: String) {
        #expect(LocalArchiveIndexer.isNoiseEntry(entry))
        #expect(!LocalArchiveIndexer.isImageEntry(entry))
    }

    @Test("图片条目判定", arguments: [
        "001.jpg", "page.PNG", "a/b/c.jpeg", "x.webp", "y.avif", "z.heic",
    ])
    func detectsImages(entry: String) {
        #expect(LocalArchiveIndexer.isImageEntry(entry))
    }

    @Test("非图片条目被排除", arguments: ["readme.txt", "a/b/info.xml", "cover.psd", "noext"])
    func rejectsNonImages(entry: String) {
        #expect(!LocalArchiveIndexer.isImageEntry(entry))
    }

    // MARK: 索引纯函数：自然排序

    @Test("自然排序把数字当整数比较")
    func naturalSortOrdersNumbers() {
        let names = ["10.jpg", "2.jpg", "1.jpg", "3.jpg"]
        let sorted = names.sorted { LocalArchiveIndexer.naturalCompare($0, $1) == .orderedAscending }
        #expect(sorted == ["1.jpg", "2.jpg", "3.jpg", "10.jpg"])
    }

    @Test("自然排序处理多段数字与大小写")
    func naturalSortHandlesSegments() {
        let names = ["p1-10.jpg", "p1-2.jpg", "P1-1.JPG"]
        let sorted = names.sorted { LocalArchiveIndexer.naturalCompare($0, $1) == .orderedAscending }
        #expect(sorted == ["P1-1.JPG", "p1-2.jpg", "p1-10.jpg"])
    }

    @Test("自然排序：相等与前缀")
    func naturalSortEdgeCases() {
        #expect(LocalArchiveIndexer.naturalCompare("a1.jpg", "A1.JPG") == .orderedSame)
        #expect(LocalArchiveIndexer.naturalCompare("a", "a1") == .orderedAscending)
        #expect(LocalArchiveIndexer.naturalCompare("b", "a") == .orderedDescending)
    }

    @Test("超长数字不会溢出")
    func naturalSortHandlesHugeNumbers() {
        let big = String(repeating: "9", count: 30)
        #expect(LocalArchiveIndexer.naturalCompare("\(big).jpg", "1.jpg") == .orderedDescending)
        #expect(LocalArchiveIndexer.naturalCompare("\(big).jpg", "\(big)0.jpg") == .orderedAscending)
    }

    // MARK: 索引纯函数：分章规则

    @Test("多目录 → 每目录一章，按自然序")
    func indexesMultipleDirectories() {
        let index = LocalArchiveIndexer.index(
            entryNames: ["第2话/001.jpg", "第1话/001.jpg", "第1话/002.jpg", ".DS_Store"],
            bookTitle: "Book"
        )
        #expect(index.chapters.map(\.name) == ["第1话", "第2话"])
        #expect(index.chapters[0].pageEntries == ["第1话/001.jpg", "第1话/002.jpg"])
        #expect(index.pageCount == 3)
    }

    @Test("根目录图片 → 单章，章名取书名")
    func indexesRootImages() {
        let index = LocalArchiveIndexer.index(
            entryNames: ["1.jpg", "10.jpg", "2.jpg"],
            bookTitle: "My Book"
        )
        #expect(index.chapters.count == 1)
        #expect(index.chapters[0].name == "My Book")
        #expect(index.chapters[0].path.isEmpty)
        #expect(index.chapters[0].pageEntries == ["1.jpg", "2.jpg", "10.jpg"])
    }

    @Test("单个目录 → 单章，章名取目录名")
    func indexesSingleDirectory() {
        let index = LocalArchiveIndexer.index(
            entryNames: ["Chapter A/02.png", "Chapter A/01.png"],
            bookTitle: "Book"
        )
        #expect(index.chapters.count == 1)
        #expect(index.chapters[0].name == "Chapter A")
        #expect(index.chapters[0].pageEntries == ["Chapter A/01.png", "Chapter A/02.png"])
    }

    @Test("根目录与目录混合 → 整体一章")
    func indexesMixedLayout() {
        let index = LocalArchiveIndexer.index(
            entryNames: ["cover.jpg", "第1话/001.jpg", "第2话/001.jpg"],
            bookTitle: "Mixed"
        )
        #expect(index.chapters.count == 1)
        #expect(index.chapters[0].name == "Mixed")
        #expect(index.chapters[0].pageEntries.count == 3)
    }

    @Test("没有图片时返回空章节")
    func indexesNoImages() {
        let index = LocalArchiveIndexer.index(entryNames: ["readme.txt", ".DS_Store"], bookTitle: "X")
        #expect(index.chapters.isEmpty)
        #expect(index.pageCount == 0)
    }

    // MARK: 导入

    @Test("导入多章归档：章节名、页数与噪音过滤都正确")
    func importsMultiChapterArchive() throws {
        let (source, root) = try makeSource()
        defer { TestFileSystem.remove(root) }

        let file = try writeTemporaryArchive(Self.multiChapterArchive, fileName: "作品 [汉化组].cbz", in: root)
        let (manga, chapters) = try source.importBook(from: file)

        #expect(manga.sourceID == .local)
        #expect(manga.title == "作品")           // 去掉方括号后缀
        #expect(chapters.count == 2)
        #expect(chapters.map(\.name) == ["第1话", "第2话"])
        #expect(chapters[0].mangaID == manga.id)

        let firstPages = try source.pages(for: chapters[0], manga: manga)
        let secondPages = try source.pages(for: chapters[1], manga: manga)
        #expect(firstPages.count == 3)
        #expect(secondPages.count == 3)
        // 第 2 话里 010.jpg 应排在 002.jpg 之后
        #expect(secondPages.map { ($0.imageURL as NSString).lastPathComponent } == ["001.jpg", "002.jpg", "010.jpg"])
        #expect(secondPages.first?.index == 0)
    }

    @Test("导入根目录归档：自然排序保证阅读顺序")
    func importsRootLayoutArchive() throws {
        let (source, root) = try makeSource()
        defer { TestFileSystem.remove(root) }

        let file = try writeTemporaryArchive(Self.singleChapterRootArchive, fileName: "Root.cbz", in: root)
        let (manga, chapters) = try source.importBook(from: file)

        let pages = try source.pages(for: chapters[0], manga: manga)
        #expect(pages.map { ($0.imageURL as NSString).lastPathComponent } == ["1.jpg", "2.jpg", "10.jpg"])
    }

    @Test("导入单目录归档：章名取目录名")
    func importsSingleFolderArchive() throws {
        let (source, root) = try makeSource()
        defer { TestFileSystem.remove(root) }

        let file = try writeTemporaryArchive(Self.singleFolderArchive, fileName: "Folder.cbz", in: root)
        let (manga, chapters) = try source.importBook(from: file)
        #expect(chapters.count == 1)
        #expect(chapters[0].name == "Chapter A")
        _ = manga
    }

    @Test("导入后能立刻取到页数据（走缓存）")
    func readsPageDataRightAfterImport() throws {
        let (source, root) = try makeSource()
        defer { TestFileSystem.remove(root) }

        let file = try writeTemporaryArchive(Self.multiChapterArchive, fileName: "Read.cbz", in: root)
        let (manga, chapters) = try source.importBook(from: file)
        let pages = try source.pages(for: chapters[0], manga: manga)
        let page = try #require(pages.first)

        let data = try source.imageDataSync(for: page, manga: manga)
        #expect(data.count > 0)
        // 夹具用的是伪 JPEG（ÿØÿ 开头）
        #expect(data.prefix(3) == Data([0xFF, 0xD8, 0xFF]))
    }

    @Test("异步入口与同步入口结果一致")
    func asyncEntryPointMatchesSync() async throws {
        let (source, root) = try makeSource()
        defer { TestFileSystem.remove(root) }

        let file = try writeTemporaryArchive(Self.multiChapterArchive, fileName: "Async.cbz", in: root)
        let (manga, chapters) = try source.importBook(from: file)
        let page = try #require(try source.pages(for: chapters[0], manga: manga).first)

        let viaSync = try source.imageDataSync(for: page, manga: manga)
        let viaAsync = try await source.imageData(for: page, manga: manga, chapter: chapters[0])
        #expect(viaSync == viaAsync)
    }

    // MARK: 导入异常

    @Test("导入重复文件是幂等的：同一份归档只存在一次")
    func importIsIdempotent() throws {
        let (source, root) = try makeSource()
        defer { TestFileSystem.remove(root) }

        let file = try writeTemporaryArchive(Self.multiChapterArchive, fileName: "Same.cbz", in: root)
        let first = try source.importBook(from: file)
        let second = try source.importBook(from: file)

        #expect(first.manga.url == second.manga.url)
        #expect(try source.books().count == 1)
    }

    @Test("同名不同内容 → 两份独立作品")
    func differentContentProducesSeparateBooks() throws {
        let (source, root) = try makeSource()
        defer { TestFileSystem.remove(root) }

        let a = try writeTemporaryArchive(Self.multiChapterArchive, fileName: "Book.cbz", in: root)
        let b = try writeTemporaryArchive(Self.singleChapterRootArchive, fileName: "Book2.cbz", in: root)
        let first = try source.importBook(from: a)
        let second = try source.importBook(from: b)

        #expect(first.manga.url != second.manga.url)
        #expect(try source.books().count == 2)
    }

    @Test("不支持的扩展名被拒绝", arguments: ["book.txt", "book.pdf", "book"])
    func rejectsUnsupportedExtension(fileName: String) throws {
        let (source, root) = try makeSource()
        defer { TestFileSystem.remove(root) }

        let file = try writeTemporaryArchive(Data("x".utf8), fileName: fileName, in: root)
        expectThrows(LocalSourceError.unsupportedExtension((fileName as NSString).pathExtension.lowercased())) {
            _ = try source.importBook(from: file)
        }
    }

    @Test("文件不存在时报错")
    func rejectsMissingFile() throws {
        let (source, root) = try makeSource()
        defer { TestFileSystem.remove(root) }

        let missing = root.appendingPathComponent("nope.cbz")
        expectThrows(LocalSourceError.sourceFileMissing("nope.cbz")) {
            _ = try source.importBook(from: missing)
        }
    }

    @Test("不是 ZIP 的 .cbz 文件被拒绝")
    func rejectsNonArchive() throws {
        let (source, root) = try makeSource()
        defer { TestFileSystem.remove(root) }

        let file = try writeTemporaryArchive(Data("这不是归档".utf8), fileName: "fake.cbz", in: root)
        expectThrows(LocalSourceError.notAZipArchive("fake.cbz")) {
            _ = try source.importBook(from: file)
        }
        // 失败不应留下任何文件
        #expect(try source.books().isEmpty)
    }

    @Test("归档里没有图片时报错且不留文件")
    func rejectsArchiveWithoutImages() throws {
        let (source, root) = try makeSource()
        defer { TestFileSystem.remove(root) }

        let file = try writeTemporaryArchive(Self.noImagesArchive, fileName: "empty.cbz", in: root)
        expectThrows(LocalSourceError.noImages("empty.cbz")) {
            _ = try source.importBook(from: file)
        }
        #expect(try source.books().isEmpty)
    }

    // MARK: 列出与删除

    @Test("books() 从文件系统重建本地作品列表")
    func listsBooks() throws {
        let (source, root) = try makeSource()
        defer { TestFileSystem.remove(root) }

        #expect(try source.books().isEmpty)

        let file = try writeTemporaryArchive(Self.multiChapterArchive, fileName: "作品A [组].cbz", in: root)
        try source.importBook(from: file)

        let books = try source.books()
        #expect(books.count == 1)
        #expect(books[0].title == "作品A")
        #expect(books[0].sourceID == .local)
        #expect(try source.bookCount() == 1)
    }

    @Test("重启后（新建实例）仍能读到旧作品与其页")
    func persistsAcrossInstances() throws {
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }
        let library = root.appendingPathComponent("LocalLibrary", isDirectory: true)

        let first = LocalSource(rootDirectory: library)
        let file = try writeTemporaryArchive(Self.multiChapterArchive, fileName: "Persist.cbz", in: root)
        let (manga, chapters) = try first.importBook(from: file)

        let second = LocalSource(rootDirectory: library)
        let books = try second.books()
        #expect(books.count == 1)
        #expect(books[0].url == manga.url)

        let pages = try second.pages(for: chapters[0], manga: books[0])
        #expect(pages.count == 3)
    }

    @Test("删除作品会移除归档与侧车文件")
    func removesBook() throws {
        let (source, root) = try makeSource()
        defer { TestFileSystem.remove(root) }

        let file = try writeTemporaryArchive(Self.multiChapterArchive, fileName: "Delete.cbz", in: root)
        let (manga, _) = try source.importBook(from: file)

        #expect(try source.removeBook(mangaID: manga.id))
        #expect(try source.removeBook(mangaID: manga.id) == false)
        #expect(try source.books().isEmpty)

        let remaining = try FileManager.default.contentsOfDirectory(atPath: source.rootDirectory.path)
        #expect(remaining.isEmpty)
    }

    @Test("非法作品 ID 被拒绝（路径穿越防护）", arguments: [
        "local|../../etc/passwd",
        "local|LocalLibrary/../../escape.cbz",
        "local|/etc/passwd",
        "local|",
        "no-separator",
    ])
    func rejectsPathTraversal(mangaID: String) throws {
        let (source, root) = try makeSource()
        defer { TestFileSystem.remove(root) }

        do {
            _ = try source.removeBook(mangaID: mangaID)
            Issue.record("应当抛错")
        } catch let error as LocalSourceError {
            switch error {
            case .invalidRelativePath, .bookNotFound:
                break
            default:
                Issue.record("错误类型不符：\(error)")
            }
        } catch {
            Issue.record("未预期错误：\(error)")
        }
    }

    // MARK: 路径与命名工具

    @Test("章节地址可往返解析")
    func chapterURLRoundTrip() {
        let url = LocalSource.chapterURL(bookPath: "LocalLibrary/a-1234abcd.cbz", chapterPath: "第1话")
        #expect(LocalSource.chapterPath(fromChapterURL: url) == "第1话")

        let rootChapter = LocalSource.chapterURL(bookPath: "LocalLibrary/a-1234abcd.cbz", chapterPath: "")
        #expect(LocalSource.chapterPath(fromChapterURL: rootChapter) == "")
    }

    @Test("非法章节地址返回 nil", arguments: [
        "没有井号",
        "LocalLibrary/a.cbz#ok#extra",
        "single#",
    ])
    func rejectsMalformedChapterURL(url: String) {
        #expect(LocalSource.chapterPath(fromChapterURL: url) == nil)
    }

    @Test("标题清洗：去掉发布组后缀与多余空白")
    func cleansTitle() {
        #expect(LocalSource.displayTitle(from: "作品 [汉化组]") == "作品")
        #expect(LocalSource.displayTitle(from: "Title (Digital)") == "Title")
        #expect(LocalSource.displayTitle(from: "  A   B  ") == "A B")
        #expect(LocalSource.displayTitle(from: "[只有后缀]") == "[只有后缀]")
    }

    @Test("slug 保留 CJK 与字母数字")
    func buildsSlug() {
        #expect(LocalSource.slug(from: "作品 A") == "作品-A")
        #expect(LocalSource.slug(from: "a/b:c*d") == "a-b-c-d")
        #expect(LocalSource.slug(from: "///") == "book")
        #expect(LocalSource.slug(from: String(repeating: "x", count: 100)).count == 40)
    }

    @Test("指纹稳定且区分内容")
    func fingerprintIsStable() {
        let a = Data(repeating: 0x01, count: 1000)
        let b = Data(repeating: 0x02, count: 1000)
        #expect(LocalSource.fingerprint(a) == LocalSource.fingerprint(a))
        #expect(LocalSource.fingerprint(a) != LocalSource.fingerprint(b))
        #expect(LocalSource.fingerprint(a).count == 64)
    }

    @Test("归档文件名含 slug 与指纹前缀")
    func buildsArchiveFileName() {
        let name = LocalSource.archiveFileName(slug: "title", fingerprint: "abcdef1234567890", fileExtension: "cbz")
        #expect(name == "title-abcdef12.cbz")
        #expect(LocalSource.strippingFingerprint(name) == "title")
    }

    // MARK: 并发

    @Test("并发导入不同文件互不干扰")
    func concurrentImports() async throws {
        let (source, root) = try makeSource()
        defer { TestFileSystem.remove(root) }

        let files = try (0..<6).map { index in
            try writeTemporaryArchive(
                index % 2 == 0 ? Self.multiChapterArchive : Self.singleChapterRootArchive,
                fileName: "Book\(index).cbz",
                in: root
            )
        }

        await withTaskGroup(of: Void.self) { group in
            for file in files {
                group.addTask { _ = try? source.importBook(from: file) }
            }
        }

        // 两个归档内容只有两种：同一内容的多次导入应各自幂等
        let books = try source.books()
        #expect(books.count == 2)
        for book in books {
            #expect(try source.chapters(for: book).isEmpty == false)
        }
    }
}
