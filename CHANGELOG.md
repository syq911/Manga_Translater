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

### 🔧 修复 / Fixed

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

- `tools/preflight.sh` —— 推送前预检入口，四步串跑：
  - `check_project.py`：pbxproj 引用完整性、例外集一致性、包登记、配置语法
  - `check_imports.py`：跨包 import 完整性（本地挡掉纯编译器错误）
  - Python 脚本语法检查
  - `check_redlines.py`：合规红线（无站点名 / 无源脚本 / 无凭据）

