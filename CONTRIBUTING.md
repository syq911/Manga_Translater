# 贡献指南 / Contributing

感谢参与 MangaTranslater。本文件规定**提交规范、分支模型、代码风格与测试门槛**。

---

## 1. 分支模型

| 分支 | 用途 |
|---|---|
| `main` | 稳定主线，任一提交都应能通过 CI（编译 + 测试） |
| `dev/<version>` | 版本开发分支，如 `dev/0.2.0` |
| `fix/<version>` | 缺陷修复分支，如 `fix/0.1.1` |
| `docs/*`、`chore/*` | 文档与杂项 |

流程：从 `main` 开分支 → 提交 → 推送（CI 自动跑）→ 合并回 `main`。
发布时在合并后的提交上打 tag（`vX.Y.Z`），tag 推送会自动创建 Release。

## 2. 提交信息规范（Conventional Commits）

格式：

```
<type>(<scope>): <subject>

<body 可选>

<footer 可选>
```

**type** 取值：

| type | 含义 |
|---|---|
| `feat` | 新功能 |
| `fix` | 缺陷修复 |
| `test` | 仅测试相关 |
| `docs` | 仅文档 |
| `refactor` | 重构（不改变外部行为） |
| `perf` | 性能优化 |
| `build` | 构建系统 / 依赖 / CI |
| `chore` | 杂项（版本号、忽略文件等） |
| `revert` | 回滚 |

**scope** 取值（对应模块）：`appcore`、`comicnet`、`sourceengine`、`comicdownload`、
`translation`、`app`、`ci`、`docs`、`release`。

**示例**：

```
feat(sourceengine): 支持从仓库 URL 安装源脚本

- 解析 index.json 并校验必需字段
- 下载 .js 落盘到 Sources/<key>.js
- 新增 SourceStoreTests 覆盖非法 JSON 与超时

Closes #12
```

**发布提交**（由 CI 使用的版本提交）：

```
0.1.0: 工程基座 + 四包 + CI

<CHANGELOG 摘要>
```

## 3. 提交者身份

自动化与脚本提交统一使用：

```
dev-bot <dev-bot@local>
```

（本地 `git config user.name` / `user.email` 或 `git -c` 临时指定。）

## 4. 代码风格

- 语言：Swift 5 语言模式，iOS 18.0 起。
- 命名：类型 `UpperCamelCase`，方法 / 变量 `lowerCamelCase`，常量同理。
- 文件头注释：每个 `.swift` 文件首行注释块含文件名、所属模块、简述。
  从上游派生并修改过的文件**必须**标注 `Modified from EhViewer-Apple`（Apache-2.0 §4b）。
- 并发：跨线程共享的类型需为 `Sendable`；UI 相关默认 `@MainActor`。
  不得在包内引入 UIKit 依赖（`AppCore` / `ComicNet` / `SourceEngine` / `ComicDownload`
  均只依赖 Foundation，`ComicDownload` 允许 `Compression` 等系统库）。
- 依赖方向（只允许自下而上）：
  `AppCore` → 无内部依赖；
  `ComicNet` → `AppCore`；
  `SourceEngine` → `AppCore`, `ComicNet`；
  `ComicDownload` → `AppCore`, `ComicNet`；
  App 目标 → 全部四包。
  禁止反向依赖与循环依赖。

## 5. 测试门槛（硬性）

- **每个模块必须配套测试**，覆盖：正常流程、异常分支、边界条件
  （空输入、超长文本、非法参数、网络超时、文件缺失 / 损坏、并发调用、资源清理与回滚）。
- 测试框架：**Swift Testing**（`import Testing` / `@Test` / `#expect` / `#require`）。
- 测试必须**可重复执行且互不依赖**：不得依赖执行顺序、不得依赖网络、不得写用户目录；
  临时文件一律写入测试专属临时目录并在结束时清理。
- 新增测试文件必须同步登记到 `MangaTranslater.xcodeproj/project.pbxproj`
  的两处例外集（App 目标排除 + Tests 目标包含），见 `docs/testing.md`。
- CI 门槛：`test` job 全绿 + `build-ipa` job 成功，缺一不可。

## 6. 文档同步

任何影响以下内容的改动，必须同步更新文档：

| 改动 | 需更新 |
|---|---|
| 源 API 契约（方法 / 字段 / 行为） | `docs/source-api.md` + CHANGELOG |
| 模块划分、依赖方向 | `docs/architecture.md` |
| 构建 / 发布 / 排障流程 | `docs/development.md` |
| 测试组织方式 | `docs/testing.md` |
| 用户可见行为 | `CHANGELOG.md` |

## 7. 合规红线（务必遵守）

- 仓库、README、文档、文案中**不得出现任何具体第三方内容站点名称**，
  不得提供、引用或维护任何源脚本（sources）。本项目只定义**接口规范**。
- 不改动 `LICENSE` / `NOTICE`；不删除上游归属声明。
- NSFW 源默认隐藏、18+ 确认、隐私政策与账号注销入口属于产品合规要求，
  相关代码不得绕过。
