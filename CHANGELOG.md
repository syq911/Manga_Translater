# 更新日志 / Changelog

本项目遵循 [语义化版本](https://semver.org/lang/zh-CN/) 规范。
This project adheres to [Semantic Versioning](https://semver.org/).

版本阶段说明：
- `0.x` —— 开发期，源 API 契约尚未冻结（Source API contract not frozen）。
- `1.0.0` —— 源 API 契约 v1 冻结 + 云端翻译服务上线。

---

## [Unreleased]

### 计划中 / Planned

- M1 地基：泛化数据模型（Manga / Chapter / Page）、GRDB 书架、本地文件源、阅读器
- M2 源引擎：JavaScriptCore 单文件 JS 源、仓库管理（添加 / 安装 / 更新 / NSFW 开关）
- M3 补全：批量下载 + 后台续传 + CBZ 导出、Komga / Kavita、WebView 登录、Cloudflare 兜底
- M4 翻译与云服务：页内翻译接入、BYOK、邮箱验证码账号、额度、Lemon Squeezy 订阅
- M5 发布：中英双语文案、隐私政策、AltStore 源上线

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
  - `call` 通过 `callAsyncJavaScript` 支持脚本里的 `async/await`
  - 调用超时用任务组竞速：超时后调用方立即返回（不阻塞 UI）
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

