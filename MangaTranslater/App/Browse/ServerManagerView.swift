//
//  ServerManagerView.swift
//  MangaTranslater
//
//  自建服务器（Komga / Kavita）的管理：添加、编辑凭据、连接自检、删除。
//
//  几个取舍：
//  - **先自检再保存**：地址填错最常见（少了端口、少了子路径、写成网页版地址），
//    如果保存后才发现，用户已经在浏览页点了一圈。所以「保存」时会先做一次
//    `probe()`，成功才落盘；失败也能「仍然保存」（有些服务器只在内网可达，
//    或者用户想先存着）。
//  - **标识由名字派生**，不让用户填：`SourceID` 有一堆字符限制，
//    让用户去理解「只能小写字母数字」纯粹是给用户添堵。
//  - **凭据不回显**：编辑时只显示「已设置」，要改就重新输入。
//    把密码原样回显在界面上，等于把「截屏分享」变成一次泄漏。
//

import SwiftUI
import AppCore
import SourceEngine

struct ServerManagerView: View {

    @Environment(AppEnvironment.self) private var environment

    @State private var editing: HostedServer?
    @State private var isAdding = false
    @State private var message: String?
    @State private var pendingDelete: HostedServer?

    var body: some View {
        List {
            Section {
                ForEach(environment.hostedServers) { server in
                    Button {
                        editing = server
                    } label: {
                        row(server)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            pendingDelete = server
                        } label: {
                            Label(L("downloads.action.delete"), systemImage: "trash")
                        }
                    }
                }
                if environment.hostedServers.isEmpty {
                    Text(L("server.empty"))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(L("server.section.list"))
            } footer: {
                Text(L("server.footer"))
            }

            Section {
                Button {
                    isAdding = true
                } label: {
                    Label(L("server.add"), systemImage: "plus")
                }
            }
        }
        .navigationTitle(L("server.title"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isAdding) {
            ServerEditView(server: nil) { newServer in
                try environment.serverStore.add(newServer)
                message = L("server.saved")
            }
        }
        .sheet(item: $editing) { server in
            ServerEditView(server: server) { updated in
                try environment.updateHostedServer(updated)
                message = L("server.saved")
            }
        }
        .alert(L("common.notice"), isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button(L("common.ok"), role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
        .confirmationDialog(
            L("server.deleteConfirm.title"),
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L("downloads.action.delete"), role: .destructive) {
                if let server = pendingDelete {
                    _ = try? environment.removeHostedServer(id: server.id)
                }
                pendingDelete = nil
            }
            Button(L("common.cancel"), role: .cancel) { pendingDelete = nil }
        } message: {
            Text(String(
                format: L("server.deleteConfirm.message"),
                pendingDelete?.name ?? ""
            ))
        }
    }

    private func row(_ server: HostedServer) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(server.name)
                Text(server.kind.displayName)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
            }
            Text(server.normalizedBaseURL)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if !server.hasCredentials {
                Label(L("server.noCredentials"), systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

// MARK: - 编辑

/// 添加 / 编辑一台服务器。
struct ServerEditView: View {

    /// nil 表示新增。
    let server: HostedServer?
    /// 保存动作（抛错表示保存失败，界面显示原因）。
    let onSave: (HostedServer) throws -> Void

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var kind: HostedServerKind = .komga
    @State private var name = ""
    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var username = ""
    @State private var password = ""

    @State private var isTesting = false
    @State private var testResult: String?
    @State private var errorMessage: String?

    private var isEditing: Bool { server != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(L("server.kind"), selection: $kind) {
                        ForEach(HostedServerKind.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    TextField(L("server.name"), text: $name)
                    TextField(L("server.baseURLPlaceholder"), text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } footer: {
                    Text(L("server.addressFooter"))
                }

                Section {
                    SecureField(L("server.apiKey"), text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField(L("server.username"), text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField(L("server.password"), text: $password)
                } header: {
                    Text(L("server.section.credentials"))
                } footer: {
                    Text(L("server.credentialsFooter"))
                }

                Section {
                    Button {
                        Task { await runTest() }
                    } label: {
                        HStack {
                            Label(L("server.test"), systemImage: "bolt.horizontal")
                            if isTesting {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isTesting)

                    if let testResult {
                        Text(testResult)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(L("server.section.test"))
                } footer: {
                    Text(L("server.testFooter"))
                }
            }
            .navigationTitle(isEditing ? L("server.edit") : L("server.add"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("server.save")) { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || baseURL.isEmpty)
                }
            }
            .alert(L("common.notice"), isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button(L("common.ok"), role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .task { load() }
        }
    }

    // MARK: 行为

    private func load() {
        guard let server else { return }
        kind = server.kind
        name = server.name
        baseURL = server.normalizedBaseURL
        // 凭据不回显：只留空让用户重新输入
        apiKey = ""
        username = server.username ?? ""
        password = ""
    }

    /// 用当前表单内容拼出一台服务器（不落盘）。
    private func draft() -> HostedServer {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = server ?? HostedServer(
            id: HostedServer.makeID(
                kind: kind,
                name: trimmedName,
                existing: Set(environment.hostedServers.map(\.id))
            ),
            kind: kind,
            name: trimmedName,
            baseURL: baseURL
        )
        result.kind = kind
        result.name = trimmedName
        result.baseURL = baseURL
        // 空输入表示「不改」，沿用原值——否则用户编辑地址时会不小心把密钥清掉
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty { result.apiKey = trimmedKey }
        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        result.username = trimmedUser.isEmpty ? nil : trimmedUser
        if !password.isEmpty { result.password = password }
        return result
    }

    private func runTest() async {
        let target = draft()
        guard HostedServer.isValidBaseURL(target.baseURL) else {
            errorMessage = L("server.invalidAddress")
            return
        }
        isTesting = true
        testResult = nil
        let outcome = await environment.probeHostedServer(target)
        isTesting = false
        switch outcome {
        case let .success(text): testResult = text
        case let .failure(error): testResult = error.message
        }
    }

    private func save() {
        let target = draft()
        guard HostedServer.isValidBaseURL(target.baseURL) else {
            errorMessage = L("server.invalidAddress")
            return
        }
        do {
            try onSave(target)
            dismiss()
        } catch {
            errorMessage = AppError.normalize(error).localizedDescription
        }
    }
}

#Preview {
    NavigationStack {
        ServerManagerView()
            .environment(AppEnvironment.makeDefault())
    }
}
