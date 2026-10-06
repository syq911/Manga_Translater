# 构建、发布与排障 / Development

## 1. 环境要求

| 项 | 值 |
|---|---|
| 最低系统 | iOS 18.0 |
| Xcode | 16.0 或更高（CI 用镜像上最新的 Xcode） |
| Swift 语言模式 | 5.0 |
| Bundle ID | `com.mangatranslater.ios`（发布后不可更改） |

## 2. 本地构建

```bash
xcodebuild -resolvePackageDependencies -project MangaTranslater.xcodeproj -scheme MangaTranslater

xcodebuild build -project MangaTranslater.xcodeproj -scheme MangaTranslater \
  -destination "generic/platform=iOS" CODE_SIGNING_ALLOWED=NO
```

运行测试见 `docs/testing.md`。

## 3. CI（GitHub Actions）

工作流：`.github/workflows/build-ipa.yml`，触发于**任意分支 push**、`v*` tag 与手动派发。

### 推送前必跑本地预检

```bash
bash tools/preflight.sh
```

| 检查 | 作用 |
|---|---|
| `tools/check_project.py` | pbxproj 引用完整性（曾因结构非法导致包解析器崩溃）、例外集与磁盘测试文件一致性、包登记、配置文件语法、旧项目名残留 |
| `tools/check_imports.py` | ①「用了某包类型却没 import」；②「跨模块调用了 non-public 成员」——纯编译器错误，本地提前挡掉 |；几何类型（CG*）必须有 `import CoreGraphics`
| `tools/check_swift_syntax.py` | 括号配平、`#if/#endif` 配对、悬空 `else`、**多行字符串缩进规则**、**JSON 编解码类型必须 Codable**（本机无 Swift 工具链时的词法体检） |；`UPDATE 条目表` 必须同时写 payload
| `tools/check_docs_sync.py` | `docs/source-api.md` 的契约示例与测试夹具必须逐字一致 |（含小节编号重复检查）
| `tools/check_api_usage.py` | **构造调用与 init 声明一致性**：改签名忘改调用方（实测踩过） |
| `tools/check_localization.py` | **本地化一致性**：各语言 key 集合一致（以并集为基准）、代码里 `L("…")` 的 key 必须已定义、同一 key 的占位符类型与数量一致、`String(format:)` 参数个数吻合 |
| Python 语法检查 | CI 里 `release` job 会执行的脚本 |
| `tools/check_redlines.py` | 合规红线：不得出现第三方站点名、不得提交源脚本（`*.js`）、不得提交凭据 |

**每修掉一类问题，就把规则固化进这套预检**——否则同类问题会重复消耗一轮 CI（约 10 分钟）。

| job | 作用 |
|---|---|
| `build-ipa` | 无签名 archive → `codesign --sign -`（ad-hoc）→ `ditto` 打 ipa → 上传 artifact |
| `test` | 在镜像上最新的 iPhone 模拟器执行 `xcodebuild test` |
| `release` | 仅 `v*` tag：创建 Release（附 ipa）并生成 AltStore `source.json` |

同分支并发组为 `build-ipa-${{ github.ref }}`，新推送会取消旧运行。

## 4. 发版流程

```bash
git checkout -b dev/0.2.0
# 改代码 → 加/改测试 → 更新 CHANGELOG.md
git -c user.name='dev-bot' -c user.email='dev-bot@local' commit -m "0.2.0: ..."
git push origin dev/0.2.0

git -c user.name='dev-bot' -c user.email='dev-bot@local' tag -a v0.2.0 -m "v0.2.0"
git push origin v0.2.0
```

随后轮询 Actions，确认 `build-ipa` + `test` + `release` 全绿，
并在 Release 页确认存在 `MangaTranslater.ipa` 与 `source.json`。

**版本号只从 tag 注入**（`v0.2.0` → `MARKETING_VERSION=0.2.0`），
因此 ipa 内版本与 tag 永不漂移。

### 需要改已发布的 tag

必须先删除旧 Release，否则 `release` job 会因「已存在」失败：

```bash
curl -X DELETE -H "Authorization: Bearer <PAT>" \
  https://api.github.com/repos/<owner>/<repo>/releases/<release_id>
git tag -f v0.2.0 && git push -f origin v0.2.0
```

## 5. 推送凭据（踩过的坑）

若本机 `credential.helper` 配了交互式选择器（如 `helper-selector`），
`git push` 可能弹窗阻塞。稳妥写法是先清空再挂 store：

```bash
printf 'https://<user>:<PAT>@github.com\n' "<PAT>" > <仓库外的路径>/cred
git -c credential.helper= -c credential.helper='store --file=<路径>/cred' push origin <branch>
```

**永不要**把 token 写入仓库内任何被跟踪的文件。

## 6. 分发

- artifact / Release 中的 ipa 为 **ad-hoc 签名**，仅作重签基线，
  用户需用 AltStore / SideStore / Sideloadly / ESign 用自己的证书重签。
- AltStore 源地址：
  `https://github.com/syq911/Manga_Translater/releases/latest/download/source.json`

## 7. 排障

| 现象 | 处理 |
|---|---|
| `Resolve Swift packages` 失败 | 检查 `project.pbxproj` 的 `XCLocalSwiftPackageReference` 路径与 `Package.swift` 平台声明；**不要手写 pbxproj 结构**，改动请基于现有结构 |
| 新增测试文件后「找不到符号」 | 该文件未登记进两处例外集，见 `docs/testing.md` §6 |
| App target 误编译测试文件 | 同上（App target 的例外集必须包含测试文件名） |
| 模拟器测试卡住 | 检查是否真实等待 / 真实网络；测试必须注入 sleeper 与 stub transport |
| ipa 内版本不对 | tag 未推送或格式不是 `vX.Y.Z` |

## 8. 诊断日志

`DiagnosticsLog` 写入文档目录，App 开启文件共享后可在「文件」App 中取出；
设置页「诊断日志」一栏显示当前体积并可清空。任何排查都先加 `diag("...")` 打点。
