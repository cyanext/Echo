<p align="center"><img src="docs/icon.png" width="128" alt="回响图标"></p>

<h1 align="center">回响 Echo</h1>

<p align="center">你和 AI 聊过的，回响都记得。</p>

<p align="center">Claude Code、Codex 会话的本地归档、检索与回看工具，附带给 AI 用的命令行接口 <code>ech</code>。</p>

<p align="center"><a href="README.en.md">English</a></p>

<p align="center"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/session-dark.png"><img src="docs/session-light.png" width="860" alt="会话「回响 1.0」：左边要点栏按版本、回顾、压缩分段，悬停浮出回顾全文；标题栏下写当前所在的版本"></picture></p>

<p align="center"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/overview-dark.png"><img src="docs/overview-light.png" width="100%" alt="总览：每天的 Token、费用、消息数、AI 时长和提交，日历和每天的会话"></picture></p>

## 为什么需要它

用 Claude Code、Codex 写方案、改代码、整理资料，真正有价值的是会话里的过程：当时为什么这么定、试过哪些路、最后怎么解决的。这些很少写进文档，而会话本身留不住：

- Claude Code 默认 30 天清理会话；会话按文件夹存在本机，换一台电脑、换一个目录就找不到。
- 会话文件里大部分是截图和过程数据，原样长期保存很占空间。
- 每开一个新会话，AI 都从零开始；长会话压缩几次后，早先的细节也没了。

回响在后台归档这些会话，建好索引，让你按项目、按版本、按关键词找回当时的原话；同时把同一份数据通过 `ech` 交给 AI，让它自己查。

## 核心能力

### 会话归档与全文检索

**痛点**：记得聊过，记不得在哪个会话；原会话可能已经被清理，或者在另一台电脑上。

**实现**：

```mermaid
flowchart LR
  A["~/.claude<br>~/.codex"] -->|增量备份| B["精简 + 密钥打码"]
  B --> C[("iCloud 云盘<br>每台电脑一个文件夹")]
  C -->|备份完自动更新| D[("本机全文索引<br>SQLite FTS5")]
  D --> E["左栏搜索"]
  D --> F["ech find"]
```

- 增量备份 Claude Code、Codex 的会话。图片、思考过程不备份，工具调用的细节默认 30 天后换成占位，对话全文永久保留；Bearer 令牌、`sk-`、`ghp_` 等密钥写入前打码。
- 每台电脑只写自己的文件夹，经 iCloud 汇总，一个文件只有一个写入者，多台电脑不冲突。
- 备份完增量更新本机全文索引。会话名、你说的话、阶段总结、AI 的回复按这个优先级排序，结果按会话分组，点一处直接停在那句话上并标亮。

**价值**：会话占用下降 80% 以上，对话信息不丢；多台电脑的会话毫秒级检索。

<p align="center"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/search-dark.png"><img src="docs/search-light.png" width="100%" alt="左栏搜索「备份」，按会话列出命中处，正文里标亮"></picture></p>

### 版本时间轴与消息定位

**痛点**：一个项目的会话动辄几千轮、压缩好几次，想知道「某个版本当时怎么定的」，只能一路往上翻。

**实现**：

- 对话按 git 提交里的版本号、手动压缩点和 Claude 的回顾（recap）分段，左侧要点栏一点就跳到当时；标题栏随滚动显示当前所在的版本。
- 右侧「我的消息」按天列出你发过的每一条，点一条定位到那句话，也能在里面搜。
- 思考过程和工具调用收成一行，点开再看；AI 干活时你插进去的话也按你的消息显示。

**价值**：一个项目按版本从头看到尾，复盘、交接时能讲清楚每一步为什么这么做。

### 面向 AI 的上下文接口：ech

**痛点**：新会话不知道上次做到哪；写周报要翻聊天记录、翻 git log；AI 自己去读原会话文件又慢又费 Token。

**实现**：

```mermaid
flowchart LR
  U["你：接着上次那个做"] --> AI["Claude Code / Codex"]
  AI -->|"ech find / list"| X[("本机索引<br>总览数据")]
  AI -->|"ech context"| X
  X -->|纯文本| AI
```

回响装好后自带命令行工具 `ech` 和配套 skill。AI 听到「上次聊到哪了」「以前为什么这么定」时自己去查，查询命令只读：

```text
$ ech context e0b9311e
回响 1.0 · 演示电脑 · e0b9311e · 第 7 段起（最近一次压缩之后）（第 57 行起）
最近一次回顾（11-22 10:26）：1.0 的功能都做完了：备份、浏览、总览、搜索、ech、目录管理、开源和自动更新。还没做的：记忆管理。

[11-21 10:19] 阶段总结：…
1. 备份、浏览、总览已完成
2. 下一步：全局搜索、给 AI 用的命令行

[11-21 10:32] 我：记得聊过，记不得在哪个会话，加个搜索
  · 工具 Read ~/Projects/回响/App/EchoApp.swift
  · 工具 Bash zsh 代码/应用/tests/run.sh
…
```

```text
$ ech list --since 7d
2026-11-17 至 2026-11-23：16 个会话，我的消息 111 条，Token 35.2M，提交 13 次（总览数据）
11-23 回响 · 记忆管理需求 · 5 条 · 1.3M · beff8384
11-22 回响 · 回响 1.0 · 16 条 · 4.5M · 提交 8（0.1.0 至 0.8.0 共 8 个版本） · e0b9311e
11-22 记账本 · 分类图标改版（续） · 8 条 · 2.5M · 提交 1（1.15.0） · ae5e3f1f
…
```

**价值**：新会话不用重新交代背景，Codex 也能接上 Claude 的进度；周报、复盘一条命令拿到全部会话、提交和版本，各台电脑、各家 AI 都在。

### 会话目录管理

**痛点**：项目文件夹一改名、一挪位置，Claude Code 的 `/resume` 就找不到原来的会话；Codex 按它数据库里记的目录归类，也跟不过去；会话越攒越多，没人清理。

**实现**：

```mermaid
flowchart LR
  A["改名 / 移动 / 拖动<br>ech mv"] --> B{"会话来自"}
  B -->|Claude Code| C["会话文件挪到新目录<br>对应的 projects/"]
  B -->|Codex| D["改数据库里的 cwd<br>改前整库备份"]
  C --> E["新位置 /resume 能续上"]
  D --> E
```

- 左栏目录树里给文件夹改名、移动，会话随之移动；会话可以拖到别的文件夹。
- 在访达或 NAS 上改过名的文件夹，左栏标出「已不存在」，右键「找到新位置」按名字匹配出最可能的新目录，一步接上。
- `ech mv` 让 AI 整理目录时把会话一起带走，`--dry-run` 先预览。
- 会话改名、删除（移到废纸篓，能放回）；很久没用的会话，备份完整后自动移到废纸篓。

**价值**：文件夹随便整理，会话不丢、照样能续上，本机的会话目录也不再越攒越大。

<p align="center"><img src="docs/folders.png" width="100%" alt="「旧官网」在访达里改了名，左栏标出已不存在；右键「找到新位置…」匹配到「官网改版」，确认后把 2 个会话移过去"></p>

## 其他功能

- **用量总览**：每天的消息数、Token 用量和折合费用、AI 干活时长，git 提交和版本挂到对应的会话上；删掉的会话统计照算。
- **多应用**：Claude Code、Codex 一起备份、浏览、统计，按应用筛选。
- **浅色、深色**：跟随系统，也能手动切换。
- **自动更新**：有新版本时提示，一键下载安装，签名和当前版本一致才替换。


## 安装

在终端里运行：

```bash
curl -fsSL https://raw.githubusercontent.com/cyanext/Echo/main/install.sh | zsh
```

会下载最新版装到 `~/Applications` 并打开。也可以到 [Releases](https://github.com/cyanext/Echo/releases) 下载 `Echo-<版本>.zip`，解压后把「回响」拖到「应用程序」；用浏览器下载的，第一次打开如果提示「无法验证开发者」，到「系统设置 > 隐私与安全性」底部点「仍要打开」。

需要 macOS 14 或更新的版本、Apple 芯片。第一次打开按引导选好备份位置、要备份的应用和清理规则，macOS 询问能否访问文件夹时点「允许」。

## ech 命令

| 命令 | 做什么 |
|---|---|
| `ech find <关键词>` | 在全部会话里找，按会话列出命中处，每处带一个引用（`会话#段号`）；`--app`、`--since`、`--project` 过滤，`--tools` 连工具调用一起找 |
| `ech segs <会话>` | 会话的分段：起止时间、提交的版本、每段第一句话 |
| `ech read <会话>#<段号>` | 读一段对话的原文；`#L1200-1500` 按行读，`--tools` 带上工具输出 |
| `ech context <会话>` | 续上一个会话：最近的回顾、阶段总结和之后的全部对话 |
| `ech list --since 7d` | 按时间列会话、我的消息、Token、提交和版本；日期也能写 `2026-11-16`、`11-16` |
| `ech mv <旧路径> <新路径>` | 改文件夹名或移动文件夹，本机的会话随之移动；`--dry-run` 预览 |
| `ech backup` / `ech index` | 立即备份并更新索引 / 只更新索引和总览数据 |
| `ech schema [命令]` | 各命令的参数（JSON），给 AI 看 |

输出纯文本，一页最多 8000 字，`--page` 翻页，`--json` 给脚本用。配套 skill 装在 `~/.claude/skills/ech`，本机有 Codex 时也装到 `~/.codex/skills/ech`。

## 数据安全

- 只读 `~/.claude`、`~/.codex` 里的会话，会话内容一行不改。只有你点了改名、删除、移动，或开着自动清理时，才会改动会话文件；删除一律移到废纸篓。
- 备份只写到你选的文件夹，除了 iCloud 不传到任何地方。
- 联网只有两处，都只发一个请求，不带任何本机信息：每周下载一次公开的模型价格表，每天检查一次新版本（可在设置里关掉）。

## 从源码编译

需要 Xcode 命令行工具和 zstd（`brew install zstd`）：

```bash
zsh 代码/应用/build.sh install
```

没有签名证书时用临时签名。开发说明见 [开发说明.md](开发说明.md)。

## 许可

[MIT](LICENSE)
