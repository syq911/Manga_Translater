//
//  HTMLText.swift
//  SourceEngine
//
//  HTML 文本工具：实体解码 / 转义 / 空白折叠，以及源作者最常用的 URL 处理。
//
//  全是纯函数，可穷举单测。源脚本里 `absoluteURL` 这类需求极其常见
//  （页面给的是 `/m/123` 相对地址），放在宿主侧能省掉每个源各写一遍。
//

import Foundation

public enum HTMLText {

    /// 折叠空白：把连续空白（含换行、制表）压成一个空格并去掉首尾。
    ///
    /// 注意 `&nbsp;` 在解码阶段已变成普通空格，因此也会被折叠——
    /// 这与 HTML 的排版语义一致（源作者若需要原样空白可用元素的 `html` 字段）。
    public static func collapseWhitespace(_ value: String) -> String {
        var result = ""
        var pendingSpace = false
        for character in value {
            if character.isWhitespace {
                pendingSpace = true
                continue
            }
            if pendingSpace, !result.isEmpty { result.append(" ") }
            pendingSpace = false
            result.append(character)
        }
        return result
    }

    /// 解码 HTML 实体（命名实体子集 + 十进制 / 十六进制数字实体）。
    ///
    /// 只实现源作者会遇到的常见项：`&amp; &lt; &gt; &quot; &apos; &nbsp;`
    /// 以及 `&#123;` / `&#x1F600;` 形式的数字实体。未知实体原样保留。
    public static func decodeEntities(_ value: String) -> String {
        guard value.contains("&") else { return value }
        var result = ""
        var index = value.startIndex

        while index < value.endIndex {
            guard value[index] == "&",
                  let semicolon = value[index...].firstIndex(of: ";"),
                  // 实体不会太长，超过 12 个字符基本可判定不是实体
                  value.distance(from: index, to: semicolon) <= 12 else {
                result.append(value[index])
                index = value.index(after: index)
                continue
            }

            let body = String(value[value.index(after: index)..<semicolon])
            if let decoded = decodeEntityBody(body) {
                result.append(decoded)
                index = value.index(after: semicolon)
            } else {
                result.append(value[index])
                index = value.index(after: index)
            }
        }
        return result
    }

    /// 转义为 HTML 文本（序列化用）。
    public static func escape(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            default: result.append(character)
            }
        }
        return result
    }

    // MARK: 内部

    static func decodeEntityBody(_ body: String) -> String? {
        if body.hasPrefix("#") {
            let digits = body.dropFirst()
            let isHex = digits.hasPrefix("x") || digits.hasPrefix("X")
            let numberText = isHex ? digits.dropFirst() : digits
            guard !numberText.isEmpty,
                  let value = UInt32(numberText, radix: isHex ? 16 : 10),
                  let scalar = Unicode.Scalar(value) else { return nil }
            return String(Character(scalar))
        }
        switch body.lowercased() {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return " "
        case "ensp", "emsp", "thinsp": return " "
        case "hellip": return "…"
        case "mdash": return "—"
        case "ndash": return "–"
        case "middot": return "·"
        case "laquo": return "«"
        case "raquo": return "»"
        case "copy": return "©"
        default: return nil
        }
    }
}

// MARK: - URL 工具

public enum HTMLURL {

    /// 把可能是相对的地址解析成绝对地址。
    ///
    /// 源脚本拿到的大多是 `/m/123`、`chapter/1.html`、`//cdn.example.com/a.jpg`、
    /// `?page=2` 这类形式，统一在这里处理。
    /// - Returns: 绝对地址；无法解析时返回 nil。
    public static func absolute(_ link: String, base: String) -> String? {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 协议相对：`//host/path`
        if trimmed.hasPrefix("//") {
            guard let scheme = URL(string: base)?.scheme else { return nil }
            return "\(scheme):\(trimmed)"
        }
        // 已经是绝对地址
        if let url = URL(string: trimmed), url.scheme != nil {
            return trimmed
        }
        guard let baseURL = URL(string: base) else { return nil }
        return URL(string: trimmed, relativeTo: baseURL)?.absoluteURL.absoluteString
    }

    /// 取查询参数（解码百分号转义）。
    public static func queryValue(_ name: String, in url: String) -> String? {
        guard let components = URLComponents(string: url) else { return nil }
        return components.queryItems?.first { $0.name == name }?.value
    }

    /// 把查询参数拼到地址上（覆盖同名参数）。`nil` 值表示移除。
    public static func settingQuery(_ values: [String: String?], in url: String) -> String {
        guard var components = URLComponents(string: url) else { return url }
        var items = components.queryItems ?? []
        for (name, value) in values {
            items.removeAll { $0.name == name }
            if let value {
                items.append(URLQueryItem(name: name, value: value))
            }
        }
        components.queryItems = items.isEmpty ? nil : items
        return components.string ?? url
    }

    /// 取主机名（小写），用于 Cookie 归属判断。
    public static func host(_ url: String) -> String? {
        URL(string: url)?.host?.lowercased()
    }

    /// 反斜杠形式的转义（`\/`）在部分源返回的 JSON 里出现，统一还原。
    public static func unescapingSlashes(_ value: String) -> String {
        value.replacingOccurrences(of: "\\/", with: "/")
    }
}
