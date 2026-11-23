<p align="center"><img src="docs/icon.png" width="128" alt="回响图标"></p>

<h1 align="center">回响 Echo</h1>

<p align="center">你和 AI 聊过的，回响都记得。</p>

<p align="center">Claude Code、Codex 会话的备份、回看和检索，AI 也能自己查。<br>Mac 应用，开源免费。</p>

<p align="center"><a href="#安装">安装</a> · <a href="README.en.md">English</a></p>

<p align="center"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/session-dark.png"><img src="docs/session-light.png" width="100%" alt="会话「回响 1.0」：左边要点栏按版本、回顾、压缩分段，悬停浮出回顾全文；标题栏下写当前所在的版本"></picture></p>

- **自动备份**：会话不怕 30 天清理，占用下降 80%，几台 Mac 汇到一起
- **按版本回看**：长会话按版本、回顾分段，一点跳到当时
- **全局搜索**：会话名、你说过的话、AI 的回复，毫秒级找到
- **ech**：AI 自己查以前的会话，接着上次做
- **目录管理**：文件夹改名、移动，会话跟着走

## 自动备份

开机在后台运行，Claude Code、Codex 的会话都留下来，不怕被清理，换台电脑也看得到。

- 图片、思考过程不备份，工具调用的细节 30 天后换成占位，对话全文永久保留；占用下降 80% 以上
- 密钥、令牌写入前打码
- 备份放在 iCloud 云盘，每台电脑一个文件夹，几台 Mac 的会话汇到一起
- 很久没用的会话，备份完整后从 Claude Code、Codex 里移到废纸篓，原来的文件夹不再越攒越大

<p align="center"><img src="docs/how-archive.svg" width="100%" alt="自动备份、精简打码，几台 Mac 汇到一起，一搜就找到原话"></p>

## 按版本回看

一个项目的会话动辄几千轮、压缩好几次，按版本从头看到尾，复盘、交接都讲得清。

- 对话按 git 提交里的版本号、手动压缩和 Claude 的回顾分段，左侧要点栏一点跳到当时，悬停看全文
- 标题栏写会话名，下面一行写你正读到哪个版本
- 右侧「我的消息」按天列出你发过的每一条，点一条定位过去
- 思考过程和工具调用收成一行，点开再看

## 全局搜索

记得聊过、记不得在哪个会话，⌥⌘F 一搜就找到。

- 会话名、你说的话、阶段总结、AI 的回复都能搜，会话名命中的排最前
- 结果按会话分组，点一处直接停在那句话上，关键词标亮
- 全文索引在本机，备份完自动更新，几千个会话也是毫秒级

<p align="center"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/search-dark.png"><img src="docs/search-light.png" width="100%" alt="左栏搜索「备份」，按会话列出命中处，正文里标亮"></picture></p>

## ech：给 AI 用的回响

新开一个会话说「接着上次那个做」，AI 自己去回响里查上次做到哪，你不用再交代一遍背景。

- 装好回响就带 `ech` 命令和配套 skill，Claude Code、Codex 都能用
- AI 听到「上次聊到哪了」「以前为什么这么定」就自己去查，查询只读
- 输出纯文本，比让 AI 读原会话文件快得多、省 Token
- 写周报：`ech list --since 7d` 列出一周的会话、提交和版本，几台电脑、几家 AI 都在

<p align="center"><img src="docs/how-ech.svg" width="100%" alt="你说接着上次那个做，AI 用 ech 在回响里查到上次的回顾，接着往下做"></p>

```text
$ ech list --since 7d
2026-11-17 至 2026-11-23：16 个会话，我的消息 111 条，Token 35.2M，提交 13 次（总览数据）
11-23 回响 · 记忆管理需求 · 5 条 · 1.3M · beff8384
11-22 回响 · 回响 1.0 · 16 条 · 4.5M · 提交 8（0.1.0 至 0.8.0 共 8 个版本） · e0b9311e
11-22 记账本 · 分类图标改版（续） · 8 条 · 2.5M · 提交 1（1.15.0） · ae5e3f1f
…
```

## 会话目录管理

文件夹改名、挪位置，里面的会话跟着走，Claude Code 在新位置照样能 `/resume`。

- 左栏目录右键改名、移动到，或把会话拖到别的文件夹
- 在访达或 NAS 上改过名的，左栏标「已不存在」，右键「找到新位置…」按名字匹配出新文件夹，一步接上
- Codex 的会话也能移动；`ech mv` 让 AI 整理目录时把会话一起带走
- 会话可以改名、删除，删除都移到废纸篓，能放回

<p align="center"><img src="docs/folders.png" width="100%" alt="「旧官网」在访达里改了名，左栏标出已不存在；右键「找到新位置…」匹配到「官网改版」，确认后把 2 个会话移过去"></p>

## 总览

每天用了多少 Token、折合多少钱，AI 干了多久，做了哪些提交和版本。

- 本周的 Token、消息数、AI 时长、提交数，和上周比涨了还是跌了
- 日历一眼看出哪几天最忙，点一天展开那天的会话
- git 提交和版本挂到对应的会话上，删掉的会话统计照算

<p align="center"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/overview-dark.png"><img src="docs/overview-light.png" width="100%" alt="总览：每天的 Token、费用、消息数、AI 时长和提交，日历和每天的会话"></picture></p>

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
