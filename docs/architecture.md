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

在线阅读在 §3.20 接入：章节行直接进阅读器。


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

### 3.20 阅读数据来源：阅读器只有一个入口（M2 第七批）

阅读器需要的三件事——章节列表、页列表、页图字节——被收进一个协议：

```swift
public protocol MangaReadingSource: ChapterListProviding, PageDataProviding {}
```

于是阅读器里**没有任何「本地还是在线」的分支**，两端的差异在实现里消化：

| | `LocalReadingSource` | `RemoteReadingSource` |
|---|---|---|
| 章节 / 页 | `LocalSource` 同步 API | 源脚本 `getChapterList` / `getPageList` |
| 页图 | 归档解压 | `SourceImageLoader`（20 MB、Referer、Cookie） |
| 线程 | 内部 `Task.detached`（解压不能占主线程） | 并发 `withTaskGroup` |
| 缓存 | 不需要（数据在沙盒里） | 章节 / 页列表 LRU（各 8 / 16 条） |

三个刻意的决定：

- **本地解压放到后台**：阅读器的加载入口跑在主线程（SwiftUI 的 `.task`），
  大归档直接同步解压会把耗时算进主线程——本地翻页卡顿的来源就是它。
- **在线缓存要能按来源失效**：脚本更新后旧结果就是错的。
  `invalidate(sourceID:)` 按主键前缀（`"<sourceID>|"`）清，
  安装 / 更新 / 卸载源之后由 App 调用。
- **`imageData` 标 `nonisolated`**：这条路完全不碰 actor 状态（缓存里只有元数据），
  而图片下载可能持续几百毫秒，没必要让它们排队经过同一个 actor。

阅读器侧的两个配套规则：

- **预加载要能取消**：换页 / 换章时先取消上一次预加载任务，否则快速翻页会把
  多批下载叠起来；并发取窗口内的页，单页失败只跳过该页。
- **只有作品在书架里才写进度**：`updateProgress` 对不在书架的作品会抛
  `entryNotFound`，翻一页记一条失败日志毫无意义。因此阅读器顶部放了星标按钮，
  一键加入书架后立即开始记录（并顺手记一次当前进度）。

### 3.21 下载与离线阅读：归档是唯一的「完成」标志（M3 第一批）

下载链路的编排在应用层（`DownloadCoordinator`），队列本身（`DownloadQueue`）
只知道「给定页列表 → 逐页抓取落盘」。分开的理由是队列不该知道：
页列表从哪来（要调脚本，可能失败）、下完的散图要变成什么、哪些章节该跳过。

**一、下完就打包成 CBZ，而不是留一堆散图。**

```
抓取 → <scratch>/<chapterID>/0001.jpg …
     → 归档 → <Downloads>/<manga 目录>/<chapter 文件>.cbz + 同名 .json 清单
     → 清掉散图
```

好处有三：离线阅读与用户自己导入的本地漫画**走同一条代码路径**（同一套阅读器、
封面、章节排序）；「这一章下完了没有」可以靠「文件在不在」判断，
而不是猜「文件数 == 页数」；用户要导出时不必再打一次包。

清单（`.json`）与 CBZ 分开存：清单给列表与统计用，读一页不必解清单；
而清单丢了还能靠 CBZ 里的真实条目数兜底——**能读出来的页才是真能看的页**。

**二、文件名 = 可读部分 + 稳定哈希。**

主键形如 `<sourceID>|<url>`，含 `/`、`:`、`|` 等不能进文件名的字符。
只做可读化会撞名，只做哈希则无法人工排查，所以两者都要。
哈希**必须自己实现**（FNV-1a）：`String.hashValue` 每次进程启动都不同
（Swift 的哈希随机化），用它命名等于「这次写进去、下次找不到」。

**三、阅读侧「先归档、后网络」。**

`RemoteReadingSource` 拿到归档后：

| | 有归档 | 无归档 |
|---|---|---|
| 页列表 | 从归档读条目数，**不问脚本** | 调脚本 `getPageList` |
| 页图 | 读归档 | 走 `SourceImageLoader` |

页列表必须走归档：脚本要联网，而下载的意义就是没网也能看。
归档页的定位符用私有 scheme（`manga-archive://`）而不是伪造 http 地址——
伪造地址一旦某条分支漏了拦截，就会真的朝一个不存在的域名发请求。

**四、来源知识留在接缝上。**

Cookie 与防盗链 `Referer` 都是**来源侧**的知识，而队列只有一个 `fetcher`。
接缝是 `JobAwarePageFetching`：抓取器从任务上读来源信息，
于是一个实例能服务队列里多个来源的任务（书架里 A 站和 B 站各下一话是常态）。
页级请求头（契约 §5.3 允许每页自带 `headers`）按 URL 存在任务上，
抓取时按 URL 取用，不必退化成「整章共用一个头」。

**五、失败与取消不留半成品。**

整章失败或用户取消 → 清掉散图、不留归档、任务标为终结态。
归档写入是先写临时文件再替换：直接覆盖时若中途失败，磁盘上会留下一个
**打不开的 CBZ**，而它看起来「已下载完成」。

### 3.22 自建服务器：把「数据从哪来」抽成 `MangaDataSource`（M3 第三批）

M3 之后数据来源有三种：社区脚本源、自建 Komga / Kavita 服务器、（以及本地文件）。
界面不应该认识这三种东西，于是有了统一接口：

```swift
public protocol MangaDataSource: Sendable {
    var sourceID: SourceID { get }
    func popularManga(page: Int) async throws -> MangaListPage
    func latestUpdates(page: Int) async throws -> MangaListPage
    func search(page: Int, query: String, filters: SourceFilterValues) async throws -> MangaListPage
    func mangaDetails(url: String) async throws -> Manga
    func chapterList(mangaURL: String, mangaID: String?) async throws -> [Chapter]
    func pageList(chapterURL: String) async throws -> [ComicPage]
    func filters() async throws -> [SourceFilter]
}
```

界面的分支因此全部消失：

| 位置 | 之前 | 现在 |
|---|---|---|
| 浏览列表 | 直接用 `SourceRuntimePool` | `MangaDataSource` |
| 作品详情 | 直接用 `SourceRuntimePool` | `MangaDataSource` |
| 阅读器 | `RemoteReadingSource(pool:)` | `RemoteReadingSource(provider:)` |
| 下载 | 闭包里调 `pool.withRunner` | 闭包里调 `provider.dataSource()` |

**路由必须显式。** `CompositeDataSourceProvider` 先问「这个 id 归谁」再调：

```swift
if hosted.knows(sourceID) { return try await hosted.dataSource(for: sourceID) }
return try await scripts.dataSource(for: sourceID)
```

如果改成「挨个 try、取第一个成功的」，那么「Komga 地址填错」会显示成
「源未安装」——排查方向完全错。错误必须指向真正出问题的地方。

**连接器的三条实现约定**（Komga / Kavita 都照此写）：

1. **宽容解析**：用 `JSONSerialization` + `Mapping` 取值助手，不用 `Codable`。
   自建服务器的版本差异比第三方 API 大得多（字段增删、`number` 从数字变字符串），
   严格模型会在用户升级服务器那天直接坏掉。
2. **映射即纯函数**：`KomgaMapping` / `KavitaMapping` 全是「字典进、模型出」，
   可以脱离网络单测。CI 里连不上真实的 Komga / Kavita，
   这类代码的错几乎都在「字段路径」，纯函数测试正好打这个点。
3. **认证头跟着请求走**：Komga 的图片接口同样要鉴权，所以页请求头随
   `ComicPage.headers` 一起返回；Kavita 的图片接口吃查询串 `apiKey=`，
   因此**错误文案与日志必须脱敏**（`LogRedaction`），否则密钥会顺着
   「HTTP 401：<带 apiKey 的地址>」写进诊断日志。

**页码基准不要猜。** Komga 的 `/books/{id}/pages` 返回的数组里带 `number`，
直接用它的值拼图片地址，而不是按数组下标自己算——
页码基准在 Komga 的版本间变过（0 起 / 1 起），猜错的后果是整章错位一页。

### 3.23 登录与人工验证：网页会话与 App 网络栈的接缝（M3 第四批）

契约 §8 要求：源自身不实现登录，用户在内嵌网页里登录，宿主把 Cookie 交回该源容器。
实现上只有三个部件：

```
WKWebView（非持久化数据存储）
   ↓ 用户点「完成」
CookieHarvest（按主机过滤 + 覆盖写入）
   ↓
CookieJar（来源独立的容器） → 之后 net.* 请求自动带上
```

**一、网页会话必须与 App 的网络栈隔离。**

`WKWebsiteDataStore.nonPersistent()`：网页里访问过的所有站点的 Cookie、缓存、
localStorage 全部只活在这一次会话里，关掉就没了。要什么就显式收割什么。
用持久化存储的话，「打开过哪些网页」会悄悄留在 App 的数据里，
而这些是**别的站点**（第三方登录、CDN、统计）的会话。

**二、收割要按主机过滤。**

登录过程会顺带访问第三方域。全收等于「登录 A 站，顺带把 B 站的凭据存进 A 的容器」。
规则：同主机、或本主机是其子域的域，才收；空域（来源通用）收；
其余丢。另外过期 Cookie 不收、同名同域同路径的先去重（让计数准确）。

**三、重复登录必须覆盖旧凭据。**

「重新登录」的语义是用新身份覆盖旧的。若留着旧 session，请求会带两个同名 Cookie，
服务端行为不可预测。所以写入前先清空该来源的容器——但要**先确认这次收到了东西**
（收 0 条时清空会让用户在「打开网页却没登录」之后丢掉原本可用的凭据）。

**四、人工验证要能被识别出来。**

Cloudflare 的校验页对普通请求返回 `503` + 一页 HTML，看起来就是「请求成功但没有内容」。
不识别的话，用户看到的是「这个源没有返回任何作品」，而真正原因是「需要在浏览器里点一下」。
`ChallengeDetector` 只看三类状态码（403 / 429 / 503）**且**正文里出现厂商标记
（`cf-chl-`、`just a moment`、`g-recaptcha`…）才判定：

- 只看状态码：所有 503 都会被当成验证页；
- 不看状态码：页脚写着「Powered by Cloudflare」的正常站点会被误伤。

两者都看，才能既不漏也不误。识别到之后，来源页的失败状态里直接给出
「打开网页验证」按钮，而不是让用户自己猜。

### 3.24 下载的「后台」到底能做到什么（M3 收尾）

iOS 不给普通进程无限的后台运行时间。于是有两个选择：

1. 把取页整条链路改成 `URLSession` 的后台传输（由系统进程驱动）；
2. 用 `beginBackgroundTask` 申请一小段时间，把手上这批跑完。

本项目选 2，原因是下载不是「一堆独立的 GET」：它是
「脚本先算出页列表（要 JS 沙箱）→ 宿主逐页抓取 → 打包成 CBZ」，
中间两步没法交给系统进程。硬上后台传输只会得到一条走不通的链路。

于是 `BackgroundExecutionKeeper` 在驱动循环外圈一层申请 / 归还：

```swift
beginBackgroundWork()
defer { endBackgroundWork() }
while true { ... }        // 跑完待办为止
```

两条纪律：

- **必须归还**。系统收回时间前不调 `endBackgroundTask`，进程会被**强杀**，
  已抓取的页连同散图一起丢掉——白下载一场。
- **文案不能吹**。界面上说的是「下载在后台进行，可以离开这一页」，
  而不是「关掉 App 也会继续」。几十秒与无限期是两件事，
  承诺前者做不到的事情，用户会记住。

### 3.25 页内翻译：一个「页图进、页图出」的纯函数（M4 第一批）

翻译链路的形状是刻意选成这样的：

```
页图 ──OCR──→ 文本行（含归一化坐标与竖/横排）──翻译──→ 译文数组
                                                       │
页图 ────────────────────排版回填──────────────────────┘
      ──→ 带译文的整页图
```

也就是说：**输入一张图，输出一张图**，中间所有东西（文本行、译文）都是过程产物。
这个形状带来三个好处，也是这一层能独立成模块的原因：

1. **翻译不碰阅读器的任何状态**。阅读器只管「第 N 页的图」，翻译把它换掉即可，
   于是本地文件、在线来源、已下载归档三种来源共用同一套翻译实现。
2. **每一步都能单独测**。OCR 用合成页 + 金标准夹具；排版是纯几何计算；
   译文解析是纯字符串处理——都不需要起模拟器、也不需要真模型。
3. **缓存键天然是「作品 + 页号」**。译文图与原图一一对应，
   不需要引入内容哈希（那会把「同一话不同来源压缩参数不同」也算成不同页）。

**合并去重而不是二选一。** OCR 同时跑现代（`RecognizeTextRequest`，自动语言检测）
与传统（`VNRecognizeTextRequest`，指定语言 + 系统语言）两套 API，再按 IoU 0.4 合并，
重复时保留置信度更高 / 更长的一条。理由：两套 API 的漏检位置不一样，
合并只增加召回、不会覆盖彼此；而「选一套」意味着要赌某一套在某一类页面上更好。

**竖排判定必须换算成像素纵横比。** Vision 给的是**归一化**包围盒（原点在左下），
在非正方形页面上，归一化的「高 > 宽」并不等于像素层面的「高 > 宽」。
页面越窄长，竖排文字框在归一化坐标下越接近正方形，直接用归一化比值判就会漏。
因此判定式里带上页面纵横比修正，并把「单字符无法判方向」显式按横排处理。

**额度是这条链路里唯一的「外部成本」，因此它的默认值必须保守。**
看图的预加载窗口默认前后各 10 页，但翻译预取窗口默认只有前后各 2 页：
看图免费，翻译按页计费。把两个窗口做成同一个数值，会让用户一开翻译就烧掉一天的免费额度。

### 3.26 额度用尽不能打断阅读（M4 第二批）

翻译失败有两类，界面上的处理**必须分开**：

| 类别 | 例子 | 界面 |
|---|---|---|
| 临时故障 | 网络抖、上游 5xx、识别不到文字 | 顶部可点掉的失败横幅 |
| 额度问题 | 免费额度用尽、订阅到期 | 顶部横幅 + **「升级云服务」入口** |

把它们混成一个「翻译失败」提示，用户会以为是坏了，反复重试；
而真正该做的是「升级」或者「改用自备密钥」。
因此在编排器里额度类错误走独立的 `quotaMessage`，界面据此给入口——
但**不弹窗、不中断**：阅读是主线，翻译是附加功能，附加功能不该抢走屏幕。

另外两条：

- **并行度是硬约束**：现代 Vision 并行超过 2 个会死锁，Apple 端上翻译一次只支持一个会话。
  因此上限分别是 2 / 1，且不是可调参数。
- **失败页不再反复试探**：失败页记进 `cacheProbe`（「已探过，确实没有」），
  否则每次界面刷新都会去磁盘查一次不存在的缓存文件。

### 3.27 对话式翻译的「文本出口」：BYOK 与云服务为什么必须同构（M4 第三批）

三条翻译后端（自备密钥 / 云服务 / 设备端）走的是同一个协议，只有一处 `switch`。
其中「自备密钥」与「云服务」的**提示词与解析规则刻意保持一致**：

- 提示词不同 → 同一页在两种模式下翻出来的风格不同，用户会归因成「云服务更差」；
- 解析规则不同（比如对代码块围栏的容忍度）→ 一种模式能过、另一种报错。

两边的**分块**也是同一套：一页几十行对白整批发过去可能顶到上下文上限，
模型丢掉一部分就变成条数不符、整页失败。按 40 行切块再按原顺序拼接，
单块失败只影响该块，而且顺序永远与输入一致（排版依赖这个顺序）。

客户端的错误也统一到一套语义：`CloudError`（HTTP 层）→ `TranslationError`（翻译层）。
于是编排器只认识「未登录 / 额度用尽 / 需要订阅 / 其它」四种情况，
不必分别处理「HTTP 401」和「服务端说了 unauthorized」这两种说法。

### 3.28 服务端：只有文本过境，且这条承诺由表结构保证（M4 第五批）

服务端独立成仓库（私有），公开仓库里只留接口契约 `docs/cloud-api.md`。
它有两条不对称的设计：

**一、能装下敏感数据的地方一律不存在。** `schema.sql` 里只有五张表：
账号、验证码、额度计数、订阅权益、webhook 去重。
没有任何一列能放下原文、译文、图片或作品 URL——也就是说，
**即使有人拿到了数据库，也拿不到用户在看什么**。这条承诺不靠纪律，靠表结构。
测试里有一条断言把它钉死：翻译过后把全库所有行倒出来，
原文与译文都不出现在任何字段里。

**二、能不用定时任务的地方一律不用。** 两处都因此消掉了：

- 额度按 `(account_id, day_key)` 分行记账（`day_key` = UTC+8 自然日），
  「重置」就是换一行，旧行天然成为历史；
- 订阅只存一个 `expires_at`，「是不是 Pro」由**读取时**与当前时间比较得出
  （`effectivePlan`）。存成布尔值的话，就需要一个定时任务去把它翻回来，
  而那个任务一旦停摆，用户就会一直免费或者一直付费。

**计费放在翻译成功之后**：上游失败却扣了额度，是最容易招致投诉的那类 bug。
**webhook 按事件 ID 去重**：Lemon Squeezy 一定会重投，没有去重，
「取消订阅」被处理两次就可能把状态改错。

本地闭环测试（`test/closed-loop.test.mjs`，20 条）用 `node:sqlite` 跑**真实的
schema**，把「注册 → 额度 → 翻译 → 下单 webhook → 权益提升 → 额度重置」走完，
因此这套服务端逻辑在没有任何 Cloudflare 账号的情况下也是可验证的。

### 3.29 文案表必须在包内，而不是只在 App 里（M5 第一批）

「中英双语」这件事看起来只是翻译几百条字符串，实际暴露的是一个**分层错误**：

`AppCore` / `ComicNet` / `SourceEngine` / `ComicDownload` / `AppDatabase`
是纯 Foundation 包，依赖方向不允许反向引用 App 目标，因此它们拿不到 App 的
`L()`。于是这些包里的错误文案只能是硬编码中文——而它们是**用户可见的**：
源加载失败、归档损坏、下载失败的原因都会原样显示在界面上。
结果就是「英文界面里冒出中文句子」，而且编译器与本地检查器都看不见。

修法不是「在 App 里再包一层翻译」，而是**把文案表下沉到包**：

```
Packages/AppCore/Sources/AppCore/Resources/{en,zh-Hans}.lproj/Localizable.strings
        ↑ 由 SwiftPM 作为资源包（Bundle.module）打进 App
AppCore.Copy.text("…") / Copy.format("…", …)
        ↑ 包内唯一文案出口；五个包共用这一张表（都依赖 AppCore）
```

三处刻意的选择：

1. **漏声明就是编译错误。** `Package.swift` 里没有
   `resources: [.process("Resources")]` 时，`Bundle.module` 直接编译不过。
   「文案表没打进 App」应该是构建期问题，而不是上线后用户看到一串 key。
2. **查不到 key 时返回 key 本身**，返回 `"error.net.timeout"` 而不是空串或英文兜底：
   丑但可诊断；静默显示一句看似正常的话才是真正难查的那类问题。
3. **模型层不再持有任何文案。** 7 个 `displayName`（阅读模式、主题、翻译后端、
   语言、排序、验证种类、服务器品牌）里，前六个移到 App 层
   `Localization+Names.swift` 用 `L("…")` 提供 `localizedName`；第七个
   （`HostedServerKind`）其实是产品名，改名 `brandName` 并注明**不翻译**。
   唯一的例外是 `TranslationLanguage.promptName`：它是**给模型看的固定词表**，
   必须与设备语言无关——否则同一个页面在两台语言不同的设备上会产生不同请求，
   「同一话翻译结果不一样」将无从复现。这种情况用行内 `// i18n-exempt` 显式豁免。

配套的两个新检查（见 3.32）把这件事变成机械可验证的：包层不得再长出硬编码文案，
两张表的 key 不得互串。

### 3.30 法务文本只有一份事实来源（M5 第二批）

隐私政策/使用条款有三份载体，任何两份分叉都是对用户的误导
（App 里的那份说「不保存图片」，官网上的那份没说，用户就不知道信哪个）：

```
docs/legal/*.md ──(check_legal_sync.py --emit)──→ App 内置副本（Swift 常量）
                └─(build_website.py)────────────→ 官网 HTML
```

- **单一事实来源是 Markdown**，两个下游都是生成物；
- 生成物被**逐字校验**（`check_legal_sync.py` 与 Swift 侧的
  `LocalizationAndLegalTests` 各钉一遍——前者管推送前，后者管 CI）；
- 法务文本为什么必须**内置**而不是只放官网：本 App 是侧载分发的，
  不能假设用户此刻能上网，而「要不要登录云服务」恰恰是最需要当场看到隐私政策的时刻。

App 内用一个「够用就好」的 Markdown 渲染器（`LegalDocumentView`）：
标题、小节、列表、两列表格、代码块五种结构覆盖了法务文本的全部形态，
不引入任何 Markdown 依赖——侧载 App 的价值之一是依赖越少越好。
另外三条合规文本本身的要求也写进了正文：**不存图**、**作品地址不上传**、
**账号注销入口**（后者连服务端一起实现，见 3.31）。

### 3.31 注销账号：与「退出登录」是两件事（M5 第二批）

手册 10.3 要求「账号注销入口」。实现上有三个判断值得记下来：

- **两个动作必须分开且分列两处**：退出登录 = 清本机会话（可恢复，用同一邮箱
  重新登录即回来）；注销账号 = 服务端删号（不可恢复）。把两者混成一个按钮，
  用户会误删。
- **注销要二次确认，而确认方式是「再打一遍邮箱」**：一个被盗的令牌不该能一键毁号；
  对本人来说这几乎是零成本。服务端也会再校验一次，不一致直接 `400 email_mismatch`
  且**什么都不删**。
- **逐表显式删除，不依赖外键级联**：D1 的 `PRAGMA foreign_keys` 是连接级开关，
  把「删干净」赌在一个容易被忽略的设置上太脆。删除范围是 `account` + 该账号的
  `usage` / `entitlement` + 该邮箱残留的 `login_code`——最后一项最容易被漏：
  不清验证码的话，注销后短时间内还能用旧码登录，等于注销没生效。

### 3.32 预检从 9 项长到 13 项（M5 贯穿）

M5 期间新增的四条规则，都来自「真实踩过」：

| 新规则 | 起因 |
|---|---|
| `check_hardcoded_copy.py` | 「英文界面出现中文」编译器看不见。字符集必须含**中日韩标点**：`"URL：\(value)"` 只有全角冒号、没有汉字，用纯汉字范围扫不出来（实测漏过一条）。放行 `diag` / `logSink`（读者是维护者），支持 `// i18n-exempt` 行内豁免并**打印豁免清单**——豁免要被看见，才不会变成后门 |
| `check_legal_sync.py` | 法务文本三份载体分叉 = 误导用户 |
| `build_website.py` | 官网必须双语标记齐备、相对链接存在、**不引外部资源**（要能离线打开，也不把访客行为送给第三方）；法务页重新生成以保持一致 |
| `check_altstore_source.py` | 清单生成脚本只在打 tag 时跑一次，写错的代价是「用户加不进源」且要重新发版。用**合成发布数据**离线跑一遍生成逻辑，把字段/排序/URL 形状/资源存在性挡在发版前 |

同时升级了两个既有工具：

- `check_localization.py` 从「单表四项」变成「双表七项」：两张表分开校验且 key
  不得重名（取错表的表现是界面上冒出一串 key）、**死文案**与**重复 key** 都报错
  （`.strings` 里重名的后一条静默生效，而这正是「追加文案」最常见的失误）、
  `String(format:)` 实参个数改用**括号配对**计数（嵌套调用
  `String(format: L("k"), L("a"), b)` 曾被正则数成 1 个）、**先剥注释再扫描**
  （文档注释里举例写的 `L("…")` 曾被当成真实引用，要求表里必须有一个叫 `…` 的 key）。
- `check_project.py` 新增「包内有 `.lproj` 时 manifest 必须声明 `defaultLocalization`」：
  CI 实测 SwiftPM 会在**依赖解析阶段**直接拒绝（`manifest property
  'defaultLocalization' not set`），连编译都走不到，而报错指向包清单、
  很难联想到「我加了本地化资源」。

### 3.33 截图也是「内容」，所以画而不截（M5 第四批）

AltStore 列表与官网都需要截图。截真机屏幕有两个问题：本地没有 Xcode（跑不起来），
而且真机截图会带上**用户自己的内容**——把别人作品的书名、封面截进公开仓库，
正是本项目红线要避免的那类事（`check_redlines.py` 能扫站点名，但扫不了图片）。

所以 `tools/make_screenshots.py` 用 Pillow 画三张完全虚构的界面示意
（虚构书名 `Sample Series A`、纯色封面块、示意用的对白条），
尺寸取 6.7" 档的 1290×2796。这样截图里既没有第三方内容，
也不依赖机器上装没装中文字形（正文一律英文）。

同理，AltStore 清单里的 `minOSVersion` **从 ipa 内的 `Info.plist` 读**而不是写常量：
它随工程设置变化，而「装不上」这个问题从报错里几乎看不出根因。

### 3.34 点击语义必须有归属：视图里只留一行调用（M6 前置）

「每个按钮点了会怎样」在别处都写在 `body` 里，那它就只有一种验证方式：人工点。
本次把这类判定全部搬进可测的层，分界线是一条很硬的判据——
**它能不能被 `#expect` 断言？不能，就说明它还欠一层。**

| 判定 | 现在住哪 | 为什么值得单独一层 |
|---|---|---|
| 点左/右窄带 = 前进还是后退 | `AppCore.ReaderNavigation` | 右到左模式把方向反过来，这是最容易写错、又最不容易发现的分支（点错了也「能翻页」） |
| 横滑够不够翻页、放大时是否只平移 | 同上 | 阈值与「放大不翻页」原先散在手势回调里，改一个数就可能让长按拖动误翻页 |
| 点击带该多宽 | 同上 | 原先写死 60pt：iPhone 竖屏勉强够，iPad / 横屏点不准 |
| 章节行左滑出哪个按钮 | `AppCore.ChapterActionMenu` | 7 种状态 → 1 个按钮；原先作品详情页与下载页各写一份 `switch`，漏掉 `.queued` 就变成「点了收不回来」 |
| 破坏性操作要不要确认 | `AppCore.DestructiveActionPolicy` | 第 11 节那张矩阵原本只存在于文档；现在它是**枚举 + 策略 + 测试**，同类操作不可能再分叉 |
| 筛选菜单有哪些项、选中项被删怎么办 | `AppCore.LibraryFilterMenu` | 「分类被删后停在空列表」是个只有用户撞上才会发现的 bug |
| 表单能不能保存、凭据留空是什么意思 | `SourceEngine.ServerFormValidator` / `ServerFormDraft` | 「空 = 不改」与「空 = 清空」两条相反的规则必须写在一处并写明 |
| 排序偏好认不出怎么办 | `LibraryPreferences`（App 层） | 认不出回退默认、而不是崩或清空 |

测试的组织方式与别处一致：**穷举而不是抽样**，并且把期望值写死成矩阵。
其中两条刻意设计的「会自己报警」的断言：

1. `DestructiveAction.allCases.count == 期望矩阵.count` —— 新增一个破坏性操作，
   计数先红，逼作者回来决定「它要不要确认」，而不是默认悄悄变成「不确认」。
2. `canSave(name:baseURL:) == issues(name:baseURL:).isEmpty`（4×5 全组合）——
   按钮的 `disabled` 条件是 `canSave` 的调用方，两者永不允许分叉
   （否则会出现「看着能点，一点就报错」）。

还有一个测试内部的 `ReaderSimulator`：把「点哪一侧 / 滑多远」按 `ReaderView.advance()`
的规则作用到 `ReaderSession` 上，于是**多步序列**也能断言——
「连点右侧 6 次跨章走到第二章末页」「第二章第一页往回翻落在上一章末页」。
单点规则对、串起来错，是另一类 bug，靠穷举单点覆盖不到。

### 3.35 探活的对象不能是「存储里的那条」（M6 前置发现的缺陷）

`HostedDataSourceProvider.dataSource(for sourceID:)` 按标识回 `ServerStore` 找配置——
这对「浏览」是对的，对「测试连接」是错的：

- **新增**时存储里还没有这条记录 → 必然抛 `notConfigured`，用户填的地址完全正确也测不通；
- **编辑**时记录存在，但拿到的是**旧地址 + 旧密钥** → 改完地址点测试会得到
  「能连上」的假结论。

两个症状一个根因：**探活的对象不是用户在屏幕上填的那份配置**。
所以新增 `dataSource(for server: HostedServer)`（不查存储），
`AppEnvironment.probeHostedServer` 改走它。这也解释了为什么 `ServerEditView` 的
头注释长期写着「保存时会先 probe」而实现里没有——真要 probe 就会立刻发现 prope 不了。

由此还带出一条界面规则：**探活失败不阻止保存**。内网服务器、临时维护中的服务器
都必须允许先存下来，所以失败时给的是「仍然保存？」而不是直接拒绝。
把「校验」（地址形状）与「可达性」（此刻连不连得上）分开，是这个界面唯一说得通的顺序。

### 3.36 破坏性操作的判据：误触的代价，而不是「是不是删除」（M6 前置）

四个判据任一成立就需要二次确认：**丢用户数据**（移出书架会一并丢掉阅读进度与分类归属）、
**要花钱才能恢复**（清空译文缓存）、**影响 ≥ 2 个对象**（取消全部下载）、
**销毁攒下来的离线数据**（删除单章归档——站点还在时能重下，站点没了就永久没了）。

反过来，能一键重来的都不问：取消单个任务、清除下载记录（不删文件）、
清空封面缓存（自动重建）、退出登录（同邮箱再登录）、清除源 Cookie（重新登录）。
确认弹窗泛滥的后果是用户闭眼点「确定」，那才是真正危险的状态——
所以「不加确认」也是一个需要论证的决定，而不是偷懒。

### 3.37 「不知道」必须是一等公民（O-7 检查更新）

书架下拉检查更新的输出是一个**角标**：用户只看到「3」，看不到它是怎么来的。
所以这个功能的全部风险都集中在「什么时候该写」上。

判定只有三种结果，其中「不知道」是刻意保留的一档：

```swift
public enum LibraryUpdateVerdict { case upToDate; case newChapters(count: Int); case unknown }
```

`.unknown` 的三个来源：没读过这部作品（未读是另一件事，界面用进度文案表达）、
上次读到的那一话已不在列表里（源改过标识）、两边都没有章节号
（**列表顺序不可信**——源换一次排序就能把整架作品标成「有新章节」，用户从此不信这个角标）。

`.unknown` 与「拉取失败」的行为都是**原样保留原角标**。这条规则看起来保守，
但它是这个功能唯一说得通的默认：角标是用户决定「要不要点进去」的信号，谎报比不报更糟。
反过来，`.upToDate` 会**清零**角标——「确认没有新的」和「不知道」必须区分开。

顺带一个实现约束：`LibraryUpdateChecker` 的依赖是**闭包注入**（`loadChapters`），
因此它的测试不碰网络、不碰 JS 沙箱，只用一个字典就能把六种分支走完。

### 3.38 备份：凭据不进文件，恢复是合并（O-8）

两条硬规则，其余都是围绕它们的展开。

**一、凭据绝不进备份文件。** 备份会被丢进 iCloud、微信、邮件——它是那种会到处跑的文件；
而「凭据进钥匙串」是另一条规则（手册 §5.2），两者不能混。所以
`BackupServer` 只序列化 id / 类型 / 名称 / 地址，`HostedServer` 的
`apiKey` / `password` / `username` 一个都不进去。这条承诺由**专门用例**守着：
导出后直接在字节里搜那三个值——不靠代码注释承诺，靠测试。

**二、恢复是合并不是覆盖。** 分类按名字去重（忽略大小写与空白）、仓库取并集、
服务器按标识去重、**书架条目已存在的跳过**。最后一条是整个流程里唯一可能丢数据的地方
（本地那份带着更新的进度），所以它是显式规则 `BackupMerge.entriesToAdd`，
而不是某段循环里的顺带行为。设置是唯一的覆盖项，并且写在确认弹窗的文案里。

恢复的分类归属还需要一次**重映射**：新分类会拿到新标识（`createCategory` 自己生成），
所以条目的 `categoryID` 不能照抄，必须按名字重新对上；对不上的落回未分类——
而不是留下一个指向不存在分类的 ID。

文件格式刻意是**纯 JSON 且键有序**（`sortedKeys`）：用户可以自己打开看，
「这个备份里有什么」是个合理的问题；而且同样的数据每次导出字节完全一致，
可以用 diff 比较两份备份。

### 3.39 同一个设置两个入口 ⇒ 必须共用同一个组件（O-6）

阅读设置现在有两个入口：设置页，以及阅读器顶栏的 ⚙（手册 §8.2）。
这类「一个设置两个入口」最容易出的问题是**慢慢分叉**：
下次加一个开关只会加到其中一处，于是「在阅读器里改不了主题」这种问题会以
「用户以为是 bug」的形式回来。

所以设置项的实现只有一份：`ReaderSettingsSections`（只导出 `Section`，
因此既能放进设置页的 `List`，也能放进阅读器弹窗的 `Form`）。两个入口都引用它。

同理，阅读器顶栏的下载按钮**复用 `ChapterActionMenu`**：
未下载=下载、进行中=取消、已下载=提示——与章节行左滑、作品详情页同一套状态映射。
唯一的例外是「已下载」在顶栏不做删除：删归档是有确认流程的操作，
不该出现在阅读中的顶栏上（那里更适合「点错了也不会有后果」的动作）。

### 3.40 跳页输入：越界要钳制并说明，不能静默（O-11）

「跳到第 N 页」这句话里藏着三个决定，全部写在 `AppCore.ReaderJump` 里：

| 输入 | 决定 | 理由 |
|---|---|---|
| `12` | 1 基输入 → 0 基下标 | 用户看到的是「12 / 48」；转换只在一处发生，避免每个调用方各减一次 1 |
| `12 / 48` | 取斜杠前那半 | 这是从底部页码标签复制来的，是真实输入形态 |
| `１２` | 全角数字归一化 | 中文输入法下这是最常见的一种「我明明输了数字」 |
| `999`（越界） | **钳制到最后一页并说明** | 打错一位数字时，「跳到最后一页」比「弹个错然后什么都不做」更接近意图 |
| `abc` | 明确报错 | 不静默——静默的表现是「点了没反应」，用户只会以为按钮坏了 |

「钳制」而不是「拒绝」是这里唯一一个偏软的决定，代价是用户可能没意识到自己打错了，
所以钳制时必须同时给一句说明（`reader.jump.clampedLast`）。
