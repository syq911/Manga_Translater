# Open-source licences and third-party notices

The App's source code is released under the **Apache License 2.0**.

## 1. The App's licence

```
MangaTranslater
Copyright 2026 MangaTranslater contributors

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```

## 2. Derivative work (Apache 2.0 section 4(b))

This product includes work derived from the upstream project below, modified for
use in this project:

```
This product includes software developed at
EhViewer-Apple (https://github.com/felixchaos/EhViewer-Apple),
licensed under the Apache License, Version 2.0.
```

Files that were ported and modified carry a notice in their header comment. The
modifications include, among others: generalizing the data model to arbitrary
sources, changing the translation cache key from a site-specific item ID to
"source + title URL + page index", and making the translation backend pluggable.

## 3. Third-party components distributed with the app

| Component | Licence | Purpose |
|---|---|---|
| GRDB.swift | MIT | Local database for the library and reading progress |
| SwiftSoup | MIT | HTML parsing for source scripts (the `html` bridge) |

Each component is governed by its own licence. The full list, with links, is kept in
`NOTICE` and `docs/architecture.md`.

## 4. System frameworks

The App uses Apple system frameworks (Vision, Translation, WebKit, AVFoundation and
others) supplied by iOS, governed by Apple's licences and privacy policy.

## 5. We do not distribute content

Neither this repository nor the App contains any copyrighted third-party content,
and no source scripts are included. Source scripts are provided by third-party
repositories under licences declared by their own authors.
