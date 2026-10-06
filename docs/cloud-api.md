# 云服务接口契约 / Cloud service API contract

> 版本：v1（随 M4 冻结）
> 客户端实现：`MangaTranslater/Cloud/CloudServiceClient.swift`
> 服务端实现：**不在本仓库**（独立私有仓库，部署在 Cloudflare Workers + D1）。
> 本文是两侧唯一的事实来源——改接口先改这里，再同时改两侧。

---

## 1. 为什么要有云服务

页内翻译需要一个「免配置」的选项：自备密钥（BYOK）对高级用户没问题，
但对绝大多数读者来说，**先去注册一个模型服务、再找 Key、再回填**这条链路本身就是门槛。
云服务把这段成本挪到服务端：App 里登录一次，翻译就能用。

两条路线并存，互不替代：

| 路线 | 费用 | 是否需要账号 |
|---|---|---|
| BYOK（自备密钥） | 用户自付，直连 | 不需要 |
| 云服务 | 每日免费额度；订阅后不限量 | 需要（邮箱 + 验证码） |

---

## 2. 铁律：只过文本

`POST /translate` 的请求体**只有三个字段**：

```json
{ "lines": ["テキスト1", "テキスト2"], "source": "ja", "target": "zh-Hans" }
```

服务端：

- **不接收图片**（没有任何上传通道）；
- **不接收、不记录作品的 URL**（请求体里根本没有这个字段）；
- **不留存文本**：日志只记「条数 / 耗时 / token 数」，不落原文与译文；
- 不做任何与账号无关的内容分析。

这条铁律是产品对用户的核心承诺（也是合规的基础），两侧的实现都要能被
「请求体形状」的测试直接证伪——客户端的 `CloudTranslateRequest` 用显式
`CodingKeys` 把字段写死，测试断言 JSON 的键**恰好**是这三个。

---

## 3. 通用约定

| 项 | 约定 |
|---|---|
| 根地址 | `{base}`，无结尾 `/`（客户端会去掉多余的尾斜杠） |
| 编码 | 请求与响应均为 `application/json; charset=utf-8` |
| 字段命名 | **camelCase**（不引入 snake_case 转换，避免隐式策略带来的整片字段读不出） |
| 时间 | **epoch 秒**（整数），不用字符串时间 |
| 鉴权 | `Authorization: Bearer <token>` |
| 令牌 | HMAC-SHA256 签名的 JWT，有效期 30 天 |

### 3.1 错误信封

任何非 2xx 响应都带这个形状：

```json
{ "error": "quota_exceeded", "message": "daily free quota exceeded", "remainingToday": 0 }
```

| HTTP | `error` | 客户端行为 |
|---|---|---|
| 400 | `invalid_email` | 提示邮箱格式不对 |
| 400 | `invalid_code` | 提示验证码错误或过期，停在输码界面 |
| 401 | `unauthorized` | **清掉本地会话**，回到未登录态 |
| 402 | `quota_exceeded` | 显示额度用尽 + 「升级云服务」入口（不打断阅读） |
| 402 | `subscription_required` | 同上 |
| 429 | `rate_limited` | 按 `retryAfterSeconds` 提示稍后再试 |
| 5xx | 任意 | 当作可重试的临时故障提示 |

---

## 4. 端点

### 4.1 `POST /auth/email/send`

发 6 位验证码到邮箱。

请求：

```json
{ "email": "reader@example.com" }
```

响应 `200`：

```json
{ "ok": true, "expiresInSeconds": 600 }
```

规则：

- 邮箱一律**先规范化**（去首尾空白 + 转小写）再落库，否则会出现
  「大写注册、小写登录」变成两个账号；
- 验证码 6 位数字，有效期 10 分钟，**一次性**（校验成功即作废）；
- 同一邮箱 60 秒内只发一次（超出 → `429 rate_limited`，带 `retryAfterSeconds`）；
- 同一 IP 每小时上限（超出同样是 429）。返回 429 时不区分「邮箱是否存在」，
  避免变成账号枚举工具。

### 4.2 `POST /auth/email/verify`

用验证码换登录令牌。

请求：

```json
{ "email": "reader@example.com", "code": "123456" }
```

响应 `200`：

```json
{
  "token": "<jwt>",
  "expiresAt": 1790000000,
  "account": { "...": "见 4.3 的 account 对象" }
}
```

- 首次使用该邮箱即**注册**，之后即登录——两者是同一个动作；
- 「恢复订阅」就是**用同一个邮箱再登录一次**：账号与权益都挂在邮箱上，
  因此不存在另一条凭据通道。

### 4.3 `GET /me`

响应 `200`：`account` 对象。

```json
{
  "id": "u_9f2c…",
  "email": "reader@example.com",
  "plan": "free",
  "entitlementExpiresAt": null,
  "dailyLimit": 10,
  "usedToday": 4,
  "remainingToday": 6,
  "quotaResetAt": 1790038400
}
```

字段语义：

| 字段 | 说明 |
|---|---|
| `plan` | `free` / `pro`。**由服务端按有效期折算**，客户端不自己算 |
| `entitlementExpiresAt` | 订阅到期（epoch 秒）；免费档为 `null` |
| `dailyLimit` | 每日免费额度上限（页） |
| `usedToday` / `remainingToday` | 今日已用 / 剩余（页） |
| `quotaResetAt` | 今日额度重置时刻。**按 UTC+8 自然日的次日零点**，纯时间戳计算，无需定时任务 |

### 4.4 `POST /translate`

请求：

```json
{ "lines": ["…"], "source": "ja", "target": "zh-Hans" }
```

响应 `200`：

```json
{ "lines": ["…"], "remainingToday": 5 }
```

规则：

- `lines` 的**长度与顺序必须原样返回**——错位比翻错更糟（排版会把译文盖到别的框上），
  因此服务端宁可整体失败（500）也不要尽力对齐；
- 计费单位 = **行数**（一次请求里 `lines.count` 条）；
- 免费档：每行扣 1 页额度，额度不足 → `402 quota_exceeded`（**整批拒绝**，不做部分扣减）；
- 订阅档：不扣每日额度，但受**公平使用**软上限约束（默认 3000 行/月），
  超出 → `402 subscription_required`；
- 单次请求行数上限 200；超出 → `400`（客户端按 40 行分块，正常不会触发）；
- `source` 为 `auto` 时由模型自行判断原文语言。

### 4.5 `POST /webhooks/lemonsqueezy`

Lemon Squeezy 的订阅事件回调。**不属于客户端接口**，列在这里只为让两侧的
「账号 ID 怎么传过去」有据可查。

- 签名：`X-Signature` 头，HMAC-SHA256（密钥 = `LEMONSQUEEZY_WEBHOOK_SECRET`）；
  验签失败一律 401，且不做任何状态变更；
- 关联账号：购买页 URL 里带 `custom[user_id]=<account.id>`，
  webhook 的 `meta.custom_data.user_id` 会原样带回；
- 处理的事件：`subscription_created` / `subscription_updated` / `subscription_resumed`
  → 写/续 `entitlement`；`subscription_cancelled` / `subscription_expired` → 标记到期；
- **幂等**：以 `event id` 去重，重复投递不改变结果（webhook 一定会重投）。

---

## 5. 额度与时钟

- 免费额度按 **UTC+8 自然日**切分：`quotaResetAt` = 当日（东八区）次日 00:00 的 epoch 秒。
- 为什么是东八区而不是 UTC：目标用户主要在中文圈，跨零点时「今天的额度」应当
  跟着用户的作息变，而不是跟着服务器时区变。固定时区也让「什么时候重置」可预测。
- 客户端的 `QuotaPolicy` 只做**展示**（算重置时刻、算剩余比例），
  **不参与记账**：客户端统计的页数不可信，也没有必要。

---

## 6. 客户端不复用 HTTP 层重试

- 账号类请求（send / verify / me）由客户端自己的 HTTP 层做最多 1 次重试兜网络抖动；
- **翻译请求不重试**：重试会重复扣额度。是否重试由翻译编排器按页面粒度决定
  （失败页会留在失败状态，用户可以再点一次）。
