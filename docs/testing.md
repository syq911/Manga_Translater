# 测试规范 / Testing

## 1. 框架与位置

- **Swift Testing**（`import Testing` / `@Test` / `@Suite` / `#expect` / `#require`）。
- 测试目标：`MangaTranslaterTests`（位于 App 同步文件夹内），
  在 iPhone 模拟器上运行，可访问全部四个包的公开接口（必要时 `@testable import`）。
- 共享工具在 `MangaTranslaterTests/TestSupport.swift`。

## 2. 覆盖要求（硬性）

每个模块必须覆盖：

| 类别 | 例子 |
|---|---|
| 正常流程 | 成功下载并排序、索引正常解析、设置往返 |
| 边界条件 | 空输入、恰好达到上限、超长文本、0 / 负值 |
| 非法参数 | 非法 URL / 版本号 / 标识、路径穿越文件名 |
| 网络异常 | 超时、离线、4xx / 5xx、429 与 `Retry-After` |
| 文件异常 | 缺失、损坏（Cookie 文件、ZIP 截断、CRC 不符） |
| 并发 | 并发写设置 / Cookie / 队列调度 |
| 资源清理与回滚 | 安装失败保留旧版本、下载失败清除残页 |

## 3. 确定性原则

- **不访问真实网络**：用 `StubTransport` 脚本化响应。
- **不真实等待**：`RateLimiter`、`HTTPClient`、`DownloadQueue` 的休眠实现均可注入。
- **不写用户目录**：临时目录由 `TestFileSystem.makeTemporaryDirectory()` 创建，
  用例结束用 `defer { TestFileSystem.remove(...) }` 清理。
- **用例之间互不依赖**：不依赖执行顺序，不共享可变状态；设置类用例使用独立
  `UserDefaults(suiteName:)` 并在结束时移除持久域。

## 4. 命名与组织

- 一个模块一个文件：`ModelTests.swift`、`CookieJarTests.swift`、`LibraryStoreTests.swift`……
- **协议一致性套件**：`LibraryStoreTests.swift` 里的「书架协议一致性」把同一批断言
  跑在 GRDB 实现与内存实现上，防止两个实现的语义漂移。
- **纯逻辑单测优先**：翻页/分章/自然排序等规则放在值类型里（`ReaderSession`、
  `LocalArchiveIndexer`），不依赖 UI 与文件系统即可穷举边界。
- **需要真图的测试就用真图**：`CoverThumbnailCacheTests` 的夹具是真实 PNG
  （base64 内联），因为该类的职责就是「把真图片缩放」——用伪图片头等于没测。
- **设置快照必须能读旧备份**：`SettingsSnapshot` 的解码走 `decodeIfPresent + 默认值`，
  并有专门用例覆盖「缺字段 / 类型不符 / null / 空对象 / 未知字段」五种情况。
- **外部实现的夹具优先**：验证 ZIP deflate 解压时，夹具由 Python `zipfile` 生成并
  base64 内联（`ZipDeflateTests.swift`）——用自己的编码器造夹具验证自己的解码器
  是自证循环，独立实现才有意义。
- **能脱离 JS 就脱离 JS**：源的「返回值 → 模型」转换放在纯值类型
  `SourceResponseDecoder` 里，24 个边界用例全部只吃 JSON 文本、秒级跑完；
  真实 JS 只留给一个端到端套件（`SourceEndToEndTests`），
  它跑的是 `docs/source-api.md` 里那份 canonical 示例源——
  这样「文档示例能运行」是被 CI 证明的，而不是靠人工记得验证。
- 套件名用中文短语描述被测对象：`@Suite("Cookie 存储")`。
- 用例名描述**行为**而非实现：`@Test("未确认年龄时无法开启 NSFW 源")`。
- 参数化用例优先用 `arguments:` 覆盖同类分支。

## 5. 本地运行

```bash
xcodebuild test \
  -project MangaTranslater.xcodeproj \
  -scheme MangaTranslater \
  -destination "platform=iOS Simulator,name=iPhone 16" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
```

CI 会在 `test` job 中自动挑选当前镜像上可用的最新 iPhone 模拟器执行同一命令。

## 6. 新增测试文件必须改工程文件

Xcode 16 的「同步文件夹」机制下，`MangaTranslater/` 内的源码自动入工程，
但**测试目录内的 `.swift` 必须显式登记**到
`MangaTranslater.xcodeproj/project.pbxproj` 的
`PBXFileSystemSynchronizedBuildFileExceptionSet`：

- 「Exceptions for "MangaTranslater" folder in "MangaTranslater" target」
  → 加入文件名（表示**排除**出 App target）
- 「Exceptions for "MangaTranslater" folder in "MangaTranslaterTests" target」
  → 加入文件名（表示**包含**进 Tests target）

**只往已有测试文件里加用例不需要改工程。**

## 7. 契约文档守护（docs 即测试数据）

`docs/source-api.md` 里的**契约示例源**不是"文档示意"，而是被测试守护的夹具：

- 示例代码块以 `// canonical-example` 开头，测试文件
  `MangaTranslaterTests/SourceAPIDocTests.swift` 内保存同一份文本；
- 测试断言：示例能通过静态校验、实现全部必需方法、元信息与文档表格一致、
  不含任何被禁用 API；
- `tools/check_docs_sync.py` 在推送前比对**两侧逐字一致**。

因此：**改 docs/source-api.md 的示例就必须同步改 SourceAPIDocTests.swift**
（反之亦然），否则预检直接失败。

## 8. 真机框架的并发约束（M4 血泪）

**现代 Vision（`RecognizeTextRequest`）并行超过 2 个会死锁**，这不是性能问题，
是「进程再也不返回」的事故。它在本项目里踩了两次：

- 产品侧：翻译编排器的并行度硬上限 2（端上翻译会话更严，只有 1）。
- **测试侧**：Swift Testing 默认并行跑用例，而 `TranslationCoreTests` 里有
  3 个真机 OCR 用例 —— 不串行化就会把测试进程整个卡死。
  表现很有迷惑性：日志里其它套件全部正常收尾，只有这一个套件「启动了但从不结束」，
  然后 job 一路挂到超时被杀（看起来像「CI 变慢」，其实是死锁）。

因此该套件标了 `@Suite("翻译核心", .serialized)`。**新增真机 OCR / OCR 相关用例
必须放在这个套件里**（或自建同样串行化的套件），别图省事塞进别的套件。

死锁还占住线程池，会间接拖慢别的套件：编排器的 `Task.detached` 就绪变慢，
一度把 5 秒的等待超时撞破，报出「只翻译了 2 页而不是 3 页」这种看起来像逻辑错的假红灯。

**最后是靠 CI 层面彻底解决的**（而不是继续调超时）：`test` 作业现在分两步——

```yaml
- name: Run Vision (OCR) suite alone   # -only-testing:MangaTranslaterTests/TranslationCoreTests
- name: Run unit tests                 # -skip-testing:MangaTranslaterTests/TranslationCoreTests
```

理由是：光把该套件内部串行化还不够，**它与其它套件并行时仍然会把线程池饿死**
（Vision 的识别调用会阻塞协作线程池上的线程，于是别的套件里 `Task.detached`
长时间抢不到线程）。表现就是那条「随机少了一页」——
实测烧掉过三轮 CI，每轮 12 分钟。分开跑之后，剩下的套件只面对轻量 CPU 工作。

两步都带**计数守卫**（`grep -qE "Test run with [1-9][0-9]* tests"`），
否则「选择器写坏 → 一条没跑 → job 绿」会变成最危险的那种假绿。

同时等待型断言的写法也改了（见 §9）：**等结果，不等「不忙」**。

## 9. 等待型断言：等结果，不等「不忙」

```swift
// ❌ 等「现在没事干」——那是给进度条用的语义，不等于「该干的事都干完了」
while controller.isBusy, Date() < deadline { … }

// ✅ 等「我断言的那个状态到位」
while Date() < deadline {
    if controller.completedCount >= expected { break }
    if controller.failureMessage != nil { break }   // 真失败时立刻停，别白等
    …
}
```

后者有两个好处：**语义正确**（等的是断言的对象），以及**失败可诊断**
（再加一句 `#expect(failureMessage == nil)`，「没跑完」和「真失败」在日志里就分得开）。
超时给得宽（30 秒）——这些用例本身是毫秒级的，慢只可能来自机器忙，
**超时太紧会把「机器忙」误判成「逻辑错」**。

## 10. 判定标准

- `test` job（两个步骤都要绿） + `build-ipa` job 成功，二者缺一不可。
- 新增或修改行为必须同步新增 / 更新测试；修 bug 时先写能复现的测试。
- 报告用例数时以 `Test run with N tests in M suites passed` 为准。
