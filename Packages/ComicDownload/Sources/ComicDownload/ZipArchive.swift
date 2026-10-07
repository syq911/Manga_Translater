//
//  ZipArchive.swift
//  ComicDownload
//
//  ZIP 读写实现。
//
//  读：支持 store（方法 0）与 **deflate（方法 8）** 两种条目 ——
//  真实世界的 CBZ 绝大多数用 deflate 压缩，只支持 store 等于读不了别人的文件。
//  deflate 用系统 `Compression` 框架（`COMPRESSION_ZLIB` 即裸 DEFLATE），
//  零第三方依赖。
//
//  写：只写 store（方法 0）。漫画页图（JPEG/PNG）本身已压缩，再 deflate 收益很小；
//  store 模式字节级可预测、易于测试，且所有阅读器都能打开。
//
//  兼容性：写出标准本地头 + 中央目录 + EOCD，文件名统一打 UTF-8 标志位。
//

import Foundation
import Compression
import AppCore

/// ZIP 相关错误。
public enum ZipArchiveError: Error, Equatable {
    case emptyArchive
    case missingEndOfCentralDirectory
    case invalidSignature(found: UInt32)
    case unsupportedCompression(UInt16)
    case entryNotFound(String)
    case corruptEntry(String)
    case duplicateEntryName(String)
    case invalidName(String)
    case dataTruncated
    case tooManyBytes(Int)

    public var message: String {
        switch self {
        case .emptyArchive: return Copy.text("error.zip.emptyArchive")
        case .missingEndOfCentralDirectory: return Copy.text("error.zip.missingCentralDirectory")
        case let .invalidSignature(found):
            return Copy.format("error.zip.invalidSignature", String(found, radix: 16))
        case let .unsupportedCompression(method):
            return Copy.format("error.zip.unsupportedCompression", Int(method))
        case let .entryNotFound(name): return Copy.format("error.zip.entryNotFound", name)
        case let .corruptEntry(name): return Copy.format("error.zip.corruptEntry", name)
        case let .duplicateEntryName(name): return Copy.format("error.zip.duplicateEntryName", name)
        case let .invalidName(name): return Copy.format("error.zip.invalidName", name)
        case .dataTruncated: return Copy.text("error.zip.truncated")
        case let .tooManyBytes(limit): return Copy.format("error.zip.tooLarge", limit)
        }
    }
}

extension ZipArchiveError: LocalizedError {
    public var errorDescription: String? { message }
}

/// 条目元信息。
public struct ZipEntryInfo: Equatable, Sendable {
    public let name: String
    /// 解压后的原始大小。
    public let uncompressedSize: Int
    /// 归档内的压缩后大小（store 时与 `uncompressedSize` 相同）。
    public let compressedSize: Int
    public let crc32: UInt32
    /// 压缩方式：0 = store，8 = deflate。
    public let compressionMethod: UInt16

    public init(
        name: String,
        uncompressedSize: Int,
        compressedSize: Int? = nil,
        crc32: UInt32,
        compressionMethod: UInt16 = 0
    ) {
        self.name = name
        self.uncompressedSize = uncompressedSize
        self.compressedSize = compressedSize ?? uncompressedSize
        self.crc32 = crc32
        self.compressionMethod = compressionMethod
    }

    /// 是否为压缩存储。
    public var isCompressed: Bool { compressionMethod != 0 }
}

// MARK: - DEFLATE 解压

/// 裸 DEFLATE 解压（ZIP 方法 8）。
enum Deflate {
    /// 解压。
    /// - Parameters:
    ///   - payload: 压缩数据（不含 zlib 头尾，ZIP 就是裸流）。
    ///   - expectedSize: 中央目录声明的解压后大小。
    ///   - entryName: 仅用于错误信息。
    /// - Throws: `ZipArchiveError.corruptEntry`——解压失败或结果大小与声明不符。
    static func inflate(_ payload: Data, expectedSize: Int, entryName: String) throws -> Data {
        guard expectedSize > 0 else { return Data() }
        guard !payload.isEmpty else { throw ZipArchiveError.corruptEntry(entryName) }

        var destination = Data(count: expectedSize)
        let written = destination.withUnsafeMutableBytes { destinationBuffer -> Int in
            payload.withUnsafeBytes { sourceBuffer -> Int in
                guard let destinationPointer = destinationBuffer.bindMemory(to: UInt8.self).baseAddress,
                      let sourcePointer = sourceBuffer.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }
                return compression_decode_buffer(
                    destinationPointer,
                    expectedSize,
                    sourcePointer,
                    payload.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }

        guard written == expectedSize else {
            throw ZipArchiveError.corruptEntry(entryName)
        }
        return destination
    }
}

// MARK: - 写入

/// ZIP 写入器（store 模式）。
public struct ZipArchiveWriter {

    /// 单个归档体积上限（默认 2 GB，防御性上限）。
    public static let defaultMaxBytes = 2 * 1024 * 1024 * 1024

    private struct PendingEntry {
        let name: String
        let data: Data
        let crc: UInt32
        let dosTime: UInt16
        let dosDate: UInt16
        let localHeaderOffset: UInt32
    }

    private var buffer = Data()
    private var entries: [PendingEntry] = []
    private var finalized = false
    private let maxBytes: Int

    public init(maxBytes: Int = ZipArchiveWriter.defaultMaxBytes) {
        self.maxBytes = max(1024, maxBytes)
    }

    /// 已写入的条目数。
    public var entryCount: Int { entries.count }

    /// 追加一个文件。
    /// - Throws: `ZipArchiveError.invalidName` / `.duplicateEntryName` / `.tooManyBytes`
    public mutating func addFile(name: String, data: Data, date: Date = Date()) throws {
        guard !finalized else { throw ZipArchiveError.corruptEntry(Copy.text("error.zip.writerFinished")) }
        guard ZipArchiveWriter.isValidEntryName(name) else {
            throw ZipArchiveError.invalidName(name)
        }
        guard !entries.contains(where: { $0.name == name }) else {
            throw ZipArchiveError.duplicateEntryName(name)
        }
        guard buffer.count + data.count <= maxBytes else {
            throw ZipArchiveError.tooManyBytes(maxBytes)
        }

        let crc = Crc32.checksum(data)
        let (dosTime, dosDate) = ZipArchiveWriter.dosDateTime(from: date)
        let nameBytes = Data(name.utf8)
        guard nameBytes.count <= Int(UInt16.max) else {
            throw ZipArchiveError.invalidName(name)
        }

        let offset = UInt32(buffer.count)
        var local = Data()
        local.appendUInt32(0x04034b50)
        local.appendUInt16(20)                       // version needed
        local.appendUInt16(0x0800)                   // flags: UTF-8
        local.appendUInt16(0)                        // method: store
        local.appendUInt16(dosTime)
        local.appendUInt16(dosDate)
        local.appendUInt32(crc)
        local.appendUInt32(UInt32(data.count))       // compressed size
        local.appendUInt32(UInt32(data.count))       // uncompressed size
        local.appendUInt16(UInt16(nameBytes.count))
        local.appendUInt16(0)                        // extra length
        local.append(nameBytes)

        buffer.append(local)
        buffer.append(data)

        entries.append(
            PendingEntry(
                name: name,
                data: data,
                crc: crc,
                dosTime: dosTime,
                dosDate: dosDate,
                localHeaderOffset: offset
            )
        )
    }

    /// 结束写入并返回完整归档数据。
    /// - Throws: `ZipArchiveError.emptyArchive`（一个条目都没有）。
    public mutating func finalize() throws -> Data {
        guard !entries.isEmpty else { throw ZipArchiveError.emptyArchive }
        finalized = true

        let centralOffset = UInt32(buffer.count)
        var central = Data()

        for entry in entries {
            let nameBytes = Data(entry.name.utf8)
            central.appendUInt32(0x02014b50)
            central.appendUInt16(20)                 // version made by
            central.appendUInt16(20)                 // version needed
            central.appendUInt16(0x0800)             // flags: UTF-8
            central.appendUInt16(0)                  // method: store
            central.appendUInt16(entry.dosTime)
            central.appendUInt16(entry.dosDate)
            central.appendUInt32(entry.crc)
            central.appendUInt32(UInt32(entry.data.count))
            central.appendUInt32(UInt32(entry.data.count))
            central.appendUInt16(UInt16(nameBytes.count))
            central.appendUInt16(0)                  // extra
            central.appendUInt16(0)                  // comment
            central.appendUInt16(0)                  // disk number start
            central.appendUInt16(0)                  // internal attributes
            central.appendUInt32(0)                  // external attributes
            central.appendUInt32(entry.localHeaderOffset)
            central.append(nameBytes)
        }

        var output = buffer
        output.append(central)

        let centralSize = UInt32(central.count)
        output.appendUInt32(0x06054b50)
        output.appendUInt16(0)                       // this disk
        output.appendUInt16(0)                       // disk with central dir
        output.appendUInt16(UInt16(entries.count))
        output.appendUInt16(UInt16(entries.count))
        output.appendUInt32(centralSize)
        output.appendUInt32(centralOffset)
        output.appendUInt16(0)                       // comment length

        return output
    }

    /// 条目名合法性：非空、不含绝对路径 / 反斜杠 / `..`、不以 `/` 开头。
    public static func isValidEntryName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= Int(UInt16.max) else { return false }
        guard !name.hasPrefix("/"), !name.hasPrefix("\\") else { return false }
        guard !name.contains("\\") else { return false }
        guard !name.contains("\u{0}") else { return false }
        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains("..")
    }

    /// 时间 → DOS 时间 / 日期。
    static func dosDateTime(from date: Date) -> (UInt16, UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)

        let year = max(1980, parts.year ?? 1980)
        let month = min(max(1, parts.month ?? 1), 12)
        let day = min(max(1, parts.day ?? 1), 31)
        let hour = min(max(0, parts.hour ?? 0), 23)
        let minute = min(max(0, parts.minute ?? 0), 59)
        let second = min(max(0, parts.second ?? 0), 59)

        let dosDate = UInt16(((year - 1980) << 9) | (month << 5) | day)
        let dosTime = UInt16((hour << 11) | (minute << 5) | (second / 2))
        return (dosTime, dosDate)
    }
}

// MARK: - 读取

/// ZIP 读取器（仅支持 store 模式条目）。
public struct ZipArchiveReader {

    /// 中央目录条目内部表示。
    private struct CentralEntry {
        let name: String
        let crc: UInt32
        /// 解压后大小（中央目录偏移 +24）。
        let uncompressedSize: Int
        /// 压缩后大小（中央目录偏移 +20）。
        let compressedSize: Int
        let localHeaderOffset: Int
        let compression: UInt16
    }

    private let data: Data
    private let centralEntries: [CentralEntry]

    /// 解析归档。
    /// - Throws: `ZipArchiveError`
    public init(data: Data) throws {
        guard !data.isEmpty else { throw ZipArchiveError.emptyArchive }
        self.data = data

        guard let eocdOffset = ZipArchiveReader.findEndOfCentralDirectory(in: data) else {
            throw ZipArchiveError.missingEndOfCentralDirectory
        }

        guard data.count >= eocdOffset + 22 else { throw ZipArchiveError.dataTruncated }
        let totalEntries = Int(data.readUInt16(at: eocdOffset + 10))
        let centralSize = Int(data.readUInt32(at: eocdOffset + 12))
        let centralOffset = Int(data.readUInt32(at: eocdOffset + 16))

        guard centralOffset >= 0, centralSize >= 0,
              centralOffset + centralSize <= data.count else {
            throw ZipArchiveError.dataTruncated
        }

        var entries: [CentralEntry] = []
        var cursor = centralOffset

        for _ in 0..<totalEntries {
            guard cursor + 46 <= data.count else { throw ZipArchiveError.dataTruncated }
            let signature = data.readUInt32(at: cursor)
            guard signature == 0x02014b50 else {
                throw ZipArchiveError.invalidSignature(found: signature)
            }
            let compression = data.readUInt16(at: cursor + 10)
            let crc = data.readUInt32(at: cursor + 16)
            let compressedSize = Int(data.readUInt32(at: cursor + 20))
            let uncompressedSize = Int(data.readUInt32(at: cursor + 24))
            let nameLength = Int(data.readUInt16(at: cursor + 28))
            let extraLength = Int(data.readUInt16(at: cursor + 30))
            let commentLength = Int(data.readUInt16(at: cursor + 32))
            let localOffset = Int(data.readUInt32(at: cursor + 42))

            guard cursor + 46 + nameLength + extraLength + commentLength <= data.count else {
                throw ZipArchiveError.dataTruncated
            }
            let nameData = data.subdata(in: (cursor + 46)..<(cursor + 46 + nameLength))
            let name = String(decoding: nameData, as: UTF8.self)

            entries.append(
                CentralEntry(
                    name: name,
                    crc: crc,
                    uncompressedSize: uncompressedSize,
                    compressedSize: compressedSize,
                    localHeaderOffset: localOffset,
                    compression: compression
                )
            )
            cursor += 46 + nameLength + extraLength + commentLength
        }

        self.centralEntries = entries
    }

    /// 全部条目元信息。
    public var entries: [ZipEntryInfo] {
        centralEntries.map {
            ZipEntryInfo(
                name: $0.name,
                uncompressedSize: $0.uncompressedSize,
                compressedSize: $0.compressedSize,
                crc32: $0.crc,
                compressionMethod: $0.compression
            )
        }
    }

    /// 条目名列表（保持归档内顺序）。
    public var entryNames: [String] { centralEntries.map(\.name) }

    /// 读取指定条目的数据（store 与 deflate 都支持）。
    /// - Throws: `ZipArchiveError.entryNotFound` / `.unsupportedCompression` / `.corruptEntry`
    public func data(for name: String) throws -> Data {
        guard let entry = centralEntries.first(where: { $0.name == name }) else {
            throw ZipArchiveError.entryNotFound(name)
        }

        // 本地头：30 字节固定 + 名称长度 + 扩展长度
        let local = entry.localHeaderOffset
        guard local + 30 <= data.count else { throw ZipArchiveError.corruptEntry(name) }
        let signature = data.readUInt32(at: local)
        guard signature == 0x04034b50 else {
            throw ZipArchiveError.invalidSignature(found: signature)
        }
        let nameLength = Int(data.readUInt16(at: local + 26))
        let extraLength = Int(data.readUInt16(at: local + 28))
        let start = local + 30 + nameLength + extraLength

        // store 时压缩大小与原始大小相同；deflate 时必须用压缩大小切片
        let sliceLength = entry.compression == 0 ? entry.uncompressedSize : entry.compressedSize
        guard start + sliceLength <= data.count else { throw ZipArchiveError.dataTruncated }
        let raw = data.subdata(in: start..<(start + sliceLength))

        let payload: Data
        switch entry.compression {
        case 0:
            payload = raw
        case 8:
            payload = try Deflate.inflate(raw, expectedSize: entry.uncompressedSize, entryName: name)
        default:
            throw ZipArchiveError.unsupportedCompression(entry.compression)
        }

        guard payload.count == entry.uncompressedSize else {
            throw ZipArchiveError.corruptEntry(name)
        }
        // CRC 校验的是**解压后**的数据（ZIP 规范语义）
        guard Crc32.checksum(payload) == entry.crc else {
            throw ZipArchiveError.corruptEntry(name)
        }
        return payload
    }

    /// 定位 EOCD（从尾部向前扫描，容忍最多 64 KB 注释）。
    static func findEndOfCentralDirectory(in data: Data) -> Int? {
        let maxCommentLength = 65_536
        let minimumOffset = max(0, data.count - 22 - maxCommentLength)
        var offset = data.count - 22
        while offset >= minimumOffset {
            if data.readUInt32(at: offset) == 0x06054b50 {
                return offset
            }
            offset -= 1
        }
        return nil
    }
}

// MARK: - CRC32

/// 标准 CRC-32（多项式 0xEDB88320）。
public enum Crc32 {
    private static let table: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) == 1 ? (0xEDB88320 ^ (value >> 1)) : (value >> 1)
            }
            return value
        }
    }()

    public static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = table[index] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}

// MARK: - 小端读写

private extension Data {
    func readUInt16(at offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { return 0 }
        let start = startIndex + offset
        return UInt16(self[start]) | (UInt16(self[start + 1]) << 8)
    }

    func readUInt32(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        let start = startIndex + offset
        return UInt32(self[start])
            | (UInt32(self[start + 1]) << 8)
            | (UInt32(self[start + 2]) << 16)
            | (UInt32(self[start + 3]) << 24)
    }

    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
