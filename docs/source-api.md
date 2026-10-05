# 源 API 契约 v1 / Source API Contract

> **状态**：v1.0 草案（`0.1.0` 工程版本）。
> v1.0 冻结后，`1.x` 内**只增不改**；破坏性变更走 `2.0`（见 §11）。
>
> **范围**：本文件是本项目对源生态的**唯一官方产出物**——只定义接口规范，
> **不提供、不收录、不分发任何源脚本**。源由第三方社区各自编写与托管。
>
> **实现状态标注**（阅读时请注意）：
> - ✅ **已实现并冻结**：§3 仓库格式、§4 脚本与静态校验、§5 方法契约（静态预检部分）；
>   对应 `Packages/SourceEngine/Sources/SourceEngine/`。
> - 🚧 **M2 实现中**：§7 桥接能力的运行期落地（JavaScriptCore 沙箱）、§8 登录收割。
>   接口形态已冻结，实现落地前源作者可先按本文件编写。

---

## 1. 术语

| 术语 | 含义 |
|---|---|
| **源（source）** | 一个 `.js` 文件，描述如何从某个内容站点取作品/章节/页 |
| **仓库（repository）** | 一个可访问的 HTTP 目录，含 `index.json` 与若干 `.js` |
| **宿主（host）** | App 本体，负责沙箱执行、网络、Cookie、限流、UI |
| **契约（contract）** | 本文件定义的元信息字段、方法签名与桥接能力 |

---

## 2. 总览：一次数据流

```
用户添加仓库 URL
      ↓  GET index.json（≤1MB，≤500 条）
  列出可装源（NSFW 源默认隐藏）
      ↓  用户点安装 → GET <repo>/<fileName>
 静态校验（不执行脚本）→ 落盘 Sources/<key>.js + 写 installed.json
      ↓  用户在 UI 选择源
运行期：载入脚本 → 调用 getPopularManga / getSearchManga … → 返回 JSON
      ↓
宿主转换为 Manga / Chapter / ComicPage 模型 → 阅读器 / 下载 / 翻译
```

---

## 3. 仓库格式

### 3.1 目录结构

```
https://example.com/repo/
├── index.json      # 源清单（必需）
├── demo.js         # 一个源 = 一个单层文件
└── other.js
```

脚本地址由 `仓库地址` 的目录部分 + `fileName` 拼出，例如
`https://example.com/repo/index.json` → `https://example.com/repo/demo.js`。
**只支持 http/https 前缀的仓库地址**，其他 scheme 不生成下载地址。

### 3.2 `index.json`

```json
[
  {
    "name": "Demo",
    "fileName": "demo.js",
    "key": "demo",
    "version": "1.0.0",
    "description": "可选说明"
  }
]
```

| 字段 | 必填 | 约束（与实现一致） |
|---|---|---|
| `name` | 是 | 非空、去首尾空白后非空、≤200 字符 |
| `key` | 是 | 必须通过来源 ID 规则：小写字母/数字开头，仅含 `a-z0-9-_`，1–64 字符 |
| `version` | 是 | `1` / `1.2` / `1.2.3`，可带 `-pre` 后缀；正则 `^[0-9]+(\.[0-9]+){0,2}(-[0-9A-Za-z.-]+)?$` |
| `fileName` | 是 | 见 §3.3 |
| `description` | 否 | 空字符串会被归一化为「无说明」 |

**上限与失败行为**

| 项 | 上限 | 超限结果 |
|---|---|---|
| 索引体积 | 1 MB | 整份索引被拒绝 |
| 条目数 | 500 | 整份索引被拒绝 |
| `key` 重复 | 不允许 | 整份索引被拒绝 |

> 任何一条不合法 → **整份索引被拒绝**（不做部分接受）。这样源作者能立刻发现问题，
> 不会出现"仓库里一半源悄悄装不上"的情况。

### 3.3 `fileName` 安全规则（防路径穿越）

必须同时满足：

- 长度 1–128；
- 以 `.js` 结尾；
- 不含 `/`、`\`；
- 不含 `..`；
- 不以 `.` 开头；
- 仅含 `A-Za-z0-9.-_`。

因此 `../../evil.js`、`sub/dir.js`、`.hidden.js`、`script.js.txt` 一律**被拒绝**。

---

## 4. 脚本与静态校验

### 4.1 元信息块

```js
const source = {
  id: "demo",                       // 必填
  name: "Demo",                     // 必填
  lang: "all",                      // 选填
  baseUrl: "https://example.com",   // 选填
  nsfw: false,                      // 选填
  version: "1.0.0",                 // 选填
  rateLimitMs: 0,                   // 选填
  loginUrl: "https://example.com/login" // 选填
};
```

| 字段 | 必填 | 约束 | 缺省 |
|---|---|---|---|
| `id` | 是 | 来源 ID 规则（小写字母/数字开头，`a-z0-9-_`，1–64） | — |
| `name` | 是 | ≤200 字符 | — |
| `lang` | 否 | ≤16 字符，BCP-47（`zh`、`ja`、`en`…）或 `all` | `all` |
| `baseUrl` | 否 | 必须是 https（本机调试允许 `http://localhost` / `127.0.0.1` / `[::1]`，不得含空格） | 无 |
| `nsfw` | 否 | `true` 的源**默认在 UI 隐藏**，需用户在设置里手动开启 | `false` |
| `version` | 否 | 同 §3.2 版本号规则 | 无 |
| `rateLimitMs` | 否 | 整数 0–60000，同源两次请求的最小间隔 | `0` |
| `loginUrl` | 否 | 同 `baseUrl` 的地址规则；声明后宿主提供内嵌网页登录 | 无 |

**布尔解析**：`true` / `yes` / `1` → 真；`false` / `no` / `0` → 假；其他或缺失 → 假。

**解析细节**（照此写才稳定）：

- 取脚本中**第一处** `source` 之后的、**花括号配平**的对象块（字符串内的花括号不计数）；
- 块内按 `键: 值` 浅层提取，键**大小写不敏感**（内部统一小写匹配）；
- 值可用 `"双引号"`、`'单引号'`、`` `反引号` `` 或裸值；
- 同名键**以第一次出现为准**；
- 允许嵌套对象（`extra: { a: { b: 1 } }`），但不读取嵌套字段。

### 4.2 拒绝清单（静态校验，**执行前**）

宿主在**不运行脚本**的前提下先做这些检查，任一命中即拒绝安装：

| 错误 | 触发条件 |
|---|---|
| `emptyScript` | 去空白后为空 |
| `tooLarge` | 超过 **512 KB** |
| `containsNullByte` | 含 `\0`（疑似二进制） |
| `missingMetadataBlock` | 找不到 `source` 对象块 |
| `missingField` | 缺 `id` 或 `name` |
| `invalidField` | `id`/`name`/`baseUrl`/`loginUrl`/`version`/`rateLimitMs`/`lang` 不符合 §4.1 约束 |
| `forbiddenAPI` | 出现 `eval(`、`Function(`、`WebAssembly`、`import(`、`require(` 之一 |

> 禁用动态求值与模块系统：源应当是**纯声明式 + `net` 请求 + 解析**，
> 不接受任何形式的代码加载或运行期求值（沙箱审计也会拒绝）。

### 4.3 必需方法的静态预检

宿主会检查脚本是否**声明**了 5 个必需方法（见 §5）。识别以下任一写法：

```js
function getName(...) {}      // 函数声明
const getName = ...           // 变量赋值（含 = async）
getName = function (...) {}   // 赋值表达式
getName: function (...) {}    // 对象属性
getName = async (...) => {}   // 箭头函数
```

缺失时 `SourceAPIContract.missingMethods(in:)` 会列出缺失项，
宿主给出「源未实现必需方法：…」并拒绝载入。

---

## 5. 方法契约

### 5.1 必需（5 个）

| 方法 | 参数 | 返回 |
|---|---|---|
| `getPopularManga(page)` | `page`：**从 1 开始**的整数 | `{ mangas: MangaLite[], hasNextPage: boolean }` |
| `getSearchManga(page, query, filters)` | `query`：字符串（可为空串）；`filters`：由 `getFilters()` 定义的键值对 | 同上 |
| `getMangaDetails(mangaUrl)` | 作品地址 | 作品详情对象（见下） |
| `getChapterList(mangaUrl)` | 作品地址 | `Chapter[]` |
| `getPageList(chapterUrl)` | 章节地址 | `string[]` 或 `PageRef[]` |

**作品详情对象**

```ts
{
  title: string,          // 必填
  url?: string,           // 选填，缺省用传入的 mangaUrl
  author?: string,
  artist?: string,
  description?: string,
  genres?: string[],
  status?: "unknown" | "ongoing" | "completed" | "licensed" | "cancelled" | "hiatus",
  coverUrl?: string
}
```

### 5.2 可选（2 个）

| 方法 | 说明 |
|---|---|
| `getLatestUpdates(page)` | 最新更新列表。缺失时宿主回退到热门列表 |
| `getFilters()` | 返回筛选项数组，宿主自动渲染搜索界面 |

```ts
type Filter =
  | { type: "text";     key: string; name: string }
  | { type: "checkbox"; key: string; name: string }
  | { type: "select";   key: string; name: string; options: { label: string; value: string }[] }
  | { type: "sort";     key: string; name: string; options: { label: string; value: string }[] };
```

`getFilters()` 是**同步**的（不发起网络请求），宿主在渲染搜索页前调用一次。

### 5.3 语义要求（容易被忽略，但影响体验）

1. **`url` 必须在同一源内稳定且唯一**。宿主的作品主键是
   `"<sourceID>|<url>"`、章节主键是 `"<mangaID>|<url>"`——
   `url` 变化会导致书架里出现重复条目、阅读进度丢失。
2. **分页从 1 开始**，`hasNextPage` 表示"还能继续翻"。返回空数组时
   `hasNextPage` 应为 `false`，避免死循环。
3. **空结果是合法的**，不要抛错：`{ mangas: [], hasNextPage: false }`。
4. **`getPageList` 的顺序即阅读顺序**，不要依赖宿主排序。
5. 需要 Referer / User-Agent 的图片，用 `PageRef` 逐个声明 headers：
   ```ts
   { url: "https://example.com/1.jpg", headers: { "Referer": "https://example.com/" } }
   ```
6. 单页图片建议 ≤20 MB（宿主默认上限），超限该页判失败。

### 5.4 数据结构与宿主模型映射

```ts
type MangaLite = { title: string; coverUrl?: string; url: string };
type Chapter   = { name: string; url: string; chapterNumber?: number; dateUpload?: string };
type PageRef   = { url: string; headers?: Record<string, string> };
```

| 契约字段 | 宿主模型 | 备注 |
|---|---|---|
| `MangaLite` | `Manga` | `id = "<sourceID>|<url>"` |
| `Chapter` | `Chapter` | `id = "<mangaID>|<url>"`；`dateUpload` 用 ISO8601 字符串 |
| `PageRef` / `string` | `ComicPage` | `index` 由宿主按数组顺序赋值（从 0 开始） |

---

## 6. 宿主行为（源作者需要知道的）

| 行为 | 说明 |
|---|---|
| 静默期 | `rateLimitMs` 生效于该源的所有请求（不含图片直链下载） |
| 请求超时 | 桥接层单请求 15 秒 |
| 调用超时 | 单次方法调用 10 秒（`SourceRuntimeConfiguration.callTimeoutSeconds`） |
| 响应上限 | 单次调用返回数据 ≤4 MB；单页图片 ≤20 MB |
| 重试 | 宿主对可重试错误（超时/离线/429/5xx）按退避重试；4xx 不重试 |
| 失败隔离 | 源抛错不会崩 App：该源标记为「不可用」并写入诊断日志 |
| NSFW | `nsfw: true` 的源默认隐藏，用户需先确认年满 18 岁才能看到 |
| 缓存 | 宿主自行缓存封面/页图与译文，源不需要关心 |

---

## 7. 桥接能力（宿主注入，接口已冻结）

| 调用 | 说明 | 状态 |
|---|---|---|
| `net.get(url, headers?)` | 自动带该源 Cookie、受 `rateLimitMs` 节流、15 秒超时 | 🚧 M2 |
| `net.post(url, body, headers?)` | 同上 | 🚧 M2 |
| `html.parse(body)` | 返回可查询对象（CSS 选择器），用于 HTML 站点 | 🚧 M2 |
| `json.parse(text)` | 原生 JSON 解析 | 🚧 M2 |
| `cookies.get(name)` / `cookies.set(name, value)` | 仅能读写**本来源**的 Cookie 容器 | 🚧 M2 |
| `log(message)` | 写入 App 诊断日志（排查用） | 🚧 M2 |
| `source.getPreference(key)` | 读取用户在源设置页填写的值 | 🚧 M2 |

**沙箱约束**：不能访问文件系统、钥匙串、其他源的数据；不能发起未经 `net` 的请求；
不能动态加载或执行代码（见 §4.2）。

---

## 8. 登录与人工验证

1. 源声明 `loginUrl` 后，宿主在源详情页显示「登录」按钮；
2. 用户在内嵌网页完成登录，宿主把 Cookie 收割到**该源独立容器**；
3. 遇到需人工验证的站点，宿主会在必要时弹出内嵌网页，完成后把验证 Cookie
   交回同一容器；
4. 源无需自己实现登录流程，直接调用 `net.*` 即可（Cookie 由宿主自动带上）。

---

## 9. 错误语义

宿主运行期错误类型（`SourceRunnerError`）：

| 错误 | 含义 | 源作者该如何处理 |
|---|---|---|
| `notInstalled` | 该 key 未安装 | — |
| `incompleteContract` | 缺少必需方法 | 补齐 §5.1 的 5 个方法 |
| `scriptRejected` | 静态校验未过 | 按 §4.2 修正后重新发布（提升 `version`） |
| `executionTimeout` | 超过调用超时 | 减少单次请求数量、给分页加 limit |
| `executionFailed` | 脚本抛错 | 保证 `getPageList` 等返回结构合法 |
| `invalidResponse` | 返回结构不符契约 | 对照 §5.4 检查字段名与类型 |
| `cancelled` | 用户取消 | — |

**容错要求**：单个字段缺失应尽量给出合理缺省（如无 `coverUrl`），
而不是整次调用失败。

---

## 10. 安全要求（硬性）

- 不得包含 §4.2 的禁用 API；
- 不得尝试读写宿主文件系统 / 钥匙串 / 其他源数据；
- 不得在 `fileName`、`key`、`url` 中构造路径穿越；
- 不得把用户凭据写在脚本里（登录一律走 §8 的宿主 Cookie 容器）；
- 不得请求非内容用途的地址（如上传、遥测）。

---

## 11. 版本策略

| 变更 | 处理 |
|---|---|
| 新增可选字段 / 新方法 | 在 `1.x` 内直接加，必须带安全缺省值 |
| 修改既有字段语义 | 需走 `2.0`，宿主同时支持 v1 一段时间 |
| 契约版本号 | `SourceAPIContract.version`（当前 `1.0`） |
| 源自身版本 | 元信息 `version`；仓库 `index.json` 的 `version` 用于提示更新 |

---

## 12. 完整示例源

下面这个示例**通过静态校验、实现了全部必需方法**，可直接作为骨架使用。
它由 `tools/check_docs_sync.py` 与测试夹具（`SourceAPIDocTests.swift`）逐字比对，
两端任意一侧被改动都会在预检阶段报警。

```js
// canonical-example：与测试夹具逐字一致，勿单独修改
const source = {
  id: "demo",
  name: "Demo Source",
  lang: "all",
  baseUrl: "https://example.com",
  nsfw: false,
  version: "1.0.0",
  rateLimitMs: 500,
  loginUrl: "https://example.com/login"
};

async function getPopularManga(page) {
  const response = await net.get(source.baseUrl + "/popular?page=" + page);
  const doc = html.parse(response.body);
  const mangas = doc.select("div.item").map(function (node) {
    return {
      title: node.select("a.title").text(),
      coverUrl: node.select("img").attr("src"),
      url: node.select("a.title").attr("href")
    };
  });
  return { mangas: mangas, hasNextPage: doc.select("a.next").length > 0 };
}

async function getLatestUpdates(page) {
  const response = await net.get(source.baseUrl + "/latest?page=" + page);
  const doc = html.parse(response.body);
  const mangas = doc.select("div.item").map(function (node) {
    return {
      title: node.select("a.title").text(),
      coverUrl: node.select("img").attr("src"),
      url: node.select("a.title").attr("href")
    };
  });
  return { mangas: mangas, hasNextPage: doc.select("a.next").length > 0 };
}

async function getSearchManga(page, query, filters) {
  const url = source.baseUrl + "/search?q=" + encodeURIComponent(query) + "&page=" + page;
  const response = await net.get(url);
  const doc = html.parse(response.body);
  const mangas = doc.select("div.item").map(function (node) {
    return {
      title: node.select("a.title").text(),
      coverUrl: node.select("img").attr("src"),
      url: node.select("a.title").attr("href")
    };
  });
  return { mangas: mangas, hasNextPage: false };
}

async function getMangaDetails(mangaUrl) {
  const response = await net.get(mangaUrl);
  const doc = html.parse(response.body);
  return {
    title: doc.select("h1.title").text(),
    url: mangaUrl,
    author: doc.select("span.author").text(),
    description: doc.select("div.summary").text(),
    genres: [doc.select("span.genre").text()],
    status: "ongoing",
    coverUrl: doc.select("img.cover").attr("src")
  };
}

async function getChapterList(mangaUrl) {
  const response = await net.get(mangaUrl);
  const doc = html.parse(response.body);
  return doc.select("ul.chapters li").map(function (node) {
    return {
      name: node.select("a").text(),
      url: node.select("a").attr("href"),
      chapterNumber: 0,
      dateUpload: node.attr("data-date")
    };
  });
}

async function getPageList(chapterUrl) {
  const response = await net.get(chapterUrl);
  const doc = html.parse(response.body);
  return doc.select("div.page img").map(function (node) {
    return node.attr("data-src");
  });
}

function getFilters() {
  return [
    { type: "text", key: "author", name: "作者" },
    { type: "select", key: "genre", name: "分类", options: [{ label: "全部", value: "" }] },
    { type: "sort", key: "sort", name: "排序", options: [{ label: "最新", value: "latest" }] }
  ];
}
```

> 注意：`net` / `html` / `json` / `cookies` / `log` 由宿主注入，**不要**在脚本里
> 尝试声明或引入它们（会出现 `require(` / `import(` 而被拒绝）。

---

## 13. 发布前自检清单

- [ ] 脚本 ≤512 KB，不含空字节；
- [ ] 不含 `eval(` / `Function(` / `WebAssembly` / `import(` / `require(`；
- [ ] `id` 与仓库 `index.json` 的 `key` 完全一致；
- [ ] `baseUrl` 为 https（或本机调试地址）；
- [ ] 5 个必需方法齐全，且各自的返回结构符合 §5.4；
- [ ] `MangaLite.url` / `Chapter.url` 在同一源内稳定唯一；
- [ ] 分页从 1 开始，末页 `hasNextPage` 为 `false`；
- [ ] 成人内容源声明 `nsfw: true`；
- [ ] 请求频繁的站点声明合理的 `rateLimitMs`；
- [ ] 提升 `version`（宿主据此提示用户更新）。

## 14. 如何验证自己的源

1. 本地跑通静态校验：安装到 App 后能出现在「浏览 → 已安装的源」即表示
   §4 全部通过；失败时诊断日志（设置 → 诊断日志）会给出具体拒绝原因。
2. 仓库发布前，可用本项目的测试夹具方式自查：
   `MangaTranslaterTests/SourceAPIDocTests.swift` 演示了如何对一份脚本做
   「静态校验 + 必需方法预检 + 元信息字段断言」。
3. 修改 `docs/source-api.md` 中的示例后，请同步更新测试夹具，
   否则 `tools/preflight.sh` 的文档同步检查会失败。
