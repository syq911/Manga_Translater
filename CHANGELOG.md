# 更新日志 / Changelog

本项目遵循 [语义化版本](https://semver.org/lang/zh-CN/) 规范。
This project adheres to [Semantic Versioning](https://semver.org/).

版本阶段说明：
- `0.x` —— 开发期，源 API 契约尚未冻结（Source API contract not frozen）。
- `1.0.0` —— 源 API 契约 v1 冻结 + 云端翻译服务上线。

---

## [Unreleased]

### 计划中 / Planned

- ~~M1 地基：泛化数据模型（Manga / Chapter / Page）、GRDB 书架、本地文件源、阅读器~~ ✅ 已完成
- ~~M2 源引擎：JavaScriptCore 单文件 JS 源、仓库管理（添加 / 安装 / 更新 / NSFW 开关）~~ ✅ 已完成（契约 v1 冻结）
- ~~M3 补全：批量下载 + 后台续传 + CBZ 导出、Komga / Kavita、WebView 登录 + Cookie 收割、Cloudflare 兜底~~ ✅ 已完成
- M4 翻译与云服务：页内翻译接入、BYOK、邮箱验证码账号、额度、Lemon Squeezy 订阅
- M5 发布：中英双语文案、隐私政策、AltStore 源上线

### 🔧 修复 / Fixed（M4 期间）

- **云客户端不该建在 `HTTPClient` 之上**：后者的语义是「非 2xx 就抛 `NetworkError`」，
  而它的错误里**不带响应体**；API 客户端必须同时拿到状态码与错误体才能分类
  （401 → 退回未登录、402 + `quota_exceeded` → 给升级入口）。
  实测后果是所有业务错误被压成 `transport("服务器返回 401")`，
  `mapFailure` 成了死代码、12 条错误分类断言全红。
  改为直接用可注入的 `HTTPTransporting` 发请求。`HTTPClient` 是给抓站用的
  （Cookie 注入、按源限流、正文上限），API 客户端用不上。
- **真机 Vision 用例必须串行**：现代 `RecognizeTextRequest` 并行超过 2 个会死锁，
  而 Swift Testing 默认并行；3 个真机 OCR 用例同跑会把测试进程卡死到 job 超时。
  给该套件加 `.serialized`，并在 `docs/testing.md` 固化这条约定。
- 顺带修掉两个只在编译期暴露的问题：转义闭包里的隐式 `self`（类里必须写 `self.`）、
  三元表达式里两个隐式成员分属不同 `ShapeStyle`（`.orange` vs `.secondary`）。
- 「译文条数必须与输入一致」的校验统一到翻译层：各层只抛自己那一层的错误类型，
  避免界面文案分裂。
- 测试 job 的 30 分钟上限放宽到 50 分钟（测试目标文件数随里程碑增长）。

---

## [Unreleased] · M4 翻译与云服务

### ✨ 新增 / Added

**页内翻译全链（M4 第一批）**

- **数据模型**：`MangaTextLine` / `MangaTranslatedLine` / `TranslationStage` / `PageTranslation`，
  缓存键 `PageTranslationKey` 为 **来源 + 作品地址 + 页号**（旧工程是 `(gid, page)`，
  本项目没有 gid）。主键含 `/` 与 `:`，目录名统一经 `FileNameSanitizer` 安全化。
- **OCR**：`VisionTextRecognizer` 同时跑现代（`RecognizeTextRequest`，自动语言检测）与
  传统（`VNRecognizeTextRequest`，指定语言 + 系统语言）两套 API，按 IoU 0.4 合并去重，
  保留置信度更高 / 更长的一条；竖排判定把归一化盒子换算成像素纵横比再比较，
  页面非正方时不会误判。漏行兜底（横向压扁重试）可关。
- **排版**：`MangaTypesetter` 盖框底色取文字框**外圈**平均色（避开框内文字像素），
  文字颜色按底色亮度自动选黑/白；横排自动换行并逐级缩字号，
  竖排逐字竖排、必要时分列、从右往左；可选择额外标注一行小号原文。
- **后端**：`MangaTranslator` 协议 + `DeepSeekTranslator`（BYOK，任意 OpenAI 兼容端点）。
  新增**分块**（一页几十行可能顶到上下文上限，按 40 条切块再按原顺序拼接）与
  **可重试错误的退避重试**（408/429/5xx；4xx 不重试——重试只会把同一个错误再撞一遍）。
- **端上翻译**：`AppleTranslationBridge`（iOS 18 `Translation` 框架），
  由视图侧 `.translationTask` 消费会话。
- **译文缓存**：`TranslationStore` 内存 LRU + 磁盘（按作品一个目录、页号作文件名），
  写盘先写临时文件再原子替换；支持清空、按作品清理、损坏文件当作未命中。
- **凭据存储**：`SecureValueStore`（Keychain 优先，失败回退本机存储；
  侧载 / ad-hoc 签名下 Keychain 可能因缺 entitlement 而写入失败，功能不该因此不可用）。

**翻译接入阅读器（M4 第二批）**

- `TranslationController`：顶部按钮点一下开启连续翻译（当前页 + 前后 N 页并行），
  再点一下显示原文；翻页自动补队列并**丢弃已翻过去的页**（不把额度花在不会看的页上）；
  进度浮层显示「翻译中…剩余 N 页」；失败是可点掉的横幅；
  **额度不足不打断阅读**——单独走 `quotaMessage`，界面给「升级云服务」入口。
- 并行度是硬约束而非调优：现代 Vision 超过 2 个并行会死锁，端上翻译一次只支持一个会话，
  因此上限分别是 2 / 1。
- 新增设置「翻译预取页数」（默认前后各 2 页）：看图免费、翻译按页计费，
  默认值刻意远小于读图的预加载窗口（默认 10）。
- 设置页新增独立「翻译」子页：后端 / 语言 / 识别 / 自备密钥 / 排版 / 译文缓存占用与清理。
- 设置项新增（含快照向后兼容解码）：`translationUsesSampledBackground`、
  `translationShowsOriginalText`、`translationPrefetchWindow`、`cloudServiceBaseURL`、
  `cloudUpgradeURL`；`TranslationLanguage` 新增 `promptName` 与 `targetChoices`
  （`auto` 只能作原文语言）。

**云服务客户端（M4 第三批）**

- 契约 `docs/cloud-api.md` v1 冻结：`POST /auth/email/send`、`POST /auth/email/verify`、
  `GET /me`、`POST /translate`、`POST /webhooks/lemonsqueezy`；统一错误信封，
  以及「**只有文本过境**」的铁律——`/translate` 请求体只有
  `lines` / `source` / `target`，客户端用显式 CodingKeys 写死，并由测试断言。
- `CloudServiceClient`：邮箱验证码登录、账号与额度查询、翻译代理；错误按语义分类
  （401 未登录、402 额度用尽、429 限流、坏 JSON、5xx），传输层可注入因此全部离线可测。
- `CloudSessionStore`：会话（令牌 + 到期时刻 + 账号快照）整体序列化后存钥匙串，
  损坏自动清除；协议化以便测试注入内存实现（不碰真实钥匙串）。
- `CloudAccountModel`：状态机（发码 → 验证 → 登录 → 刷新 / 退出）。
  **401 视为「会话过期」并自动退回未登录**，而不是让之后每次请求都失败一次；
  邮箱脱敏展示；「恢复订阅」就是用同一邮箱再登录一次，不另开凭据通道。
- `QuotaPolicy`：免费额度按 **UTC+8 自然日**重置的纯计算（只用于展示，不参与记账），
  与服务端 `src/quota.js` 用同一组时间戳交叉断言。
- `CloudTranslationService`：`MangaTranslator` 的云端实现，与 BYOK 共用分块与提示词；
  每次翻译回传「今天还剩几页」，界面额度实时更新而无需再发 `/me`。

**云服务界面与充值入口（M4 第四批）**

- `CloudAccountView`：状态（档位 / 额度 / 订阅有效期）、登录注册（邮箱 + 验证码）、
  刷新、退出、「升级 Pro」= **打开官网购买页**（外部浏览器，带 `custom[user_id]`
  便于服务端把订阅绑到账号）。App 内不出现收银台、不接任何支付 SDK。
- 三处入口到位：设置 → 账号与云服务、设置 → 翻译 → 云服务、阅读器额度用尽横幅。

**服务端与闭环自测（M4 第五批，仓库外）**

- 服务端实现放在公开仓库**之外**的 `MangaTranslater-Cloud/`（《开发手册》7.1 要求
  独立私有仓库）：Cloudflare Workers + D1 —— 邮箱验证码、HS256 JWT、额度记账、
  DeepSeek 代理、Lemon Squeezy webhook（HMAC 验签 + 事件去重）。
- `schema.sql` 只有五张表，**没有任何一列能装下原文 / 译文 / 图片 / 作品 URL**：
  「只有文本过境」由表结构保证，并由测试断言钉死。
- 闭环自测 20 条（`npm test`，用 `node:sqlite` 跑**真实 schema**）：
  注册 → 额度 → 翻译扣额度 → 用尽被拒 → 下单 webhook → 权益升 Pro →
  不再受每日限制 → 取消到期回落免费 → 跨自然日重置；外加验证码重放/过期、
  发码限流、坏令牌、webhook 验签失败与重投幂等、上游条数不符（不扣额度）等失败路径。

### 🧪 测试 / Tests

- `TranslationCoreTests`：竖排判定（含页面纵横比修正）、竖排布局（含退化输入）、
  坐标映射、合并去重（含置信度/长度择优）、译文 JSON 解析（纯 JSON / 代码块 / 夹带散文 /
  非字符串元素 / 条数不符 / 无数组）、分块顺序、请求头与**用户提示词必须是纯 JSON 数组**、
  4xx 不重试、5xx 重试、分块跨请求顺序不变、排版尺寸不变；
  以及**真实 Vision** 的三条：金标准夹具比对（行数 ≥3、字符召回 ≥0.60）、
  合成密集页 ≥5/6 句召回、竖排方向判定。
- `TranslationStoreTests`：键安全化与去重、内存往返、LRU 淘汰后磁盘仍可命中、
  跨实例磁盘持久化、损坏 PNG 视为未命中、缺清单仍能用、清空/按作品清理、覆盖写。
- `TranslationControllerTests`：开关语义、展示原图/译文、预取窗口边界（含 0）、
  翻页补队列、未开启时不翻译、缓存命中不重复花额度、磁盘缓存跨会话复用、
  条数不符与识别不到文字的失败横幅、**额度用尽走升级提示而非失败横幅**、
  未登录云服务的提示、退出重置、按作品清理缓存。
- `CloudClientTests`：请求路径/方法/鉴权头、**`/translate` 请求体恰好只有三个字段**
  且不含任何 URL 字样、错误语义映射（401/402/429/坏 JSON/5xx）、
  邮箱规范化与校验、额度重置时刻（东八区自然日，含 UTC 日界不同的用例）、
  剩余比例钳制与三态摘要。
- `CloudAccountTests`：未登录/已登录开局、发码与校验的成功与失败、
  验证码为空不发请求、刷新更新额度、**401 自动退回未登录并清会话**、
  退出登录、额度回传按上限钳制、购买链接带账号 ID、
  云端后端的错误映射与分块顺序、网络失败映射。

### 🛠 工具 / Tooling

- `tools/make_ocr_fixture.py`：生成金标准 OCR 夹具（**中性内容**的合成页 + 基准文本）。
  真实页图会把第三方作品内容带进公开仓库；合成页同样覆盖「位图 → Vision → 文本行」，
  而且因为「先知道印了什么」，基准文本比人工抄写更权威。
- `check_api_usage`：修 `split_top_level` 的深度问题——默认值闭包里的裸 `>`
  （如 `guard interval > 0`）被当成泛型闭合，深度变负后闭包与其后**所有**参数之间的
  逗号都不再被识别，参数被静默吞掉并报出「未声明的参数标签」这种假错误。
- `check_imports`：补登记 `ComicDownload` 的 `FileNameSanitizer` / `DownloadArchiveStore` /
  `DownloadedChapter` / `JobAwarePageFetching`——漏登记导致
  「用了 `FileNameSanitizer` 却没 import」一路烧到 CI 才被编译器发现。
- `check_swift_syntax` 新增**主 actor 静态成员**规则：在非 `@MainActor` 上下文里调用
  `@MainActor` 类型的静态成员会报
  "call to main actor-isolated static method … in a synchronous nonisolated context"，
  而这类错误**只有测试目标会报**，不挡就要为它单独等一轮 CI。
  规则刻意收窄（只查测试文件、跳过含 `@MainActor` 的文件、排除已标 `nonisolated` 的成员），
  因为 SwiftUI 的 `body` / `#Preview` 本身就是主 actor 上下文但文件里没有 `@MainActor` 字面量——
  照字面判会把合法调用全报成错。已按「改坏 → 确认拦下 → 改回」双向验证。


---

## [0.1.0] - 2026-10-05

> 工程基座：可编译、可测试、CI 全绿的空壳，按《开发手册》M0 里程碑交付。

### ✨ 新增 / Added

- **工程基座**：`MangaTranslater.xcodeproj`（Xcode 16 同步文件夹机制，iOS 18.0 起步），
  App 目标 + 单元测试目标，共享 scheme。
- **四个 SwiftPM 本地包**：
  - `AppCore` —— 泛化数据模型、应用设置、错误类型、诊断日志
  - `ComicNet` —— HTTP 客户端、按源隔离的 CookieJar、请求节流器
  - `SourceEngine` —— 源脚本校验、源仓库索引解析、源仓库管理、JS 桥接口定义
  - `ComicDownload` —— 下载队列状态机、下载任务模型、CBZ 打包
- **App 外壳**：四 Tab 信息架构（书架 / 浏览 / 下载 / 设置），空状态引导文案，
  中英双语字符串表。
- **CI**：`.github/workflows/build-ipa.yml` —— 无签名 archive → ad-hoc 签名 → 打包 IPA 上传
  产物；独立 `test` job 在模拟器上跑 Swift Testing；`v*` tag 触发 Release 并生成
  AltStore `source.json`。
- **文档**：`docs/architecture.md`、`docs/development.md`、`docs/source-api.md`、`docs/testing.md`。
- **合规**：`LICENSE`（Apache-2.0）、`NOTICE`（上游归属声明）、README 中性话术。

### 🔧 修复 / Fixed（M1 收尾）

- **`deleteCategory` 只改了投影列、没改 payload**（测试抓到）：条目的唯一事实来源是
  payload，只把 `category_id` 置空会导致「删除分类后，读出的条目仍带着该分类」。
  现在在同一事务内读出 payload、改掉分类、连同列一起写回。
  并把该约定固化为预检规则（含 `UPDATE 条目表` 的语句必须写 `payload`，已反向验证）。


- `ZoomStateTests` 里 `CGSize(width: .nan, ...)` 报 "ambiguous use of 'nan'"：
  同时 import Foundation 与 CoreGraphics 时 `CGFloat.nan` 有两处定义。
  改为显式 `CGFloat.nan`，并把「几何构造函数里裸写 `.nan` / `.infinity`」
  加进预检（已反向验证）。


- `CoverThumbnailCache` 多解了一层 Optional：Swift 5 起 `try?` 会**折叠**嵌套
  Optional，故 `try? load()`（load 返回 `Data?`）的类型是 `Data?` 而非 `Data??`，
  写 `guard let a = try?, let a` 会报「initializer for conditional binding must
  have Optional type, not 'Data'」。已改为只解一层。
- `AppEnvironment.addToLibrary` 丢弃 `try?` 的包装结果（消除
  "result of 'try?' is unused" 警告）。


- `LocalBooksView` 一处编辑把换行吃掉，导致两条语句挤在同一行
  （编译报 `Consecutive statements on a line must be separated by ';'`）。
  已修复，并把「值 + 4 空格以上 + 语句关键字」这一漏换行特征加进预检
  （已反向验证：人为还原该行即被拦下）。


- **`AppCore` 缺 `import CoreGraphics`**：`CGSize`/`CGFloat` 经 Foundation 可见，
  但 `.zero` 与 `Equatable` 一致性定义在 CoreGraphics 模块里，导致
  「type 'CGSize' has no member 'zero'」与「ZoomState 不符合 Equatable」编译失败。
  已加 import，并把该盲区固化为预检规则（见下）。


- 本地文件列表在每个 cell 渲染时同步解析 ZIP 取章节数，文件多时会明显卡顿；
  改为在 `reload()` 时**一次算好**（并放到后台任务）。
- 阅读器原来没有恢复「上次读到的页码」（只恢复了章节），进入时总从第 1 页开始；
  现在按保存的页码恢复，越界由页数钳制收敛。

### 🔧 修复 / Fixed（M1 第二段）

- **自然排序在超长数字上失效**：原实现把数字段截断到 1e9 防溢出，导致 30 位以上
  数字无法区分。改为「去前导零 → 比长度 → 比字典序」，任意长度精确且无溢出。
- **导入幂等应按内容而非文件名**：同一份归档用不同文件名导入会产生多份副本。
  改为按**内容指纹**查重（侧车 meta 记录指纹），并把「查重 + 落盘 + 写侧车」
  串行化，避免并发导入同内容各写一份。
- 上述串行化引入过一处**自锁死**（临界区内调用了同样加该锁的 `store(reader:)`），
  已拆成独立的导入锁并加注释说明原因。


- `ReaderSessionTests` 里 22 处 `#expect(session.moveToPage(...))` 编译失败：
  **`#expect` 的参数会被宏包进闭包，闭包捕获的变量不可变**，故不能在其中调用
  `mutating` 方法。改为「先调用取返回值，再断言」，并把该规则固化进预检
  （收集仓库内 `mutating func` 名字，命中 `#expect(... xxx.method(...) ...)` 即报错）。


- `LibraryView` 缺少 `import AppDatabase`（`LibrarySortOrder` 不在作用域）——
  根因是**导入检查器的包类型表里没有 AppDatabase**，已补齐并通过反向验证。
- `ReaderView.loadCurrentChapter` 在 `guard let` 的不可变绑定上调用 mutating 方法，
  改为 var 副本、钳制后写回 `@State`。
- 导入检查器新增 `@testable import` 语义：该模块下的 internal 成员应视为可见
  （此前会把测试里的 internal 用法误报为错误），已双向验证。
- 清理误入库的生成脚本中间产物 `LocalSourceFixtures.txt`，并在 `.gitignore` 忽略。
- `IntegrationTests` 里 `AppEnvironment(...)` 仍是旧签名（改 init 后忘改调用方），
  编译失败。为此新增预检 `tools/check_api_usage.py`：比对 `Type(...)` 调用与 init 声明，
  缺少**无默认值**参数即报错（已双向验证：临时改回旧签名会被拦下）。
  实现过程中修掉两个自身缺陷：空行会重置类型上下文、闭包默认值漏判。


- `BrowseView` 缺少 `import SourceEngine`，导致 App 与测试两个 target 编译失败。
- `HTTPClient.parseRetryAfter` 由 internal 提升为 public（跨模块测试与自定义重试策略需要）。
- `AppSettings.fontScale` 默认值取成了范围下限 0.5，应为 1.0；并把各默认值收敛为具名常量。
- **`DownloadQueue` 重构**：原实现用 `Task {}`（继承 actor 隔离）驱动状态机，
  CI 上实测出现任务永久停在 `.running`、`waitUntilIdle` 超时、页数据未落盘的问题。
  改为显式驱动 `processPending()` + `Task.detached` 的 `start()`，
  取消改为协作式（页边界生效），并把测试改为确定性推进。

### ✨ 新增 / Added（M1 第一段）

- **`Packages/AppDatabase`（新包，GRDB/SQLite）**：书架持久层
  - `LibraryStoring` 协议 + `DatabaseLibraryStore` 实现：条目 upsert/读取/移除、
    三种排序（最近阅读/标题/最近加入，置顶恒优先、未读最后）、分类筛选与列举、
    置顶、未读数（负数归零）、删除条目连带清理历史
  - 阅读进度：`updateProgress` 原子更新条目 + 写历史（同章节覆盖，不新增）
  - 阅读历史：倒序查询、按作品查询、删单条、清空、`pruneHistory(keep:)`
  - 迁移：`Migrations.initial`（v1 schema + 5 个索引），打开时自动执行，可查询已应用迁移
  - 设计：**查询列 + JSON payload**（payload 是唯一事实来源，加字段无需迁移）
  - GRDB 作为**本地包的远程依赖**引入（`from: 7.11.0`），工程文件仍只登记本地包
- **CBZ 读能力（ComicDownload）**：`ZipArchiveReader` 新增 **deflate（方法 8）解压**
  - 用系统 `Compression` 框架（`COMPRESSION_ZLIB` = 裸 DEFLATE），零第三方依赖
  - 正确区分「压缩后大小」（切片）与「解压后大小」（校验），CRC 校验在解压后数据上
  - `ZipEntryInfo` 新增 `compressedSize` / `compressionMethod` / `isCompressed`
  - 为什么必须做：真实世界的 CBZ 绝大多数是 deflate 压缩，只支持 store 等于读不了别人的文件

### ✨ 新增 / Added（M1 第二段：本地 CBZ 可读、进度可存）

- **本地文件源（`SourceEngine/LocalSource` + `LocalArchiveIndexer`）**
  - 导入 CBZ/ZIP：复制进沙盒、指纹幂等、原子写、失败清理
  - 分章规则：多目录各一章 / 单目录单章 / 根目录存图则整体一章；过滤 macOS 与系统噪音
  - 自然排序保证阅读顺序（`1.jpg < 2.jpg < 10.jpg`）
  - 路径穿越防护；归档小容量缓存（导入后立刻可读、翻页不重复读盘）
  - `books()` 以文件系统为事实来源，重启后仍能列出本地作品
- **阅读器内核（`AppCore/ReaderSession`）**：翻页/翻章/预加载窗口的纯逻辑，
  返回值明确区分「移动」「需要换章」「到头了」，杜绝 off-by-one
- **页数据来源抽象（`AppCore/PageDataProviding`）**：本地源同步解压、在线源走 HTTP，
  阅读器零分支
- **内存版书架（`AppDatabase/InMemoryLibraryStore`）**：数据库不可用时降级（App 不崩、
  仅不持久化并明确提示），同时作为协议测试的第二实现
- **App 接线**：书架页（导入 / 排序 / 删除 / 进度显示 / 持久化降级提示）、阅读器页
  （翻页、预加载、进度写回）、本地文件页（浏览 / 导入 / 直接阅读）

### ✨ 新增 / Added（M1 收尾：封面、阅读外观与手势）

- **书架封面**：`LocalSource.coverData(for:)` 取首页原始字节（纯 Foundation、可单测），
  `CoverThumbnailCache` 负责等比缩放与内存 + 磁盘缓存（文件名由作品 ID 哈希派生）。
  书架与本地文件列表均显示封面；设置页可一键清空缓存。
- **阅读器外观设置**（`AppSettings`）：阅读背景主题（跟随系统/浅色/米黄/深色/纯黑）、
  页面留白（0–60 pt）、阅读时屏幕常亮。
- **阅读器手势**：双击缩放、捏合缩放、放大后拖动平移；
  未放大时横滑翻页，方向随阅读模式变化（右到左模式下左滑为上一页）。
- **`AppCore.ZoomState`**：缩放/平移的纯逻辑（档位、捏合基准、平移边界钳制）。
- **设置快照向后兼容**：`SettingsSnapshot` 改为 `decodeIfPresent + 默认值` 解码，
  旧版本导出的备份（缺新字段）仍可恢复。

### ✨ 新增 / Added（M1 收尾：分类管理）

- **分类升级为独立实体**（`AppCore.LibraryCategory` + 迁移 `v2_categories`）：
  可以创建**空分类**、重命名、排序；迁移把旧的分类名直接当 id 回填，
  既有条目引用无需改写，对用户无感。
- `LibraryStoring` 新增 `categories()` / `createCategory` / `renameCategory` /
  `deleteCategory`（条目移出但不删除，返回受影响数）/ `reorderCategories`。
- `save` 与 `setCategory` 遇到未登记的分类 id 自动补建，避免孤立引用。
- **书架分类筛选**：工具栏可选「全部作品」或某个分类；分类被删除后自动回退到全部。
- **分类管理页**（`CategoryManagerView`）：新建 / 重命名 / 删除 / 拖动排序，
  并显示每个分类的作品数。
- **条目长按菜单**：移动到分类、置顶、移出书架。

### ✨ 新增 / Added（M2 第一批：JavaScriptCore 源运行时）

- **`JSSourceRuntime`**（`SourceRuntimeExecuting` 的 M2 实现）：
  - 每个源一个 `JSVirtualMachine`，沙箱互不可见；`load` 即替换沙箱
  - 装载前二次静态校验（体积 / 禁用 API / 必需方法 / id 一致性）
  - **自建 Promise 桥**支持脚本里的 `async/await`：把 async 调用包成 Promise，
    再挂 `then`/`catch` 取结果（该 SDK 没有 `callAsyncJavaScript`，
    这条路也让我们完全掌握结算点、错误信息与取消）
  - 调用超时用「detached 工作 + 独立计时器 + 一次性结果盒」竞速：
    超时后调用方**立即**返回，不等待 JS 侧结束（任务组必须等所有子任务，
    实测出现过单次调用拖到 28 秒并连累同套件其他用例）
- **四个桥接 API**（JS 侧只看到普通对象，Swift 侧只传字符串）：
  `net.fetch`（自动带该源 Cookie + 节流 + 体积上限）、`cookies.get/set`、
  `prefs.get/set`（键按来源隔离）、`log.info/warn/error`（截断、不落内容）
- **`SourceTransporting`** 抽象 + `DefaultSourceTransport` 实现：
  按源持有 `HTTPClient` 与 `RateLimiter`（慢源不会拖住快源）；
  只允许 http/https，`http` 仅限本机；请求方法与体积在此收口
- **`SourcePreferencesStoring`**：`UserDefaults` 版与内存版

### ✨ 新增 / Added（M2 第二批：HTML 选择器引擎）

- **HTML 解析器**（零依赖）：标签 / 属性（双引号、单引号、无引号、布尔）/
  嵌套与自动闭合 / 不匹配结束标签忽略 / void 标签 / 注释与 DOCTYPE 跳过 /
  script·style 原文 / 实体解码 / 空白折叠 / `outerHTML` 序列化
- **CSS 选择器**：类型、`#id`、`.class`、属性（存在 / 相等 / 前缀 / 后缀 / 包含）、
  通配 `*`、后代与直接子代组合子、多级链；结果按文档顺序去重；
  非法选择器给出明确错误（空 / 悬空组合子 / 不完整属性）
- **文本与 URL 工具**：实体解码（命名 + 数字）、空白折叠、转义、
  `absolute`（四种相对地址）、`queryValue` / `settingQuery` / `host` / 反斜杠还原
- 选择器支持在**元素子树内**继续查询（源提取列表项的常见写法）

### ✨ 新增 / Added（M2 第三批：`html` 桥接）

- **`html.parse(body)` → 文档对象**，`doc.select(sel)` / `doc.selectFirst(sel)` /
  `doc.dispose()`；元素与集合共用 `text()` / `attr(name)` / `html()` /
  `select(sel)` / `selectFirst(sel)`，集合是**真数组**（可 `map`）且支持 `.length`
- **句柄表** `HTMLHandleStore`：JS 只持有整数句柄，解析结果留在宿主侧；
  线程安全、容量上限 16（超出淘汰最旧）、`load`/`teardown` 时清空
- **选择器非法不致命**：返回错误对象，JS 侧记日志并给出空集合
- `html()` 按需序列化（避免每次查询都序列化整棵子树）
- 与 `docs/source-api.md` 的契约示例逐字对应，避免文档与实现分叉

### ✨ 新增 / Added（M2 第四批：响应解码 + 类型化门面）

- **`SourceResponseDecoder`**（`Packages/SourceEngine`）：契约返回值 → 宿主模型的
  **纯解码层**，不依赖 JavaScriptCore，可以脱离 JS 单测。容错策略集中于此：
  - 地址：相对地址按「页面地址 → 来源 `baseUrl`」依次补全；协议相对 `//host/path`
    借用基地址协议；非 http(s)（`javascript:` / `data:` / `blob:`）一律拒绝；
    作品/章节地址允许保留**来源自定义标识**（如 `series:123`），图片地址不允许
  - 弱类型字段：`status` 容错映射（`FINISHED`→`completed`、认不出→`unknown`）、
    `genres` 接受单字符串或数组、`chapterNumber` 接受数字与数字字符串、
    日期支持 ISO8601（含/不含毫秒）/`yyyy-MM-dd`/秒·毫秒时间戳
  - 条目容错：缺 `url` 的条目**跳过而不是整次失败**，被丢弃的条数经
    `SourceDecodeOutcome.skippedItems` 回传给上层写诊断日志
- **`SourceRunner`**：actor 门面，把「调用脚本 + 解码」合成一次可读调用
  （`popularManga` / `latestUpdates` / `search` / `mangaDetails` / `chapterList` /
  `pageList` / `filters`），并承担三类降级与收口：
  - 参数按契约以**独立 JSON 片段**编码（页码是数字字面量、查询串只编码一层、
    筛选是对象），不再让 `JSONSerialization` 把参数多包一层引号
  - 可选方法缺失时降级：`getLatestUpdates` 回退热门列表、`getFilters` 返回空数组
  - 错误语义统一：运行时的 `SourceRunnerError` 原样传播，外来错误包装为
    `executionFailed`，`CancellationError` 映射为 `cancelled`
- **`AppCore.SourceFilter`**：契约 §5.2 的筛选项模型（`text`/`checkbox`/`select`/`sort`），
  含 `defaultValue`、`defaultValues()` 与 `sanitize(_:)`（源升级删掉筛选项后，
  把用户上次留下的旧键裁剪掉再发请求）

### 🔧 修复 / Fixed（M2 第四批：补齐契约 §7 里未落地的桥接）

- **`net.get(url, headers?)` / `net.post(url, body, headers?)`**：契约 §7 冻结、
  §12 的示例源也在用，但此前只实现了 `net.fetch`。**任何照文档写的源都会在
  运行期抛 `net.get is not a function`**——由端到端用例抓到并补上。
- **`json.parse` / `json.stringify`**：按契约名字显式对齐（原生 `JSON` 一直在，
  但源作者照文档写就会踩空）。
- **`source.getPreference(key, fallback)`**：`source` 是脚本自己声明的对象，
  宿主在桥接阶段拿不到（桥接早于脚本求值，且顶层 `const` 挂在全局词法环境、
  不是 `globalThis` 属性）。改为**脚本求值之后**用另一段脚本在同一词法环境里补齐，
  并对「对象被冻结 / 没声明 source」做了兜底：补齐失败只写日志，不影响载入。

### 📖 文档 / Docs（M2 第四批）

- `docs/source-api.md` §7 的桥接能力由 🚧 更新为 ✅ 已实现，并补上 §5.4 的
  `lastUpdated` 可选字段与「条目被跳过时的行为」说明。
- `docs/architecture.md` 新增 §3.14（响应解码）与 §3.15（类型化门面），
  并修正依赖表：HTML 解析为**零依赖自研**，不再计划引入 SwiftSoup。

### 🧪 测试 / Tests（新增 4 个套件 / 58 个用例）

- `SourceResponseDecoderTests`（24 例）：地址补全与 scheme 拒绝、自定义标识、
  裸数组/`null` 顶层、字段缺失与类型不符的容错、日期与状态映射、
  筛选项去重与候选项校验、丢弃计数在 `map` 后仍保留
- `SourceRunnerTests`（17 例）：参数编码（含「只编码一层」与空筛选 `{}`）、
  未载入报错、载入失败传播、`teardown` 后可重载、可选方法降级、
  丢弃项写日志、外来错误被包装
- `SourceEndToEndTests`（10 例）：用真实 `JSSourceRuntime` 跑
  **`docs/source-api.md` 的 canonical 示例源**（与文档逐字一致），
  断言五个必需方法与 `getFilters` 全部跑通、地址与模型字段正确——
  这份用例的存在意味着「文档里的示例确实可运行」
- `JSSourceBridgeTests`（7 例）：`net.get`/`net.post`/`json.parse`/`source.getPreference`
  逐个钉住，含请求描述解码与「source 被冻结仍能载入」

### ✨ 新增 / Added（M2 第五批：仓库服务 + 运行时池）

- **`SourceRepositoryService`**（actor）：把索引解析与落盘用网络串起来
  - `catalog(for:)`：拉 `index.json` → 解析 → **合并本地安装状态**
    （`installedVersion` / `hasUpdate` / `isInstallable`）
  - `install(_:)` / `install(key:from:)`：下载脚本 → UTF-8 校验 →
    **key 一致性校验** → 静态校验 → 原子落盘（复用 `SourceStore` 的回滚）
  - `catalogs()`：刷新全部仓库，**单个仓库失败只影响该条**（返回逐条结果与原因）
  - `availableUpdates()`：所有仓库里可更新的源
- **`SourceIndexParser.indexURL` / `directoryURL`**：仓库地址规范化。
  用户填 `.../repo/`、`.../repo`、`.../repo/index.json` 三种形式都能用；
  修正了旧实现「取最后一个 `/` 之前」在 `https://example.com`（无路径）下
  拼出 `https:/demo.js` 的问题；保留端口与 IPv6 方括号；带查询串/片段一律拒绝。
- **`SourceVersion`**：版本号解析与比较。缺段补零（`1.2` == `1.2.0`）、
  按数字而非字符串比较（`1.10` > `1.9`）、正式版高于同号预发布版、
  **解析不了就不提示更新**（宁可漏提示，也不让用户反复看到装不上的「新版本」）。
- **`SourceRuntimePool`**（actor）：已安装源的运行时池
  - 同一 key 只载入一次（**single-flight**，并发取用共用一次载入）
  - 超过 `maxLoadedSources`（默认 3）淘汰最久未用；**每次取用计一次租约**，
    有租约的源不参与淘汰，全在使用中时宁可临时超限并写警告日志
  - `runner(for:)`（可能被回收）与 `withRunner(for:_:)`（全程持租约）两种用法
  - `invalidate` / `invalidateAll`：安装、更新、卸载后回收旧沙箱
  - 错误统一为 `SourceRunnerError`：脚本文件缺失 → `notInstalled`，
    静态校验不过 → `scriptRejected`；**缺失必需方法的契约预检放在建运行时之前**
    （沙箱昂贵，脚本不全时没必要先建虚拟机再扔掉）
- **`SourceVisibilityRule`**：成人内容源的可见性规则只实现一处——
  界面一律用过滤后的列表，避免某个页面漏写 `if !source.isNSFW` 导致合规约束失效。
- **应用层接线**（`AppEnvironment`）：新增仓库服务与运行时池，
  提供 `visibleInstalledSources` / `hiddenSourceCount` / `reloadRepositoryCatalogs` /
  `installSource` / `uninstallSource` / `sourceRunner(for:)` 等入口；
  日志统一进诊断日志（每个来源带 key 前缀，便于排查）。

### ✨ 新增 / Added（M2 第六批：浏览界面接真实源）

界面（全程不内置任何源，也不提供仓库清单）：

- **`RepositoryManagerView`**：添加 / 删除仓库、刷新可装源、逐个安装与更新。
  单个仓库读取失败只在该行显示原因；安装按 key 记「进行中」防连点；
  安装成人内容源时提示「已在设置中隐藏」。
- **`SourceBrowseView`**：某个来源的热门 / 搜索 + 翻页（末行出现即预取下一页），
  含加载 / 失败重试 / 空结果三种状态；**搜索在提交时才发请求**。
- **`SourceMangaDetailView`**：作品信息（封面、作者、画师、状态、题材、简介）+
  章节列表 + 加入书架；详情失败整页提示，章节失败只在章节区提示。
- **`BrowseView`** 接入：已安装源列表（读 `visibleInstalledSources`，
  底部提示「另有 N 个成人内容源已隐藏」）+ 「管理源仓库」入口。
- **在线封面**：`CoverThumbnailView` 增加远程分支（走来源 Cookie + Referer），
  取到后仍进同一个缩略图缓存，缓存键与本地来源一致。

引擎：

- **`SourceImageLoader`**：图片字节加载（封面与漫画页共用）。与文本桥接
  刻意分开——返回二进制、上限 20 MB（契约 §5.3）、自动重试一次、
  支持页级请求头（`PageRef.headers` / `Referer`）、自动带来源 Cookie；
  **识别「200 + HTML 错误页」**（只拒绝 `text/*`、`html`、`json`、`xml`，
  不用 `image/*` 白名单，因为很多图床返回 `application/octet-stream`）。

范围说明：**在线阅读尚未接入**（需要阅读器支持异步取图，随下载一起做）。
在线作品在阅读器里给出明确提示，而不是抛「归档损坏」这种让人误解的底层错误。

### ✨ 新增 / Added（M2 第七批：在线阅读接入）

- **`MangaReadingSource`**（`AppCore`）：阅读器唯一的数据入口 =
  `ChapterListProviding` + `PageDataProviding`。阅读器里**不再有任何**
  「本地还是在线」的分支。
- **`LocalReadingSource`**（`SourceEngine`）：把本地文件源的同步接口包成异步，
  内部用 `Task.detached`——大归档解压不该占主线程（本地翻页卡顿的来源）。
- **`RemoteReadingSource`**（`SourceEngine`，actor）：源脚本取章节 / 页列表 +
  `SourceImageLoader` 取图；章节列表与页列表各带 LRU 缓存（默认 8 / 16 条）；
  `invalidate(sourceID:)` 按主键前缀清缓存（安装 / 更新 / 卸载源后由 App 调用）；
  `imageData` 标 `nonisolated`，图片下载不排队经过 actor。
- **阅读器接入两端**：`ReaderView` 改为注入数据来源（`readingSource:` +
  可选 `startChapterID`），加载链路全部异步化；预加载改为并发 + **可取消**
  （换页前取消上一次，避免快速翻页叠起多批下载）；
  来源作品的章节行直接进入阅读器。
- **进度规则收敛**：只有作品在书架里才写进度（`updateProgress` 对不在书架的作品
  会抛 `entryNotFound`，翻一页记一条失败日志毫无意义）。阅读器顶部新增星标，
  一键加入书架并立即记录当前进度。
- 提示文案统一走 `L(…)`（阅读器的提示标题与按钮此前是硬编码中文）。

### ✨ 新增 / Added（M2 收尾：自测仓库 + 契约 v1 冻结）

**M2 验收标准的落地**：「加一个自建的中性测试仓库，能看在线漫画」。

- **`tools/make_demo_repo.py`**：现场生成一个完全中性的静态「漫画站」+ 配套源脚本
  （`index.json`、`demo.js`、8 个页面、5 张 PNG），供本机联调走完
  「添加仓库 → 安装 → 热门/最新/搜索 → 详情 → 章节 → 阅读」。
  - **不写入本仓库**：生成物含 `.js`，会触发合规红线；写到仓库目录内会被**拒绝**
    （须显式 `--allow-in-repo`）。默认输出到系统临时目录。
  - `--check <目录>` 自检（脚本静态规则、索引字段、页面引用资源是否存在），
    把「http.server 少个文件 → 页面 404」这类时间黑洞提前挡住。
  - `--emit-swift <路径>` 把语料写进 CI 夹具，避免手抄。
- **`tools/check_demo_repo.py`**（预检第 8 项）：生成器与
  `MangaTranslaterTests/DemoCorpus.swift` 的 10 个文本块**逐字比对**、
  图片文件名集合比对。已反向验证（改一个词 / 换一个图片名均被拦下）。
- **契约 v1 冻结**（`docs/source-api.md`）：状态由「草案」改为「v1.0 已冻结」，
  写明「冻结意味着什么」与「可做 / 不可做」边界表；
  §8（登录收割）状态由「M2 进行中」修正为「M3 待补」（接口已冻结，实现后补）。
- **浏览页新增「最新更新」**（`getLatestUpdates`）；源未实现时由 `SourceRunner`
  自动回退到热门列表。

### ✨ 新增 / Added（M3 第一批：下载与离线阅读打通）

- **`DownloadArchiveStore`**（`ComicDownload`）：把下载完的一章打包成 CBZ 落盘，
  并支持读回单页、列表、统计、删除。目录布局 `<Downloads>/<作品>/<章节>.cbz` +
  同名 `.json` 清单；文件名是「可读部分 + FNV-1a 稳定哈希」
  （`String.hashValue` 跨进程不稳定，用它命名会导致下次启动找不到自己写的文件）。
  写入先落临时文件再替换：直接覆盖失败会留下**打不开的 CBZ**，
  而它看起来「已下载完成」。
- **`JobAwarePageFetching`**（`ComicDownload`）：让抓取器从任务上读来源信息的接缝。
  Cookie 与防盗链 `Referer` 是来源侧知识，队列不该知道；有了这个协议，
  一个 `SourcePageFetcher` 实例就能服务队列里多个来源的任务。
- **`SourcePageFetcher`**（`SourceEngine`）：`SourceImageLoader` → `PageFetching` 适配。
  按 `DownloadJob` 带来源 Cookie、`Referer`，并按 URL 取页级请求头
  （契约允许每页自带 `headers`，不必退化成整章共用一个头）。
- **`DownloadJob`** 增加 `pageHeaders`（按 URL）与 `referer`；`FilePageStore`
  增加 `pages(jobID:)`（按文件名数字前缀排页序——`contentsOfDirectory` 顺序不保证）。
- **`RemoteReadingSource` 归档优先**：有归档的章节，页列表从归档读（**不问脚本**，
  因为脚本要联网）、页图从归档读（不发请求）。归档页用私有 scheme
  `manga-archive://` 定位，避免伪造 http 地址被漏拦时真的发请求出去。
- **`DownloadCoordinator`**（App 层）：下载的**唯一**入口。负责批量入队（单章取页失败
  不中断整批）、跳过已下载与已在队列的、进度快照、暂停/继续/取消/重试、
  完成后打包归档（在后台线程，避免几十 MB 压缩卡住界面）、归档的增删查。
- **`AppEnvironment`** 接线：`archiveStore`（`Downloads/`）与 `downloads`（编排），
  抓取散图放 `DownloadScratch/`——两个目录分开，归档目录里出现任何东西都意味着
  「这一章能离线看」。

### ✨ 新增 / Added（M3 收尾：后台执行断言）

- **`BackgroundExecutionKeeper`**：下载驱动期间用 `beginBackgroundTask` 申请
  一小段后台时间，用户切走 App 后下载还能多跑一会儿；驱动结束（或系统收回）
  时归还。
  为什么不用 `URLSession` 的后台传输：下载不是「一堆独立 GET」，而是
  「脚本算页列表（JS 沙箱）→ 逐页抓取 → 打包 CBZ」，中间两步交不了给系统进程。
  **必须归还**：不调 `endBackgroundTask` 会被强杀，已抓的页连同散图一起丢。
  文案也不吹：说的是「可以离开这一页」，不是「关掉 App 也会继续」。

### 🧪 测试 / Tests（M3 收尾新增 1 个用例）

- `DownloadCoordinatorTests`：驱动期间后台断言恰好申请一次、归还一次
  （把申请 / 归还应成注入闭包，测试不碰 UIKit）

### 🔧 修复 / Fixed（M3 第四批 · 五轮）

首轮**完整跑完**的 CI（749 用例 / 53 套件，20 秒；编译与打包全绿），
3 条失败全在 `CookieHarvest`，暴露一个真实的计数错误：

- **`CookieJar.set(_:for:)` 返回的是「被拒绝的条数」，不是「写入的条数」**。
  我把它当成了写入条数，于是收割成功也返回 0——界面上会显示
  「没有找到可保存的登录凭据」，用户以为登录没生效（而 Cookie 其实已经存进去了）。
  改成自己算：`stored.count - rejected`。
- 顺带把「宿主存不下的 Cookie」在**过滤阶段**就拒掉（名称含 `;` `=` 换行、
  值含换行）。这样「收下的一定写得进去」，「清空旧凭据再写入」不会白做。
- 另一条失败是**测试期望写错**：我拿 `cdn.example.com` 的 Cookie 去比
  `www.example.com`——两者是**兄弟域**，本来就不该收。改成站在
  `cdn.example.com` 上验三条都收，并另外补一条「兄弟域不收」的用例钉住语义。
- 给 `DownloadCoordinator` 的两处等待加**上界**（`waitUntilSettled` 超时、
  驱动循环「长时间无进展即退出并写日志」）。纯粹是防御：`await task.value`
  一旦停不下来，调用方就永久挂住，而这类问题在 CI 上的表现是「作业超时被强杀」，
  日志里看不到任何线索。

### 🔧 修复 / Fixed（M3 第四批 · 四轮）

- `SourceMangaDetailView` 的 `chapterDownloadActions` 漏了 `.queued` 分支
  （`switch must be exhaustive`）。顺手补上语义：**排队中的章节也要能点掉**
  ——否则用户点了下载，行上写着「已加入下载队列」，却收不回来。
- `environment.downloads.archivedChapterIDs(...)` 是 `RemoteReadingSource` 的方法，
  协调器上没有。给协调器补一个**读快照**的版本（不碰磁盘）：
  章节列表可能上百行，每行去读一次归档清单文件是灾难；
  详情页改成「先 `refreshArchives()` 刷一次快照，再按列表查」。

### 🔧 修复 / Fixed（M3 第四批 · 三轮）

- `SourceLoginView` 两处：
  `HTTPCookie.properties` 是 **Optional**（Swift 侧签名如此），直接传会编译失败
  → `?? [:]`（`HarvestedCookie` 对缺失字段本来就有兜底）；
  `environment.diag(...)` 把 AppCore 的**全局函数**当成了 `AppEnvironment` 的方法
  → 改回 `diag(...)`。
- **新增预检规则「`environment.xxx` 必须是 `AppEnvironment` 的成员」**。
  `environment` 在本项目里只有一种身份（`@Environment(AppEnvironment.self)`），
  所以「名字不在成员表里」必是错的——判定精确、零误报，已反向验证。
- 顺带修 `check_api_usage.strip_comments`：它原先把注释行**删掉**，
  于是报出来的行号比真实行号少几行（报第 209 行、实际在第 248 行）。
  改成把注释行换成空行，行号与文件一致。

### 🔧 修复 / Fixed（M3 第四批 · 二轮）

- `cookieJar.persist()` 漏写 `try`（它是 throwing）——两处：
  `AppEnvironment.clearSourceCookies` 与 `SourceLoginView` 的收割收尾。
  两处都用 `try?`：写盘失败不致命（内存里的容器已经对了，最坏是重启后重登一次）。
- `HostedServerError.map` 由 `internal` 改 `public`：App 层要用它把网络错误
  翻译成能显示的文案（跨模块的内部函数不可见）。
- **新增预检规则「无参 throwing 调用漏写 try」**。这条规则前后收了三次才收敛，
  过程本身有参考价值：
  1. 第一版只看「同一行里 `func x() throws`」，漏掉了**跨行签名**
     （`func f(
  参数…
) -> T` 里的 `throws` 在闭括号之后），
     于是普通重载也被当成 throwing；
  2. 第二版改成「每个同名声明都是 throwing 才算」，
     但复用通用字面量剥离函数时踩到第二个坑：它把字符串抹成空，
     `contains("\u{0}")` 变成 `contains()`，凭空造出「无参调用」；
  3. 第三版只去注释（保留换行以免行号错位）、保留字符串，
     再额外排除「落在字符串字面量里」的匹配（`@Test("books() …")`）。
  三向验证：漏写 `try` 被报出、`try?` 不报、字符串里的同名文本不报，全仓零误报。

### ✨ 新增 / Added（M3 第四批：登录与人机验证，契约 §8 落地）

- **`SourceLoginView`**：内嵌 `WKWebView` 的登录 / 验证页。
  数据存储用 `WKWebsiteDataStore.nonPersistent()`——网页会话与 App 的网络栈、
  与其他来源完全隔离；用户点「完成」后收割本页 Cookie。
  刻意**不自动判断登录成功**：真实站点上不可靠，还会在用户输到一半时抢走页面。
- **`CookieHarvest`**（`SourceEngine`，不依赖 WebKit）：收割规则。
  按主机过滤（同域 / 子域 / 空域收，第三方域丢）、丢弃过期与无名项、
  同名同域同路径去重；写入前清空该来源容器（「重新登录」= 覆盖旧身份），
  但**这次一条都没收上来时不清理**（否则「打开网页但没登录」会丢掉原本可用的凭据）。
  域归一化（去前导点 + 小写）：留着 `".Example.com"` 会让后缀匹配永远失败，
  表现为「登录了但请求不带 Cookie」。
- **`ChallengeDetector`**：识别 Cloudflare / 人机验证页。
  只看**三类状态码**（403 / 429 / 503）且正文出现厂商标记才判定——
  只看状态码会把所有 503 当验证页，不看状态码又会让页脚写着
  「Powered by Cloudflare」的正常站点被误伤。另提供从错误文案嗅探的版本
  （脚本源的网络错误类型穿不过 JS 沙箱，只剩文案），判定刻意保守：
  只认厂商名与状态码，不认「验证」这类泛词。
- **来源页入口**：工具栏「登录」（脚本声明 `loginUrl` 才有）/「打开网页验证」
  （没有登录页时退化为来源主页或服务器地址）/「清除登录状态」；
  失败状态识别到验证页痕迹时直接给出验证入口。

### 🧪 测试 / Tests（M3 第四批新增 1 个套件 / 25 个用例）

- `LoginAndChallengeTests`：Cookie 收割（主机归属含「同后缀不同域」的反例、
  域归一化、过滤过期/无名/第三方、写入容器后**其他来源不受影响**、
  重复登录覆盖、收 0 条不破坏已有状态、同名去重计数、
  从属性字典构造含缺失字段兜底、会话级 Cookie 永不过期）
  与验证页识别（Cloudflare / 人机验证、200 正文出现厂商名不判、
  非 HTML 不判、没有标记的 503 不判、空正文不判、多标记优先级、
  缺省 Content-Type 按 HTML、从文案嗅探的松紧度）

### 🔧 修复 / Fixed（M3 第四批）

- `Mapping.date` 原先写 `Date.ISO8601FormatStyle.year()`——那是**在类型上**
  调实例方法，编译器直接拒绝（"instance member 'year' cannot be used on type"），
  两个 CI 作业（test + build-ipa）一起红。改用 `ISO8601DateFormatter`。
  **已固化为预检规则**（`check_swift_syntax.py`：`ISO8601FormatStyle` 后面紧跟
  `.` 而不是 `(` 即报错，已反向验证）。

### ✨ 新增 / Added（M3 第三批：自建服务器 Komga / Kavita）

- **`MangaDataSource`**（`AppCore`）：统一的数据来源接口。浏览、详情、章节、
  阅读、下载**全部只认它**，于是界面里再没有「这是脚本源还是服务器」的分支。
  配 `MangaDataSourceProviding`（按来源标识解析）与 `MangaDataSourceProbing`
  （连接自检，和「拉一屏作品」分开——后者在 500 部作品的服务器上要好几秒）。
- **`RuntimeDataSource`**：脚本源 → 统一接口的薄适配；`SourceRuntimePool` 因此
  直接满足 `MangaDataSourceProviding`，且**不在解析时就建沙箱**
  （每个方法内部才 `withRunner`，渲染来源列表不会拉起一堆 JS 虚拟机）。
- **`HostedServer` + `ServerStore`**：自建服务器配置（地址 / 类型 / API Key 或
  账号密码）。标识由名称派生（用户不必理解「只能小写字母数字」的字符集限制），
  同名自动加序号，超长自动截断到 `SourceID` 上限内。配置文件所在目录标记为
  **不参与 iCloud 备份**（里面是用户的服务器密钥）；文件损坏时改名备份后当空处理，
  而不是覆盖掉。
- **`KomgaDataSource`**：`/api/v1/series`、`/series/latest`、`/series/{id}`、
  `/series/{id}/books`、`/books/{id}/pages` → 模型。`X-API-Key` 优先，
  否则 Basic（邮箱 + 密码）。图片接口同样要鉴权，所以鉴权头随
  `ComicPage.headers` 一起返回。页地址用接口返回的 `number` 拼，
  不按数组下标猜页码基准（Komga 的基准在版本间变过）。
- **`KavitaDataSource`**：`POST /api/Plugin/authenticate` 换 JWT（`KavitaSession`
  actor 缓存），401 时换一次 token 重试（**只重试一次**——凭据真错了就该报错）；
  `/api/Series`、`/Series/latest`、`/Search/search`（分组结果拍平）、
  `/Series/volumes`（卷里的章节拍平并按章节号排序）、
  `/Reader/chapter-info` + `/Reader/image`（查询串鉴权）。
- **`LogRedaction`**：把 `apiKey=` / `token=` / `password=` 的值在日志与错误文案里
  换成 `***`。Kavita 的图片地址必须带 apiKey，不做脱敏等于把密钥写进诊断日志。
- **`CompositeDataSourceProvider`**：把服务器与脚本源合成一个入口。
  **显式先判断归属再调用**——靠 try/catch 挨个试会让「服务器地址填错」
  显示成「源未安装」，排查方向直接跑偏。
- **界面**：`ServerManagerView` / `ServerEditView`（添加 / 编辑 / 连接自检 / 移除；
  编辑时凭据不回显，留空表示不改）；浏览页的来源列表改用 `browseSources`，
  把服务器与脚本源合成同一种条目，且**成人内容过滤只作用于脚本源**
  （服务器是用户自己的库）。

### 🧪 测试 / Tests（M3 第三批新增 3 个套件 / 44 个用例）

- `HostedServerTests`（12 例）：地址规范化（只去尾斜杠）与合法性、
  标识派生（中文名 / 全符号名 / 超长 / 去重且不超 64 字符）、凭据判定、
  存储增删改查、重复与非法标识拒绝、落盘重读、**损坏文件改名备份后不崩**、清空计数
- `HostedDataSourceTests`（25 例）：Komga（地址与分页基准、API Key 与 Basic 两条
  鉴权路径、字段映射与 `last` 分页、搜索关键词编码、详情地址反解、章节映射、
  页地址用返回的 `number`、页级鉴权头、401 / 非 JSON 错误、自检）
  与 Kavita（先认证再 Bearer、token 复用、401 换一次重试、连续 401 不无限换、
  无凭据直接报错且不发请求、按装满判定分页、搜索分组拍平、卷内章节拍平排序、
  页数取自 chapter-info、页码从 0 起、0 页报错、自检）以及 `LogRedaction`
- `DataSourceProviderTests`（7 例）：路由归属（服务器走连接器 / 脚本走池 /
  未知报 notInstalled）、移除服务器后立刻失效、
  应用层的来源合并顺序与字段、添加服务器的标识派生与地址校验、
  来源可解析性、**成人内容过滤不影响自建服务器**

### ✨ 新增 / Added（M3 第二批：下载界面 + 章节下载入口）

- **`DownloadsView` 真实化**：进行中（进度、状态、暂停/继续/取消/重试）+
  已下载（按作品分组、章节数 · 占用体积、可**点进去离线阅读**、导出 CBZ、删除）+
  已结束（失败原因、重试）。破坏性操作一律二次确认；下载记录与归档文件分开管理
  （「清除记录」不会删文件）。
- **作品详情页的下载入口**：工具栏「下载全部」（一次入队所有未下载章节，
  已下载的由协调器跳过）、章节行左滑「下载本话 / 删除下载 / 取消下载」。
  单话下载刻意**不放在行内**：行本身是 `NavigationLink`，往里塞按钮会出现
  「点下载却进了阅读器」的误触。
- **行内状态徽标**：已下载 / 下载中 x/y / 排队中 / 已暂停 / 失败
  （读的是协调器的 `jobs`，所以进度是活的，不必手动刷新）。
- `DownloadJob` 增加 `mangaTitle`，`DownloadedChapter`（清单）增加 `mangaTitle`——
  下载页要显示「哪部作品的哪一话」，而主键里只有 URL。清单字段是可选类型，
  所以**老清单仍能读出来**（不能因为加字段让已有下载全部失效）。

### 🔧 修复 / Fixed（M3 第二批）

CI 用 28 条断言失败一次性暴露了两个真实缺陷 —— 都不是界面问题：

1. **`FilePageStore` 拒绝含 `/` 的任务标识，导致在线章节全下不了。**
   章节主键是 `<mangaID>|<url>`，**必然含 `/`**（URL 就在里面），
   而早期实现的路径穿越防护是「jobID 含 `/` 就报错」，
   于是每一次下载都在第一步抛「任务标识不合法」。
   抽出了 `FileNameSanitizer`（可读部分 + FNV-1a 稳定哈希），
   归档与抓取散图共用同一套命名；顺带彻底消除路径穿越。
2. **终结态的任务记录会永久挡住重新下载。**
   队列里同 ID 只能有一个任务，而取消/失败的任务记录**会一直留着**，
   所以「取消后再下载」「失败后重试」都会静默失效
   （`retry` 里先 `cancel` 再 `enqueue`，而 `cancel` 对终结态直接返回）。
   新增 `DownloadQueue.remove(_:)`，入队与重试都先摘掉旧记录。
3. `DownloadJob.headers(forURL:)` 由「页级整体替换任务级」改为**逐键合并**：
   页级只写了 `X-Page` 时，任务级的 `Referer` 会被整块丢掉，防盗链站点立刻 403。
   同名键按小写比较（HTTP 头不区分大小写）。

### 🛠 工具 / Tooling（M3 第二批）

- `check_swift_syntax.py` 新增「路径片段安全化」规则：`appendingPathComponent(jobID)`
  这类把主键直接当路径片段用的写法一律报出（主键含 `/`）。
  判定精确到「第一个实参是裸标识符」，经过 `FileNameSanitizer.segment(...)`
  的写法不会被匹配。已反向验证（把修复改回去 → 精确报出该行）。
- `check_api_usage.py` 新增「未声明的参数标签」规则（拼错标签是编译错误，
  但它既不属于「缺少必需参数」也过得了顺序检查）。同时修掉一个**真实解析缺陷**：
  `clock: @escaping @Sendable () -> Date = { Date() }` 这类闭包类型默认值里的
  `->` 被当成 `>` 闭合括号，深度变成负数后所有顶层逗号都不再被识别，
  导致 `RateLimiter` 的 `sleeper` 参数整个消失、连带两条检查全部误报。
  修好后检查覆盖从 254 处升到 419 处构造调用。

### 🧪 测试 / Tests（M3 第一批新增 4 个套件 / 46 个用例）

- `DownloadArchiveStoreTests`（10 例）：写入与读回、缺失/越界页的安静返回、
  非 jpg 扩展名（webp/png）、重复归档整章替换、空页拒绝、主键含 `/|:` 不产生子目录、
  命名唯一且稳定、删除单章/整部/全部
- `DownloadCoordinatorTests`（15 例）：归档产出、跳过已下载与重复点击、
  批量容错（单章失败不中断）、空页列表、页级请求头保留、失败不留半成品、
  体积超限、重试、暂停/恢复、取消后可重下、清理记录、删除归档后可重下、按时间倒序
- `SourcePageFetcherTests`（8 例）：带来源 Cookie、**不泄漏其他来源的 Cookie**、
  Referer、页级头优先、回落任务级、空页级头不盖掉任务级、
  无上下文时**一个请求都不发**并报错、HTML 错误页拒绝
- `DownloadedReadingTests`（7 例）：页列表来自归档且**脚本零调用**、
  取图**零网络请求**、未归档仍走网络、缺页回落、归档页数不按脚本撒谎、
  已下载标识集合、未接归档时行为不变

### 🔧 修复 / Fixed（M3 第一批）

- `tools/check_swift_syntax.py` 的「悬空 `else`」规则会误报**多行条件**：

  ```swift
  guard let a,
        let b = f(a),
        b > 0
  else { return nil }
  ```

  `else` 的上一行是 `b > 0`，既不以 `,` 也不以 `)` 结尾。改成往回找语句开头：
  只要在撞上 `{` / `}` / `;` 之前先碰到 `guard` / `if` 就放行。
  已双向验证：真悬空仍被报出，多行 guard 不再误报。

### 🧪 测试 / Tests（M2 收尾新增 1 个套件 / 9 个用例）

- **`DemoRepositoryTests`（M2 验收）**：用自测仓库的真实脚本与页面，一次跑通
  「拉 index.json → 安装落盘 → 载入沙箱 → 热门分页 → 最新/搜索 → 详情 →
  章节（含数字字符串编号与两种日期写法）→ 页列表 → 取图（真 PNG 字节 + Referer）
  → 阅读来源缓存命中 → 筛选项」。

### 🔧 修复 / Fixed（M2 收尾）

- `tools/check_imports.py` 此前只剥离注释、不剥离字符串字面量：
  夹具里内联的 HTML 出现「Demo Manga One」就被判成用了 `Manga`，
  误报「需要 import AppCore」。现在复用 `check_swift_syntax` 的字面量剥离
  （它会保留插值里的代码），不再误报。

### 🧪 测试 / Tests（M2 第七批新增 1 个套件 / 10 个用例）

- `ReadingSourcesTests`：在线来源（章节 / 页列表缓存命中、图片带章节页 Referer、
  单页请求头优先、按来源失效、LRU 淘汰、失败不写缓存）
  与本地适配（章节 / 页序与同步实现一致、取图、找不到作品时的错误传递）

### 🧪 测试 / Tests（M2 第六批新增 2 个套件 / 19 个用例）

- `SourceImageLoaderTests`（9 例）：取回字节、页级 Referer 优先级、来源 Cookie、
  HTML 错误页拒绝、`octet-stream`/缺 Content-Type 接受、空响应、
  体积上限、HTTP 403、非 http(s) 地址不发起请求
- `SourceBrowseModelTests`（10 例）：首屏加载、翻页追加而非覆盖、末页不再请求、
  已加载不重复请求、refresh 强制重载、空结果不算失败、首屏失败可重试、
  **翻页失败保留已见内容**、并发触发只发一次请求、错误文案映射

### 🛠 工具 / Tooling

- **新增预检第 7 项 `tools/check_localization.py`**：多语言 key 集合一致
  （以并集为基准，避免报错方向反过来）、代码里 `L("…")` 的 key 必须已定义、
  同一 key 的占位符类型/数量一致、`String(format:)` 参数个数吻合。
  已做反向验证（注入三类问题 → 全部被拦下）。顺带修掉两处占位符问题：
  `%d` 配 64 位 `Int`（改 `%ld`）、`%@` 与位置占位符混用导致同一参数被吃两次。

### 🧪 测试 / Tests（M2 第五批新增 4 个套件 / 45 个用例）

- `SourceIndexURLTests`（4 例）：三种输入形式的规范化、端口与 IPv6、
  非法地址（含 `http` 非本机）一律拒绝、脚本地址由目录推导
- `SourceRepositoryServiceTests`（10 例）：目录合并本地状态、更新检测（含本地更新不提示）、
  404 / 非法 JSON / 路径穿越文件名的拒绝、安装落盘、**key 不一致拒绝且不落盘**、
  禁用 API / 非 UTF-8 / HTTP 500、多仓库部分失败、空仓库、只读下载
- `SourceRuntimePoolTests`（10 例）：载入一次并复用、并发 single-flight、
  未安装 / 缺必需方法（且不建运行时）的错误映射、载入失败可重试、LRU 淘汰、
  **租约保护（含超限警告日志）**、
  租约释放后恢复可淘汰、invalidate 重载、卸载后报错、invalidateAll
- `SourceVisibilityRuleTests`（2 例）：未开启时隐藏成人内容源、开启后全部可见
- `IntegrationTests` 新增「应用环境：可见源过滤 + 运行时池接线」：
  装两个源（含一个 `nsfw: true`）→ 可见列表只显示一个 → 确认年龄并开启后两个都可见 →
  取运行器调用契约方法并解码 → 卸载后取运行器报 `notInstalled`（全程无网络）

### 📖 文档 / Docs

- **`docs/source-api.md` 契约按实现细化**：补齐仓库/脚本校验的**精确规则表**
  （各上限常量、字段约束、拒绝清单、布尔与引号解析细节）、方法契约的
  **语义要求**（`url` 稳定性 → 主键派生、分页从 1 开始、空结果不报错、
  页序即阅读顺序、单页大小上限）、宿主行为表（静默期/超时/重试/NSFW 隐藏）、
  错误语义表、安全要求、发布前自检清单，以及一份**可直接照抄的完整示例源**；
  并按实现状态标注「已冻结 ✅ / M2 实现中 🚧」，避免承诺未落地的能力。
- 契约示例由**测试守护**：新增 `MangaTranslaterTests/SourceAPIDocTests.swift`
  逐项断言示例能过校验、方法齐全、元信息与文档表格一致；
  `tools/check_docs_sync.py` 保证文档与夹具**逐字一致**（预检第 4 项）。

### 🧪 测试 / Tests（新增 16 个用例）

- `JSSourceHTMLBridgeTests`：用**真实源写法**（`html.parse` → `doc.select` →
  `.text()`/`.attr()`/`.length`）端到端跑通列表 / 搜索 / 详情 / 章节 / 页列表；
  选择器写错不中断且记日志；未匹配时单值取空串、集合取空数组；
  空 HTML 不崩溃；重新装载清空句柄
- `HTMLHandleStoreTests`：存取、释放、容量淘汰、清空、
  按 `nodeID` 查元素、`selectJSON` 的失效句柄 / 非法选择器 / 正常返回 / 子树限定

### 🧪 测试 / Tests（新增 60 个用例）

- `HTMLParserTests`：四种属性写法、大小写规范化、嵌套、void 标签、自闭合、
  多余结束标签、未闭合自动闭合、跨层级补闭合、注释/DOCTYPE、raw text、
  非法尖括号、空输入、空白折叠、`outerHTML` 往返、`nodeID` 唯一性
- `CSSSelectorTests`：四类简单选择器、两种组合子（含无空格 `a>b`）、
  多级链、结果顺序与去重、子树范围、典型字段提取、五类非法输入、解析细节
- `HTMLTextTests`：命名/数字实体与未知实体、解析期解码、空白折叠、转义、
  URL 绝对化四种形式、查询参数读改、host、反斜杠还原

### 🧪 测试 / Tests（新增 27 个用例）

- `JSSourceRuntimeTests.swift`：装载校验（缺方法 / 禁用 API / id 不符 / 顶层抛错）、
  契约方法调用、`net` 的 GET/POST（方法、头、体、响应体）、网络失败在 JS 侧可捕获、
  `cookies` 读写、`prefs` 默认值与写入、`log` 送达宿主、超时、
  `teardown` 与未装载调用、重载替换沙箱、非法 JSON 参数、
  **两个运行时沙箱隔离**、四则纯函数（请求解码 / 响应编码 / 数组字面量 / 偏好键）
- 网络用可编程替身 `StubSourceTransport`：全部用例不依赖真实网络、可重复

### 🧪 测试 / Tests（新增 13 个用例）

- 分类：空分类可保存、名称清洗与截断、空名/重名被拒（忽略空白与大小写）、
  重命名保持 id 与条目引用（含改自己大小写、撞他人被拒）、删除分类不删条目并返回
  受影响数、重排（含非法/重复 id 稳健性）、`save`/`setCategory` 自动补建分类、
  落盘重启后分类仍在；以上除落盘用例外均在 GRDB 与内存两个实现上各跑一遍。

### 🧪 测试 / Tests（新增 47 个用例）

- `ZoomStateTests.swift`：缩放钳制（含 NaN/无穷）、缩回 1 倍归零位移、
  捏合基准、双击往返、适配尺寸、**平移边界钳制**（未放大不可拖动 /
  只允许按超出量移动 / 单轴无溢出则锁死）
- `CoverThumbnailCacheTests.swift`：真实 PNG 夹具自检、文件名派生（稳定 / 无非法字符 /
  区分不同作品）、等比缩放五种边界、生成产物可再解码、
  内存与磁盘命中、损坏图片不落盘、清空缓存、目录按需创建、并发一致性
- `AppSettingsTests.swift` 扩充：新阅读字段的钳制与往返；
  **快照向后兼容**（缺字段 / 类型不符 / null / 空对象 / 未知字段）

### 🧪 测试 / Tests（新增 60 个用例）

- `LocalSourceTests.swift`：噪音过滤、自然排序（含超长数字防溢出）、四种分章布局、
  导入幂等、同名不同内容、非归档/无图片/文件缺失/扩展名非法、立即读取、异步与同步一致、
  跨实例持久、删除、路径穿越防护、命名与slug/标题清洗/指纹、并发导入
- `ReaderSessionTests.swift`：初始化钳制、空章节、章内前进后退、章末/章首/全书两端、
  换章重置页码、边界换章失败、预加载窗口四种边界、进度标记、连续遍历恰好经过每一页
- `LibraryStoreContractTests`（同文件）：排序 / 置顶 / 连带删除 / 进度 / 历史裁剪 /
  分类 / 未读归零 —— 每一条都在 GRDB 与内存实现上各验一遍

### 🧪 测试 / Tests（新增 30 个用例）

- `LibraryStoreTests.swift`：CRUD、upsert、三种排序与置顶、分类筛选、
  进度与历史一致性、历史覆盖/裁剪/清空、非法参数（负页码 / 非法 limit）、
  对不存在条目的原子性（失败不留痕）、500 条批量、并发读写、落盘重启后仍在、
  重复打开不重复迁移、损坏 payload 报 `corruptRow` 而非崩溃
- `ZipDeflateTests.swift`：deflate 条目读取、store/deflate 混合归档、空内容、
  CRC 由外部实现写入的逐字节校验、不支持的方法被拒、声明尺寸不符、
  压缩流被破坏、缺失条目

### 🔧 修复 / Fixed

- `ReadingHistoryEntry` 缺少 `Codable`（被 JSON payload 编解码使用），编译失败；
  并把这类问题固化为预检规则：`decode(X.self …)` 涉及的自有类型必须声明 `Codable`
  （已实测能抓到该缺陷）。
- `ZipDeflateTests` 的多行 base64 字面量首行缺缩进，编译报
  "Insufficient indentation of line in multi-line string literal"；
  修正生成逻辑（每行含首行都按结束定界符缩进 + `.ignoreUnknownCharacters` 跳过换行），
  并把「多行字符串缩进规则」加进预检（已实测能抓到该缺陷）。

### 🧪 测试 / Tests

- 覆盖全部四个包的正常流程、异常分支与边界条件（空输入、超长文本、非法参数、
  网络超时、文件缺失 / 损坏、并发调用、资源清理与回滚）。
- 13 个测试文件（含共享工具 `TestSupport.swift`）。

### 🛠 工程工具 / Tooling

- `check_swift_syntax.py` 的「去字面量」扫描器重写为**带上下文栈的状态机**：
  早先它把字符串插值 `\(…)` 整体当字符串内容，导致插值里的括号漏计、
  在复杂行上报出虚假的「圆括号不配平」；现在正确区分
  「插值内的代码」与「插值内的字符串」，并记录括号深度以识别插值结束点。
  同时补上 **raw string（`#"…"#`）** 的识别——正则里的 `[\[\(]` 不再被计入括号。

### 🛠 工程工具 / Tooling

- `tools/preflight.sh` —— 推送前预检入口，四步串跑：
  - `check_project.py`：pbxproj 引用完整性、例外集一致性、包登记、配置语法
  - `check_imports.py`：跨包 import 完整性（本地挡掉纯编译器错误）
  - Python 脚本语法检查
  - `check_redlines.py`：合规红线（无站点名 / 无源脚本 / 无凭据）

