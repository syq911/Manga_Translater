# 开源许可与第三方声明

本 App 的源代码以 **Apache License 2.0** 发布。

## 1. 本 App 的许可

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

## 2. 派生说明（Apache 2.0 第 4(b) 条）

本产品包含派生自下述上游项目的工作，并已为适用于本项目而作出修改：

```
This product includes software developed at
EhViewer-Apple (https://github.com/felixchaos/EhViewer-Apple),
licensed under the Apache License, Version 2.0.
```

被搬运并修改的文件在其文件头注明了来源与修改。修改内容包括但不限于：
面向通用来源的数据模型泛化、缓存键从作品 ID 改为「来源 + 作品地址 + 页号」、
翻译后端从单一服务改为可插拔等。

## 3. 随 App 分发的第三方组件

| 组件 | 许可 | 用途 |
|---|---|---|
| GRDB.swift | MIT | 书架与阅读进度的本地数据库 |
| SwiftSoup | MIT | 源脚本的 HTML 解析（`html` 桥） |

各组件分别适用其自身许可。完整清单与其原文链接见仓库 `NOTICE` 与
`docs/architecture.md`。

## 4. 系统框架

本 App 使用 Apple 系统框架（Vision、Translation、WebKit、AVFoundation 等），
它们由 iOS 提供，适用 Apple 的许可与隐私政策。

## 5. 我们不分发内容

本仓库与本 App 均不包含任何受版权保护的第三方内容，也不包含任何源脚本。
源脚本由第三方仓库提供，其作者与许可由其自行声明。
