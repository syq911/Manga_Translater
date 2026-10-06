//
//  RepositoryManagerView.swift
//  MangaTranslater
//
//  源仓库管理：添加 / 删除仓库、刷新可装源、安装与更新。
//
//  合规要点（勿改）：
//  - **出厂零仓库**：这里只列出用户自己添加的地址，不存在任何预置仓库；
//  - 界面文案不出现任何具体站点名，也不暗示「去哪里找仓库」；
//  - 安装是用户逐个确认的动作，不做「一键全装」。
//
//  交互约定：
//  - 单个仓库拉取失败只在该仓库这一行显示原因，不影响其他仓库（服务层已按此返回）；
//  - 安装 / 更新按 key 记「进行中」，避免连点触发重复安装；
//  - 安装成功后刷新目录，让「可更新」状态立刻反映出来。
//

import SwiftUI
import AppCore
import SourceEngine

struct RepositoryManagerView: View {

    @Environment(AppEnvironment.self) private var environment

    @State private var newRepositoryURL = ""
    @State private var results: [RepositoryCatalogResult] = []
    @State private var isRefreshing = false
    @State private var busyKeys: Set<String> = []
    @State private var statusMessage: String?
    @State private var didLoad = false

    var body: some View {
        Form {
            addSection
            repositoriesSection
            catalogSection
        }
        .navigationTitle(L("repo.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await refresh() }
                } label: {
                    if isRefreshing {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(environment.repositories.isEmpty || isRefreshing)
            }
        }
        .task {
            guard !didLoad else { return }
            didLoad = true
            await refresh()
        }
        .alert(L("common.notice"), isPresented: Binding(
            get: { statusMessage != nil },
            set: { if !$0 { statusMessage = nil } }
        )) {
            Button(L("common.ok"), role: .cancel) { statusMessage = nil }
        } message: {
            Text(statusMessage ?? "")
        }
    }

    // MARK: 添加仓库

    private var addSection: some View {
        Section {
            TextField(L("repo.add.placeholder"), text: $newRepositoryURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button(L("repo.add.action")) {
                addRepository()
            }
            .disabled(newRepositoryURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } header: {
            Text(L("repo.section.add"))
        } footer: {
            Text(L("repo.add.footer"))
        }
    }

    private func addRepository() {
        let trimmed = newRepositoryURL.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let added = try environment.sourceStore.addRepository(trimmed)
            newRepositoryURL = ""
            if added {
                Task { await refresh() }
            } else {
                statusMessage = L("repo.add.duplicate")
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    // MARK: 仓库列表

    private var repositoriesSection: some View {
        Section(L("repo.section.list")) {
            if environment.repositories.isEmpty {
                Text(L("repo.empty"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(environment.repositories, id: \.self) { repository in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(repository)
                                .font(.footnote)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if let failure = failureMessage(for: repository) {
                                Text(failure)
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                            }
                        }
                        Spacer()
                        Button(role: .destructive) {
                            removeRepository(repository)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    private func removeRepository(_ repository: String) {
        do {
            _ = try environment.sourceStore.removeRepository(repository)
            // 已装的源不随仓库删除而卸载：仓库只是「安装来源」，不是运行时依赖
            results.removeAll { $0.repositoryURL == repository }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func failureMessage(for repository: String) -> String? {
        results.first { $0.repositoryURL == repository }?.errorMessage
    }

    // MARK: 可装的源

    private var catalogSection: some View {
        Section {
            if environment.repositories.isEmpty {
                Text(L("repo.catalog.noRepo"))
                    .foregroundStyle(.secondary)
            } else if results.isEmpty && isRefreshing {
                HStack {
                    ProgressView()
                    Text(L("repo.catalog.loading"))
                        .foregroundStyle(.secondary)
                }
            } else if !results.isEmpty && results.allSatisfy({ $0.catalog == nil }) {
                Text(L("repo.catalog.allFailed"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(results, id: \.repositoryURL) { result in
                    if let catalog = result.catalog {
                        ForEach(catalog.entries) { entry in
                            entryRow(entry)
                        }
                    }
                }
            }
        } header: {
            Text(L("repo.section.catalog"))
        } footer: {
            Text(L("repo.catalog.footer"))
        }
    }

    private func entryRow(_ entry: RepositoryEntry) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.name)
                    if entry.hasUpdate {
                        Image(systemName: "arrow.up.circle.fill")
                            .foregroundStyle(.tint)
                            .imageScale(.small)
                    }
                }
                Text("\(entry.key) · \(entry.version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let summary = entry.summary {
                    Text(summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            if busyKeys.contains(entry.key) {
                ProgressView()
            } else if !entry.isInstallable {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            } else {
                Button(buttonTitle(for: entry)) {
                    Task { await install(entry) }
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func buttonTitle(for entry: RepositoryEntry) -> String {
        if entry.hasUpdate { return L("repo.action.update") }
        return entry.isInstalled ? L("repo.action.reinstall") : L("repo.action.install")
    }

    // MARK: 行为

    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        results = await environment.reloadRepositoryCatalogs()
        isRefreshing = false
    }

    private func install(_ entry: RepositoryEntry) async {
        guard !busyKeys.contains(entry.key) else { return }
        busyKeys.insert(entry.key)
        defer { busyKeys.remove(entry.key) }

        do {
            let installed = try await environment.installSource(entry)
            var parts = [String(format: L("repo.installed.format"), installed.name, installed.version ?? "-")]
            if installed.isNSFW, !environment.settings.showsNSFWSources {
                parts.append(L("repo.installed.nsfwHidden"))
            }
            statusMessage = parts.joined(separator: "\n")
            await refresh()
        } catch let error as SourceRepositoryError {
            statusMessage = error.message
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}
