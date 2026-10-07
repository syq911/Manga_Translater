//
//  ServerFormValidator.swift
//  SourceEngine
//
//  「添加 / 编辑服务器」表单的校验规则。
//
//  抽出来的原因：校验原本散在视图里（保存时的地址检查、按钮的 disabled 条件、
//  「空输入表示不改」的凭据语义），而**视图不能单测**。抽到这里之后，
//  「什么情况下能保存、什么情况下报什么错」可以被穷举。
//
//  规则本身属于「服务器」这个领域，所以放在 SourceEngine（`HostedServer` 所在包），
//  而不是 AppCore——这样它复用同一个 `HostedServer.isValidBaseURL`，
//  不会出现「界面按 A 规则放行、存储层按 B 规则拒绝」的分叉。
//
//  注意一条**刻意不在校验里**的规则：连接可用性（能不能连上）不是「能不能保存」的
//  前提。内网服务器、临时维护中的服务器都必须允许先存下来——探活失败只提示，
//  由用户决定要不要继续（见 `ServerEditView`）。
//

import Foundation

/// 表单上的一处问题（界面负责映射成文案）。
public enum ServerFormIssue: Equatable, Sendable {
    case missingName
    case invalidAddress
}

public enum ServerFormValidator {

    /// 校验顺序固定（先名字后地址），界面据此只显示第一条——顺序稳定，测试也才钉得住。
    public static func issues(name: String, baseURL: String) -> [ServerFormIssue] {
        var issues: [ServerFormIssue] = []
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.missingName)
        }
        if !HostedServer.isValidBaseURL(baseURL) {
            issues.append(.invalidAddress)
        }
        return issues
    }

    /// 能否保存（= 没有任何问题）。
    public static func canSave(name: String, baseURL: String) -> Bool {
        issues(name: name, baseURL: baseURL).isEmpty
    }
}

/// 编辑表单里的原始输入。
///
/// 存在的意义是把两条**容易被静默改坏**的语义从视图里搬出来：
///
/// 1. **空 = 不改**（API Key / 密码）：凭据不回显，于是「留空」必须是
///    「保持原值」而不是「清空」。用户在编辑界面只是改了个地址，
///    不该顺手把密钥抹掉——那种 bug 只有下次连服务器时才会暴露。
/// 2. **空 = 清空**（用户名）：用户名是明文可见的，空就是空。
///
/// 两条规则相反，所以更要写在一处、写明，而不是散在视图的赋值语句里。
public struct ServerFormDraft: Equatable, Sendable {

    public var kind: HostedServerKind
    public var name: String
    public var baseURL: String
    /// 留空 = 不改。
    public var apiKey: String
    /// 留空 = 清空。
    public var username: String
    /// 留空 = 不改。
    public var password: String

    public init(
        kind: HostedServerKind = .komga,
        name: String = "",
        baseURL: String = "",
        apiKey: String = "",
        username: String = "",
        password: String = ""
    ) {
        self.kind = kind
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.username = username
        self.password = password
    }

    /// 用已有服务器的内容填充表单（**凭据不回显**，因此留空）。
    public static func editing(_ server: HostedServer) -> ServerFormDraft {
        ServerFormDraft(
            kind: server.kind,
            name: server.name,
            baseURL: server.normalizedBaseURL,
            apiKey: "",
            username: server.username ?? "",
            password: ""
        )
    }

    /// 校验当前输入。
    public func issues() -> [ServerFormIssue] {
        ServerFormValidator.issues(name: name, baseURL: baseURL)
    }

    /// 归一化后的 API Key（空 = 未填）。
    ///
    /// 新增路径用它：`hasCredentials` 会 trim，但把 `"  "` 存进去终究是脏数据。
    public var normalizedAPIKey: String? { trimmedOrNil(apiKey) }

    /// 归一化后的用户名（空 = 未填）。
    public var normalizedUsername: String? { trimmedOrNil(username) }

    /// 归一化后的密码（空 = 未填）。密码**不 trim**：首尾空格可能是密码的一部分。
    public var normalizedPassword: String? { password.isEmpty ? nil : password }

    private func trimmedOrNil(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 合并成「准备落盘」的服务器。
    ///
    /// - Parameters:
    ///   - existing: 编辑时的原服务器；新增传 `nil`。
    ///   - id: 要用的标识（新增时由调用方按 `HostedServer.makeID` 派生，
    ///     编辑时沿用原值——**改类型不该改标识**，否则服务器上已有的下载会认不出来）。
    public func merged(into existing: HostedServer?, assigningID id: String) -> HostedServer {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = HostedServer(
            id: existing?.id ?? id,
            kind: kind,
            name: trimmedName,
            baseURL: HostedServer.normalizeBaseURL(baseURL),
            apiKey: existing?.apiKey,
            username: existing?.username,
            password: existing?.password,
            addedAt: existing?.addedAt ?? Date()
        )
        result.kind = kind
        result.name = trimmedName

        // 空 = 不改
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty { result.apiKey = trimmedKey }
        if !password.isEmpty { result.password = password }

        // 空 = 清空
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        result.username = trimmedUsername.isEmpty ? nil : trimmedUsername

        return result
    }
}
