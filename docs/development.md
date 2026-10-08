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

预检共 **14 项**（每一步都对应一类真实踩过的问题，修完就把规则固化进来）：

| # | 检查 | 作用 |
|---|---|---|
| 1 | `tools/check_project.py` | pbxproj 引用完整性（曾因结构非法导致包解析器崩溃）、例外集与磁盘测试文件一致性、包登记、配置文件语法、旧项目名残留、**包内有 `.lproj` 时 manifest 必须声明 `defaultLocalization`** |
| 2 | `tools/check_imports.py` | ①「用了某包类型却没 import」；②「跨模块调用了 non-public 成员」——纯编译器错误，本地提前挡掉；几何类型（CG*）必须有 `import CoreGraphics` |
| 3 | `tools/check_swift_syntax.py` | 括号配平、`#if/#endif` 配对、悬空 `else`、**多行字符串缩进规则**、**JSON 编解码类型必须 Codable**、`UPDATE` 条目表必须同时写 payload、静态成员限定、主 actor 静态成员、路径片段安全化、日期写法、throwing 调用、**SwiftUI `Section(标题) { } header:/footer:` 误用**（本机无 Swift 工具链时的词法体检） |
| 4 | `tools/check_docs_sync.py` | `docs/source-api.md` 的契约示例与测试夹具必须逐字一致；`docs/*.md` 小节编号不得重复或回退 |
| 5 | `tools/check_api_usage.py` | **构造调用与 init 声明一致性**：改签名忘改调用方、参数标签写错、**参数顺序写反**（实测踩过）；支持**重载**（按「匹配任意一个 init」判定）与**尾随闭包**（尾随闭包会满足最后一个参数） |
| 6 | Python 脚本语法 | CI 里 `release` / `pages` job 会执行的脚本 |
| 7 | `tools/check_localization.py` | **本地化一致性（两张表）**：App 表与包层表各自 key 集合一致、代码引用的 key 必须存在、占位符类型与数量一致、`String(format:)` 实参个数吻合、**死文案**与**重复 key** 报错、两表 key 不得重名、**测试不得断言文案字面值**；先剥注释再扫描 |
| 8 | `tools/check_hardcoded_copy.py` | **用户可见文案不得硬编码中文**（含中日韩标点）；放行 `diag` / `logSink` 等开发者日志，`// i18n-exempt` 可显式豁免并会被打印出来 |
| 9 | `tools/check_legal_sync.py` | **法务文本三份载体不得分叉**（`docs/legal` ↔ App 内置副本 ↔ 官网）；`--emit` 由 Markdown 单向生成 |
| 10 | `tools/check_demo_repo.py` | **自测仓库语料与 CI 夹具逐字一致**：生成器里的 10 个文本块与 `DemoCorpus.swift` 必须相同，图片文件名集合也要一致 |
| 11 | `tools/build_website.py` | 重新生成法务页面；校验官网双语标记齐备、相对链接存在、**不引外部资源** |
| 12 | `tools/check_altstore_source.py` | 用**合成发布数据**把 AltStore 清单生成逻辑离线跑一遍：字段、版本倒序、URL 形状、图标与截图是否真实存在 |
| 13 | `tools/check_member_receiver.py` | **成员挂错接收者**：`Type.member(…)` 里的 member 不声明在 `Type` 上、却唯一地声明在另一个包的类型上（`LibraryCategory.categoryNameKey` 实际在 `ModelValidation` 上——这种错只有编译器看得见，一轮 CI 12 分钟） |
| 14 | `tools/check_redlines.py` | 合规红线：不得出现第三方站点名、不得提交源脚本（`*.js`）、不得提交凭据 |

**每修掉一类问题，就把规则固化进这套预检**——否则同类问题会重复消耗一轮 CI（约 10 分钟）。

| job | 作用 |
|---|---|
| `build-ipa` | 无签名 archive → `codesign --sign -`（ad-hoc）→ `ditto` 打 ipa → 上传 artifact |
| `test` | 在镜像上最新的 iPhone 模拟器执行 `xcodebuild test` |
| `release` | 仅 `v*` tag：创建 Release（附 ipa）并生成 AltStore `source.json` |

另有 `.github/workflows/pages.yml` 部署官网（`website/`）。
它**刻意只支持手动触发**：该 job 需要仓库先在 Settings → Pages 里选好
“GitHub Actions”，否则会失败；挂在 push 上会让没配 Pages 的克隆每次推送都飘红，
而那种红与代码质量无关。配好之后想自动部署，把文件里的 `push:` 段打开即可。

同分支并发组为 `build-ipa-${{ github.ref }}`，新推送会取消旧运行。

## 4. 发版流程

```bash
# 改代码 → 加/改测试 → 更新 CHANGELOG.md → bash tools/preflight.sh（14 项全绿）
git commit -m "0.0.1: ..."
git push origin main

git -c user.name='dev-bot' -c user.email='dev-bot@local' tag -a v0.0.1 -m "v0.0.1"
git push origin v0.0.1
```

随后轮询 Actions，确认 `build-ipa` + `test` + `release` 全绿，
并在 Release 页确认存在 `MangaTranslater.ipa` 与 `source.json`。

**版本号只从 tag 注入**（`v0.0.1` → `MARKETING_VERSION=0.0.1`），
因此 ipa 内版本与 tag 永不漂移；分支构建用 `0.0.1` 兜底（与 pbxproj 保持一致）。

### 测试版必须发成「正式 Release」，不能勾 Pre-release

`build_altstore_source.py` 会跳过 `draft` 与 `prerelease` 的发布——这不是疏漏，
而是设计意图（AltStore 只该看到可长期使用的版本）。但它带来一个反直觉的后果：

**若某个版本是仓库里唯一带 ipa 的发布、且被勾成 Pre-release，
脚本会因为「找不到任何正式发布」直接以非零码退出，`release` job 标红**
（此时 Release 与 ipa 其实已经建好了，只是 `source.json` 没生成）。

所以 0.x 阶段的公开测试版同样按**正式 Release** 发。注意它同时会占据
`releases/latest` 的位置：`source.json` 的对外地址依赖这个位置。
将来发过 `1.0.0` 之后**不要**再补发 `0.0.x` 的正式 Release——那会让
`latest` 倒退，AltStore 会把旧版本当成「有更新」推给用户。

发版前需要人工完成的外部配置（域名、Cloudflare、Resend、DeepSeek、
Lemon Squeezy 的结账链接等）见 **`docs/going-live.md`**。

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
| **真机「启动即闪退」，模拟器与 CI 全绿** | 十有八九是 `__objc_protorefs` 被放进了只读的 `__DATA_CONST`（见下），**不是业务代码的问题** |
| 真机「启动即闪退」，已排除上一条 | 取 `Documents/boot.log`（见 §8）。文件不存在 → 加载 / 签名层；停在某一步 → 那一步之后崩的 |

**真机崩但 CI 全绿是正常组合，别因此怀疑测试**：单元测试是以 App 为测试宿主
跑的，等于在**模拟器**上启动过 App 且全绿；而模拟器**不校验代码签名**。
所以「模拟器好、真机崩」这个组合本身就把范围限定在了真机专属的那一层。

### Xcode 26 + iOS 18：`__objc_protorefs` 会让 App 启动即闪退

这是本项目**实际踩到过的第一个真机崩溃**，也是「本地完全看不见」的典型：
不是编译错误、不是测试能覆盖的路径、模拟器上永远复现不出来。

Xcode 26 的链接器默认把 `__objc_protorefs` 放进只读的 `__DATA_CONST`
（Xcode 16 及更早放在可写的 `__DATA`）。dyld 在 fixup 完成后会把该段标记为只读，
而 iOS 18 的 `libobjc` 在 `map_images_nolock` 做 protocol fixup 时仍要写它 →
在 `main()` 之前 `EXC_BAD_ACCESS (SIGBUS)`。

工程已在 App target 的 Debug / Release 各加 `-Wl,-no_data_const` 规避。
**验证方式是对着产物看，不是看标志有没有写**：

```bash
otool -l MangaTranslater.app/MangaTranslater | grep -A2 __objc_protorefs
#   segname 必须是 __DATA；出现 __DATA_CONST 就说明标志没生效
```

CI 的 `build-ipa` 已经把这条检查固化成一个步骤，一旦回到 `__DATA_CONST` 直接失败。

## 8. 诊断日志

`DiagnosticsLog` 写入文档目录，App 开启文件共享后可在「文件」App 中取出；
设置页「诊断日志」一栏显示当前体积并可清空。任何排查都先加 `diag("...")` 打点。

### 启动轨迹 `boot.log`

真机上「启动即闪退」时，`DiagnosticsLog` 往往是空的——它要等 App 跑到写日志
那一步才有内容，而进程可能根本没跑起来。这时看 **`Documents/boot.log`**
（同一个「文件」App 位置：「我的 iPhone」→ MangaTranslater），
它由 `BootTrace` 写出，是最原始的那条线索。

**两套设施刻意分开**：`BootTrace` 不碰 `DiagnosticsLog`（它有自己的轮转、
formatter 与目录选择），也不碰 `Copy`（文案表是否可用本身就在待查清单上），
只用最基础的 `FileManager` + `FileHandle`，任何失败一律静默。
排查启动问题时，工具本身越简单越好。

判读只有三种情况：

| boot.log | 结论 |
|---|---|
| 文件不存在，或一行都没有 | 进程没执行到我们的代码。方向是**加载层**：代码签名、`MinimumOSVersion`、dyld 找不到符号 |
| 停在中间某一步 | 就是那一步之后崩的。序列：`env.begin` → `env.directory` → `env.stores` → `env.database.persistent=…` → `env.graph.begin` → `env.graph.done` |
| 一路写到 `rootView.shown` | 启动本身没问题，崩点在首屏渲染之后，与启动无关 |

每次进程启动会**覆盖**上一轮的轨迹，所以文件里永远是最近一次启动的记录。

## 9. 自测仓库（本机联调）

**App 不内置任何在线源**，所以「想看看在线功能到底通不通」需要自己准备一个站点。
`tools/make_demo_repo.py` 现场生成一个**完全中性**的静态「漫画站」+ 配套源脚本：

```bash
python3 tools/make_demo_repo.py                  # 生成到系统临时目录，并打印路径
cd <打印出来的目录> && python3 -m http.server 8000
# App → 浏览 → 管理源仓库 → 添加 http://127.0.0.1:8000/ → 安装 demo
# 之后：热门 / 最新 / 搜索 → 作品详情 → 章节 → 阅读（翻页、翻章、预加载）
```

几个刻意的约定：

- **不写入本仓库**：脚本是 `*.js`，提交进来会触发合规红线；
  生成器会**拒绝**把输出写到仓库目录内（要强行写需显式 `--allow-in-repo`）。
  页面里的 `baseUrl` 固定为 `http://127.0.0.1:8000`，直接对应上面的托管命令。
- **与 CI 用同一份语料**：生成器里的 10 个文本块（`index.json`、`demo.js`、
  8 个页面）与 `MangaTranslaterTests/DemoCorpus.swift` 逐字一致，
  由 `tools/check_demo_repo.py` 在推送前比对。改了生成器就同步重跑：

  ```bash
  python3 tools/make_demo_repo.py --emit-swift MangaTranslater/MangaTranslaterTests/DemoCorpus.swift
  python3 tools/check_demo_repo.py     # 确认两侧一致
  ```

- **`--check <目录>`** 可以对已生成的仓库做一次自检（脚本静态规则、索引字段、
  页面引用的资源是否存在）——`http.server` 少一个文件时的 404 很费时间，
  这里提前挡住。

CI 里对应的验证是 `MangaTranslaterTests/DemoRepositoryTests.swift`：
它用同一批页面跑「拉索引 → 安装 → 浏览 → 详情 → 章节 → 页列表 → 取图」，
是 M2 的验收用例。

## 10. 交互清单与点击语义层

| 产物 | 位置 | 用途 |
|---|---|---|
| 交互清单 | `docs/interaction-map.md` | 逐个列出可点元素（含缺失的入口）、破坏性操作确认矩阵、问题观察（O-1…）、以及「哪些已可测 / 哪些要先抽层 / 哪些本地测不了」 |
| 点击语义层 | `Packages/AppCore/Sources/AppCore/InteractionRules.swift`、`Packages/SourceEngine/Sources/SourceEngine/ServerFormValidator.swift` | 视图里**不允许**再写「点了会怎样」的判定；判定住在这里，视图只留一行调用 |
| 模拟点击测试 | `MangaTranslater/MangaTranslaterTests/InteractionRulesTests.swift` | 穷举状态组合 + 多步序列（`ReaderSimulator`） |

改交互时的固定动作：

1. 先在 `docs/interaction-map.md` 对应屏补/改那一行（行号不写，按「屏 + 元素名」定位）；
2. 破坏性操作加进 `DestructiveAction`；章节行状态加进 `ChapterDownloadState`；
3. 跑 `InteractionRulesTests`——`DestructiveActionPolicyTests` 的**计数断言**会提醒你
   更新期望矩阵（即「这个新操作要不要确认」这个决定不能漏）；
4. 判定能抽成纯函数就抽（判据：**它能不能被 `#expect` 断言**）。

## 11. 官网与 AltStore 源

| 产物 | 生成方式 | 校验 |
|---|---|---|
| `website/*.html` | 首页/定价手写；三页法务由 `tools/build_website.py` 从 `docs/legal/*.md` 生成 | 同一个脚本（预检第 11 项） |
| `website/assets/screenshots/*.png` | `tools/make_screenshots.py` 用 Pillow 合成（完全虚构的界面示意） | 被第 12 项间接校验（清单引用的文件必须存在） |
| `source.json`（AltStore 源清单） | `.github/scripts/build_altstore_source.py`，仅在 `v*` tag 的 `release` job 里生成并作为 Release 附件上传 | `tools/check_altstore_source.py`（预检第 12 项） |

法务文本的**单一事实来源是 `docs/legal/*.md`**：

```bash
# 改完文案后的固定动作
python3 tools/check_legal_sync.py --emit      # 同步 App 内置副本
python3 tools/build_website.py                # 同步官网页面
python3 tools/check_legal_sync.py             # 确认三份一致
```

字段依据与真机验证方式见 `docs/altstore.md`。
