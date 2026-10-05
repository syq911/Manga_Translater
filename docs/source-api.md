# 源 API 契约 v1 / Source API Contract

> 状态：**草案（0.1.0）**。v1.0.0 冻结后只允许向后兼容地新增字段。
> 本文件是唯一官方产出物：本项目**只定义接口规范，不提供任何源脚本**。

## 1. 仓库格式

一个源仓库就是一个可访问的 HTTP 目录：

```
https://example.com/repo/
├── index.json      # 源清单
├── demo.js         # 一个源 = 一个 JS 文件
└── other.js
```

`index.json`：

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

| 字段 | 必填 | 约束 |
|---|---|---|
| `name` | 是 | ≤200 字符 |
| `fileName` | 是 | 单层文件名、以 `.js` 结尾、不含 `/` `\` `..`、≤128 字符 |
| `key` | 是 | 与脚本内 `id` 一致；小写字母/数字开头，允许 `-` `_`，1–64 字符 |
| `version` | 是 | `1` / `1.2` / `1.2.3`，可带 `-pre` 后缀 |
| `description` | 否 | 空字符串会被归一化为缺省 |

索引上限：1 MB / 500 条；违规条目会导致**整份索引被拒绝**。

## 2. 脚本结构

```js
const source = {
  id: "demo",                 // 必填，与仓库 key 一致
  name: "Demo",               // 必填，≤200 字符
  lang: "all",                // 选填，BCP-47 或 "all"
  baseUrl: "https://example.com", // 选填，必须是 https（本机调试可用 http://localhost）
  nsfw: false,                // 选填，true 的源默认在 UI 隐藏
  version: "1.0.0",           // 选填
  rateLimitMs: 0,             // 选填，0–60000，两次请求最小间隔
  loginUrl: "https://example.com/login" // 选填，声明后 App 提供内嵌登录
};
```

静态校验会拒绝：空脚本、超过 512 KB、含空字节、缺少 `source` 块、
缺少 `id`/`name`、非法 `id`/`version`/`baseUrl`/`rateLimitMs`，
以及包含 `eval(`、`Function(`、`import(`、`require(`、`WebAssembly` 的脚本。

## 3. 方法契约

### 必需（5）

| 方法 | 参数 | 返回 |
|---|---|---|
| `getPopularManga(page)` | `page`: 从 1 开始 | `{ mangas: MangaLite[], hasNextPage: boolean }` |
| `getSearchManga(page, query, filters)` | `query`: 字符串；`filters`: 由 `getFilters()` 定义 | 同上 |
| `getMangaDetails(mangaUrl)` | 作品地址 | `{ title, author?, artist?, description?, genres?, status?, coverUrl?, url }` |
| `getChapterList(mangaUrl)` | 作品地址 | `Chapter[]` |
| `getPageList(chapterUrl)` | 章节地址 | `string[]` 或 `{ url, headers? }[]` |

### 可选（2）

| 方法 | 说明 |
|---|---|
| `getLatestUpdates(page)` | 最新更新列表；缺失时 App 回退到热门 |
| `getFilters()` | 返回筛选项数组，App 自动渲染搜索界面 |

### 数据结构

```ts
type MangaLite = { title: string, coverUrl?: string, url: string };
type Chapter   = { name: string, url: string, chapterNumber?: number, dateUpload?: string };
```

## 4. 桥接能力（由宿主注入）

| 调用 | 说明 |
|---|---|
| `net.get(url, headers?)` | 自动带上该来源的 Cookie，受 `rateLimitMs` 节流，超时 15 秒 |
| `net.post(url, body, headers?)` | 同上 |
| `html.parse(body)` | 返回可查询对象（CSS 选择器） |
| `json.parse(text)` | 原生 JSON |
| `cookies.get(name)` / `cookies.set(name, value)` | 仅能访问本来源的 Cookie 容器 |
| `log(message)` | 写入诊断日志（排查用） |
| `source.getPreference(key)` | 读取用户在源设置页填写的值 |

**沙箱约束**：单次调用超时 10 秒；不能访问文件系统、钥匙串、其他来源的数据；
不能发起未经 `net` 的请求。

## 5. 登录与反爬

- 源声明 `loginUrl` 后，App 在源详情页显示「登录」按钮，
  用内嵌网页让用户完成登录，并收割 Cookie 到该来源的隔离容器。
- 遇到需人工验证的站点，App 会在必要时弹出内嵌网页让用户完成验证，
  完成后把验证 Cookie 交回该来源容器。

## 6. 版本策略

- `1.x` 内 **只增不改**：新增字段必须有安全默认值。
- 破坏性变更走 `2.0`，且 App 需同时支持 v1 一段时间。
