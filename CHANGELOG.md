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

