# 架构说明 / Architecture

## 1. 定位

MangaTranslater 是一个**通用漫画阅读器**：不自带任何在线源，用户通过
「本地文件 / 自建服务器（Komga、Kavita）/ 第三方源仓库 URL」三种方式获得内容，
并内置基于设备端 OCR 的页内翻译。

产品与合规边界见仓库根 `CONTRIBUTING.md` 第 7 节。**任何改动都不得
内置、内置推荐或代为分发第三方源脚本。**

## 2. 分层与依赖方向

依赖只能自下而上，禁止反向与循环依赖：

```
App（SwiftUI，MangaTranslater target）
 ├─ AppDatabase     书架持久化（GRDB / SQLite）  ── 远程依赖 GRDB
 ├─ ComicDownload   下载队列 / CBZ 打包 / ZIP 读写（store + deflate）
 ├─ SourceEngine    源脚本校验 / 仓库索引 / 仓库管理 / 运行时契约
 ├─ ComicNet        HTTP 客户端 / CookieJar / 节流器
 └─ AppCore         数据模型 / 设置 / 错误 / 诊断日志
        ↑ 其余四个包都依赖 AppCore
```

> **GRDB 为什么放在本地包的依赖里**：工程文件只登记本地包（该引用格式已被 CI 反复验证），
> 远程依赖由 `Packages/AppDatabase/Package.swift` 声明后由 SwiftPM 传递解析，
> 避免在 `project.pbxproj` 里手工新增 `XCRemoteSwiftPackageReference`（多一类失败面）。

| 模块 | 职责 | 依赖 | 是否依赖 UI 框架 |
|---|---|---|---|
| `AppCore` | 模型（`Manga`/`Chapter`/`ComicPage`/`SourceMeta`/`LibraryEntry`）、`AppSettings`、`AppError`、`DiagnosticsLog`、**`PageDataProviding`**（页数据来源抽象）、**`ReaderSession`**（翻页/翻章/预加载的纯逻辑） | 无 | 否（纯 Foundation） |
| `ComicNet` | `HTTPClient`（重试 / 超时 / 大小保护）、`CookieJar`（按来源隔离）、`RateLimiter` | AppCore | 否 |
| `SourceEngine` | `SourceScriptValidator`、`SourceIndexParser`、`SourceStore`、`SourceAPIContract`、`SourceRuntimeExecuting`；**内置本地文件源 `LocalSource` + `LocalArchiveIndexer`** | AppCore、ComicNet、ComicDownload | 否 |
| `ComicDownload` | `DownloadQueue`（actor）、`PageFetching`/`PageStoring`、`ZipArchiveWriter/Reader`、`CbzExporter` | AppCore、ComicNet | 否 |
| `AppDatabase` | `LibraryStoring` 协议 + `DatabaseLibraryStore`（GRDB）：书架条目、阅读进度、阅读历史、分类、置顶、迁移 | AppCore、GRDB | 否 |；另含 `InMemoryLibraryStore`（降级兜底 + 协议测试第二实现） |
| App target | 四 Tab UI、`AppEnvironment`、本地化、后续接入阅读器与翻译 | 全部四包 | 是（SwiftUI） |

## 3. 关键设计决策

### 3.1 源 = 单文件 JavaScript（执行由 JavaScriptCore 承担）

- 源是用户从第三方仓库安装的**不受信任代码**，必须先静态校验（`SourceScriptValidator`）
  再执行；执行期由 `SourceRuntimeExecuting` 用独立 JS 沙箱承载（M2 实现）。
- 静态校验在**不执行脚本**的前提下拦截：空/超大脚本、空字节、缺失元信息、
  非法 `id`/`version`/`baseUrl`、以及 `eval(`、`Function(`、`import(`、`require(`、
  `WebAssembly` 等动态求值入口。
- 契约 v1 的必需方法集合固化在 `SourceAPIContract`，脚本是否实现由静态预检判定。

### 3.2 数据模型与站点解耦

`Manga.id` 与 `Chapter.id` 由 `(来源, URL)` 稳定派生（`"<sourceID>|<url>"`），
因此书架、历史、下载、翻译缓存都以同一主键工作，切换来源实现不影响上层。
所有 URL 以 `String` 存储，合法性统一由 `ModelValidation` 判定。

### 3.3 文件系统与网络都可注入

- `SourceFileSystem` / `PageStoring` / `PageFetching` / `HTTPTransporting` / `RateLimiter` 的
  时钟与休眠实现均可注入。
- 目的：**所有异常路径都能在单元测试里确定性复现**（超时、5xx、429、磁盘写失败、
  Cookie 文件损坏、下载中途失败回滚等），无需真实网络与真实等待。

### 3.4 失败必须可回滚

- 安装源：临时文件 → 备份旧版本 → 就位 → 写元数据 → 删备份；任一步失败都恢复原状。
- 下载：任务失败或取消时清理已落盘的页，不留半成品。
- Cookie：持久化用原子写；损坏文件备份为 `.corrupt` 后重置，绝不阻塞启动。

### 3.5 书架持久化：查询列 + JSON payload（0.2.0 起）

`DatabaseLibraryStore` 用「**一列 payload（完整模型 JSON）+ 若干投影列**」存书架：

- payload 是**唯一事实来源**；投影列（`title` / `added_at` / `last_read_at` /
  `is_pinned` / `category_id` / `source_id`）只为排序、筛选、置顶服务，并建了索引；
- 两者在**同一个事务**里更新（`mutateEntry` / `updateProgress`），不会出现
  "列与 payload 不一致"的中间态；
- 好处：给 `Manga` 加字段**不需要写迁移**；读路径只依赖
  `String.fetchOne/fetchAll` + `Int.fetchOne` + 自己的 JSON 编解码——对外部库的
  API 依赖面窄，不容易因库升级产生编译问题。

失败必须无痕：`updateProgress` 对不存在的条目抛 `entryNotFound` 时，
不应写入任何历史（有专门用例断言）。

### 3.6 队列由调用方驱动（0.2.0 起）

`DownloadQueue` **不派生后台任务来驱动状态机**，推进流程是显式的
`await queue.processPending()`：

- 测试完全确定性：入队 → `processPending()` → 断言，无需轮询等待；
- App 走 `start()`（内部 `Task.detached` 跑 `processPending()`）+ `waitUntilIdle()`；
- 取消是协作式的：置状态后在**页边界**收尾并清理，保证「取消后磁盘无残留」可断言；
- `processPending()` 单线程推进，`maxConcurrentJobs` 天然不会被突破。

> 背景：0.1.0 用 `Task {}`（继承 actor 隔离）驱动，CI 上实测出现任务永久停在
> 中途、`waitUntilIdle` 超时的现象。改为显式驱动后问题消失。


### 3.7 本地文件源与阅读器内核（M1）

**本地文件源（`SourceEngine/LocalSource`）**

- 导入即**复制**到沙盒 `LocalLibrary/<slug>-<指纹前8位>.cbz`：原文件被移动/删除不影响阅读，
  作品地址（`Manga.url`）也因此稳定 —— 而作品主键由 `(来源, url)` 派生，稳定才有稳定的书架。
- **幂等**：文件名由「大小 + 首尾各 64KB」指纹派生，同一文件重复导入不会产生第二份。
- **原子写**：先写 `.importing` 再 move，失败清理临时文件，不留半个归档。
- **路径穿越防护**：作品地址只接受「根目录名 / 单层文件名」，`../`、绝对路径一律拒绝。
- **分章规则**（`LocalArchiveIndexer`，纯函数可单测）：过滤 `__MACOSX/`、`._` 前缀、
  `.DS_Store`、非图片；全在目录内且顶层目录 ≥2 → 每目录一章；恰好 1 个目录 → 单章取目录名；
  存在根目录图片 → 整体一章取书名。
- **自然排序**：`1.jpg < 2.jpg < 10.jpg`（字典序会排成 1, 10, 2，阅读顺序就错了）。

**阅读器内核（`AppCore/ReaderSession`）**

翻页、章末跳转、预加载窗口这些**全是 off-by-one 高发区**，因此做成不依赖 UI 的值类型：
`advanceForward/advanceBackward` 返回 `moved / needsNextChapter / needsPreviousChapter / atEnd / atStart`，
视图只负责把结果画出来。`preloadRange(pageCount:window:)` 负责钳制预加载窗口。

**页数据来源抽象（`AppCore/PageDataProviding`）**

阅读器通过这一个协议取页数据；本地源同步解压，M2 的在线源走 HTTP，阅读器零分支。

### 3.8 封面缩略图与缩放：把「平台相关」留在 App 层（M1 收尾）

**封面**分两段，各自落在能测的那一层：

| 层 | 职责 | 为什么在这 |
|---|---|---|
| `SourceEngine.LocalSource.coverData(for:)` | 找出「第一章第一页」并返回**原始字节** | 纯 Foundation，可单测；不涉及图形框架 |
| `App.CoverThumbnailCache` | 等比缩放成缩略图、内存 + 磁盘缓存 | 依赖 UIKit/CoreGraphics，只留在 App 层 |

缓存文件名由 `SHA256(mangaID)` 前 16 位派生 —— 作品 ID 含 `|`、`/` 与中文，
不能直接当文件名；哈希后也天然保证「同一作品只占一个文件」。
损坏图片**不写缓存**，避免下次直接命中坏数据；缓存写失败只记日志，不影响阅读。

**缩放/平移**的规则同样抽成值类型 `AppCore.ZoomState`（可单测），视图只做手势映射。
两条容易出错的规则被固化成测试：

1. 缩回 1 倍时位移必须归零（否则复原后画面偏）；
2. 内容未超出容器的方向**不允许拖动**（否则能把整页拖出屏幕）。

阅读区背景、页面留白、屏幕常亮都来自 `AppSettings`；
单击区方向语义随 `readerMode` 变化（右到左模式下左侧是「下一页」）。

### 3.10 分类独立成表（v2 迁移）

早期分类只是条目上的一个自由字符串（`LibraryEntry.categoryID`）。这带来两个硬伤：

1. **无法表达「暂无作品的分类」**——用户新建后一刷新就消失；
2. 无法重命名与排序（字符串既是名字又是引用）。

v2 迁移把分类升级为独立实体 `LibraryCategory { id, name, sortOrder }`：

- **迁移对用户无感**：回填时直接用旧的分类名当 `id`，于是既有的 `category_id`
  引用无需改写；新建的分类才使用 UUID。
- **id 与 name 分离**：重命名只改 `name`，条目引用不受影响。
- **不留孤立引用**：`save` / `setCategory` 遇到未登记的分类 id 会自动补建
  （这样「直接设 categoryID」这种旧用法仍然工作）。
- **删除分类不删书**：同一事务内先把条目的 `category_id` 置空，再删分类，
  并返回受影响的条目数。
- 名称查重忽略大小写与连续空白（`ModelValidation.categoryNameKey`）。

### 3.9 沙箱与限流

- 源运行时的调用超时、响应上限、是否允许联网集中在 `SourceRuntimeConfiguration`。
- 每个来源一个 `RateLimiter`（遵守源声明的 `rateLimitMs`），避免触发站点风控。

## 4. 目录结构

```
MangaTranslater/
├── MangaTranslater/                  # App target（Xcode 16 同步文件夹）
│   ├── App/                          # 入口、环境、主 Tab、本地化
│   │   ├── Library/  Browse/  Download/  Settings/
│   ├── MangaTranslaterTests/         # 全部单元测试与集成测试（Swift Testing）
│   ├── Resources/                    # 资源、Assets.xcassets、en/zh-Hans 字符串
│   ├── Info.plist
│   └── MangaTranslater.entitlements
├── Packages/
│   ├── AppCore/  ComicNet/  SourceEngine/  ComicDownload/
├── docs/                             # 本目录
├── Tests/Fixtures/                   # 测试素材（不打进 App bundle）
└── .github/workflows/build-ipa.yml   # CI
```

## 5. 第三方依赖

| 依赖 | 用途 | 许可证 | 状态 |
|---|---|---|---|
| GRDB.swift | 本地数据库（书架 / 历史 / 下载） | MIT | **已引入**（`Packages/AppDatabase`，`from: 7.11.0`） |
| SwiftSoup | 源脚本 HTML 解析桥 | MIT | 计划于 M2 引入 |

引入新依赖前请同步更新本表、`NOTICE` 与 `README`。

## 6. 相关文档

- 源 API 契约：`docs/source-api.md`
- 构建与发布：`docs/development.md`
- 测试规范：`docs/testing.md`
- 贡献规范：`CONTRIBUTING.md`
