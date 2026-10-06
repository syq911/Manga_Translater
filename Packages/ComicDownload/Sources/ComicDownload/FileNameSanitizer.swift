//
//  FileNameSanitizer.swift
//  ComicDownload
//
//  把任意标识（主键、任务 ID）转成「可读 + 唯一 + 安全」的文件名片段。
//
//  为什么需要它：本项目的标识都是「主键 = 若干字段用 `|` 拼起来」的形式，
//  里面**必然含 `/` 与 `:`**（因为包含 URL）。直接当文件名用会有两个后果：
//  1. 路径穿越：`../` 之类会跑到目录外（这也是为什么早期实现干脆拒绝含 `/` 的 ID，
//     结果就是「在线章节的 ID 一律非法」，下载功能整个走不通）；
//  2. 同名冲突：不同 URL 的尾巴可能一样。
//
//  做法是「可读部分 + 稳定哈希」：只保留字母数字与 `._-`（其余换成 `_`），
//  再拼上 FNV-1a 哈希的后 8 位十六进制。可读部分方便人工排查，
//  哈希保证唯一。
//

import Foundation

/// 文件名片段生成器。

public enum FileNameSanitizer {

    /// 可读部分的长度上限。
    ///
    /// iOS 的文件名上限是 255 **字节**（UTF-8 下中文占 3 字节），
    /// 主键里的 URL 可能很长；截断到 60 个字符，加上哈希也远在限制内。
    public static let maxReadableLength = 60

    /// 生成文件名片段。
    public static func segment(_ raw: String, maxLength: Int = maxReadableLength) -> String {
        let readable = String(raw.map { character -> Character in
            if character.isLetter || character.isNumber {
                return character
            }
            if character == "." || character == "-" || character == "_" {
                return character
            }
            return "_"
        }.prefix(max(1, maxLength)))
        // 全被替换掉时（例如主键只由符号组成）给个兜底词，避免文件名只剩下划线
        let stem = readable.isEmpty ? "item" : readable
        return "\(stem)_\(stableHash(raw))"
    }

    /// FNV-1a 64 位哈希（取低 32 位，十六进制）。
    ///
    /// 不用 `String.hashValue`：它每次进程启动都会变（Swift 的哈希随机化），
    /// 用它命名等于「这次写进去、下次找不到」。
    public static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%08x", UInt32(truncatingIfNeeded: hash))
    }
}
