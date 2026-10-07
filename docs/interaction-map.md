# 交互与跳转清单 / Interaction & navigation map

这份文档把 App 里**每一个可点击/可滑动/可手势的元素**逐个列出来：
它是什么、点了会怎样、有什么前置条件与副作用、失败时会看到什么。

用途有两个：

1. **测试取材清单**：第 10 节说明哪些交互已经能被单元测试覆盖、哪些需要先把
   判定逻辑从视图里抽出来才能测（这是下一步做「模拟点击」测试的地图）；
2. **评审清单**：第 8、9 节把「破坏性操作的二次确认矩阵」和「发现的问题」
   摊开来看——这类问题只有全部列在一起才看得出**不一致**。

约定：

- **类型**：`Button` / `NavigationLink`（入栈）/ `sheet`（模态）/ `Menu`（展开不跳转）/
  `swipe`（滑动）/ `gesture`（手势）/ `Alert`·`Dialog`（确认与提示）。
- **守卫**：什么条件下这个元素不可点、或点了会走另一条分支。
- **副作用**：写盘、网络、外部浏览器、后台任务。
- 行号不写（会腐化），定位请按「屏 + 元素名」搜。

> 统计口径：**12 个跳转面**（4 个 Tab + 8 个子页/模态），下面逐条编号共 **167 条**，
> 其中约 120 条是真正可点的元素，其余是静态展示、副作用（无按钮的自动跳转），
> 以及**明确标出的缺失入口**（缺失项也编号，否则它们最容易被忘掉）。

---

## 1. 全局骨架

| # | 元素 | 类型 | 动作 | 备注 |
|---|---|---|---|---|
| G1 | 底部 Tab「书架」 | TabItem | 切到 `LibraryView` | 四个 Tab 各自持有 `NavigationStack`，栈状态互不影响 |
| G2 | 底部 Tab「浏览」 | TabItem | 切到 `BrowseView` | |
| G3 | 底部 Tab「下载」 | TabItem | 切到 `DownloadsView`，进入即 `.task { refresh() }` | 每次进入都刷新归档快照 |
| G4 | 底部 Tab「设置」 | TabItem | 切到 `SettingsView` | |
| G5 | 系统返回手势 / 返回键 | 系统 | `NavigationStack` 出栈 | 无自定义返回逻辑；无「返回时是否保存」类询问 |
| G6 | 根视图 | `RootView` | 直接承载 `MainTabView` | 注释说明「引导页 / 应用锁从这里插入」——**目前没有引导页，也没有应用锁**（`Info.plist` 里已声明 FaceID 用途文案，但没有实现） |

## 2. 书架（LibraryView）

| # | 元素 | 类型 | 动作 / 去向 | 守卫与副作用 |
|---|---|---|---|---|
| L1 | 空状态「导入本地文件」 | Button（borderedProminent） | `showsImporter = true` → 系统文件选择器（多选，CBZ/ZIP） | 与 L7 共用 `handleImport` |
| L2 | 工具栏左「分类筛选」 | Menu | 展开菜单（不跳转） | |
| L3 | 菜单项「全部作品」 | Button | `selectedCategoryID = nil` + `reload()` | |
| L4 | 菜单项「〈分类名〉」 | Button | `selectedCategoryID = id` + `reload()` | 每个分类一项；当前项带 checkmark |
| L5 | 菜单项「管理分类…」 | **NavigationLink（嵌在 Menu 内）** | push `CategoryManagerView` | iOS 上 Menu 内嵌 NavigationLink 的入栈/关闭时序由系统处理，建议真机确认（见 O-12） |
| L6 | 工具栏左「排序」 | Menu + 内嵌 Picker | 选中后 `.onChange` → `reload()` | 三个选项：最近阅读 / 标题 / 最近加入 |
| L7 | 工具栏右「+ 导入」 | Button | 同 L1 | |
| L8 | 列表行（作品） | NavigationLink | push `ReaderView(manga:readingSource:)` | `readingSource(for:)` 在**点击那一刻**求值（本地/在线分流） |
| L9 | 行左滑删除（系统 swipe-to-delete） | `.onDelete` | 直接 `libraryStore.remove(mangaID:)` | 系统滑动手势本身算一次确认；**不会删除已下载的文件** |
| L10 | 「书架无法持久化」提示行 | 静态 Label | — | 仅 `isLibraryPersistent == false` 时出现 |
| L11 | 行长按菜单「移出分类」 | contextMenu Button | `setCategory(mangaID:, nil)` → `reload()` | 失败 → alert |
| L12 | 行长按菜单「〈分类名〉」 | Button | `setCategory(mangaID:, id)` → `reload()` | |
| L13 | 行长按菜单「置顶 / 取消置顶」 | Button | `setPinned` → `reload()` | |
| L14 | 行长按菜单「移出书架」 | Button（destructive） | `remove(mangaID:)` → `reload()` | **无确认**；不删下载 |
| L15 | 提示 alert「好」 | Alert | 关闭 | 导入结果 / 移出失败都用它 |

## 3. 分类管理（CategoryManagerView）

| # | 元素 | 类型 | 动作 / 去向 | 守卫与副作用 |
|---|---|---|---|---|
| C1 | 右上「编辑」 | EditButton（系统） | 进入编辑态（显示拖动把手与删除） | |
| C2 | 右上「+ 新建分类」 | Button | `isCreating = true` → alert | |
| C3 | 新建 alert「取消」 | Alert | 关闭 | |
| C4 | 新建 alert「创建」 | Alert | `createCategory(name:)` → `reload()` | 名字非法（空/超长/重复）→ alert 报原因 |
| C5 | 分类行点击 | 手势（onTapGesture） | `renameDraft = name` → 重命名 alert | 整行都是热区 |
| C6 | 重命名 alert「取消」/「保存」 | Alert | `renameCategory(id:to:)` → `reload()` | 失败 → alert |
| C7 | 行左滑删除 / 编辑态删除 | `.onDelete` | `deleteCategory(id:)` → `reload()` | **无确认**（footer 已解释「只移出分类」） |
| C8 | 拖动排序 | `.onMove` | `reorderCategories(ids)` → `reload()` | |

## 4. 浏览（BrowseView）

| # | 元素 | 类型 | 动作 / 去向 | 守卫 |
|---|---|---|---|---|
| B1 | 「本地文件」行 | NavigationLink | push `LocalBooksView` | |
| B2 | 「管理自建服务器」行 | NavigationLink | push `ServerManagerView` | |
| B3 | 「管理源仓库」行 | NavigationLink | push `RepositoryManagerView` | |
| B4 | 自建服务器行（每台） | NavigationLink | push `SourceBrowseView(source:)` | 只列 `isHosted` |
| B5 | 已安装源行（每个脚本源） | NavigationLink | push `SourceBrowseView(source:)` | NSFW 过滤在 `environment` 层完成，视图不再判断 |
| B6 | 空状态文案 | 静态 | — | 合规文案（「不自带任何在线源」） |
| B7 | 仓库地址文本行 | 静态 | — | 只读展示 |

## 5. 本地文件（LocalBooksView）

| # | 元素 | 类型 | 动作 / 去向 | 守卫与副作用 |
|---|---|---|---|---|
| LB1 | 工具栏「+ 导入」 | Button | `showsImporter = true` | `isImporting` 时 disabled |
| LB2 | 作品行 | NavigationLink | push `ReaderView(manga:readingSource:)` | 文件头注释说「点进去会自动加入书架」——**实现里不是**（见 O-5） |
| LB3 | 空状态 | 静态 | — | |
| LB4 | 导入结果 alert「好」 | Alert | 关闭 | 成功/部分失败都在这里 |
| LB5 | 缺失：删除本地文件 | — | — | App 内没有任何删除入口（见 O-9） |

## 6. 服务器与仓库

### 6.1 服务器管理（ServerManagerView）

| # | 元素 | 类型 | 动作 / 去向 | 守卫与副作用 |
|---|---|---|---|---|
| S1 | 服务器行 | Button（plain） | `editing = server` → sheet `ServerEditView` | 整行可点 |
| S2 | 行右滑「删除」 | swipe Button（destructive） | `pendingDelete = server` → 确认对话框 | |
| S3 | 确认对话框「删除」 | Dialog | `removeHostedServer(id:)` | 已下载章节不受影响 |
| S4 | 确认对话框「取消」 | Dialog | `pendingDelete = nil` | |
| S5 | 「添加服务器」行 | Button | `isAdding = true` → sheet | |
| S6 | 编辑 sheet 保存回调 | 闭包 | 新增走 `serverStore.add`；编辑走 `updateHostedServer` → alert「已保存」 | 两条路径不一致，见 O-4 |
| S7 | 「无凭据」警告标签 | 静态 | — | 仅 `!hasCredentials` |

### 6.2 服务器编辑（ServerEditView，模态）

| # | 元素 | 类型 | 动作 | 守卫与副作用 |
|---|---|---|---|---|
| SE1 | 类型 Picker | Picker | 改 `kind` | 编辑态也允许改类型（ID 不变，见 O-17） |
| SE2 | 名称 / 地址 | TextField | 写局部 state | |
| SE3 | API Key / 密码 | SecureField | 写局部 state | **不回显**：编辑时留空表示「不改」 |
| SE4 | 用户名 | TextField | 写局部 state | 留空 → 清空用户名 |
| SE5 | 「测试连接」 | Button | `draft()` → `probeHostedServer` → 显示结果文本 | 地址非法 → alert；测试中 disabled + 转圈 |
| SE6 | 「取消」 | ToolbarItem | `dismiss()` | 丢弃改动 |
| SE7 | 「保存」 | ToolbarItem | 校验地址 → `onSave(draft)` → `dismiss()` | 名字空或地址空时 disabled；**没有先探活**（与文件头注释不符，见 O-3） |
| SE8 | 错误 alert「好」 | Alert | 关闭 | 保存失败的原因在这里 |

### 6.3 仓库管理（RepositoryManagerView）

| # | 元素 | 类型 | 动作 | 守卫与副作用 |
|---|---|---|---|---|
| R1 | 仓库地址输入框 | TextField | 写 state | URL 键盘 |
| R2 | 「添加」 | Button | `addRepository(trimmed)` → 成功即 refresh | 空输入 disabled；重复 → alert；非法 → alert |
| R3 | 工具栏「刷新」 | Button | `refresh()` | 无仓库 / 刷新中 disabled |
| R4 | 仓库行「🗑」 | Button（destructive） | `removeRepository` + 从结果里移除 | **无确认**；已装源不会被卸载（footer 未说明，见 O-13） |
| R5 | 目录条目「安装 / 更新 / 重新安装」 | Button | `install(entry)` → alert 结果 + refresh | `busyKeys` 防连点；`isInstallable == false` 时只显示警告图标（不可点）；NSFW 源且开关关着 → 额外提示「已隐藏」 |
| R6 | 提示 alert「好」 | Alert | 关闭 | |

## 7. 来源浏览与详情

### 7.1 作品列表（SourceBrowseView）

| # | 元素 | 类型 | 动作 | 守卫与副作用 |
|---|---|---|---|---|
| SB1 | 分段控件 热门 / 最新 / 搜索 | Picker（segmented） | 改 `mode` → `.task(id:)` 重建模型并加载第一页 | 切模式 = 重新请求 + 回到顶部 |
| SB2 | 搜索框 | TextField | 只改 `query`（**不发请求**） | |
| SB3 | 搜索框回车 | `onSubmit` | `submittedQuery = query` → 重新加载 | |
| SB4 | 搜索框「✕」 | Button | 清空 query 与 submittedQuery → 重新加载 | 仅 query 非空时出现 |
| SB5 | 作品行 | NavigationLink | push `SourceMangaDetailView(manga:)` | |
| SB6 | 末行出现 | `onAppear` 副作用 | `loadNextPage()` | 预取下一页，无可见按钮 |
| SB7 | 下拉刷新 | `.refreshable` | `model.refresh()` | |
| SB8 | 失败态「重试」 | Button | `model.refresh()` | |
| SB9 | 失败态「打开网页验证」 | Button | 打开 `SourceLoginView(purpose: .verification)` | 仅当失败文案命中验证页特征；无 URL → alert |
| SB10 | 工具栏「⋯」 | Menu | 展开 | |
| SB11 | 菜单「登录」 | Button | sheet `SourceLoginView(purpose: .login)` | 仅当源声明了 `loginUrl` |
| SB12 | 菜单「打开网页验证」 | Button | 同 SB9 | 任何情况都显示 |
| SB13 | 菜单「清除登录状态」 | Button（destructive） | `clearSourceCookies` + alert | 仅当该源有 Cookie |
| SB14 | 提示 alert「好」 | Alert | 关闭 | |

### 7.2 作品详情（SourceMangaDetailView）

| # | 元素 | 类型 | 动作 | 守卫与副作用 |
|---|---|---|---|---|
| SD1 | 整页失败「重试」 | Button | `load()`（详情 + 章节） | |
| SD2 | 「加入书架」 | Button | `addToLibrary()` → alert | 已在书架时 **disabled**（不可重复点） |
| SD3 | 章节行 | NavigationLink | push `ReaderView(..., startChapterID:)` | |
| SD4 | 章节行左滑「下载本话」 | swipe Button（蓝） | `download(chapter)` → alert + 刷新下载状态 | 未下载 / 失败 / 已取消 / 已排队时出现 |
| SD5 | 章节行左滑「删除下载」 | swipe Button（destructive） | `deleteArchive` + 刷新 | **无确认**（下载页同类操作有确认，见 O-1） |
| SD6 | 章节行左滑「取消下载」 | swipe Button（destructive） | `cancel(chapterID:)` + 刷新 | 下载中 / 暂停时出现 |
| SD7 | 章节区失败「重试」 | Button | `loadChapters()` | 只重试章节，作品信息保留 |
| SD8 | 工具栏「⋯」→「下载全部」 | Button | `downloadAll()` → alert | 全已下载 → alert「没有需要下载的章节」 |
| SD9 | 工具栏「⋯」→「删除全部下载」 | Button（destructive） | `deleteArchives(mangaID:)` + 刷新 | **无确认**（同 O-1） |
| SD10 | 提示 alert「好」 | Alert | 关闭 | |
| SD11 | 下载状态角标 | 静态 | — | 已下载 / 进度 x/y / 暂停 / 排队中 / 失败 |

### 7.3 网页登录 / 人工验证（SourceLoginView，模态）

| # | 元素 | 类型 | 动作 | 守卫与副作用 |
|---|---|---|---|---|
| SL1 | 网页内容 | WKWebView | 导航、页面内点击由网页自己处理 | 非持久化数据存储；与 App 其他网络栈隔离 |
| SL2 | 底部「重试」 | Button | `model.reload()` | 仅当有加载错误时出现 |
| SL3 | 「取消」 | ToolbarItem | `dismiss()` | **不收割**任何 Cookie |
| SL4 | 「完成」 | ToolbarItem | 收割 Cookie（按主机过滤）→ 合并进该源容器 → alert 结果 | 收割中 disabled；0 条 → 「没有找到可保存的凭据」；>0 → 「已保存 N 条」；alert 的「好」也会 `dismiss()` |
| SL5 | 页面返回手势 | 系统 | WebView 内前进/后退 | `allowsBackForwardNavigationGestures = true` |

## 8. 阅读器（ReaderView）

| # | 元素 | 类型 | 动作 | 守卫与副作用 |
|---|---|---|---|---|
| RD1 | 左侧 60pt 点击带 | 手势 | `advance(forward:)`，方向随阅读模式（右到左时左=下一页） | 宽度写死 60pt（见 O-19） |
| RD2 | 右侧 60pt 点击带 | 手势 | 反向 | 中间区域单击**无动作**（见 O-10） |
| RD3 | 双击页面 | 手势 | 1× / 2× 缩放切换，并钳制位移 | |
| RD4 | 横向拖动（未放大） | 手势 | 位移 > 40 且横向为主 → 翻页 | 放大状态下只平移，不翻页 |
| RD5 | 捏合 | 手势 | 缩放（`ZoomState` 限幅） | 手势结束钳制位移 |
| RD6 | 底栏「上一页」 | Button | `advance(false)` | `session == nil` 时 disabled |
| RD7 | 底栏「下一页」 | Button | `advance(true)` | 同上 |
| RD8 | 顶栏「翻译」（书页图标） | Button | 开连续翻译；再点 → 显示原文 | `translation == nil` 或加载中 disabled |
| RD9 | 顶栏「星标」 | Button | `addToLibrary()` + 立刻记一次进度 | 已在书架时 disabled |
| RD10 | 翻译失败提示条「✕」 | Button | `dismissFailure()` | |
| RD11 | 额度提示条「升级云服务」 | Button | `openURL(cloudUpgradeURL)`（外部浏览器） | 带 `custom[user_id]` |
| RD12 | 额度提示条「✕」 | Button | `dismissQuotaNotice()` | |
| RD13 | 翻页到章末继续前进 | 副作用（无按钮） | 自动切下一章并载入 | 无「已进入下一话」提示 |
| RD14 | 首章第一页再后退 | 副作用 | alert「已经是第一页了」 | |
| RD15 | 末章最后一页再前进 | 副作用 | alert「已经是最后一页了」 | |
| RD16 | 提示 alert「好」 | Alert | 关闭 | |
| RD17 | 返回 | 系统 | `onDisappear`：恢复系统休眠、取消预加载、`translation.stopAndReset()` | 翻译缓存留盘（跨会话复用） |
| RD18 | 缺失：下载当前章 | — | — | 手册 §8.2 顶栏有 ⤓（见 O-6） |
| RD19 | 缺失：阅读设置入口 | — | — | 手册 §8.2 顶栏有 ⚙（见 O-6） |

## 9. 下载（DownloadsView）

| # | 元素 | 类型 | 动作 | 守卫与副作用 |
|---|---|---|---|---|
| D1 | 进行中行右滑 | swipe | 暂停 / 继续 / 重试（按状态切换单个按钮） | |
| D2 | 进行中行左滑「取消」 | swipe（destructive） | `cancel(chapterID:)` | **无确认**（取消会清掉已抓的页） |
| D3 | 已下载章节行 | NavigationLink | push `ReaderView(startChapterID:)` | **仅当作品在书架**；否则退化为不可点的普通行 |
| D4 | 已下载行右滑「导出 CBZ」 | ShareLink | 系统分享面板 | 归档文件存在时才有 |
| D5 | 已下载行左滑「删除」 | swipe | 确认对话框 → `deleteArchive` | 有确认 ✓ |
| D6 | 已结束行右滑「重试」 | swipe | `retry(chapterID:)` | |
| D7 | 工具栏「⋯」→「全部取消」 | Button | 确认对话框 → `cancelAll()` | 有确认 ✓（仅当有进行中任务） |
| D8 | 工具栏「⋯」→「删除〈作品〉的全部下载」 | Button | 确认对话框 → `deleteArchives(mangaID:)` | 有确认 ✓（每个作品一项） |
| D9 | 工具栏「⋯」→「清空下载」 | Button | 确认对话框 → `deleteAllArchives()` | 有确认 ✓ |
| D10 | 工具栏「⋯」→「清除记录」 | Button | `removeFinished()` | 无确认（不删文件，风险低） |
| D11 | 下拉刷新 | `.refreshable` | `downloads.refresh()` | |
| D12 | 确认对话框「取消」 | Dialog | `confirmation = nil` | |
| D13 | 提示 alert「好」 | Alert | 关闭 | 入队失败 / 打包失败等 |

## 10. 设置

### 10.1 设置首页（SettingsView）

| # | 元素 | 类型 | 动作 | 守卫与副作用 |
|---|---|---|---|---|
| ST1 | 「云翻译服务」行 | NavigationLink | push `CloudAccountView` | 副标题显示额度或「未登录」 |
| ST2 | 「显示成人（18+）源」开 | Toggle | 未确认年龄 → 年龄确认 alert；已确认 → 直接开启 | **合规要点**（`setShowsNSFWSources` 内部再裁决一次） |
| ST3 | 年龄确认「取消」 | Alert | 关闭，保持关闭 | |
| ST4 | 年龄确认「我已年满 18 周岁」 | Alert | `hasConfirmedAdultContent = true` + 开启 | |
| ST5 | 该 Toggle 关 | Toggle | 直接关闭 | |
| ST6 | 「翻译」行 | NavigationLink | push `TranslationSettingsView` | 副标题显示后端 + 语言对 |
| ST7 | 阅读模式 Picker | Picker | `settings.readerMode` | |
| ST8 | 阅读背景 Picker | Picker | `settings.readerTheme` | |
| ST9 | 页面留白 Stepper | Stepper | `settings.readerPageSpacing` | |
| ST10 | 屏幕常亮 Toggle | Toggle | `settings.keepsScreenAwake` | |
| ST11 | 预加载页数 Stepper | Stepper | `settings.preloadWindow` | |
| ST12 | 下载并发 Stepper | Stepper | `settings.maxConcurrentDownloads` | |
| ST13 | 「开源许可 / 隐私政策 / 使用条款」 | NavigationLink ×3 | push `LegalDocumentView(kind:)` | 三种文档共用一个页面 |
| ST14 | 「清空日志」 | Button（destructive） | `diagnostics.clear()` | 无确认 |
| ST15 | 「清空封面缓存」 | Button | `coverCache.removeAll()` → alert 结果 | 无确认（可再生成） |
| ST16 | 版本行 | 静态 | — | 显示 `CFBundleShortVersionString (build)` |
| ST17 | 提示 alert「好」 | Alert | 关闭 | |
| ST18 | 缺失：备份 / 恢复 | — | — | `AppSettings` 已有快照编解码，只缺入口（见 O-8） |

### 10.2 翻译设置（TranslationSettingsView）

| # | 元素 | 类型 | 动作 | 守卫与副作用 |
|---|---|---|---|---|
| T1 | 后端 Picker（inline） | Picker | `settings.translationBackend`；下方分区随之切换（自备密钥 / 云 / 端上） | |
| T2 | 原文语言 Picker | Picker | `settings.sourceLanguage` | |
| T3 | 译文语言 Picker | Picker | `settings.targetLanguage`（不含 `auto`） | |
| T4 | 预取页数 Stepper | Stepper | `settings.translationPrefetchWindow` | |
| T5 | 「漏行兜底」Toggle | Toggle | `settings.usesLineDropFallback` | |
| T6 | 接口地址 / 模型 TextField | TextField | 立即写回设置（非法值被钳制回默认） | |
| T7 | API Key SecureField | SecureField | 写钥匙串 | 没填时 footer 变成「填了才能用」 |
| T8 | 「云翻译服务」行 | NavigationLink | push `CloudAccountView` | 仅云后端时出现 |
| T9 | 底色取样 / 额外标注原文 Toggle | Toggle | `settings.translationUses…` / `…ShowsOriginalText` | |
| T10 | 译文字号 Slider | Slider | `settings.fontScale` | |
| T11 | 「清空译文缓存」 | Button（destructive） | `translationStore.removeAll()` → alert 清除页数 | **无确认**，而清空等于把已花的额度作废（见 O-2） |
| T12 | 提示 alert「好」 | Alert | 关闭 | |

### 10.3 云账号（CloudAccountView）

| # | 元素 | 类型 | 动作 | 守卫与副作用 |
|---|---|---|---|---|
| CL1 | 「刷新状态」 | Button | `model.refresh()` | `isBusy` 时 disabled |
| CL2 | 「退出登录」 | Button（destructive） | `model.signOut()` | 无确认（可恢复） |
| CL3 | 「升级 Pro」 | Button | `openURL(purchaseURL)` 外部浏览器 | 唯一的付费入口，App 内无收银台 |
| CL4 | 「注销账号」 | Button（destructive） | 确认 alert（要求输入邮箱） | `isBusy` 时 disabled |
| CL5 | 注销 alert「取消」 | Alert | 清空输入并关闭 | |
| CL6 | 注销 alert「永久注销」 | Alert | `deleteAccount(email:)` | 邮箱不符 → notice；401 → 退回未登录 |
| CL7 | 邮箱输入框 + 「发送验证码」 | TextField / Button | `model.sendCode(email:)` | 空或非法 → 不发请求，直接提示 |
| CL8 | 验证码输入框 + 「登录」 | TextField / Button | `model.verifyCode(code)` | 成功后清空输入并进已登录态 |
| CL9 | 「换一个邮箱」 | Button | `model.cancelVerification()` | |
| CL10 | 提示 alert「好」 | Alert | `clearNotice()` | 登录/注销/错误都在这里 |
| CL11 | 页面出现 | `.task` | 自动 `refresh()` | 与 CL1 同源，重复进入会各刷一次 |

### 10.4 法务文档（LegalDocumentView）

| # | 元素 | 类型 | 动作 | 备注 |
|---|---|---|---|---|
| LG1 | 右上「safari」 | Button | `openURL(官网对应页面)` | 设备端副本随版本冻结，官网是最新一份 |
| LG2 | 正文 | 静态渲染 | — | 标题/小节/列表/表格/代码块五种块 |

## 11. 破坏性操作与二次确认矩阵

这张表是把「同类操作是否一致」摊开来看的地方。

| 操作 | 在哪 | 有确认？ | 可恢复？ | 备注 |
|---|---|---|---|---|
| 移出书架 | 书架长按菜单 | 否 | 可（重新收藏） | 不删下载 |
| 删除分类 | 分类管理 | **否** | 部分（分类没了，作品还在） | |
| 取消单个下载 | 下载页左滑 | **否** | 可重下 | 已抓的页被丢弃 |
| 取消全部下载 | 下载页菜单 | **是** | 可重下 | |
| 删除单章归档 | 下载页左滑 | **是** | 可重下 | |
| 删除单章归档 | **作品详情左滑** | **否** | 可重下 | 与上一行同类操作不一致（O-1） |
| 删除某作品全部下载 | 下载页菜单 | **是** | 可重下 | |
| 删除某作品全部下载 | **作品详情菜单** | **否** | 可重下 | 同 O-1 |
| 清空全部下载 | 下载页菜单 | **是** | 可重下 | |
| 清除下载记录 | 下载页菜单 | 否 | 是（不删文件） | 风险低 |
| 删除服务器 | 服务器管理 | **是** | 需重填凭据 | |
| 删除仓库 | 仓库管理 | **否** | 可重加 | 已装源保留 |
| 清空诊断日志 | 设置 → 关于 | 否 | 不可（日志丢了） | 影响排查 |
| 清空封面缓存 | 设置 → 关于 | 否 | 自动重建 | |
| 清空译文缓存 | 翻译设置 | **否** | 要重新翻译（**耗额度/花钱**） | 建议加确认（O-2） |
| 退出登录 | 云账号 | 否 | 可（同邮箱再登录） | |
| 注销账号 | 云账号 | **是（输邮箱）** | **不可** | 合规要求 |

## 12. 发现的问题（建议逐条确认后再动手）

标 **[一致性]** 的是「同类操作两种行为」，标 **[缺失]** 的是「手册里有、实现里没有」，
标 **[过期]** 的是「注释/文档与实现不符」。

- **O-1 [一致性] 删除下载的确认不一致**：下载页的归档删除有确认，作品详情页的左滑
  「删除下载」与菜单「删除全部下载」没有。用户学到的规则会互相矛盾，且详情页那条
  更容易误触（章节行左滑的手势区域大）。建议把「是否需要确认」抽成一处判定（见第 13 节），
  破坏性操作一律确认。
- **O-2 [一致性] 清空译文缓存没有确认**：它是**唯一会浪费钱**的清理动作——云服务按页
  扣额度，缓存清了就得重翻。至少要在按钮旁说明后果，或加确认。
- **O-3 [过期] ServerEditView 的头注释说「保存时先 probe，成功才落盘」**，但 `save()`
  只校验地址格式，探活只发生在「测试连接」按钮上。要么补上探测，要么改注释。
- **O-4 [一致性] 新增服务器走 `serverStore.add`，而 `AppEnvironment.addHostedServer`
  （含名字校验、ID 派生、诊断打点）没有被 UI 使用**。于是「测试覆盖的那条路径」与
  「用户真正走的路径」不是同一条。建议 UI 改走 environment 的方法。
- **O-5 [过期] LocalBooksView 头注释说「点进去阅读时会自动加入书架」**，实现里只有点
  星标才加入书架（阅读器顶部），不点就不记进度。
- **O-6 [缺失] 阅读器顶栏缺「下载」与「阅读设置」两个入口**（手册 §8.2 的线框图是
  ⤓ / Ⓣ / ⚙）。现在想改阅读主题必须退出阅读器回设置页，对长时间阅读很不友好。
- **O-7 [缺失] 书架没有「下拉检查更新」**（手册 §8.1），也没有独立的「最近阅读条」。
- **O-8 [缺失] 设置里没有「备份 / 恢复」入口**：`AppSettings` 的快照编解码、越界钳制、
  向后兼容解码都已经写好并有测试，只缺一层界面（这是一个纯 UI 的收尾工作）。
- **O-9 [缺失] 本地导入的文件在 App 内没有删除入口**：只能把作品移出书架，文件仍占空间；
  用户找不到「清理导入文件」的地方（下载页只管理下载的归档）。
- **O-10 [体验] 阅读器中间区域单击无动作**：两侧 60pt 是翻页带，中间只响应双击。
  常见阅读器会把「中间单击」用于隐藏/呼出工具栏，这里工具栏常驻，挤压了阅读面积。
- **O-11 [体验] 阅读器没有「跳章 / 跳页」入口**：只能一页页翻（换章是自动的）。长作品
  （几十话）想回到某处非常费劲。
- **O-12 [风险] 书架「管理分类…」是 Menu 内嵌 NavigationLink**：iOS 上这类组合在
  「菜单关闭」与「入栈」的时序上有过边缘行为（点了没跳 / 菜单残留），建议真机确认；
  更稳的做法是换成独立入口或 sheet。
- **O-13 [说明] 删除仓库不会卸载已装源**（设计如此——仓库只是安装来源），但界面没有
  说明，用户可能以为「删了仓库源就没了」。
- **O-14 [说明] 提前告知**：删分类、移出书架、删仓库、清日志都没有确认。是否加确认取决于
  你对「误触成本」的判断；建议至少让 O-1 那一组统一。
- **O-15 [体验] 作品列表切模式（热门/最新/搜索）会重建模型**：回到列表顶部、丢弃已加载页、
  重复发请求。当前实现简单可靠，但快速来回切换会看到闪烁。
- **O-16 [体验] 已下载章节在作品不在书架时不可点**（刻意不给「点了没反应」的假入口），
  但用户会困惑「为什么下载了却打不开」。建议给一行说明 + 「加入书架」快捷入口。
- **O-17 [细节] 编辑服务器时允许改类型，但 ID 不变**（`makeID` 只在新增时按 kind 派生），
  于是行内标签与 ID 前缀可能不一致。界面无碍（ID 不可见），但值得记下来。
- **O-18 [细节] 阅读器两侧点击带宽度写死 60pt**，iPad / 横屏下偏窄；改成按容器宽度的比例
  （例如 15%，且有上下限）会更稳。
- **O-19 [一致性] 提示机制有两套**：多数页面用局部 `@State` + alert，下载页用
  `DownloadCoordinator.message`（因为下载在后台仍要提示）。两套都合理，但改动提示文案时
  要记得它们不是一处。
- **O-20 [体验] 登录页收割 0 条时，点「好」会把整个登录页关掉**（alert 的按钮里调了
  `dismiss()`）。用户的下一步往往就是「那我再试一次」，结果得重新从菜单打开登录页。
  建议：成功才关闭；失败时只关 alert、留着网页让用户继续操作。
- **O-21 [缺失] 应用锁没有实现**：`Info.plist` 已经声明了 Face ID 用途文案
  （`NSFaceIDUsageDescription`），`RootView` 的注释也写着「应用锁从这里插入」，
  但代码里没有任何 `LocalAuthentication` 调用。要么实现，要么把那条 plist 声明删掉——
  留着一条未使用的权限说明，在审核/用户信任上都不是好事。

## 13. 下一步：这些交互怎么变成可测的

SwiftUI 视图本身不能直接单测（没有 ViewInspector 之类的依赖），所以「模拟点击」的
可行做法是**把点击语义抽成纯函数，再对纯函数穷举**。分三档：

**A 档（已经有测试，补边界即可）**——点击背后的规则层：

| 交互 | 可测层 | 已有 |
|---|---|---|
| 翻页 / 翻章 / 到首尾 | `ReaderSession.advanceForward/Backward`、`moveToChapter` | `ReaderSessionTests` |
| 双击 / 捏合 / 位移钳制 | `ZoomState` | `ZoomStateTests` |
| 加入书架 / 置顶 / 分类 / 进度 | `LibraryStoring`（两个实现跑同一批断言） | `LibraryStoreTests` |
| 下载入队 / 暂停 / 继续 / 取消 / 重试 / 删除 / 归档 | `DownloadCoordinator`、`DownloadQueue` | `DownloadCoordinatorTests`、`DownloadQueueTests` |
| 列表分页 / 失败 / 空态 | `SourceBrowseModel` | `SourceBrowseModelTests` |
| 发码 / 校验 / 刷新 / 退出 / 注销 / 额度 | `CloudAccountModel` | `CloudAccountTests`、`CloudClientTests` |
| 翻译开关 / 预取窗口 / 额度降级 | `TranslationController` | `TranslationControllerTests` |
| NSFW 开关的年龄门槛 | `AppSettings.setShowsNSFWSources` | `AppSettingsTests` |

**B 档（需要先抽层，然后就能测）**——把散在视图里的判定搬出来：

1. `ReaderTapZone.resolve(isLeading:isRightToLeft:) -> Bool`（RD1/RD2 的 forward 语义）
2. `ReaderSwipe.resolve(dx:dy:isRightToLeft:) -> Advance?`（RD4，含阈值与「放大时不翻页」）
3. `ChapterSwipeMenu.actions(for:) -> [ChapterAction]`（SD4/SD5/SD6 的状态 → 动作映射）
4. `DestructiveActionPolicy.requiresConfirmation(_:) -> Bool`（把第 11 节那张表变成契约，
   顺便解决 O-1 的不一致：要么全都确认，要么全都说明白）
5. `ServerFormDraft.validate() -> [FieldIssue]`（SE7 的校验，含「空输入表示不改」的语义）
6. `LibraryMenu.items(categories:selected:)` / `SortMenu.items(current:)`（菜单项生成）
7. `DownloadsView.readerTarget(record:) -> Manga?`（D3 的守卫：不在书架就不可点）

这些类型都是纯值与纯函数，测试可以用「参数化 + 穷举状态组合」的方式把每个分支走一遍：
例如 `ChapterSwipeMenu` 对上 6 种下载状态 × 是否已归档 = 12 种组合，逐个断言
「出现哪些按钮、点了调用哪个协调器方法」。

**C 档（本地无法自动验证，只能真机/CI 手工）**：系统文件选择器、ShareLink 分享面板、
`openURL` 跳外部浏览器、WKWebView 登录与 Cookie 收割、Vision OCR（需真机框架）、
AltStore 安装与重签、FaceID（尚未实现）。
这些地方的策略是：**把决策与副作用分离**——决策层进 A/B 档测试，副作用只保留一行调用。
