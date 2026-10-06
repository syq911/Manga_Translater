//
//  CoverThumbnailView.swift
//  MangaTranslater
//
//  书架 / 列表里的封面缩略图。
//
//  生成缩略图要读盘 + 解码 + 缩放，放到主线程会让列表滑动卡顿，
//  因此这里把工作丢到后台任务；由于 `CoverThumbnailCache` 与 `LocalSource`
//  都是线程安全的（`@unchecked Sendable` + 内部加锁），可以安全地在后台调用。
//

import SwiftUI
import UIKit
import AppCore

struct CoverThumbnailView: View {

    let manga: Manga
    var width: CGFloat = 44
    var height: CGFloat = 60

    @Environment(AppEnvironment.self) private var environment
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholder
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .task(id: manga.id) { await load() }
    }

    private var placeholder: some View {
        ZStack {
            Color.secondary.opacity(0.12)
            Image(systemName: manga.sourceID == .local ? "doc.zipper" : "book.closed")
                .font(.system(size: min(width, height) * 0.35))
                .foregroundStyle(.secondary)
        }
    }

    private func load() async {
        // 先把引用取到局部：`AppEnvironment` 是 @MainActor 隔离的，
        // 但其持有的这两个对象本身线程安全，可交给后台任务使用。
        let cache = environment.coverCache
        let manga = manga

        // 在线来源：封面要联网取（走来源 Cookie 与体积上限），
        // 取到后再交给同一个缓存做缩放与落盘，缓存键与本地来源一致。
        if manga.sourceID != .local {
            guard let remote = await environment.loadRemoteCover(for: manga) else { return }
            let thumb = await Task.detached(priority: .utility) { () -> Data? in
                cache.thumbnail(mangaID: manga.id) { remote }
            }.value
            // 注意别写成 `(thumb ?? remote).flatMap { … }`：合并后 `Data` 不是 Optional，
            // `.flatMap` 会解析到 `Sequence` 那个重载，编译不过。
            image = UIImage(data: thumb ?? remote)
            return
        }

        let source = environment.localSource
        let data = await Task.detached(priority: .utility) { () -> Data? in
            cache.thumbnail(mangaID: manga.id) {
                try source.coverData(for: manga)
            }
        }.value

        image = data.flatMap { UIImage(data: $0) }
    }
}
