# MangaTranslater

A free, open-source comic reader for iOS with built-in page translation.

MangaTranslater ships with **no online sources**. You bring your own:

- **Local files** — import CBZ / ZIP / image folders and read them offline.
- **Self-hosted servers** — connect your own Komga or Kavita library.
- **Third-party source repositories** — add a repository URL in
  `Settings → Sources` to install community-built sources.

Built-in **page translation** runs entirely on-device for OCR (Apple Vision),
then translates the recognized text and typesets it back onto the page image.
You can use your own translation API key (bring-your-own-key), or subscribe to
the optional hosted cloud service.

---

一个免费开源的 iOS 漫画阅读器，内置页内 AI 翻译。

MangaTranslater **不自带任何在线源**，内容由你自己提供：

- **本地文件** —— 导入 CBZ / ZIP / 图片文件夹，离线阅读。
- **自建服务器** —— 连接你自己的 Komga 或 Kavita 库。
- **第三方源仓库** —— 在「设置 → 源仓库」里添加仓库 URL，即可安装社区维护的源。

内置**页内翻译**：用 Apple Vision 在设备端完成 OCR，翻译识别出的文字，
再按原排版回填到页图上。可自备翻译 API Key 免费使用，也可订阅官方云服务。

## Status

Early development. See [CHANGELOG.md](CHANGELOG.md) and [docs/](docs/).

## Requirements

- iOS 18.0 or later
- Built with Xcode 16 or later

## Install (sideload)

Releases ship an ad-hoc signed `MangaTranslater.ipa`, which must be re-signed
with your own certificate:

- AltStore / SideStore source: `https://github.com/syq911/Manga_Translater/releases/latest/download/source.json`
- Or download the IPA from the latest release and sign it with Sideloadly / ESign.

## Building

```bash
xcodebuild -resolvePackageDependencies -project MangaTranslater.xcodeproj -scheme MangaTranslater
xcodebuild build -project MangaTranslater.xcodeproj -scheme MangaTranslater \
  -destination "generic/platform=iOS" CODE_SIGNING_ALLOWED=NO
```

Continuous integration builds and tests run on GitHub Actions
(`.github/workflows/build-ipa.yml`). See [docs/development.md](docs/development.md).

## Writing a source

The source API contract is documented in [docs/source-api.md](docs/source-api.md).
Sources are plain JavaScript files distributed through a repository `index.json`.

## License

Apache License 2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE).

This project is a general-purpose reader and contains no third-party content.
It is not affiliated with, endorsed by, or connected to any content website.
Users are responsible for complying with the laws of their jurisdiction and the
terms of any source they choose to add.

## Disclaimer

This software is provided for learning and technical exchange. The maintainers
do not curate, host, or distribute any sources. No copyrighted content is
included in this repository.
