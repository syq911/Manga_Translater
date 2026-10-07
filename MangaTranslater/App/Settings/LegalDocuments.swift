//
//  LegalDocuments.swift
//  MangaTranslater
//
//  隐私政策 / 使用条款 / 开源许可的**设备端副本**。
//
//  为什么要在 App 里内置一份法务文本：
//  本 App 是侧载分发的，不能假设用户此刻能上网；而「隐私政策」恰恰是用户在
//  决定要不要登录云服务时最需要当场看到的文件。把用户推到官网再回来看，
//  既别扭，也容易在离线时看不到。
//
//  三份载体的关系（刻意做成单向同步）：
//
//      docs/legal/*.md            ← 唯一事实来源（正式文本，也是官网的来源）
//            │  tools/check_legal_sync.py --emit
//            ▼
//      LegalText（本文件）         ← App 内可读副本
//            │  tools/build_website.py
//            ▼
//      官网 privacy / terms 页面
//
//  改文案请改 Markdown，然后重跑 `--emit`；`tools/check_legal_sync.py` 会在
//  推送前拦下任何分叉——法务文本上的「文档过时」等于对用户误导，
//  所以这条链路必须由工具保证，不能靠自觉。
//
//  正文两种语言各一份，**不跟随 App 内的翻译设置**：那个设置是给漫画用的，
//  法务文本应当跟随系统语言。
//

import Foundation

/// 三份法务文档。
enum LegalDocumentKind: String, Identifiable, CaseIterable {
    case privacy
    case terms
    case licenses

    var id: String { rawValue }

    /// 标题走 App 的字符串表（用户可见文案一律不硬编码）。
    var title: String {
        switch self {
        case .privacy: return L("settings.about.privacy")
        case .terms: return L("settings.about.terms")
        case .licenses: return L("settings.about.license")
        }
    }

    /// 官网上的对应路径（`legal.siteBaseURL` + 本值）。
    var websitePath: String {
        switch self {
        case .privacy: return "/privacy"
        case .terms: return "/terms"
        case .licenses: return "/licenses"
        }
    }

    /// 按系统语言挑正文（只区分「中文 / 非中文」两种）。
    var body: String {
        Self.prefersChinese ? chineseBody : englishBody
    }

    static var prefersChinese: Bool {
        (Locale.preferredLanguages.first ?? "en").hasPrefix("zh")
    }

    private var chineseBody: String {
        switch self {
        case .privacy: return LegalText.privacyChinese
        case .terms: return LegalText.termsChinese
        case .licenses: return LegalText.licensesChinese
        }
    }

    private var englishBody: String {
        switch self {
        case .privacy: return LegalText.privacyEnglish
        case .terms: return LegalText.termsEnglish
        case .licenses: return LegalText.licensesEnglish
        }
    }
}

/// 法务文本本体。**不要手改**：由 `tools/check_legal_sync.py --emit` 生成。
enum LegalText {
    // legal-documents:begin
    static let privacyEnglish = """
    # MangaTranslater Privacy Policy

    Last updated: 2026-10-07 · Applies to MangaTranslater for iOS 1.0.0 and later

    MangaTranslater (the "App") is a comic reader for iOS. It **ships with no online
    content**: what you read comes either from local files you import yourself, from
    third-party source repositories you add yourself, or from your own Komga / Kavita
    server.

    This policy states, in plain language, **what stays on your device, what leaves it,
    and for how long we keep anything**.

    ## 1. The short version

    - OCR (text recognition) runs **entirely on your device**. Images **never** leave
      your phone.
    - Only the **recognized text** is sent for translation — text only: no images, no
      comic titles, no comic URLs, no reading history.
    - The hosted service's request body has exactly three fields: `lines` (the text),
      `source`, and `target`. This is enforced by the server's database schema, which
      has no column that could hold an image, a URL, or any source text.
    - Keys and sign-in tokens live in the system keychain, excluded from iCloud backup.
    - We ship no analytics SDK, no advertising SDK, and no crash-reporting SDK.

    ## 2. Data that stays on your device

    | Data | Where | Why | iCloud backup |
    |---|---|---|---|
    | Reading settings (direction, font scale, languages) | Local preferences | Remember your choices | Yes (system default) |
    | Library, categories, reading progress | Local database | Your library and "where you left off" | Yes (system default) |
    | Imported files and downloaded chapters | App sandbox | Offline reading | No (excluded by the app) |
    | Translation cache (finished page images) | App sandbox | Never translate — or spend quota on — the same chapter twice | No |
    | Your own translation API key | System keychain | Call your own translation service | No |
    | Source sign-in cookies | App sandbox | Access sources you have signed in to | No |
    | Cloud sign-in token | System keychain | Passwordless access to the hosted service | No |
    | Diagnostics log | App sandbox documents | Troubleshooting; one-tap clear in Settings → About | Only if you export it via the Files app |

    The diagnostics log records technical events only (request hostnames, status codes,
    durations, error kinds). **It does not record source text, translations, image data,
    or cookie values**; API keys and tokens are redacted before anything is written.
    You can inspect its size, clear it, or pull it out through the Files app at any time.

    ## 3. Data that leaves your device

    Only three things ever leave the device, and none of them is covert:

    **1. Addresses you ask the App to visit.** Third-party source repositories you add,
    the sites their scripts request, and your own Komga / Kavita server all receive
    requests from the App — exactly as if you opened them in a browser. Those requests
    carry your IP address and request content. **What their operators see and do with it
    is up to them and outside our control.**

    **2. Text sent for translation.** Once you turn on page translation:

    | Backend | What leaves the device | Where it goes |
    |---|---|---|
    | Your own API key | Recognized text + your API key | The endpoint you configured (any OpenAI-compatible service) |
    | Hosted cloud service | Recognized text | Our server, which forwards it to an upstream model service |
    | On-device translation | Nothing (the system framework runs locally; downloading a language pack the first time may use the network) | — |

    **3. Hosted-service account data**, and only if you sign in:

    - your **email address** (used to send sign-in codes and restore subscriptions);
    - an account identifier, a **per-day count of translated pages**, and your
      **subscription expiry**;
    - a payment reference produced by the payment processor (Lemon Squeezy) —
      **we never handle your card number**.

    The server database has **five tables**: accounts, verification codes, quota
    counters, entitlements, and webhook deduplication. **No column in any of them can
    hold source text, translations, images, or comic URLs.** Even a full database dump
    would not reveal what anybody is reading.

    We do not use this data for advertising or profiling, and we do not sell it.

    ## 4. Third-party processors

    | Service | When it is used | What it can see |
    |---|---|---|
    | The translation service you choose (own-key mode) | When you translate | Recognized text and your own account details |
    | Our upstream model provider (cloud mode) | When you translate via the cloud | Recognized text (no images, no comic URLs) |
    | Email delivery service | When you request a sign-in code | Your email address and that one message |
    | Lemon Squeezy (merchant of record) | When you buy a subscription on the website | Your payment details and email (**we never see card numbers**) |
    | Cloudflare (hosting) | While the cloud service runs | Request metadata (time, route, status code) |
    | Apple (on-device translation, system frameworks) | When you use on-device translation or system OCR | Governed by Apple's own privacy policy |

    The App integrates **no payment SDK** and shows no checkout: all payments happen on
    the website.

    ## 5. Retention

    | Data | Retention |
    |---|---|
    | Cloud account and entitlement records | Until you delete your account (section 6) |
    | Daily quota counters | Stored per calendar day; deleted with the account |
    | Sign-in codes | 10 minutes |
    | Server request logs | Kept by the hosting platform, normally no longer than 7 days; no source text or translations |
    | On-device translation cache | Until you clear it in Settings, or delete the app |

    ## 6. Your controls (including account deletion)

    - **Delete your account**: Settings → Account & Cloud → Delete account (you will be
      asked to type your email again to confirm). We delete the account along with its
      quota counters and entitlement records **within 30 days**. Transaction records
      related to your purchase are retained by the merchant of record as required by law.
    - **Sign out**: clears this device only; your account and subscription remain. Sign
      in again with the same email to restore them.
    - **Clear the translation cache, diagnostics log, or downloads**: one tap each in
      Settings.
    - **Export the diagnostics log**: via the Files app — read it before you share it.

    ## 7. Minors

    The App is not directed at minors. Adult-content sources are **hidden by default**
    and can only be enabled after explicitly confirming "I am 18 or older". The App
    bundles, recommends, and hosts no content site, and will not fetch content for you.

    ## 8. Security

    - Credentials and tokens prefer the system keychain, falling back to local storage
      when the keychain is unavailable (with a redacted log entry).
    - The hosted service is HTTPS-only; expired JWTs make the client fall back to the
      signed-out state.
    - Keys and tokens in request payloads are redacted before logging.
    - That said, no system is "absolutely secure". This is open-source software
      distributed by sideloading; please judge the trustworthiness of the sources and
      repositories you add.

    ## 9. Changes

    Changes will be recorded in the repository changelog and on the website, and the
    date at the top of this document will be updated. Material changes to data handling
    will also be surfaced inside the App.

    ## 10. Contact

    Privacy questions and data-deletion requests: **privacy@mangatranslater.com**.
    (Replace with your real address before going live — see `docs/going-live.md`.)
    """

    static let privacyChinese = """
    # MangaTranslater 隐私政策

    最后更新：2026-10-07 ｜ 适用于 MangaTranslater for iOS 1.0.0 及之后版本

    MangaTranslater（下称「本 App」）是一个 iOS 漫画阅读器。它**不自带任何在线内容**：
    你阅读的内容要么来自你自己导入的本地文件，要么来自你自己填写的第三方源仓库，
    要么来自你自己的 Komga / Kavita 服务器。

    这份政策用大白话说明：**什么留在你的设备上、什么会离开你的设备、我们保留多久**。

    ## 1. 一份最短的摘要

    - OCR（文字识别）**完全在设备上完成**，图片**不会**离开你的手机。
    - 只有**识别出来的文字**会发给翻译服务，且只发文字：不含图片，不含作品名称，
      不含作品地址，不含你的阅读记录。
    - 云翻译服务的请求体只有三个字段：`lines`（文字）、`source`（原文语言）、
      `target`（译文语言）。这一点由服务端的数据库结构保证——它没有任何一列
      能装下图片、地址或原文。
    - 密钥、云服务登录令牌存在系统钥匙串里，不进 iCloud 备份。
    - 我们不使用任何第三方统计 SDK、广告 SDK 或崩溃上报 SDK。

    ## 2. 留在你设备上的数据

    | 数据 | 位置 | 用途 | 会不会进 iCloud 备份 |
    |---|---|---|---|
    | 阅读设置（方向、字号、语言等） | 本机偏好存储 | 记住你的选择 | 是（系统默认行为） |
    | 书架、分类、阅读进度 | 本机数据库 | 书架与「读到哪儿」 | 是（系统默认行为） |
    | 导入的本地漫画、下载的章节 | App 沙盒目录 | 离线阅读 | 否（App 主动排除） |
    | 译文缓存（译好的整页图） | App 沙盒目录 | 同一话重看时不重复翻译、不重复扣额度 | 否 |
    | 自备翻译 API Key | 系统钥匙串 | 调用你自己的翻译服务 | 否 |
    | 源登录凭据（Cookie） | App 沙盒目录 | 访问你已登录的源 | 否 |
    | 云服务登录令牌 | 系统钥匙串 | 免密访问云服务 | 否 |
    | 诊断日志 | App 沙盒文档目录 | 排查问题（可在「设置 → 关于」一键清空） | 是（仅当你在「文件」App 中导出时） |

    诊断日志只记录技术事件（请求地址的主机名、状态码、耗时、错误类型）。
    **它不记录原文、译文、图片内容或 Cookie 值**；云服务的密钥与令牌在写入前会被脱敏。
    你可以在「设置 → 关于」里查看体积、随时清空，或通过「文件」App 取出后自行检查。

    ## 3. 会离开你设备的数据

    只有下面三种情况会有数据离开设备，且都不是「我们偷偷收集」：

    **一、你让本 App 去访问的地址。** 你添加的第三方源仓库、源脚本访问的站点、
    你自己的 Komga / Kavita 服务器，都会收到本 App 发出的请求——
    就像你自己用浏览器访问它们一样。这些请求包含你的 IP 地址与请求内容，
    **它们的运营者能看到什么、怎么处理，由他们决定，不由我们控制**。

    **二、翻译时发送的文字。** 你开启页内翻译后：

    | 翻译后端 | 离开设备的东西 | 去向 |
    |---|---|---|
    | 自备密钥 | 识别出的文字 + 你的 API Key | 你填的那个接口地址（任何 OpenAI 兼容服务） |
    | 云翻译服务 | 识别出的文字 | 我们的服务端，再由它转发给上游模型服务 |
    | 设备端翻译 | 无（由系统框架在本机完成；首次使用某语言对时可能联网下载语言包） | — |

    **三、云翻译服务的账号数据。** 只有当你主动登录时才会有：

    - 你的**邮箱地址**（用于发送登录验证码、找回订阅）；
    - 一个账号标识、每天的**已用页数计数**、订阅的**到期时间**；
    - 支付凭证编号（由收款方 Lemon Squeezy 产生，我们不经手你的卡号）。

    服务端的数据库**只有五张表**：账号、验证码、额度计数、订阅权益、支付回调去重。
    其中**没有任何一列能装下原文、译文、图片或作品地址**。
    换句话说：即使数据库被完整拿到，也无法还原任何人在看什么。

    我们不把上述数据用于广告、画像或再销售；也不与第三方共享，除了下面第 4 条列出的处理方。

    ## 4. 我们使用的第三方服务

    | 服务 | 什么时候用到 | 它能看到什么 |
    |---|---|---|
    | 你选择的翻译服务（自备密钥时） | 你用它翻译时 | 识别出的文字与你自己的账号信息 |
    | 我们托管的上游模型服务（云服务时） | 你用云翻译时 | 识别出的文字（不带图片、不带作品地址） |
    | 邮件发送服务 | 你请求登录验证码时 | 你的邮箱地址与那封验证码邮件 |
    | Lemon Squeezy（收款方） | 你在官网购买订阅时 | 你的支付信息与邮箱（**我们不经手卡号**） |
    | Cloudflare（服务端托管） | 云服务运行时 | 请求元数据（时间、路由、状态码） |
    | Apple（设备端翻译、系统框架） | 你使用设备端翻译或系统 OCR 时 | 由 Apple 的隐私政策约束 |

    App 内**不接入任何支付 SDK**，也没有收银台：付款全部在官网页面上完成。

    ## 5. 保留期

    | 数据 | 保留期 |
    |---|---|
    | 云服务账号与订阅记录 | 直到你注销账号（见第 6 条） |
    | 每日额度计数 | 按自然日分行保存；注销账号时一并删除 |
    | 登录验证码 | 10 分钟（过期即失效） |
    | 服务端请求日志 | 由托管平台保留，通常不超过 7 天；不含原文与译文 |
    | 设备上的译文缓存 | 直到你在设置里清空，或删除 App |

    ## 6. 你的控制权（注销账号）

    - **注销账号**：在「设置 → 账号与云服务 → 注销账号」按提示操作（需要再次输入你的邮箱确认）。
      我们会在 **30 天内**删除账号及其额度计数、订阅权益记录。与你订阅相关的交易凭证，
      收款方会按其法定要求另行保留。
    - **退出登录**：只清掉本机的登录状态，账号与订阅保留；用同一个邮箱重新登录即可「恢复订阅」。
    - **清空译文缓存 / 诊断日志 / 下载内容**：都在「设置」里，一键完成。
    - **导出诊断日志**：在「文件」App 里自行取出，先看再决定要不要发给维护者。

    ## 7. 未成年人

    本 App 不面向未成年人。涉及成人内容的源**默认隐藏**，开启前必须明确确认
    「我已年满 18 周岁」。本 App 不内置、不推荐、不收录任何内容站点，
    也不会替你去获取任何内容。

    ## 8. 安全

    - 凭据与令牌优先存系统钥匙串，钥匙串不可用时回退到本机存储（并记录一条脱敏日志）。
    - 服务端只提供 HTTPS 接口；JWT 过期后客户端自动退回未登录状态。
    - 请求体里的密钥、令牌在写入日志前会被脱敏。
    - 但请理解：没有任何系统能承诺「绝对安全」。本 App 是侧载分发的开源软件，
      请自行评估你所添加的源与仓库是否可信。

    ## 9. 政策变更

    政策变更会写进仓库的更新日志与官网页面，并更新本文顶部日期。
    涉及数据处理的实质性变更，会在 App 内以提示的方式告知。

    ## 10. 联系方式

    隐私相关问题与数据删除请求：**privacy@mangatranslater.com**。
    （上线前请替换为你的真实邮箱；见 `docs/going-live.md`。）
    """

    static let termsEnglish = """
    # MangaTranslater Terms of Use

    Last updated: 2026-10-07 · Applies to MangaTranslater for iOS 1.0.0 and later

    ## 1. Acceptance

    By downloading, installing, or using MangaTranslater (the "App") you accept these
    terms. If you do not accept them, please do not use the App.

    ## 2. What the App is

    The App is a **general-purpose comic reader**:

    - it **bundles, recommends, and hosts no content site**;
    - it ships no source scripts; sources come from third-party repository URLs that
      **you** add;
    - its built-in server support (Komga / Kavita) connects to **your own** server;
    - its page translation is a tool: recognize the text on a page, translate it, and
      typeset it back onto the image.

    The App is not affiliated with, endorsed by, or connected to any content site, and
    is not responsible for their conduct.

    ## 3. Your responsibilities

    1. You judge for yourself whether the repositories, scripts, and content you access
       are lawful and trustworthy.
    2. Use source scripts only for content you are entitled to access, and comply with
       the laws of your jurisdiction and the terms of the services involved.
    3. Signing in through the App (including signing in on a web page and handing the
       resulting credentials back to that source) is for **your own accounts** only.
    4. You must not use the App to infringe the rights of others, circumvent technical
       protection measures, or break the law.
    5. You are responsible for the copyright status and legality of files you import and
       content you download.

    ## 4. We do not distribute content

    The App does not host, upload, cache, or mirror any third-party content. When you
    browse online, image data is requested by your device directly from addresses you
    configured; we neither proxy nor retain it. This repository contains no copyrighted
    content.

    ## 5. Hosted translation service (optional)

    The hosted translation service is an **optional** paid service, independent of the
    open-source app:

    1. **Account**: sign in with an email address and a one-time code. There is no password.
    2. **Free quota**: each account gets a number of free pages per calendar day
       (currently 10 pages/day, resetting on each UTC+8 calendar day). The amount may
       change; changes will be communicated in the App and on the website.
    3. **Subscription**: payments are handled by the merchant of record (Lemon Squeezy)
       and **take place entirely on the website**. The App integrates no payment SDK and
       shows no checkout.
    4. **Renewal and cancellation**: handled by the merchant of record. After cancelling,
       access continues until the end of the paid period.
    5. **Fair use**: a subscription is a personal licence. Reselling quota, sharing
       accounts, automated bulk extraction, and attempts to bypass quotas by reverse
       engineering are prohibited and may result in suspension or termination.
    6. **Translation quality**: machine translation makes mistakes. Treat the output as
       reference material, not as professional, legal, or medical advice.
    7. **Availability**: the cloud service is provided on a best-effort basis and may
       experience outages, rate limits, and upstream failures. You can always switch to
       your own API key or on-device translation.

    ## 6. Adult content (18+ clause)

    1. The App is intended for adults. If you are under 18 (or under the age of majority
       where you live), please do not use the App.
    2. Sources that may contain adult content are **hidden by default**; enabling them
       requires explicitly confirming "I am 18 or older".
    3. Whether you may lawfully view such content depends on **your local law**. Verifying
       that and accepting the consequences is your responsibility.
    4. We do not provide, recommend, or review any such content.

    ## 7. Disclaimer of warranty

    The App is provided "as is", without warranty of any kind, express or implied,
    including but not limited to merchantability, fitness for a particular purpose, and
    non-infringement. We do not warrant that source scripts or third-party sites will
    work, that translations will be accurate, that the cloud service will be
    uninterrupted, or that downloads will be complete.

    ## 8. Limitation of liability

    To the maximum extent permitted by law, the maintainers are not liable for any
    indirect, incidental, special, punitive, or consequential damages, nor for disputes
    arising from your use of the App or of third-party sources. Our total liability
    relating to the hosted service is limited to the amount you actually paid for it in
    the preceding 12 months.

    ## 9. Open-source licence

    The App's source code is released under the **Apache License 2.0** (see `LICENSE`
    and `NOTICE` in the repository) and includes work derived from upstream open-source
    projects. Where the open-source licence grants you rights that conflict with these
    terms, the licence prevails; these terms govern **distribution and use of the hosted
    service**.

    ## 10. Changes and termination

    Changes will be recorded in the repository changelog and on the website, and the date
    at the top of this document will be updated. If you breach these terms we may
    terminate your access to the hosted service; the open-source licence is unaffected.

    ## 11. Contact

    **support@mangatranslater.com** (replace with your real address before going live —
    see `docs/going-live.md`).
    """

    static let termsChinese = """
    # MangaTranslater 使用条款

    最后更新：2026-10-07 ｜ 适用于 MangaTranslater for iOS 1.0.0 及之后版本

    ## 1. 接受条款

    下载、安装或使用 MangaTranslater（下称「本 App」）即表示你接受本条款。
    若不接受，请不要使用本 App。

    ## 2. 本 App 是什么

    本 App 是一个**通用漫画阅读器**：

    - 它**不自带、不推荐、不收录任何在线内容站点**；
    - 它不自带任何源脚本，源由你自行添加第三方仓库 URL 来获得；
    - 它内置的「自建服务器」支持（Komga / Kavita）连接的是**你自己的服务器**；
    - 它内置的页内翻译是一个工具：识别页面文字、翻译、再排版回页面。

    本 App 与任何内容站点都没有隶属、合作或背书关系，也不为其行为负责。

    ## 3. 你的责任

    1. 你添加的源仓库、源脚本、以及你浏览的内容，**由你自行判断是否合法、是否可信**。
    2. 你只能把源脚本用于你有权访问的内容；请遵守你所在地区的法律与相关服务条款。
    3. 你在本 App 内的登录操作（包括在网页里登录后再把登录凭据交回该源），
       仅应用于**你自己的账号**。
    4. 你不得使用本 App 从事侵犯他人权利、绕过技术保护措施或违反法律的活动。
    5. 导入的本地文件、下载保存的内容，其版权与合法性由你负责。

    ## 4. 我们不分发内容

    本 App 不托管、不上传、不缓存、不转存任何第三方内容。
    在线浏览时，图片数据由你的设备直接向你自己配置的地址请求，
    我们不经过、也不留存这些数据。仓库中不包含任何受版权保护的内容。

    ## 5. 云翻译服务（可选）

    云翻译服务是**可选**的付费服务，与本 App 的开源部分相互独立：

    1. **账号**：用邮箱 + 一次性验证码注册/登录，没有密码。
    2. **免费额度**：每个账号每个自然日有一定页数的免费额度（当前为 10 页/天，
       按北京时间自然日重置）。额度数量可能调整，调整会在 App 内与官网说明。
    3. **订阅**：付费渠道由收款方（Lemon Squeezy）提供，**付款全程在官网页面上完成**，
       App 内不接入任何支付 SDK、不出现收银台。
    4. **续费与取消**：由收款方按其流程处理。取消后，权益保留到当期结束。
    5. **公平使用**：订阅为个人使用授权。禁止转售额度、共享账号、自动化批量刷取、
       或通过逆向手段绕过额度。出现这类行为时，我们可暂停或终止该账号的服务。
    6. **翻译质量**：机器翻译会出错。译文仅供参考，不应作为专业、法律或医疗用途的依据。
    7. **可用性**：云服务为尽力而为（best-effort）提供，可能存在中断、限流与上游故障。
       上游服务商不可用时，你可以随时改用自备密钥或设备端翻译。

    ## 6. 成人内容（18+ 条款）

    1. 本 App 面向成年人。如果你未满 18 周岁（或你所在地区的成年年龄），请不要使用本 App。
    2. 可能包含成人内容的源**默认隐藏**；开启前必须明确确认「我已年满 18 周岁」。
    3. 你是否可以合法查看此类内容，取决于**你所在地区的法律**，由你自己确认并承担后果。
    4. 我们不提供、不推荐、不审核任何此类内容。

    ## 7. 免责声明

    本 App 按「现状」提供，不附带任何明示或默示的担保，包括但不限于适销性、
    特定用途适用性与不侵权担保。我们不担保：源脚本可用、第三方站点可用、
    翻译准确、云服务不中断、下载内容完整。

    ## 8. 责任限制

    在适用法律允许的最大范围内，维护者不对任何间接、附带、特殊、惩罚性或
    后果性损害负责；也不对因你使用本 App 或第三方源而产生的任何纠纷负责。
    云服务相关责任的总上限为你在过去 12 个月内为云服务实际支付的金额。

    ## 9. 开源许可

    本 App 的源代码以 **Apache License 2.0** 发布（见仓库 `LICENSE` 与 `NOTICE`），
    其中包含派生自上游开源项目的工作。开源许可授予你的权利优先于本条款中与之冲突的部分；
    本条款约束的是**分发与云服务的使用**。

    ## 10. 条款变更与终止

    条款变更会写进仓库更新日志与官网页面，并更新本文顶部日期。
    若你违反本条款，我们可以终止你使用云服务的权利（开源部分的许可不受影响）。

    ## 11. 联系方式

    **support@mangatranslater.com**（上线前请替换为你的真实邮箱；见 `docs/going-live.md`）。
    """

    static let licensesEnglish = """
    # Open-source licences and third-party notices

    The App's source code is released under the **Apache License 2.0**.

    ## 1. The App's licence

    ```
    MangaTranslater
    Copyright 2026 MangaTranslater contributors

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

        http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.
    ```

    ## 2. Derivative work (Apache 2.0 section 4(b))

    This product includes work derived from the upstream project below, modified for
    use in this project:

    ```
    This product includes software developed at
    EhViewer-Apple (https://github.com/felixchaos/EhViewer-Apple),
    licensed under the Apache License, Version 2.0.
    ```

    Files that were ported and modified carry a notice in their header comment. The
    modifications include, among others: generalizing the data model to arbitrary
    sources, changing the translation cache key from a site-specific item ID to
    "source + title URL + page index", and making the translation backend pluggable.

    ## 3. Third-party components distributed with the app

    | Component | Licence | Purpose |
    |---|---|---|
    | GRDB.swift | MIT | Local database for the library and reading progress |
    | SwiftSoup | MIT | HTML parsing for source scripts (the `html` bridge) |

    Each component is governed by its own licence. The full list, with links, is kept in
    `NOTICE` and `docs/architecture.md`.

    ## 4. System frameworks

    The App uses Apple system frameworks (Vision, Translation, WebKit, AVFoundation and
    others) supplied by iOS, governed by Apple's licences and privacy policy.

    ## 5. We do not distribute content

    Neither this repository nor the App contains any copyrighted third-party content,
    and no source scripts are included. Source scripts are provided by third-party
    repositories under licences declared by their own authors.
    """

    static let licensesChinese = """
    # 开源许可与第三方声明

    本 App 的源代码以 **Apache License 2.0** 发布。

    ## 1. 本 App 的许可

    ```
    MangaTranslater
    Copyright 2026 MangaTranslater contributors

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

        http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.
    ```

    ## 2. 派生说明（Apache 2.0 第 4(b) 条）

    本产品包含派生自下述上游项目的工作，并已为适用于本项目而作出修改：

    ```
    This product includes software developed at
    EhViewer-Apple (https://github.com/felixchaos/EhViewer-Apple),
    licensed under the Apache License, Version 2.0.
    ```

    被搬运并修改的文件在其文件头注明了来源与修改。修改内容包括但不限于：
    面向通用来源的数据模型泛化、缓存键从作品 ID 改为「来源 + 作品地址 + 页号」、
    翻译后端从单一服务改为可插拔等。

    ## 3. 随 App 分发的第三方组件

    | 组件 | 许可 | 用途 |
    |---|---|---|
    | GRDB.swift | MIT | 书架与阅读进度的本地数据库 |
    | SwiftSoup | MIT | 源脚本的 HTML 解析（`html` 桥） |

    各组件分别适用其自身许可。完整清单与其原文链接见仓库 `NOTICE` 与
    `docs/architecture.md`。

    ## 4. 系统框架

    本 App 使用 Apple 系统框架（Vision、Translation、WebKit、AVFoundation 等），
    它们由 iOS 提供，适用 Apple 的许可与隐私政策。

    ## 5. 我们不分发内容

    本仓库与本 App 均不包含任何受版权保护的第三方内容，也不包含任何源脚本。
    源脚本由第三方仓库提供，其作者与许可由其自行声明。
    """
}
