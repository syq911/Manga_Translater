//
//  BrowseSource.swift
//  MangaTranslater
//
//  浏览页用的「来源」条目：把社区脚本源与自建服务器**合成同一种东西**。
//
//  为什么需要这一层：脚本源来自 `SourceStore`（`InstalledSource`），
//  自建服务器来自 `ServerStore`（`HostedServer`）。两者的界面行为完全一样
//  （点进去看热门 / 搜索 / 详情 / 章节），但字段名不同。
//  如果让界面分别处理，就会出现「浏览页要认识两种模型」——
//  每加一种来源都要改一遍界面。
//
//  成人内容过滤只对**脚本源**生效：自建服务器是用户自己的库，
//  没有「第三方成人源」的问题（服务器上的内容由用户自己管理）。
//

import Foundation
import AppCore
import SourceEngine

struct BrowseSource: Identifiable, Hashable, Sendable {

    /// 与 `Manga.sourceID` 对应的稳定标识（脚本源是 key，服务器是派生 id）。
    let id: String
    let name: String
    let kind: SourceKind
    /// 版本（脚本源有；服务器没有）。
    let version: String?
    let language: String
    let isNSFW: Bool
    /// 副标题（服务器显示地址，脚本源显示 key）。
    let subtitle: String?

    var isHosted: Bool {
        kind == .komga || kind == .kavita
    }

    var sourceID: SourceID { SourceID(id) }

    /// 副标题：优先用显式给的，否则用 key。
    var displaySubtitle: String {
        if let subtitle, !subtitle.isEmpty { return subtitle }
        return id
    }

    init(
        id: String,
        name: String,
        kind: SourceKind,
        version: String? = nil,
        language: String = "all",
        isNSFW: Bool = false,
        subtitle: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.version = version
        self.language = language
        self.isNSFW = isNSFW
        self.subtitle = subtitle
    }

    init(installed: InstalledSource) {
        self.init(
            id: installed.key,
            name: installed.name,
            kind: .remote,
            version: installed.version,
            language: installed.language,
            isNSFW: installed.isNSFW
        )
    }

    init(server: HostedServer) {
        self.init(
            id: server.id,
            name: server.name,
            kind: server.sourceKind,
            subtitle: server.normalizedBaseURL
        )
    }

    var iconName: String {
        switch kind {
        case .komga, .kavita: return "server.rack"
        case .local: return "folder"
        case .remote: return "shippingbox"
        }
    }
}
