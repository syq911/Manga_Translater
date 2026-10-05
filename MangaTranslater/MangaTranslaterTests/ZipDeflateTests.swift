//
//  ZipDeflateTests.swift
//  MangaTranslaterTests
//
//  CBZ / ZIP 的 **deflate（方法 8）解压**测试。
//
//  为什么必须支持 deflate：真实世界的 CBZ 绝大多数用 deflate 压缩，
//  只支持 store（方法 0）等于读不了别人的文件。
//
//  夹具由**外部实现**（Python zipfile）生成并以 base64 内联：
//  独立实现才能真正验证我们的解码器；内联也避免依赖仓库外路径
//  （测试跑在模拟器里，读不到仓库目录）。
//
//  注意：多行字面量里每行都按结束定界符缩进，且用 .ignoreUnknownCharacters
//  跳过换行——这是 Swift 多行字符串的缩进规则决定的。
//

import Testing
import Foundation
import ComicDownload

@Suite("ZIP deflate 解压")
struct ZipDeflateTests {

    /// 219 字节；由外部实现（Python zipfile）生成，用于独立验证解码器。
    static let deflateArchiveData = Data(
        base64Encoded: """
        UEsDBBQAAAAIAAAAIVwuOFkVaQAAALgLAAAIAAAAMDAwMS5qcGfzdfRzd9QNcHR31WVgZGJm
        YWVj5+Dk4ubh5eMXEBQSFhEVE5eQlJKWkZWTV1BUUlZRVVPX0NTS1tHV0zcwNDI2MTUzt7C0
        sraxtbP3HTVq1KhRo0aNGjVq1KhRo0aNGjVq1KhRo2hjFABQSwECFAAUAAAACAAAACFcLjhZ
        FWkAAAC4CwAACAAAAAAAAAAAAAAAgAEAAAAAMDAwMS5qcGdQSwUGAAAAAAEAAQA2AAAAjwAA
        AAAA
        """,
        options: .ignoreUnknownCharacters
    )!

    /// 311 字节；由外部实现（Python zipfile）生成，用于独立验证解码器。
    static let mixedArchiveData = Data(
        base64Encoded: """
        UEsDBBQAAAAAAAAAIVwYuoApDAAAAAwAAAAFAAAAYS50eHRzdG9yZWQtZW50cnlQSwMEFAAA
        AAgAAAAhXC44WRVpAAAAuAsAAAUAAABiLnR4dPN19HN31A1wdHfVZWBkYmZhZWPn4OTi5uHl
        4xcQFBIWERUTl5CUkpaRlZNXUFRSVlFVU9fQ1NLW0dXTNzA0MjYxNTO3sLSytrG1s/cdNWrU
        qFGjRo0aNWrUqFGjRo0aNWrUqFGjaGMUAFBLAQIUABQAAAAAAAAAIVwYuoApDAAAAAwAAAAF
        AAAAAAAAAAAAAACAAQAAAABhLnR4dFBLAQIUABQAAAAIAAAAIVwuOFkVaQAAALgLAAAFAAAA
        AAAAAAAAAACAAS8AAABiLnR4dFBLBQYAAAAAAgACAGYAAAC7AAAAAAA=
        """,
        options: .ignoreUnknownCharacters
    )!

    /// 118 字节；由外部实现（Python zipfile）生成，用于独立验证解码器。
    static let emptyDeflateArchiveData = Data(
        base64Encoded: """
        UEsDBBQAAAAIAAAAIVwAAAAAAgAAAAAAAAAJAAAAZW1wdHkudHh0AwBQSwECFAAUAAAACAAA
        ACFcAAAAAAIAAAAAAAAACQAAAAAAAAAAAAAAgAEAAAAAZW1wdHkudHh0UEsFBgAAAAABAAEA
        NwAAACkAAAAAAA==
        """,
        options: .ignoreUnknownCharacters
    )!

    /// 219 字节；由外部实现（Python zipfile）生成，用于独立验证解码器。
    static let unsupportedMethodArchiveData = Data(
        base64Encoded: """
        UEsDBBQAAABjAAAAIVwuOFkVaQAAALgLAAAIAAAAMDAwMS5qcGfzdfRzd9QNcHR31WVgZGJm
        YWVj5+Dk4ubh5eMXEBQSFhEVE5eQlJKWkZWTV1BUUlZRVVPX0NTS1tHV0zcwNDI2MTUzt7C0
        sraxtbP3HTVq1KhRo0aNGjVq1KhRo0aNGjVq1KhRo2hjFABQSwECFAAUAAAAYwAAACFcLjhZ
        FWkAAAC4CwAACAAAAAAAAAAAAAAAgAEAAAAAMDAwMS5qcGdQSwUGAAAAAAEAAQA2AAAAjwAA
        AAAA
        """,
        options: .ignoreUnknownCharacters
    )!

    /// 219 字节；由外部实现（Python zipfile）生成，用于独立验证解码器。
    static let wrongSizeArchiveData = Data(
        base64Encoded: """
        UEsDBBQAAAAIAAAAIVwuOFkVaQAAALgLAAAIAAAAMDAwMS5qcGfzdfRzd9QNcHR31WVgZGJm
        YWVj5+Dk4ubh5eMXEBQSFhEVE5eQlJKWkZWTV1BUUlZRVVPX0NTS1tHV0zcwNDI2MTUzt7C0
        sraxtbP3HTVq1KhRo0aNGjVq1KhRo0aNGjVq1KhRo2hjFABQSwECFAAUAAAACAAAACFcLjhZ
        FWkAAAAzDAAACAAAAAAAAAAAAAAAgAEAAAAAMDAwMS5qcGdQSwUGAAAAAAEAAQA2AAAAjwAA
        AAAA
        """,
        options: .ignoreUnknownCharacters
    )!

    /// 219 字节；由外部实现（Python zipfile）生成，用于独立验证解码器。
    static let corruptedDeflateArchiveData = Data(
        base64Encoded: """
        UEsDBBQAAAAIAAAAIVwuOFkVaQAAALgLAAAIAAAAMDAwMS5qcGfzdQtzd9QNcHR31WVgZGJm
        YWVj5+Dk4ubh5eMXEBQSFhEVE5eQlJKWkZWTV1BUUlZRVVPX0NTS1tHV0zcwNDI2MTUzt7C0
        sraxtbP3HTVq1KhRo0aNGjVq1KhRo0aNGjVq1KhRo2hjFABQSwECFAAUAAAACAAAACFcLjhZ
        FWkAAAC4CwAACAAAAAAAAAAAAAAAgAEAAAAAMDAwMS5qcGdQSwUGAAAAAAEAAQA2AAAAjwAA
        AAAA
        """,
        options: .ignoreUnknownCharacters
    )!

    /// 3000 字节；由外部实现（Python zipfile）生成，用于独立验证解码器。
    static let expectedPayloadData = Data(
        base64Encoded: """
        TUFOR0EtUEFHRS0AAQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkq
        KywtLi8wMTIzNDU2Nzg5Ojs8PT4/TUFOR0EtUEFHRS0AAQIDBAUGBwgJCgsMDQ4PEBESExQV
        FhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg5Ojs8PT4/TUFOR0EtUEFHRS0A
        AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8wMTIzNDU2
        Nzg5Ojs8PT4/TUFOR0EtUEFHRS0AAQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAh
        IiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg5Ojs8PT4/TUFOR0EtUEFHRS0AAQIDBAUGBwgJCgsM
        DQ4PEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg5Ojs8PT4/TUFO
        R0EtUEFHRS0AAQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywt
        Li8wMTIzNDU2Nzg5Ojs8PT4/TUFOR0EtUEFHRS0AAQIDBAUGBwgJCgsMDQ4PEBESExQVFhcY
        GRobHB0eHyAhIiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg5Ojs8PT4/TUFOR0EtUEFHRS0AAQID
        BAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg5
        Ojs8PT4/TUFOR0EtUEFHRS0AAQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMk
        JSYnKCkqKywtLi8wMTIzNDU2Nzg5Ojs8PT4/TUFOR0EtUEFHRS0AAQIDBAUGBwgJCgsMDQ4P
        EBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg5Ojs8PT4/TUFOR0Et
        UEFHRS0AAQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8w
        MTIzNDU2Nzg5Ojs8PT4/TUFOR0EtUEFHRS0AAQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRob
        HB0eHyAhIiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg5Ojs8PT4/TUFOR0EtUEFHRS0AAQIDBAUG
        BwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg5Ojs8
        PT4/TUFOR0EtUEFHRS0AAQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMkJSYn
        KCkqKywtLi8wMTIzNDU2Nzg5Ojs8PT4/TUFOR0EtUEFHRS0AAQIDBAUGBwgJCgsMDQ4PEBES
        ExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg5Ojs8PT4/TUFOR0EtUEFH
        RS0AAQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8wMTIz
        NDU2Nzg5Ojs8PT4/TUFOR0EtUEFHRS0AAQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0e
        HyAhIiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg5Ojs8PT4/TUFOR0EtUEFHRS0AAQIDBAUGBwgJ
        CgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg5Ojs8PT4/
        TUFOR0EtUEFHRS0AAQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkq
        KywtLi8wMTIzNDU2Nzg5Ojs8PT4/TUFOR0EtUEFHRS0AAQIDBAUGBwgJCgsMDQ4PEBESExQV
        FhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg5Ojs8PT4/TUFOR0EtUEFHRS0A
        AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8wMTIzNDU2
        Nzg5Ojs8PT4/TUFOR0EtUEFHRS0AAQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAh
        IiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg5Ojs8PT4/TUFOR0EtUEFHRS0AAQIDBAUGBwgJCgsM
        DQ4PEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg5Ojs8PT4/TUFO
        R0EtUEFHRS0AAQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywt
        Li8wMTIzNDU2Nzg5Ojs8PT4/TUFOR0EtUEFHRS0AAQIDBAUGBwgJCgsMDQ4PEBESExQVFhcY
        GRobHB0eHyAhIiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg5Ojs8PT4/TUFOR0EtUEFHRS0AAQID
        BAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg5
        Ojs8PT4/TUFOR0EtUEFHRS0AAQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMk
        JSYnKCkqKywtLi8wMTIzNDU2Nzg5Ojs8PT4/TUFOR0EtUEFHRS0AAQIDBAUGBwgJCgsMDQ4P
        EBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg5Ojs8PT4/TUFOR0Et
        UEFHRS0AAQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8w
        MTIzNDU2Nzg5Ojs8PT4/TUFOR0EtUEFHRS0AAQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRob
        HB0eHyAhIiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg5Ojs8PT4/TUFOR0EtUEFHRS0AAQIDBAUG
        BwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg5Ojs8
        PT4/TUFOR0EtUEFHRS0AAQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMkJSYn
        KCkqKywtLi8wMTIzNDU2Nzg5Ojs8PT4/TUFOR0EtUEFHRS0AAQIDBAUGBwgJCgsMDQ4PEBES
        ExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg5Ojs8PT4/TUFOR0EtUEFH
        RS0AAQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8wMTIz
        NDU2Nzg5Ojs8PT4/TUFOR0EtUEFHRS0AAQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0e
        HyAhIiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg5Ojs8PT4/TUFOR0EtUEFHRS0AAQIDBAUGBwgJ
        CgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg5Ojs8PT4/
        TUFOR0EtUEFHRS0AAQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkq
        KywtLi8wMTIzNDU2Nzg5Ojs8PT4/TUFOR0EtUEFHRS0AAQIDBAUGBwgJCgsMDQ4PEBESExQV
        FhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg5Ojs8PT4/TUFOR0EtUEFHRS0A
        AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8wMTIzNDU2
        Nzg5Ojs8PT4/TUFOR0EtUEFHRS0AAQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAh
        IiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg5Ojs8PT4/
        """,
        options: .ignoreUnknownCharacters
    )!

    // MARK: 正常路径

    @Test("能读取 deflate 压缩的条目")
    func readsDeflatedEntry() throws {
        let reader = try ZipArchiveReader(data: Self.deflateArchiveData)
        #expect(reader.entryNames == ["0001.jpg"])
        #expect(reader.entries.first?.uncompressedSize == Self.expectedPayloadData.count)
        #expect(reader.entries.first?.isCompressed == true)

        let data = try reader.data(for: "0001.jpg")
        #expect(data == Self.expectedPayloadData)
    }

    @Test("混合归档：store 与 deflate 条目都能读")
    func readsMixedArchive() throws {
        let reader = try ZipArchiveReader(data: Self.mixedArchiveData)
        #expect(reader.entryNames == ["a.txt", "b.txt"])
        #expect(try reader.data(for: "a.txt") == Data("stored-entry".utf8))
        #expect(try reader.data(for: "b.txt") == Self.expectedPayloadData)
        #expect(reader.entries.first?.isCompressed == false)
    }

    @Test("空内容的 deflate 条目返回空数据")
    func readsEmptyDeflatedEntry() throws {
        let reader = try ZipArchiveReader(data: Self.emptyDeflateArchiveData)
        #expect(try reader.data(for: "empty.txt").isEmpty)
    }

    @Test("解压结果与外部实现一致（CRC 由外部写入）")
    func inflatedDataMatchesChecksum() throws {
        let reader = try ZipArchiveReader(data: Self.deflateArchiveData)
        let data = try reader.data(for: "0001.jpg")
        let info = try #require(reader.entries.first)
        #expect(Crc32.checksum(data) == info.crc32)
    }

    // MARK: 异常分支

    @Test("不支持的压缩方式被拒绝")
    func rejectsUnsupportedMethod() throws {
        let reader = try ZipArchiveReader(data: Self.unsupportedMethodArchiveData)
        expectThrows(ZipArchiveError.unsupportedCompression(99)) {
            _ = try reader.data(for: "0001.jpg")
        }
    }

    @Test("解压后大小与声明不符时报错")
    func rejectsSizeMismatch() throws {
        let reader = try ZipArchiveReader(data: Self.wrongSizeArchiveData)
        do {
            _ = try reader.data(for: "0001.jpg")
            Issue.record("应当抛错")
        } catch let error as ZipArchiveError {
            if case .corruptEntry = error { } else { Issue.record("错误类型不符：\(error)") }
        } catch {
            Issue.record("未预期错误：\(error)")
        }
    }

    @Test("压缩数据被破坏时报错而不是返回脏数据")
    func rejectsCorruptedStream() throws {
        let reader = try ZipArchiveReader(data: Self.corruptedDeflateArchiveData)
        do {
            _ = try reader.data(for: "0001.jpg")
            Issue.record("应当抛错")
        } catch let error as ZipArchiveError {
            switch error {
            case .corruptEntry, .unsupportedCompression:
                break
            default:
                Issue.record("错误类型不符：\(error)")
            }
        } catch {
            Issue.record("未预期错误：\(error)")
        }
    }

    @Test("读取不存在的条目仍然报 entryNotFound")
    func missingEntryStillThrows() throws {
        let reader = try ZipArchiveReader(data: Self.mixedArchiveData)
        expectThrows(ZipArchiveError.entryNotFound("zzz")) {
            _ = try reader.data(for: "zzz")
        }
    }

    @Test("内联夹具本身可解码（防止生成器写坏）")
    func fixtureDecodes() {
        for data in [Self.deflateArchiveData, Self.mixedArchiveData, Self.emptyDeflateArchiveData] {
            #expect(data.count > 0)
        }
        #expect(Self.expectedPayloadData.count == 3000)
    }
}
