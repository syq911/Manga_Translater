//
//  ServerManagerView.swift
//  MangaTranslater
//
//  自建服务器（Komga / Kavita）的管理：添加、编辑凭据、连接自检、删除。
//
//  几个取舍：
//  - **先自检再保存**：地址填错最常见（少了端口、少了子路径、写成网页版地址），
//    如果保存后才发现，用户已经在浏览页点了一圈。所以「保存」先做一次
//    `probe()`，连不上就问一句「仍然保存？」——而不是直接拒绝：
//    内网服务器、临时维护中的服务器都必须允许先存下来。
//    （探活用的是**表单里当前填的配置**，不是存储里那份旧的；见
//    `HostedDataSourceProvider.dataSource(for:)`。）
//  - **标识由名字派生**，不让用户填：`SourceID` 有一堆字符限制，
//    让用户去理解「只能小写字母数字」纯粹是给用户添堵。
//  - **凭据不回显**：编辑时只显示「已设置」，要改就重新输入。
//    把密码原样回显在界面上，等于把「截屏分享」变成一次泄漏。
//    由此带来一条必须写明的语义：**凭据留空 = 不改**（见 `ServerFormDraft`）。
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
            ServerEditView(server: nil) { draft in
                // 走 `AppEnvironment.addHostedServer` 而不是直接 `serverStore.add`：
                // 名字校验、标识派生、诊断打点都在那里——**用户走的路径必须就是
                // 单测覆盖的那条**，否则「测过了」和「真在跑」不是一回事。
                _ = try environment.addHostedServer(
                    kind: draft.kind,
                    name: draft.name,
                    baseURL: draft.baseURL,
                    apiKey: draft.normalizedAPIKey,
                    username: draft.normalizedUsername,
                    password: draft.normalizedPassword
                )
                message = L("server.saved")
            }
        }
        .sheet(item: $editing) { server in
            ServerEditView(server: server) { draft in
                // 合并（含「空 = 不改」的凭据语义）在可测的 `ServerFormDraft` 里
                try environment.updateHostedServer(
                    draft.merged(into: server, assigningID: server.id)
                )
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
                Text(server.kind.brandName)
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
    /// 保存动作。收到的是**原始表单**（`ServerFormDraft`），
    /// 「空凭据 = 不改」之类的合并语义由它自己负责——这样那条规则可以单测。
    /// 抛错表示保存失败，界面显示原因。
    let onSave: (ServerFormDraft) throws -> Void

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    /// 表单内容。凭据是**局部状态**而不是直接绑到 `HostedServer` 上：
    /// 编辑时它们留空表示「不改」，这个语义需要一个独立的容器来表达。
    @State private var draft = ServerFormDraft()

    @State private var isTesting = false
    @State private var testResult: String?
    @State private var errorMessage: String?
    /// 保存前的探活失败原因（配合下面那句「仍然保存？」）。
    @State private var saveFailure: String?
    /// 待「仍然保存」的表单快照（非 nil 即弹确认）。
    @State private var pendingSave: ServerFormDraft?
    @State private var isSaving = false

    private var isEditing: Bool { server != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(L("server.kind"), selection: $draft.kind) {
                        ForEach(HostedServerKind.allCases, id: \.self) { kind in
                            Text(kind.brandName).tag(kind)
                        }
                    }
                    TextField(L("server.name"), text: $draft.name)
                    TextField(L("server.baseURLPlaceholder"), text: $draft.baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } footer: {
                    Text(L("server.addressFooter"))
                }

                Section {
                    SecureField(L("server.apiKey"), text: $draft.apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField(L("server.username"), text: $draft.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField(L("server.password"), text: $draft.password)
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
                    if isSaving {
                        // 保存会先探活，所以要给转圈——否则用户会以为按钮没反应
                        ProgressView()
                    } else {
                        Button(L("server.save")) {
                            Task { await save() }
                        }
                        .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
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
            .confirmationDialog(
                L("server.saveAnyway.title"),
                isPresented: Binding(
                    get: { pendingSave != nil },
                    set: { if !$0 { pendingSave = nil; saveFailure = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button(L("server.saveAnyway.confirm")) {
                    if let form = pendingSave { commit(form) }
                    pendingSave = nil
                    saveFailure = nil
                }
                Button(L("common.cancel"), role: .cancel) {
                    pendingSave = nil
                    saveFailure = nil
                }
            } message: {
                Text(saveFailure ?? "")
            }
            .task { load() }
        }
    }

    // MARK: 行为

    private func load() {
        guard let server else { return }
        // 凭据不回显：只留空让用户重新输入（留空 = 不改）
        draft = .editing(server)
    }

    /// 把表单合并成一台服务器（**不落盘**）。
    ///
    /// 新增时的标识按「种类 + 名字」派生；编辑时**沿用原标识**——
    /// 改类型不该改标识，否则服务器上已有的下载与书架记录会认不出来。
    private func resolved(_ form: ServerFormDraft) -> HostedServer {
        let identifier = server?.id ?? HostedServer.makeID(
            kind: form.kind,
            name: form.name,
            existing: Set(environment.hostedServers.map(\.id))
        )
        return form.merged(into: server, assigningID: identifier)
    }

    private func runTest() async {
        let target = resolved(draft)
        guard HostedServer.isValidBaseURL(target.baseURL) else {
            errorMessage = L("server.invalidAddress")
            return
        }
        isTesting = true
        testResult = nil
        // 探活的对象是**当前填的内容**（未保存也能测）
        let outcome = await environment.probeHostedServer(target)
        isTesting = false
        switch outcome {
        case let .success(text): testResult = text
        case let .failure(error): testResult = error.message
        }
    }

    /// 保存：先探活，连不上就问一句「仍然保存？」。
    ///
    /// 先探活是为了把「地址少了端口 / 少了子路径」这类最常见的错误挡在保存之前——
    /// 保存后才发现的话，用户已经在浏览页点了一圈、看到一堆失败。
    /// 但**不强制**：内网服务器、临时维护中的服务器都得允许先存下来。
    private func save() async {
        let target = resolved(draft)
        guard ServerFormValidator.canSave(name: target.name, baseURL: target.baseURL) else {
            errorMessage = target.name.isEmpty ? L("server.error.missingName") : L("server.invalidAddress")
            return
        }
        isSaving = true
        let outcome = await environment.probeHostedServer(target)
        isSaving = false
        switch outcome {
        case .success:
            commit(draft)
        case let .failure(error):
            saveFailure = error.message
            pendingSave = draft
        }
    }

    private func commit(_ form: ServerFormDraft) {
        do {
            try onSave(form)
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
