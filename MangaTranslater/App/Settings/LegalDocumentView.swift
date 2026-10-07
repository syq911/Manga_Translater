//
//  LegalDocumentView.swift
//  MangaTranslater
//
//  法务文档阅读页（隐私政策 / 使用条款 / 开源许可）。
//
//  为什么不直接把 Markdown 塞进 `Text`：那样用户会看到 `##`、`|---|` 这些记号。
//  这里用一个「够用就好」的渲染器：标题、小节、列表、两列表格、代码块
//  这五种结构覆盖了法务文本的全部形态，不需要引入任何 Markdown 依赖
//  （侧载 App 的价值之一是依赖越少越好）。
//
//  正文来源见 `LegalDocuments.swift`：由 `docs/legal/*.md` 单向生成，
//  并由 `tools/check_legal_sync.py` 保证三份载体不分叉。
//

import SwiftUI

struct LegalDocumentView: View {

    let kind: LegalDocumentKind

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(LegalMarkdown.parse(kind.body).enumerated()), id: \.offset) { _, block in
                    block.view
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    openWebsite()
                } label: {
                    Image(systemName: "safari")
                }
                .accessibilityLabel(L("legal.openInBrowser"))
            }
        }
    }

    /// 「在官网查看」：官方页面始终是最新版本，设备端副本是随版本冻结的。
    private func openWebsite() {
        guard let base = environment.legalSiteURL else { return }
        let url = URL(string: base.absoluteString + kind.websitePath) ?? base
        openURL(url)
    }
}

// MARK: - 极简 Markdown

/// 法务文本里实际出现的结构。
enum LegalBlock {
    case title(String)
    case heading(String)
    case bullet(String)
    /// 两列表格行（法务文本里的表格都是「项 / 说明」两列）。
    case row(String, String)
    case code(String)
    case paragraph(String)

    @ViewBuilder
    var view: some View {
        switch self {
        case let .title(text):
            Text(text)
                .font(.title2.bold())
                .padding(.bottom, 2)
        case let .heading(text):
            Text(text)
                .font(.headline)
                .padding(.top, 8)
        case let .bullet(text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•")
                Text(text)
            }
            .font(.body)
        case let .row(left, right):
            HStack(alignment: .top, spacing: 10) {
                Text(left)
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 116, alignment: .leading)
                Text(right)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case let .code(text):
            Text(text)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        case let .paragraph(text):
            Text(text)
                .font(.body)
        }
    }
}

enum LegalMarkdown {

    /// 把法务 Markdown 拆成可渲染的块。
    ///
    /// 只处理这几种形态，且**刻意不做嵌套**：法务文本不需要，而一个能处理嵌套的
    /// 解析器意味着更多的出错方式（错一层的渲染比不做渲染更难发现）。
    static func parse(_ text: String) -> [LegalBlock] {
        var blocks: [LegalBlock] = []
        var inCodeFence = false
        var codeBuffer: [String] = []

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inCodeFence {
                    blocks.append(.code(codeBuffer.joined(separator: "\n")))
                    codeBuffer = []
                }
                inCodeFence.toggle()
                continue
            }
            if inCodeFence {
                codeBuffer.append(trimmed)
                continue
            }

            if trimmed.isEmpty || trimmed == "---" {
                continue
            }
            // 表格分隔行 `|---|---|`
            if isTableSeparator(trimmed) {
                continue
            }
            if trimmed.hasPrefix("|") {
                let cells = splitTableRow(trimmed)
                if cells.count >= 2 {
                    blocks.append(.row(plain(cells[0]), plain(cells[1])))
                } else if let only = cells.first {
                    blocks.append(.paragraph(plain(only)))
                }
                continue
            }
            if trimmed.hasPrefix("### ") {
                blocks.append(.heading(plain(String(trimmed.dropFirst(4)))))
                continue
            }
            if trimmed.hasPrefix("## ") {
                blocks.append(.heading(plain(String(trimmed.dropFirst(3)))))
                continue
            }
            if trimmed.hasPrefix("# ") {
                blocks.append(.title(plain(String(trimmed.dropFirst(2)))))
                continue
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                blocks.append(.bullet(plain(String(trimmed.dropFirst(2)))))
                continue
            }
            if let numbered = numberedListItem(trimmed) {
                blocks.append(.bullet(numbered))
                continue
            }
            blocks.append(.paragraph(plain(trimmed)))
        }

        if inCodeFence, !codeBuffer.isEmpty {
            blocks.append(.code(codeBuffer.joined(separator: "\n")))
        }
        return blocks
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        guard line.hasPrefix("|") else { return false }
        let stripped = line.replacingOccurrences(of: "|", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: " ", with: "")
        return stripped.isEmpty
    }

    private static func splitTableRow(_ line: String) -> [String] {
        var cells = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        if cells.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeFirst() }
        if cells.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// `1. xxx` → `1. xxx`（保留序号，列表语义不丢）。
    private static func numberedListItem(_ line: String) -> String? {
        guard let dot = line.firstIndex(of: "."), dot > line.startIndex else { return nil }
        let head = line[line.startIndex..<dot]
        guard head.allSatisfy(\.isNumber) else { return nil }
        let rest = line[line.index(after: dot)...].trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }
        return "\(head). \(plain(rest))"
    }

    /// 去掉行内标记（`**粗体**`、`` `代码` ``、`[文字](链接)`）；
    /// 在 SwiftUI 的纯 `Text` 里这些记号会原样显示出来。
    static func plain(_ line: String) -> String {
        var result = line.replacingOccurrences(of: "**", with: "")
        result = result.replacingOccurrences(of: "`", with: "")

        // [文字](链接) → 文字 (链接)
        var output = ""
        var index = result.startIndex
        while index < result.endIndex {
            guard result[index] == "[",
                  let close = result[index...].firstIndex(of: "]"),
                  let open = result.index(close, offsetBy: 1, limitedBy: result.endIndex),
                  open < result.endIndex, result[open] == "(",
                  let end = result[open...].firstIndex(of: ")")
            else {
                output.append(result[index])
                index = result.index(after: index)
                continue
            }
            let label = result[result.index(after: index)..<close]
            let link = result[result.index(after: open)..<end]
            output += "\(label) (\(link))"
            index = result.index(after: end)
        }
        return output
    }
}

#Preview {
    NavigationStack {
        LegalDocumentView(kind: .privacy)
            .environment(AppEnvironment.makeDefault())
    }
}
