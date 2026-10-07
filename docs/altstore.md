# AltStore / SideStore 源 / AltStore source

## 1. 它解决什么问题

iOS 在内核层强制代码签名，App 无法自更新。所以本项目的分发方式是：

```
GitHub Actions ──→ ad-hoc 签名的 MangaTranslater.ipa ──→ Release 附件
                                    │
                          生成 source.json（源清单）
                                    │
        用户在 AltStore / SideStore 里添加一次源地址
                                    │
              之后新版本出现在更新列表里，用用户自己的证书重签安装
```

用户只需要加一次源：

```
https://github.com/syq911/Manga_Translater/releases/latest/download/source.json
```

`releases/latest` 永远指向最新正式发布，所以这个地址是**固定的**，
内容随版本自动更新。

## 2. 清单怎么生成

- 生成脚本：`.github/scripts/build_altstore_source.py`
- 触发时机：`.github/workflows/build-ipa.yml` 的 `release` job（仅 `v*` tag）
- 做法：拉取仓库的全部 Release → 过滤 → 组装 → 作为本次 Release 的附件上传
  （`gh release upload ... source.json --clobber`）
- 离线校验：`python3 tools/check_altstore_source.py`（预检第 12 项）

**为什么不只放最新一版**：AltStore 需要看到完整的 `versions` 数组，
才能判断「有没有比本机更新的版本」。只放最新一条会让降级与跳版判断失效。

## 3. 字段依据

| 字段 | 来源 | 填错会怎样 |
|---|---|---|
| `name` / `identifier` | 常量 | `identifier` 是 AltStore 区分源的键；改动等于换了一个源，用户的更新会断 |
| `sourceURL` | 固定为 `releases/latest/download/source.json` | 指向不存在的位置时，添加源会直接失败 |
| `apps[].bundleIdentifier` | `com.mangatranslater.ios`（与工程一致） | 与 ipa 内的不一致时，AltStore 认为「这不是同一个 App」，装不上 |
| `apps[].subtitle` | 一句话描述（英文） | 只影响列表观感 |
| `apps[].localizedDescription` | 完整描述 | 同上 |
| `apps[].iconURL` | 仓库里的 `AppIcon-1024.png` raw 链接 | 404 会让列表显示成空白方块 |
| `apps[].tintColor` | `4A3FA8`（与 App 强调色一致） | 只影响观感 |
| `apps[].category` | `entertainment` | 只影响观感 |
| `apps[].screenshots` | 仓库里的三张中性截图（`website/assets/screenshots/`） | 同上；截图是**合成**的界面示意，不含任何第三方内容 |
| `versions[].version` | tag 去掉 `v` 前缀 | 与 ipa 内的 `CFBundleShortVersionString` 不一致会导致「更新提示反复出现」 |
| `versions[].date` | Release 的 `published_at` | AltStore 据此排序 |
| `versions[].downloadURL` | Release 附件里 `.ipa` 的地址 | 形状错误（不是 `releases/download/<tag>/<file>.ipa`）时下载 404 |
| `versions[].size` | 附件的字节数 | 用于显示进度与校验 |
| `versions[].minOSVersion` | **从 ipa 内的 `Info.plist` 读取** | 写死一个常量就会漂移；填大了用户装不上，填小了装完闪退 |

`minOSVersion` 刻意不写死：它随工程设置变化，而「装不上」这类问题从报错里
很难看出根因（用户只会看到「无法安装」）。脚本会真的把 ipa 下下来、
读里面 `Payload/*.app/Info.plist` 的 `MinimumOSVersion`；读失败则回退 `18.0`
并打一条警告，不让整个清单挂掉。

## 4. 本地怎么验

**离线（不需要网络、不需要设备）**：

```bash
python3 tools/check_altstore_source.py
```

它用合成的 Release 数据把生成脚本跑一遍，逐条断言字段、排序、URL 形状，
并确认清单里引用的图标与截图在仓库里真实存在。

**真机**：AltStore / SideStore 只接受 **HTTPS** 的源地址。
本机 `python3 -m http.server` 给的 `http://` 地址它们不收，
需要一条 HTTPS 隧道（例如把 `website/` 用任意静态托管上线，或临时用隧道工具
把本机端口暴露成 https），再在设备上「Add Source」填那个地址。

## 5. 上线清单

1. 仓库 Settings → Pages → Source 选 “GitHub Actions”（官网用）；
2. 打第一个 tag（`v1.0.0`）→ 等 `build-ipa` + `test` + `release` 全绿；
3. 打开 Release 页确认三个附件齐备：`MangaTranslater.ipa`、`source.json`
   （以及 `gh` 上传时的日志）；
4. 用 `https://github.com/<owner>/<repo>/releases/latest/download/source.json`
   在 AltStore 里「Add Source」验证：能看到图标、截图、版本与描述；
5. 装一次、确认版本号与 App 内「设置 → 关于 → 版本」一致。

以上第 1 步与域名、Cloudflare、Lemon Squeezy 等**必须由人来做的**外部配置，
统一整理在 `docs/going-live.md`。
