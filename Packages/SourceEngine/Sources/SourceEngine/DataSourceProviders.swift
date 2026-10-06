//
//  DataSourceProviders.swift
//  SourceEngine
//
//  数据来源的两个「路由器」：
//  - `HostedDataSourceProvider`：按服务器配置（Komga / Kavita）建连接器；
//  - `CompositeDataSourceProvider`：把「自建服务器」与「社区脚本源」合成一个入口。
//
//  为什么路由要显式而不是「挨个试」：脚本源的池在遇到未安装的 id 时会抛错，
//  如果靠 try/catch 挨个试，最后抛出的错误会是「最后一个 provider 的错误」，
//  于是「Komga 服务器地址填错」会显示成「源未安装」——排查方向完全错了。
//  先判断「这个 id 归谁」，再调它，错误才指向真正出问题的地方。
//

import Foundation
import AppCore
import ComicNet

/// 自建服务器数据来源。
public struct HostedDataSourceProvider: MangaDataSourceProviding {

    private let store: ServerStore
    private let client: HTTPClient

    public init(store: ServerStore, client: HTTPClient) {
        self.store = store
        self.client = client
    }

    /// 这个标识是否属于某台已配置的服务器。
    public func knows(_ sourceID: SourceID) -> Bool {
        store.server(id: sourceID.rawValue) != nil
    }

    /// 已配置的全部服务器。
    public func servers() -> [HostedServer] {
        store.all()
    }

    public func dataSource(for sourceID: SourceID) async throws -> MangaDataSource {
        guard let server = store.server(id: sourceID.rawValue) else {
            throw HostedServerError.unavailable("没有配置这台服务器：\(sourceID.rawValue)")
        }
        switch server.kind {
        case .komga:
            return try KomgaDataSource(server: server, client: client)
        case .kavita:
            return KavitaDataSource(server: server, client: client)
        }
    }
}

/// 数据来源总入口。
public struct CompositeDataSourceProvider: MangaDataSourceProviding {

    private let hosted: HostedDataSourceProvider
    private let scripts: SourceRuntimePool

    public init(hosted: HostedDataSourceProvider, scripts: SourceRuntimePool) {
        self.hosted = hosted
        self.scripts = scripts
    }

    public func dataSource(for sourceID: SourceID) async throws -> MangaDataSource {
        if hosted.knows(sourceID) {
            return try await hosted.dataSource(for: sourceID)
        }
        return try await scripts.dataSource(for: sourceID)
    }
}
