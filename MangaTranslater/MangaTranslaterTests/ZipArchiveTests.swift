//
//  ZipArchiveTests.swift
//  MangaTranslaterTests
//
//  覆盖 ZIP（CBZ）读写：往返一致、CRC 校验、边界（空归档 / 空文件 /
//  非 ASCII 名 / 重名 / 大数据）、异常（截断 / 错误签名 / 非法名）、
//  CBZ 导出与页名规则。
//

import Testing
import Foundation
import AppCore
import ComicDownload

@Suite("ZIP 与 CBZ")
struct ZipArchiveTests {

    // MARK: 写入 / 读取往返

    @Test("单文件往返一致")
    func roundTripSingleFile() throws {
        var writer = ZipArchiveWriter()
        let payload = Data("hello zip".utf8)
        try writer.addFile(name: "a.txt", data: payload, date: Date(timeIntervalSince1970: 1_700_000_000))

        let archive = try writer.finalize()
        let reader = try ZipArchiveReader(data: archive)

        #expect(reader.entryNames == ["a.txt"])
        #expect(try reader.data(for: "a.txt") == payload)
    }

    @Test("多文件保持归档顺序并可分别读取")
    func roundTripMultipleFiles() throws {
        var writer = ZipArchiveWriter()
        try writer.addFile(name: "0001.jpg", data: Data(repeating: 0x01, count: 10))
        try writer.addFile(name: "0002.jpg", data: Data(repeating: 0x02, count: 20))
        try writer.addFile(name: "0003.jpg", data: Data(repeating: 0x03, count: 30))

        let archive = try writer.finalize()
        let reader = try ZipArchiveReader(data: archive)

        #expect(reader.entryNames == ["0001.jpg", "0002.jpg", "0003.jpg"])
        #expect(try reader.data(for: "0002.jpg").count == 20)
        #expect(reader.entries[2].uncompressedSize == 30)
    }

    @Test("空文件内容可往返")
    func roundTripEmptyFile() throws {
        var writer = ZipArchiveWriter()
        try writer.addFile(name: "empty.bin", data: Data())

        let archive = try writer.finalize()
        let reader = try ZipArchiveReader(data: archive)
        #expect(try reader.data(for: "empty.bin").isEmpty)
    }

    @Test("非 ASCII 文件名可往返")
    func roundTripUnicodeName() throws {
        var writer = ZipArchiveWriter()
        let payload = Data("中文内容".utf8)
        try writer.addFile(name: "第 1 页/说明.txt", data: payload)

        let archive = try writer.finalize()
        let reader = try ZipArchiveReader(data: archive)
        #expect(reader.entryNames == ["第 1 页/说明.txt"])
        #expect(try reader.data(for: "第 1 页/说明.txt") == payload)
    }

    @Test("较大数据块往返一致")
    func roundTripLargeFile() throws {
        var writer = ZipArchiveWriter()
        var payload = Data()
        for index in 0..<100_000 { payload.append(UInt8(index % 251)) }
        try writer.addFile(name: "big.jpg", data: payload)

        let archive = try writer.finalize()
        let reader = try ZipArchiveReader(data: archive)
        #expect(try reader.data(for: "big.jpg") == payload)
    }

    @Test("归档结构包含标准签名")
    func archiveContainsSignatures() throws {
        var writer = ZipArchiveWriter()
        try writer.addFile(name: "a.txt", data: Data("x".utf8))
        let archive = try writer.finalize()

        #expect(archive.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]))
        // 末尾 22 字节 EOCD 签名
        let eocd = archive.suffix(22)
        #expect(eocd.prefix(4) == Data([0x50, 0x4B, 0x05, 0x06]))
    }

    // MARK: 边界与异常

    @Test("空归档 finalize 抛错")
    func finalizeWithoutEntriesThrows() {
        var writer = ZipArchiveWriter()
        expectThrows(ZipArchiveError.emptyArchive) {
            _ = try writer.finalize()
        }
    }

    @Test("重名文件被拒绝")
    func rejectsDuplicateName() {
        var writer = ZipArchiveWriter()
        expectThrows(ZipArchiveError.duplicateEntryName("a.txt")) {
            try writer.addFile(name: "a.txt", data: Data())
            try writer.addFile(name: "a.txt", data: Data("x".utf8))
        }
    }

    @Test("非法条目名被拒绝", arguments: ["", "\\evil.txt", "/absolute.txt", "../escape.txt", "a/../../b.txt"])
    func rejectsInvalidNames(name: String) {
        var writer = ZipArchiveWriter()
        expectThrows(ZipArchiveError.invalidName(name)) {
            try writer.addFile(name: name, data: Data())
        }
    }

    @Test("超过体积上限被拒绝")
    func rejectsTooLargeArchive() {
        var writer = ZipArchiveWriter(maxBytes: 1024)
        expectThrows(ZipArchiveError.tooManyBytes(1024)) {
            try writer.addFile(name: "a.bin", data: Data(repeating: 0x01, count: 2048))
        }
    }

    @Test("空数据不是有效归档")
    func rejectsEmptyArchiveData() {
        expectThrows(ZipArchiveError.emptyArchive) {
            _ = try ZipArchiveReader(data: Data())
        }
    }

    @Test("随机数据找不到中央目录")
    func rejectsGarbageData() {
        let garbage = Data(repeating: 0x7A, count: 512)
        do {
            _ = try ZipArchiveReader(data: garbage)
            Issue.record("应当抛错")
        } catch let error as ZipArchiveError {
            if case .missingEndOfCentralDirectory = error { } else {
                Issue.record("错误类型不符：\(error)")
            }
        } catch {
            Issue.record("未预期错误：\(error)")
        }
    }

    @Test("截断的归档被拒绝")
    func rejectsTruncatedArchive() throws {
        var writer = ZipArchiveWriter()
        try writer.addFile(name: "a.txt", data: Data(repeating: 0x41, count: 100))
        let archive = try writer.finalize()

        let truncated = archive.prefix(40)
        do {
            _ = try ZipArchiveReader(data: Data(truncated))
            Issue.record("应当抛错")
        } catch is ZipArchiveError {
            // 预期
        } catch {
            Issue.record("未预期错误：\(error)")
        }
    }

    @Test("读取不存在的条目报错")
    func missingEntryThrows() throws {
        var writer = ZipArchiveWriter()
        try writer.addFile(name: "a.txt", data: Data())
        let reader = try ZipArchiveReader(data: try writer.finalize())

        expectThrows(ZipArchiveError.entryNotFound("b.txt")) {
            _ = try reader.data(for: "b.txt")
        }
    }

    @Test("条目内容被篡改时 CRC 校验失败")
    func detectsCorruptedEntry() throws {
        var writer = ZipArchiveWriter()
        try writer.addFile(name: "a.txt", data: Data("original".utf8))
        var archive = try writer.finalize()

        // 破坏本地头之后的有效载荷（偏移 30 + 名称长度）
        let nameLength = "a.txt".utf8.count
        let payloadOffset = 30 + nameLength
        archive[payloadOffset] = archive[payloadOffset] ^ 0xFF

        let reader = try ZipArchiveReader(data: archive)
        expectThrows(ZipArchiveError.corruptEntry("a.txt")) {
            _ = try reader.data(for: "a.txt")
        }
    }

    // MARK: CRC

    @Test("CRC32 已知值")
    func crcKnownValues() {
        #expect(Crc32.checksum(Data()) == 0)
        #expect(Crc32.checksum(Data("123456789".utf8)) == 0xCBF43926)
        #expect(Crc32.checksum(Data("a".utf8)) == 0xE8B7BE43)
    }

    // MARK: CBZ 导出

    @Test("导出 CBZ 可被重新读取且页序正确")
    func exportsReadableCbz() throws {
        let pages = [
            CbzPage(index: 2, data: Data(repeating: 0x03, count: 30)),
            CbzPage(index: 0, data: Data(repeating: 0x01, count: 10)),
            CbzPage(index: 1, data: Data(repeating: 0x02, count: 20)),
        ]
        let exporter = CbzExporter()
        let archive = try exporter.export(pages: pages, title: "测试漫画")

        let reader = try ZipArchiveReader(data: archive)
        #expect(reader.entryNames == ["comicinfo.txt", "0001.jpg", "0002.jpg", "0003.jpg"])
        #expect(try reader.data(for: "0003.jpg").count == 30)
        #expect(try reader.data(for: "0002.jpg").count == 20)
    }

    @Test("不含标题时不写入信息文件")
    func exportsWithoutTitle() throws {
        let exporter = CbzExporter()
        let archive = try exporter.export(pages: [CbzPage(index: 0, data: Data("x".utf8))], title: nil)
        let reader = try ZipArchiveReader(data: archive)
        #expect(reader.entryNames == ["0001.jpg"])
    }

    @Test("空页列表被拒绝")
    func rejectsEmptyPageList() {
        expectThrows(CbzExportError.noPages) {
            _ = try CbzExporter().export(pages: [], title: nil)
        }
    }

    @Test("页数超过上限被拒绝")
    func rejectsTooManyPages() {
        let exporter = CbzExporter(maxPages: 2)
        let pages = (0..<3).map { CbzPage(index: $0, data: Data()) }
        expectThrows(CbzExportError.tooManyPages(3)) {
            _ = try exporter.export(pages: pages, title: nil)
        }
    }

    @Test("非法扩展名被拒绝")
    func rejectsInvalidExtension() {
        expectThrows(CbzExportError.invalidExtension("exe")) {
            _ = try CbzExporter().export(pages: [CbzPage(index: 0, data: Data(), fileExtension: "exe")], title: nil)
        }
    }

    @Test("空标题被拒绝")
    func rejectsBlankTitle() {
        expectThrows(CbzExportError.invalidTitle("   ")) {
            _ = try CbzExporter().export(pages: [CbzPage(index: 0, data: Data())], title: "   ")
        }
    }

    @Test("页名规则：4 位零填充且支持大序号")
    func pageNameFormatting() {
        #expect(CbzExporter.defaultPageName(index: 0) == "0001.jpg")
        #expect(CbzExporter.defaultPageName(index: 9) == "0010.jpg")
        #expect(CbzExporter.defaultPageName(index: 9999) == "10000.jpg")
        #expect(CbzExporter.pageName(index: 0, fileExtension: "PNG") == "0001.png")
    }

    @Test("导出到文件成功")
    func exportsToFile() throws {
        let directory = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(directory) }

        let url = directory.appendingPathComponent("book.cbz")
        let bytes = try CbzExporter().export(
            pages: [CbzPage(index: 0, data: Data(repeating: 0x01, count: 32))],
            title: "书",
            to: url
        )

        #expect(bytes > 0)
        #expect(FileManager.default.fileExists(atPath: url.path))
        let reader = try ZipArchiveReader(data: try Data(contentsOf: url))
        #expect(reader.entryNames.contains("0001.jpg"))
    }
}
