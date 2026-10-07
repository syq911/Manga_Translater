# 上线清单（必须由人完成的部分）/ Going live

代码、测试与本地闭环已经全部就绪（`bash tools/preflight.sh` 13 项全绿，
CI 的 `build-ipa` + `test` 全绿）。剩下的事都需要**外部账号**，
无法在仓库里自动完成，因此集中列在这里。

> 原则：仓库里所有对外地址都是**占位符**（`mangatranslater.com`、
> `api.mangatranslater.com`、`REPLACE-ME` 的结账链接、`support@` 邮箱）。
> 上线就是把它们换成真值——所以下面每一项都写明「改哪里」。

---

## 1. 域名与官网

1. 注册域名（建议 `.com`，与 Bundle ID `com.mangatranslater.ios` 对齐）。
2. 托管 `website/`（两种都行，`website/` 里全是静态文件、无构建步骤）：
   - **GitHub Pages**：仓库 Settings → Pages → Source 选 “GitHub Actions”，
     然后手动跑一次 `.github/workflows/pages.yml`；
   - 或 **Cloudflare Pages**：Build command 留空，输出目录填 `website`。
3. 换掉代码里的默认地址：
   - `Packages/AppCore/Sources/AppCore/AppSettings.swift` 的
     `defaultWebsiteURL` / `defaultCloudServiceBaseURL`；
   - `website/index.html`、`website/upgrade.html` 里的 GitHub 仓库地址（若换了 owner）。

自检：`python3 tools/build_website.py`（会提示还剩下哪些占位符）。

## 2. 云服务端（Cloudflare Workers + D1）

服务端源码在**仓库之外**（`MangaTranslater-Cloud/`，私有）。上线步骤：

```bash
cd MangaTranslater-Cloud
npm install                       # 只为 wrangler
npx wrangler d1 create mangatranslater
# 把返回的 database_id 填进 wrangler.toml
npx wrangler d1 execute mangatranslater --file=schema.sql --remote
npx wrangler secret put JWT_SECRET
npx wrangler secret put DEEPSEEK_API_KEY
npx wrangler secret put RESEND_API_KEY
npx wrangler secret put LEMONSQUEEZY_WEBHOOK_SECRET
npx wrangler secret put MAIL_FROM           # 例如 no-reply@your-domain
npx wrangler deploy
```

- `JWT_SECRET` 用随机长串（例如 `openssl rand -hex 32`），**不要**提交进任何仓库。
- 绑定自定义域（`api.<你的域名>`），与 App 的 `defaultCloudServiceBaseURL` 一致。
- 上线后先打一次健康检查：`GET https://api.<域名>/health` 应当返回
  `{"ok":true,"service":"mangatranslater-cloud","apiVersion":1}`。

## 3. 邮件发送（登录验证码）

1. 注册 Resend（或同类服务），验证发信域名；
2. 把 API Key 写进上一步的 `RESEND_API_KEY`，`MAIL_FROM` 用已验证域名的地址；
3. **冒烟测试**：在 App 里用一个真实邮箱请求验证码，确认能收到、能登录。

## 4. 上游模型

1. 申请 DeepSeek（或任何 OpenAI 兼容服务）的 API Key，写进 `DEEPSEEK_API_KEY`；
2. 在服务商后台设**消费上限**——免费额度是按页计费的，被人刷起来是要花钱的；
3. `DEEPSEEK_MODEL` 默认 `deepseek-v4-flash`（`deepseek-chat` 别名已弃用，别回退）。

## 5. 收款（Lemon Squeezy）

1. 注册 Lemon Squeezy（它是 merchant of record，负责计税与合规）；
2. 建一个订阅产品（定价见 `website/upgrade.html`，例如 $1.99/月）；
3. 复制结账链接，替换 `website/upgrade.html` 里的 `REPLACE-ME`；
4. 在 Lemon Squeezy 后台配 webhook，指向
   `https://api.<你的域名>/webhooks/lemonsqueezy`，事件选
   `subscription_created` / `subscription_updated` / `subscription_resumed` /
   `subscription_cancelled` / `subscription_expired`；
   把签名密钥写进 `LEMONSQUEEZY_WEBHOOK_SECRET`；
5. 购买页 URL 里的 `custom[user_id]` 由 App 自动带上（`CloudAccountModel.purchaseURL`），
   服务端据此把订阅绑到账号——**不要**把这个参数去掉。

**App 内不接任何支付 SDK、不出现收银台**：付款只在官网完成。
这条不是风格偏好，而是资金流切割的前提（手册 7.4）。

## 6. 法务文本

1. 把 `docs/legal/*.md` 里的 `privacy@` / `support@` 邮箱换成你的真实邮箱；
   改完必须重跑 `python3 tools/check_legal_sync.py --emit`（App 内置副本会同步更新），
   再跑 `python3 tools/build_website.py`（官网同步）。
2. 隐私政策与使用条款已覆盖手册 10.3 要求的内容（不存图、第三方 LLM 处理、
   日志保留期、账号注销入口、18+ 条款）。若你面向特定司法辖区正式运营，
   建议请律师过一遍措辞。
3. **不要**在任何文案里出现具体的内容站点名（`tools/check_redlines.py` 会拦，
   但人也别写）。

## 7. App 内的默认值

| 位置 | 项 | 换成 |
|---|---|---|
| `AppSettings.defaultWebsiteURL` | `https://mangatranslater.com` | 你的官网 |
| `AppSettings.defaultCloudServiceBaseURL` | `https://api.mangatranslater.com` | 你的 API 域名 |
| `.github/scripts/build_altstore_source.py` 的 `REPO` | `syq911/Manga_Translater` | 你的仓库（CI 里由 `GITHUB_REPOSITORY` 自动覆盖，本地跑要改） |
| `README.md` / `website/*.html` | GitHub 链接 | 你的仓库 |

## 8. 发版

```bash
git tag -a v1.0.0 -m "v1.0.0"
git push origin v1.0.0
```

然后轮询 Actions，确认 **`build-ipa` + `test` + `release` 三个 job 全绿**，
并在 Release 页确认附件里有 `MangaTranslater.ipa` 与 `source.json`。

最后在真机上验证 AltStore 源：
`https://github.com/<owner>/<repo>/releases/latest/download/source.json`
能加成源、能看到图标与截图、能装上、版本号与 App 内一致。

## 9. 上线之后

- **看成本**：上游模型的消费上限、免费额度的实际用量（每人每天 10 页封顶）；
- **抽查隐私承诺**：随便查一次数据库，确认里面没有原文、译文、图片或作品地址
  （`MangaTranslater-Cloud/test/closed-loop.test.mjs` 里的那条断言就是这件事）；
- **看错误日志**：托管的请求日志通常保留 7 天，只看状态码与耗时；
- **订阅对账**：Lemon Squeezy 的订阅数与数据库里的 `pro` 账号数应当对得上。

## 10. 上线时不要做的事（红线）

1. 不内置、不推荐、不收录任何源；不在任何渠道「提供源」；
2. 不在国内平台推广，也不面向国内用户收费；
3. 服务端不碰图片，日志不落文本内容，不存作品地址；
4. 不把密钥（JWT / DeepSeek / Resend / Lemon Squeezy）提交进任何仓库，也不写进 App；
5. 不在 App 名、官网、收款页里出现任何具体内容站点名。

---

## 快速核对表

- [ ] 域名已注册，官网可访问（HTTPS）
- [ ] 发布页附件可访问：`releases/latest/download/source.json`
- [ ] Cloudflare Worker 已部署，`/health` 正常
- [ ] D1 已执行 `schema.sql`
- [ ] 四个 secret 已配置（JWT / DeepSeek / Resend / Lemon Squeezy webhook）
- [ ] 验证码邮件真的能收到
- [ ] Lemon Squeezy 产品与 webhook 已配，结账链接已替换 `REPLACE-ME`
- [ ] 法务文本里的邮箱已替换，且 `check_legal_sync --emit` 与 `build_website` 都跑过
- [ ] `AppSettings` 里的两个默认地址已换
- [ ] `v1.0.0` tag 已推送，三个 CI job 全绿
- [ ] AltStore 里加源、安装、版本号一致
- [ ] 数据库抽查过：没有原文 / 译文 / 图片 / 作品地址
