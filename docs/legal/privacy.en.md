# MangaTranslater Privacy Policy

Last updated: 2026-10-07 · Applies to MangaTranslater for iOS 1.0.0 and later

MangaTranslater (the "App") is a comic reader for iOS. It **ships with no online
content**: what you read comes either from local files you import yourself, from
third-party source repositories you add yourself, or from your own Komga / Kavita
server.

This policy states, in plain language, **what stays on your device, what leaves it,
and for how long we keep anything**.

## 1. The short version

- OCR (text recognition) runs **entirely on your device**. Images **never** leave
  your phone.
- Only the **recognized text** is sent for translation — text only: no images, no
  comic titles, no comic URLs, no reading history.
- The hosted service's request body has exactly three fields: `lines` (the text),
  `source`, and `target`. This is enforced by the server's database schema, which
  has no column that could hold an image, a URL, or any source text.
- Keys and sign-in tokens live in the system keychain, excluded from iCloud backup.
- We ship no analytics SDK, no advertising SDK, and no crash-reporting SDK.

## 2. Data that stays on your device

| Data | Where | Why | iCloud backup |
|---|---|---|---|
| Reading settings (direction, font scale, languages) | Local preferences | Remember your choices | Yes (system default) |
| Library, categories, reading progress | Local database | Your library and "where you left off" | Yes (system default) |
| Imported files and downloaded chapters | App sandbox | Offline reading | No (excluded by the app) |
| Translation cache (finished page images) | App sandbox | Never translate — or spend quota on — the same chapter twice | No |
| Your own translation API key | System keychain | Call your own translation service | No |
| Source sign-in cookies | App sandbox | Access sources you have signed in to | No |
| Cloud sign-in token | System keychain | Passwordless access to the hosted service | No |
| Diagnostics log | App sandbox documents | Troubleshooting; one-tap clear in Settings → About | Only if you export it via the Files app |

The diagnostics log records technical events only (request hostnames, status codes,
durations, error kinds). **It does not record source text, translations, image data,
or cookie values**; API keys and tokens are redacted before anything is written.
You can inspect its size, clear it, or pull it out through the Files app at any time.

## 3. Data that leaves your device

Only three things ever leave the device, and none of them is covert:

**1. Addresses you ask the App to visit.** Third-party source repositories you add,
the sites their scripts request, and your own Komga / Kavita server all receive
requests from the App — exactly as if you opened them in a browser. Those requests
carry your IP address and request content. **What their operators see and do with it
is up to them and outside our control.**

**2. Text sent for translation.** Once you turn on page translation:

| Backend | What leaves the device | Where it goes |
|---|---|---|
| Your own API key | Recognized text + your API key | The endpoint you configured (any OpenAI-compatible service) |
| Hosted cloud service | Recognized text | Our server, which forwards it to an upstream model service |
| On-device translation | Nothing (the system framework runs locally; downloading a language pack the first time may use the network) | — |

**3. Hosted-service account data**, and only if you sign in:

- your **email address** (used to send sign-in codes and restore subscriptions);
- an account identifier, a **per-day count of translated pages**, and your
  **subscription expiry**;
- a payment reference produced by the payment processor (Lemon Squeezy) —
  **we never handle your card number**.

The server database has **five tables**: accounts, verification codes, quota
counters, entitlements, and webhook deduplication. **No column in any of them can
hold source text, translations, images, or comic URLs.** Even a full database dump
would not reveal what anybody is reading.

We do not use this data for advertising or profiling, and we do not sell it.

## 4. Third-party processors

| Service | When it is used | What it can see |
|---|---|---|
| The translation service you choose (own-key mode) | When you translate | Recognized text and your own account details |
| Our upstream model provider (cloud mode) | When you translate via the cloud | Recognized text (no images, no comic URLs) |
| Email delivery service | When you request a sign-in code | Your email address and that one message |
| Lemon Squeezy (merchant of record) | When you buy a subscription on the website | Your payment details and email (**we never see card numbers**) |
| Cloudflare (hosting) | While the cloud service runs | Request metadata (time, route, status code) |
| Apple (on-device translation, system frameworks) | When you use on-device translation or system OCR | Governed by Apple's own privacy policy |

The App integrates **no payment SDK** and shows no checkout: all payments happen on
the website.

## 5. Retention

| Data | Retention |
|---|---|
| Cloud account and entitlement records | Until you delete your account (section 6) |
| Daily quota counters | Stored per calendar day; deleted with the account |
| Sign-in codes | 10 minutes |
| Server request logs | Kept by the hosting platform, normally no longer than 7 days; no source text or translations |
| On-device translation cache | Until you clear it in Settings, or delete the app |

## 6. Your controls (including account deletion)

- **Delete your account**: Settings → Account & Cloud → Delete account (you will be
  asked to type your email again to confirm). We delete the account along with its
  quota counters and entitlement records **within 30 days**. Transaction records
  related to your purchase are retained by the merchant of record as required by law.
- **Sign out**: clears this device only; your account and subscription remain. Sign
  in again with the same email to restore them.
- **Clear the translation cache, diagnostics log, or downloads**: one tap each in
  Settings.
- **Export the diagnostics log**: via the Files app — read it before you share it.

## 7. Minors

The App is not directed at minors. Adult-content sources are **hidden by default**
and can only be enabled after explicitly confirming "I am 18 or older". The App
bundles, recommends, and hosts no content site, and will not fetch content for you.

## 8. Security

- Credentials and tokens prefer the system keychain, falling back to local storage
  when the keychain is unavailable (with a redacted log entry).
- The hosted service is HTTPS-only; expired JWTs make the client fall back to the
  signed-out state.
- Keys and tokens in request payloads are redacted before logging.
- That said, no system is "absolutely secure". This is open-source software
  distributed by sideloading; please judge the trustworthiness of the sources and
  repositories you add.

## 9. Changes

Changes will be recorded in the repository changelog and on the website, and the
date at the top of this document will be updated. Material changes to data handling
will also be surfaced inside the App.

## 10. Contact

Privacy questions and data-deletion requests: **privacy@mangatranslater.com**.
(Replace with your real address before going live — see `docs/going-live.md`.)
