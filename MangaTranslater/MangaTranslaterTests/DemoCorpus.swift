//
//  DemoCorpus.swift
//  MangaTranslaterTests
//
//  自测仓库语料：**由 tools/make_demo_repo.py --emit-swift 生成，请勿手改**。
//
//  为什么单独一个文件：这套页面既是「手工联调用的自测仓库」的内容，
//  也是 CI 里跑通「仓库 → 安装 → 浏览 → 详情 → 章节 → 阅读」的语料。
//  两侧必须逐字一致，由 tools/check_demo_repo.py 在推送前逐块比对。
//
//  块顺序固定（与生成器一致）：index.json / demo.js / 8 个页面。
//

import Foundation

enum DemoCorpus {

    /// 托管地址（与 demo.js 里的 baseUrl 一致）。
    static let baseURL = "http://127.0.0.1:8000"

    /// 夹具用的真实 PNG 字节（内容不参与与生成器的比对，只需是合法图片）。
    static let pngBytes = Data(base64Encoded: iVBORw0KGgoAAAANSUhEUgAAAAwAAAASCAIAAADgy6hbAAAAFUlEQVR42mNwXuBOEDGMKhpVRG9FACMT+3HfsgthAAAAAElFTkSuQmCC)!

    /// 页面文件名（顺序与生成器一致）。
    static let pageNames = [
        "popular-1.html",
        "popular-2.html",
        "latest-1.html",
        "search.html",
        "manga-1.html",
        "manga-2.html",
        "chapter-1.html",
        "chapter-2.html",
    ]

    /// 生成器里同名常量的逐字副本（顺序即比对顺序，勿调整）。
    static let indexJSON = """
    [
      {
        "name": "Demo Source",
        "fileName": "demo.js",
        "key": "demo",
        "version": "1.0.0",
        "description": "本机联调用中性示例源（由 tools/make_demo_repo.py 生成）"
      }
    ]

    """

    static let sourceScript = """
    // demo.js —— 中性自测源。仅供本机联调，不含任何真实站点。
    // 与 tools/make_demo_repo.py 生成的静态页面配套使用。
    const source = {
      id: "demo",
      name: "Demo Source",
      lang: "all",
      baseUrl: "http://127.0.0.1:8000",
      nsfw: false,
      version: "1.0.0",
      rateLimitMs: 0
    };

    // 列表页结构一致，抽出来复用
    function items(doc) {
      return doc.select("article.item").map(function (node) {
        return {
          title: node.select("a.title").text(),
          coverUrl: node.select("img.cover").attr("src"),
          url: node.select("a.title").attr("href")
        };
      });
    }

    async function getPopularManga(page) {
      const res = await net.get(source.baseUrl + "/popular-" + page + ".html");
      const doc = html.parse(res.body);
      return { mangas: items(doc), hasNextPage: doc.select("a.next").length > 0 };
    }

    async function getLatestUpdates(page) {
      const res = await net.get(source.baseUrl + "/latest-" + page + ".html");
      const doc = html.parse(res.body);
      return { mangas: items(doc), hasNextPage: doc.select("a.next").length > 0 };
    }

    async function getSearchManga(page, query, filters) {
      const url = source.baseUrl + "/search.html?q=" + encodeURIComponent(query) + "&page=" + page;
      const res = await net.get(url);
      const doc = html.parse(res.body);
      return { mangas: items(doc), hasNextPage: false };
    }

    async function getMangaDetails(mangaUrl) {
      const res = await net.get(mangaUrl);
      const doc = html.parse(res.body);
      return {
        title: doc.select("h1.title").text(),
        author: doc.select("span.author").text(),
        artist: doc.select("span.artist").text(),
        description: doc.select("div.summary").text(),
        genres: doc.select("span.genre").map(function (node) { return node.text(); }),
        status: doc.select("span.status").text(),
        coverUrl: doc.select("img.cover").attr("src")
      };
    }

    async function getChapterList(mangaUrl) {
      const res = await net.get(mangaUrl);
      const doc = html.parse(res.body);
      return doc.select("ul.chapters li").map(function (node) {
        return {
          name: node.select("a").text(),
          url: node.select("a").attr("href"),
          chapterNumber: node.attr("data-number"),
          dateUpload: node.attr("data-date")
        };
      });
    }

    async function getPageList(chapterUrl) {
      const res = await net.get(chapterUrl);
      const doc = html.parse(res.body);
      return doc.select("div.pages img").map(function (node) {
        return node.attr("data-src");
      });
    }

    function getFilters() {
      return [
        { type: "text", key: "author", name: "作者" },
        {
          type: "select",
          key: "genre",
          name: "分类",
          options: [
            { label: "全部", value: "" },
            { label: "冒险", value: "adventure" }
          ]
        }
      ];
    }

    """

    /// 页面：文件名 → 内容（顺序与生成器一致）。
    static let pages: [String: String] = [
        "popular-1.html": """
    <!DOCTYPE html>
    <html lang="en">
    <head><meta charset="utf-8"><title>Demo · Popular (page 1)</title></head>
    <body>
    <h1>Popular (page 1)</h1>
    <article class="item">
      <a class="title" href="/manga-1.html">Demo Manga One</a>
      <img class="cover" src="/img/cover-1.png" alt="cover">
      <span class="author">Demo Author</span>
    </article>
    <article class="item">
      <a class="title" href="/manga-2.html">Demo Manga Two</a>
      <img class="cover" src="/img/cover-2.png" alt="cover">
      <span class="author">Demo Author</span>
    </article>
    <a class="next" href="/popular-2.html">Next page</a>
    </body>
    </html>

    """,
        "popular-2.html": """
    <!DOCTYPE html>
    <html lang="en">
    <head><meta charset="utf-8"><title>Demo · Popular (page 2)</title></head>
    <body>
    <h1>Popular (page 2)</h1>
    <article class="item">
      <a class="title" href="/manga-2.html">Demo Manga Two</a>
      <img class="cover" src="/img/cover-2.png" alt="cover">
      <span class="author">Demo Author</span>
    </article>
    </body>
    </html>

    """,
        "latest-1.html": """
    <!DOCTYPE html>
    <html lang="en">
    <head><meta charset="utf-8"><title>Demo · Latest (page 1)</title></head>
    <body>
    <h1>Latest (page 1)</h1>
    <article class="item">
      <a class="title" href="/manga-1.html">Demo Manga One</a>
      <img class="cover" src="/img/cover-1.png" alt="cover">
      <span class="author">Demo Author</span>
    </article>
    </body>
    </html>

    """,
        "search.html": """
    <!DOCTYPE html>
    <html lang="en">
    <head><meta charset="utf-8"><title>Demo · Search</title></head>
    <body>
    <h1>Search results</h1>
    <p class="query">The query string is accepted but ignored by this static demo.</p>
    <article class="item">
      <a class="title" href="/manga-1.html">Demo Manga One</a>
      <img class="cover" src="/img/cover-1.png" alt="cover">
      <span class="author">Demo Author</span>
    </article>
    <article class="item">
      <a class="title" href="/manga-2.html">Demo Manga Two</a>
      <img class="cover" src="/img/cover-2.png" alt="cover">
      <span class="author">Demo Author</span>
    </article>
    </body>
    </html>

    """,
        "manga-1.html": """
    <!DOCTYPE html>
    <html lang="en">
    <head><meta charset="utf-8"><title>Demo Manga One</title></head>
    <body>
    <h1 class="title">Demo Manga One</h1>
    <img class="cover" src="/img/cover-1.png" alt="cover">
    <span class="author">Demo Author</span>
    <span class="artist">Demo Artist</span>
    <span class="status">ongoing</span>
    <div class="summary">A neutral sample title used to exercise the reader end to end.</div>
    <span class="genre">Adventure</span>
    <span class="genre">Comedy</span>
    <ul class="chapters">
      <li data-number="1" data-date="2024-01-02T03:04:05Z"><a href="/chapter-1.html">Chapter 1</a></li>
      <li data-number="2" data-date="2024-02-03"><a href="/chapter-2.html">Chapter 2</a></li>
    </ul>
    </body>
    </html>

    """,
        "manga-2.html": """
    <!DOCTYPE html>
    <html lang="en">
    <head><meta charset="utf-8"><title>Demo Manga Two</title></head>
    <body>
    <h1 class="title">Demo Manga Two</h1>
    <img class="cover" src="/img/cover-2.png" alt="cover">
    <span class="author">Demo Author</span>
    <span class="artist">Demo Artist</span>
    <span class="status">completed</span>
    <div class="summary">A second neutral sample title, used to verify per-title details.</div>
    <span class="genre">Comedy</span>
    <ul class="chapters">
      <li data-number="1" data-date="2023-12-31"><a href="/chapter-2.html">Chapter 1</a></li>
    </ul>
    </body>
    </html>

    """,
        "chapter-1.html": """
    <!DOCTYPE html>
    <html lang="en">
    <head><meta charset="utf-8"><title>Demo Manga One · Chapter 1</title></head>
    <body>
    <h1>Chapter 1</h1>
    <div class="pages">
      <img data-src="/img/page-1.png" alt="page 1">
      <img data-src="/img/page-2.png" alt="page 2">
    </div>
    </body>
    </html>

    """,
        "chapter-2.html": """
    <!DOCTYPE html>
    <html lang="en">
    <head><meta charset="utf-8"><title>Demo Manga One · Chapter 2</title></head>
    <body>
    <h1>Chapter 2</h1>
    <div class="pages">
      <img data-src="/img/page-3.png" alt="page 3">
    </div>
    </body>
    </html>

    """
    ]
}
