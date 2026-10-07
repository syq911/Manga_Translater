//
//  CloudAccountView.swift
//  MangaTranslater
//
//  云服务页：账号状态、额度、登录 / 注册、升级入口、恢复订阅。
//
//  合规要点（勿改，《开发手册》7.4）：
//  - 「升级 Pro」= **打开官网购买页**（外部浏览器）。App 内不出现收银台、
//    不接任何支付 SDK——收款全在官网完成（资金流切割）。
//  - 「恢复订阅」不是另一套凭据通道，就是**用同一个邮箱再登录一次**：
//    账号与权益都挂在邮箱上。
//  - 未登录时也能看这一页：入口要能解释清楚「云服务是什么、怎么买」，
//    而不是把人挡在登录外面。
//

import SwiftUI
import AppCore

struct CloudAccountView: View {

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openURL) private var openURL

    @State private var email = ""
    @State private var code = ""
    /// 注销账号的二次确认（要用户把邮箱再打一遍）。
    @State private var isConfirmingDeletion = false
    @State private var deletionEmail = ""

    private var model: CloudAccountModel { environment.cloud }
    private var settings: AppSettings { environment.settings }

    var body: some View {
        Form {
            statusSection
            if model.isSignedIn {
                accountSection
                upgradeSection
                deletionSection
            } else {
                loginSection
                upgradeSection
            }
            aboutSection
        }
        .navigationTitle(L("cloud.title"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.refresh() }
        .alert(L("cloud.delete.confirm.title"), isPresented: $isConfirmingDeletion) {
            TextField(L("cloud.delete.confirm.placeholder"), text: $deletionEmail)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button(L("common.cancel"), role: .cancel) { deletionEmail = "" }
            Button(L("cloud.delete.confirm.action"), role: .destructive) {
                let typed = deletionEmail
                deletionEmail = ""
                Task { _ = await model.deleteAccount(email: typed) }
            }
        } message: {
            Text(L("cloud.delete.confirm.message"))
        }
        .alert(L("common.notice"), isPresented: Binding(
            get: { model.notice != nil },
            set: { if !$0 { model.clearNotice() } }
        )) {
            Button(L("common.ok"), role: .cancel) { model.clearNotice() }
        } message: {
            Text(model.notice ?? "")
        }
    }

    // MARK: 状态

    private var statusSection: some View {
        Section {
            HStack {
                Text(L("cloud.account.plan"))
                Spacer()
                Text(model.planName)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text(L("cloud.account.quota"))
                Spacer()
                Text(model.quotaSummary)
                    // 显式写 `Color.`：`.orange` 与 `.secondary` 分属两种 ShapeStyle
                    // （前者是 Color，后者是 HierarchicalShapeStyle），
                    // 用隐式成员写法放在三元里会因类型不一致而编译失败。
                    .foregroundStyle(model.account?.isQuotaExhausted == true ? Color.orange : Color.secondary)
            }

            if let expires = model.entitlementDescription {
                HStack {
                    Text(L("cloud.account.expires"))
                    Spacer()
                    Text(expires).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(L("cloud.section.status"))
        } footer: {
            Text(String(format: L("cloud.quota.resetFooter"), model.resetDescription))
        }
    }

    // MARK: 已登录

    private var accountSection: some View {
        Section {
            if model.isSignedIn {
                HStack {
                    Text(L("cloud.account.email"))
                    Spacer()
                    Text(model.maskedEmail).foregroundStyle(.secondary)
                }
            }

            Button(L("cloud.account.refresh")) {
                Task { await model.refresh() }
            }
            .disabled(model.isBusy)

            Button(L("cloud.account.signOut"), role: .destructive) {
                model.signOut()
            }
        } header: {
            Text(L("cloud.section.account"))
        } footer: {
            Text(L("cloud.account.footer"))
        }
    }

    // MARK: 未登录

    private var loginSection: some View {
        Section {
            if model.isAwaitingCode {
                TextField(L("cloud.login.code"), text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                Button(L("cloud.login.verify")) {
                    Task {
                        let ok = await model.verifyCode(code)
                        if ok { code = "" }
                    }
                }
                .disabled(model.isBusy || code.trimmingCharacters(in: .whitespaces).isEmpty)
                Button(L("cloud.login.cancel")) { model.cancelVerification() }
            } else {
                TextField(L("cloud.login.email"), text: $email)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.emailAddress)
                Button(L("cloud.login.sendCode")) {
                    Task { _ = await model.sendCode(email: email) }
                }
                .disabled(model.isBusy || email.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text(L("cloud.login.title"))
        } footer: {
            Text(model.isAwaitingCode ? L("cloud.login.codeFooter") : L("cloud.login.footer"))
        }
    }

    // MARK: 注销账号

    /// 注销与「退出登录」放在相邻两处，但文案必须把差别说清楚：
    /// 一个是清本机、一个是删服务端，混起来会让用户误删。
    private var deletionSection: some View {
        Section {
            Button(L("cloud.delete.action"), role: .destructive) {
                deletionEmail = ""
                isConfirmingDeletion = true
            }
            .disabled(model.isBusy)
        } header: {
            Text(L("cloud.section.delete"))
        } footer: {
            Text(L("cloud.delete.footer"))
        }
    }

    // MARK: 升级 / 恢复

    private var upgradeSection: some View {
        Section {
            Button(L("cloud.upgrade")) { openUpgradePage() }
        } header: {
            Text(L("cloud.section.upgrade"))
        } footer: {
            Text(L("cloud.upgradeFooter"))
        }
    }

    private func openUpgradePage() {
        guard let url = model.purchaseURL else { return }
        openURL(url)
    }

    // MARK: 关于

    private var aboutSection: some View {
        Section {
            Text(L("cloud.privacyNote"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text(L("cloud.section.about"))
        } footer: {
            Text(L("cloud.footer"))
        }
    }
}
