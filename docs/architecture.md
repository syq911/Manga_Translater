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

### 3.9 沙箱与限流

- 源运行时的调用超时、响应上限、是否允许联网集中在 `SourceRuntimeConfiguration`。
- 每个来源一个 `RateLimiter`（遵守源声明的 `rateLimitMs`），避免触发站点风控。

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

### 3.11 源执行沙箱：JavaScriptCore + 桥接（M2）

**隔离**：每个源一个 `JSVirtualMachine`（不共享对象图与 GC），
一个源无法读到另一个源的全局；`load` 时可随时替换沙箱（重载即换 VM）。

**桥接只传字符串**。Swift 侧注入 `__bridge`（若干 `@convention(block)` 函数），
再由一段固定的引导脚本把它包装成友好的 JS API：

| JS API | 语义 | 宿主侧 |
|---|---|---|
| `net.fetch(url, options)` | 返回 `{status, ok, headers, body, text}` | `SourceTransporting.send`：带该源 Cookie + 节流 + 体积上限 |
| `cookies.get(url[, name])` / `.set(url, obj)` | 读写该源 Cookie | `SourceTransporting.cookies/storeCookies` |
| `prefs.get(key, fallback)` / `.set(key, v)` | 源自定义设置 | `SourcePreferencesStoring`，键带 `source.<id>.pref.` 前缀 |
| `log.info/warn/error(msg)` | 诊断日志（截断 200 字符、不落内容） | `logSink` 回调 |

之所以「只传字符串」：JSON 在两个世界之间是唯一无歧义的载体，
省掉了大量 JSValue ↔ Swift 类型映射代码，出错面小得多。

**错误语义**：网络失败不让 Swift 抛异常，而是让 JS 的 Promise **reject**
（`parsed.error`），源脚本可以自行 `try/catch` 降级——这符合源作者的直觉。

**超时**：`call` 用「任务组竞速」——JS 与计时器谁先完成谁生效。
脚本里的死循环无法被 JSC 中断，因此超时的语义是
**「调用方立即返回，不再等待 JS」**，而不是「杀掉 JS」；
配合「每源独立 VM」，一个失控的源不会拖垮其他源或 UI。

**为什么桥接的读操作是同步的**：脚本里写 `prefs.get(...)` 比 `await` 自然。
取值需回到 actor，因此用短超时同步等待：
常规路径（脚本在 async 函数内调用）时 actor 是空闲的，不会阻塞；
极端情况会等满超时并返回默认值，不会死锁。

### 3.12 HTML 选择器引擎（M2 第二批）

源脚本的核心能力是「取回 HTML → 用 CSS 选择器提取字段」。这里**自己实现**
而不引第三方解析器：包的依赖策略是「能不加就不加」，而源用到的子集其实很小。

| 能力 | 支持 |
|---|---|
| 解析 | 标签 / 属性（四种引号写法）/ 文本 / 注释跳过 / void 标签 / script·style 原文 / 实体解码 |
| 选择器 | 类型、`#id`、`.class`、属性（存在 / `=` / `^=` / `$=` / `*=`）、通配 `*` |
| 组合子 | 后代（空格）与直接子代（`>`），支持多级链 |

**匹配策略是从左到右推进候选集合**：每一步在上一步结果的「后代 / 直接子代」里筛选，
最后一步的输出即结果，按文档顺序去重（用解析时分配的稳定 `nodeID`）。
这比从右到左回溯更好实现，语义也更直观。

**明确不做**（避免复杂度失控）：伪类、`:nth-child`、逗号并列选择器、
HTML5 的隐式标签补全。这些都不影响真实源的常见写法，缺失时源作者可自行过滤。

配套的纯函数工具（源作者的高频需求，放在宿主侧省得每个源各写一遍）：
`HTMLText.decodeEntities`（命名 + 十进制/十六进制数字实体）、
`HTMLText.collapseWhitespace`、`HTMLURL.absolute`（处理 `/m/1`、`chapter/1.html`、
`//cdn/a.jpg` 四种相对形式）、`HTMLURL.queryValue` / `settingQuery`。

### 3.13 `html` 桥接：把选择器能力交给源脚本（M2 第三批）

桥接同样遵守「同步 API 不经过 actor」的约束：解析结果存在**线程安全的句柄表**
（`HTMLHandleStore`）里，JS 只拿到一个整数句柄，查询时用
`(句柄, 起始节点号)` 定位——这样既避免把整棵 DOM 复制到 JS 侧，
又不需要回到 actor。

JS 侧暴露的 API 与 `docs/source-api.md` 的示例逐字对应：

```js
const doc = html.parse(response.body);
doc.select("div.item").map(function (node) {
    return { title: node.select("a.title").text(), url: node.select("a.title").attr("href") };
});
doc.select("a.next").length > 0
```

设计要点：

- **元素与「集合」共用一整套方法**。集合是**真数组**（`map`/`forEach`/索引都可用），
  同时在数组上挂了 `text()` / `attr()` / `html()` / `select()` / `selectFirst()`——
  取「第一个元素的值」。这样 `node.select("a").text()` 这种写法才成立（契约示例即如此）。
- **选择器非法不致命**：桥接返回 `{"error": …}`，JS 侧记一条日志后返回空集合。
  源作者写错选择器只会拿到空结果，而不是整次调用失败。
- **句柄有容量上限**（默认 16，超出淘汰最旧），避免长时间运行的源不断解析却不释放。
- `html()`（序列化）按需通过 `htmlOuter` 取，元素列表的 JSON 里不带它——
  否则每次查询都要序列化整棵子树。

### 3.14 响应解码：把「任意 JSON」收束成模型（M2 第四批）

脚本返回的是**任意 JSON**（源作者写的，契约只是约束），模型层却要求
「主键稳定、字段有界、枚举合法」。中间必须有一层专职转换，即
`SourceResponseDecoder`——它**不依赖 JavaScriptCore**，只吃 JSON 文本。

三个设计取舍：

- **容错集中在解码层，而不是散落在 UI**。`status` 认不出按 `unknown`、
  日期支持四种写法、`genres` 收单个字符串——这些「宽容」如果写在界面里，
  每个界面都要重复一遍，且行为会逐渐分叉。
- **丢弃要计数，不能静默**。缺 `url` 的条目必须丢（没有地址就无法生成主键），
  但「丢了 3 条」这件事要经 `SourceDecodeOutcome.skippedItems` 回到上层写日志。
  静默丢数据比报错更危险：用户只会觉得「这个源少了几话」。
- **地址补全有优先级**：`页面地址 → 来源 baseUrl`。章节页里的 `1.jpg` 应该
  相对**章节页**解析（HTML 语义如此），源没写 `baseUrl` 时再退回相对来源根。
  作品/章节地址允许保留「来源自定义标识」（如 `series:123`）——契约允许
  `url` 不是真 URL；**图片地址不允许**，取不到内容留着只会是破图。

### 3.15 类型化门面：`SourceRunner` 负责降级，运行时只负责跑（M2 第四批）

`JSSourceRuntime` 只知道「怎么跑 JS」，`SourceResponseDecoder` 只知道
「怎么变模型」，`SourceRunner` 是粘合处，也是**降级策略的唯一落点**：

- 参数按契约以**独立 JSON 片段**编码（页码是数字字面量、查询串只编码一层）；
  把整个参数数组交给 `JSONSerialization` 会多包一层引号，源拿到
  `"\"query\""` —— 实测踩过。
- 可选方法缺失时降级：`getLatestUpdates` 回退热门列表、`getFilters` 返回空数组。
  判断依据是**装载时的静态预检结果**，而不是「调用失败后再猜」——
  后者要靠匹配错误文本，脆弱且会掩盖真实错误。
- 错误语义统一：运行时的 `SourceRunnerError` 原样传播（保留 `invalidResponse`
  与 `executionTimeout` 的区别），外来错误包装为 `executionFailed`，
  `CancellationError` 映射为 `cancelled`。
- 它是 `actor`：同一来源的调用天然串行。JS 上下文不可重入，并发调用同一个源
  只会让状态互相打架；要并行就为每个来源各建一个 runner。

### 3.16 仓库服务：网络归网络，磁盘归磁盘（M2 第五批）

`SourceRepositoryService` 只做「把索引和落盘用网络串起来」，三件事各归各家：

| 关注点 | 归属 |
|---|---|
| 一段 JSON 是否合法（含 `fileName` 防穿越） | `SourceIndexParser` |
| 磁盘上有什么、怎么安全落盘与回滚 | `SourceStore` |
| 拉索引、下载脚本、比对版本 | `SourceRepositoryService` |

两个刻意的设计：

- **索引与脚本必须说同一个 key**。仓库索引写 `key: "foo"`，脚本里却声明
  `id: "bar"`，落盘后会出现「索引说装了 foo、磁盘上是 bar.js」的不一致。
  现在下载后立刻比对，不一致直接拒装（用例覆盖）。
- **单仓库失败不影响其他仓库**。`catalogs()` 返回逐条结果（成功带目录、
  失败带原因），而不是「一个仓库 404 就整页打不开」——用户填的仓库地址
  是第三方的，说挂就挂。

地址规范化也收在一处（`SourceIndexParser.indexURL` / `directoryURL`）：
用户可能填 `https://x.com/repo/`、`.../repo`、`.../repo/index.json` 三种形式。
**不要**用「取最后一个 `/` 之前的部分」这种写法——填 `https://x.com` 时
最后一个 `/` 落在 `https://` 里，拼出的脚本地址会缺主机名。

版本比较用 `SourceVersion`（`1.2` == `1.2.0`、正式版高于同号预发布版、
解析不了就**不提示更新**：误报会让用户反复看到装不上的「新版本」）。

### 3.17 运行时池：把「昂贵且有限」的资源管起来（M2 第五批）

每个源一个 `JSVirtualMachine`，因此不能「用一次建一次」，也不能无限留着。
`SourceRuntimePool` 负责这三件事：

- **载入一次**：同一 key 并发取用时只载入一次（single-flight）。否则两个调用
  各自建一个沙箱、互相覆盖状态——而且还会白花一次脚本解析开销。
- **上限内复用**：超过 `maxLoadedSources`（默认 3）就淘汰最久未用的。
- **不打断在用的人**：每次取用计一次「租约」，有租约的源不参与淘汰；
  若所有源都在使用中，**宁可临时超限**也不回收。因此对外提供两种用法：

  ```swift
  // 短调用：拿完就用，可能被下一次淘汰回收（够用且简单）
  let runner = try await pool.runner(for: key)

  // 长操作：整个闭包期间持有租约，保证不被回收
  try await pool.withRunner(for: key) { runner in … }
  ```

- **失效重载**：安装 / 更新 / 卸载源之后必须 `invalidate(key)`；脚本内容变了
  却继续用旧沙箱，用户会看到「更新了却还是旧行为」这种最费解的 bug。

可见性（`SourceVisibilityRule`）也刻意收在一处：成人内容源默认隐藏，
界面**一律**用过滤后的列表，而不是各页各写一次 `if !source.isNSFW`——
漏一个页面就等于这条合规约束失效。

### 3.18 图片字节：与文本桥接分开的一条路（M2 第六批）

封面与漫画页的字节加载走 `SourceImageLoader`，**不复用**源脚本的 `net.fetch` 桥接：

| 维度 | 文本桥接（脚本用） | 图片加载 |
|---|---|---|
| 返回 | `String`（契约里的响应体是文本） | `Data`（二进制） |
| 体积上限 | 4 MB | 20 MB（契约 §5.3） |
| 谁来调 | JS 里的源脚本 | 宿主（封面、阅读器） |
| 重试 | 由源自己决定 | 宿主自动重试 1 次 |

混在一起迟早会出现「文本桥接的 4 MB 上限把大图砍掉」这类难查的问题。
加载器本身只做三件 `HTTPClient` 不做的事：图片专属上限与超时、
页级请求头（`PageRef.headers`，防盗链常要 `Referer`）、
**识别「200 + HTML 错误页」**（只拒绝 `text/*`、`html`、`json`、`xml`，
不搞 `image/*` 白名单——很多图床返回 `application/octet-stream` 甚至不带类型）。

### 3.19 浏览界面：状态在模型里，视图只画（M2 第六批）

浏览链路的层次：

```
BrowseView（源列表，读 visibleInstalledSources）
├── RepositoryManagerView（加/删仓库、列可装源、安装与更新）
└── SourceBrowseView（热门 / 搜索 + 翻页）  → SourceMangaDetailView（详情 + 章节）
```

两个刻意的取舍：

- **列表状态放在 `SourceBrowseModel`**（`@Observable`），而不是视图的 `@State`。
  翻页、失败保留、末页不再请求、并发去重这些规则用单元测试钉住；
  视图只负责画。模型通过 `Loader` 闭包注入「怎么取第 N 页」，
  因此测试不需要 JavaScriptCore。
- **搜索在「提交」时才发请求**：输入框绑定 `query`，驱动加载的是
  `submittedQuery`。把输入框直接接到 `.task(id:)` 上会让每个字符都打一次网络，
  既是无谓流量，也会让结果列表来回闪。

本批**不包含在线阅读**：它要求阅读器支持异步取图，随下载一起做。
在那之前，来源作品的章节列表是只读展示 + 页脚明确说明，书架里的在线作品
在阅读器里给出明确提示（而不是抛一个「归档损坏」的底层错误）。


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
| SwiftSoup | 源脚本 HTML 解析桥 | MIT | **不引入**：HTML 解析与 CSS 选择器已零依赖自研（见 §3.12），少一个依赖就少一份供应链风险 |

引入新依赖前请同步更新本表、`NOTICE` 与 `README`。

## 6. 相关文档

- 源 API 契约：`docs/source-api.md`
- 构建与发布：`docs/development.md`
- 测试规范：`docs/testing.md`
- 贡献规范：`CONTRIBUTING.md`
