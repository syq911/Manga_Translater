//
//  ReaderJumpSheet.swift
//  MangaTranslater
//
//  阅读器的「目录」：跳章 + 跳页。
//
//  长作品（几十上百话）没有这个入口就只能一页页翻——
//  翻页是阅读，翻 300 页找某一话不是。所以它属于阅读器的基础能力，
//  而不是「附赠的便利功能」。
//
//  输入解析与越界处理全部在 `AppCore.ReaderJump`（可单测），这里只负责画出来、
//  把结果接到阅读会话上。
//

import SwiftUI
import AppCore

struct ReaderJumpSheet: View {

    let chapters: [Chapter]
    let currentChapterIndex: Int
    let pageIndex: Int
    let pageCount: Int
    /// 跳到第 N 章（0 基下标）。
    let onJumpToChapter: (Int) -> Void
    /// 跳到第 N 页（0 基下标）。
    let onJumpToPage: (Int) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var pageInput = ""
    /// 输入被钳制 / 无法解析时的说明。**不能静默**——静默等于「点了没反应」。
    @State private var hint: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 8) {
                        TextField(
                            String(format: L("reader.jump.pagePlaceholder"), pageIndex + 1, pageCount),
                            text: $pageInput
                        )
                        .keyboardType(.numberPad)

                        Button(L("reader.jump.action")) { submitPage() }
                            .disabled(pageCount == 0)
                    }

                    if let hint {
                        Text(hint)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text(L("reader.jump.pageSection"))
                } footer: {
                    Text(L("reader.jump.pageFooter"))
                }

                Section {
                    // `ForEach(chapters.indices, id: \.self)`：需要下标来回调，
                    // 而**元组没有 keypath**（`\.element.id` 编译不过）。
                    ForEach(chapters.indices, id: \.self) { index in
                        Button {
                            onJumpToChapter(index)
                            dismiss()
                        } label: {
                            HStack(spacing: 8) {
                                Text(chapters[index].name)
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                Spacer(minLength: 4)
                                if index == currentChapterIndex {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                } header: {
                    Text(String(format: L("reader.jump.chapterSection"), chapters.count))
                }
            }
            .navigationTitle(L("reader.jump.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("common.done")) { dismiss() }
                }
            }
        }
    }

    private func submitPage() {
        switch ReaderJump.resolvePage(input: pageInput, pageCount: pageCount) {
        case let .jump(toIndex):
            onJumpToPage(toIndex)
            dismiss()
        case let .outOfRange(clampedIndex):
            // 越界**跳过去**并说明：用户打错一位数字时，「跳到最后一页」
            // 比「弹个错然后什么都不做」更接近他的意图，而且他马上能看出来。
            onJumpToPage(clampedIndex)
            hint = clampedIndex == 0
                ? L("reader.jump.clampedFirst")
                : String(format: L("reader.jump.clampedLast"), pageCount)
        case .invalid:
            hint = L("reader.jump.invalid")
        }
    }
}
