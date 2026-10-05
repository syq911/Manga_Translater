//
//  ReaderView.swift
//  MangaTranslater
//
//  阅读器（M1 范围：本地文件源）。
//
//  职责划分：
//  - 翻页/翻章/预加载范围的**规则**在 `AppCore.ReaderSession`（可单元测试）；
//  - 本视图只做三件事：把当前页画出来、把点击转成前进/后退、把进度写回书架。
//
//  远程源的页加载会在 M2 接入（走 `PageDataProviding` 的异步实现），
//  本地源因为数据就在沙盒里，直接同步读取即可。
//

import SwiftUI
import UIKit
import AppCore
import SourceEngine

struct ReaderView: View {

    let manga: Manga

    @Environment(AppEnvironment.self) private var environment

    @State private var session: ReaderSession?
    @State private var pages: [ComicPage] = []
    @State private var pageImages: [Int: Data] = [:]
    @State private var message: String?
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black.opacity(0.02)
                content
            }
            .contentShape(Rectangle())
            .overlay(alignment: .leading) { tapZone(forward: false) }
            .overlay(alignment: .trailing) { tapZone(forward: true) }

            bottomBar
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task { bootstrap() }
        .alert("提示", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("好", role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    // MARK: 子视图

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("载入中…")
        } else if let image = currentImage {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            ContentUnavailableView {
                Label("这一页打不开", systemImage: "photo")
            } description: {
                Text("可能归档损坏或该页不是有效图片。")
            }
        }
    }

    private var currentImage: UIImage? {
        guard let index = session?.pageIndex, let data = pageImages[index] else { return nil }
        return UIImage(data: data)
    }

    private func tapZone(forward: Bool) -> some View {
        Color.clear
            .frame(width: 60)
            .contentShape(Rectangle())
            .onTapGesture { advance(forward: forward) }
    }

    private var bottomBar: some View {
        HStack {
            Button {
                advance(forward: false)
            } label: {
                Label("上一页", systemImage: "chevron.left")
            }
            .disabled(session == nil)

            Spacer()

            VStack(spacing: 2) {
                Text(session?.currentChapter?.name ?? manga.title)
                    .font(.footnote)
                    .lineLimit(1)
                Text(pageLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                advance(forward: true)
            } label: {
                Label("下一页", systemImage: "chevron.right")
            }
            .disabled(session == nil)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var navigationTitle: String {
        session?.currentChapter?.name ?? manga.title
    }

    private var pageLabel: String {
        guard let session, !pages.isEmpty else { return "—" }
        return "\(session.pageIndex + 1) / \(pages.count)"
    }

    // MARK: 行为

    /// 首次进入：读取章节、恢复进度、载入当前章。
    private func bootstrap() {
        guard session == nil else { return }
        do {
            let chapters = try environment.localSource.chapters(for: manga)
            let entry = try? environment.libraryStore.entry(mangaID: manga.id)
            var restored = ReaderSession(manga: manga, chapters: chapters)
            if let chapterID = entry?.lastReadChapterID,
               let index = chapters.firstIndex(where: { $0.id == chapterID }) {
                restored.moveToChapter(index)
            }
            session = restored
            loadCurrentChapter()
        } catch {
            isLoading = false
            message = (error as? LocalSourceError)?.message ?? error.localizedDescription
        }
    }

    /// 载入当前章的页列表与预加载窗口。
    private func loadCurrentChapter() {
        // 注意：`guard let session` 绑定的是不可变副本，mutating 调用必须用 var 副本，
        // 改完再写回 @State。
        guard var working = session, let chapter = working.currentChapter else {
            isLoading = false
            pages = []
            pageImages = [:]
            return
        }
        isLoading = true
        do {
            let loaded = try environment.localSource.pages(for: chapter, manga: manga)
            pages = loaded
            working.clampPageIndex(pageCount: loaded.count)
            session = working
            preload(around: working.pageIndex)
            isLoading = false
            saveProgress()
        } catch {
            isLoading = false
            message = (error as? LocalSourceError)?.message ?? error.localizedDescription
        }
    }

    /// 预加载当前页前后各 N 页（N 取自设置里的预加载窗口）。
    private func preload(around pageIndex: Int) {
        guard let session, !pages.isEmpty else { return }
        let range = session.preloadRange(pageCount: pages.count, window: environment.settings.preloadWindow)
        for index in range where pageImages[index] == nil {
            if let data = try? environment.localSource.imageDataSync(for: pages[index], manga: manga) {
                pageImages[index] = data
            }
        }
        // 释放窗口外的缓存，避免长时间阅读内存膨胀
        let keep = range
        pageImages = pageImages.filter { keep.contains($0.key) }
    }

    private func advance(forward: Bool) {
        guard var session, !pages.isEmpty else { return }
        let result = forward
            ? session.advanceForward(pageCount: pages.count)
            : session.advanceBackward(pageCount: pages.count)

        switch result {
        case let .moved(toPage):
            self.session = session
            preload(around: toPage)
            saveProgress()

        case .needsNextChapter:
            guard session.moveToNextChapter() else { return }
            self.session = session
            loadCurrentChapter()

        case .needsPreviousChapter:
            guard session.moveToPreviousChapter() else { return }
            self.session = session
            loadCurrentChapter()

        case .atEnd:
            message = "已经是最后一页了。"

        case .atStart:
            message = "已经是第一页了。"
        }
    }

    /// 写回阅读进度（失败只提示，不打断阅读）。
    private func saveProgress() {
        guard let mark = session?.progressMark else { return }
        do {
            try environment.libraryStore.updateProgress(
                mangaID: manga.id,
                chapterID: mark.chapterID,
                chapterName: session?.currentChapter?.name ?? "",
                pageIndex: mark.pageIndex,
                at: Date()
            )
        } catch {
            diag("ReaderView: 保存进度失败 —— \(error.localizedDescription)")
        }
    }
}
