<p align="center"><img src="docs/icon.png" width="128" alt="回响图标"></p>

<h1 align="center">回响 Echo</h1>

<p align="center">你和 AI 聊过的，回响都记得。</p>

<p align="center">Claude Code、Codex 会话的备份、回看和检索，AI 也能自己查。<br>Mac 应用，开源免费，本地安全存储。</p>

<p align="center"><a href="#安装">安装</a> · <a href="README.en.md">English</a></p>

<p align="center"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/session-dark.png"><img src="docs/session-light.png" width="100%" alt="会话「回响 1.0」：左边要点栏按版本、回顾、压缩分段，悬停浮出回顾全文；标题栏下写当前所在的版本"></picture></p>

<p align="center"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/overview-dark.png"><img src="docs/overview-light.png" width="100%" alt="总览：每天的 Token、费用、消息数、AI 时长和提交，日历和每天的会话"></picture></p>

- **自动备份**：自动备份 Claude Code 和 Codex 的会话，不会被 30 天清理掉；备份比原会话小 80%，几台 Mac 的会话都能看到
- **按版本回看**：长会话按版本和回顾分好段，点一下就跳到当时的对话
- **全局搜索**：在全部会话里搜会话名、你说过的话和 AI 的回复，几毫秒就能找到
- **ech**：AI 可以自己查以前的会话，接着上次的进度做
- **目录管理**：给文件夹改名或移动位置后，里面的会话会跟着过去

## 自动备份

回响开机后在后台运行，把 Claude Code 和 Codex 的会话都备份下来，不会被清理掉，换一台电脑也能看到。

- 不备份图片和思考过程，工具调用的细节 30 天后换成占位，对话全文永久保留；备份比原会话小 80% 以上
- 写入备份前给密钥和令牌打码
- 备份放在 iCloud 云盘里，每台电脑一个文件夹，回响把几台 Mac 的会话合在一起看
- 回响确认备份完整后，把很久没用的会话从 Claude Code 和 Codex 里移到废纸篓，原来的文件夹不会越攒越大

<p align="center"><img src="docs/how-archive.svg" width="100%" alt="自动备份、精简打码，几台 Mac 汇到一起，一搜就找到原话"></p>

## 按版本回看

一个项目的会话动辄几千轮、压缩好几次。回响按版本把它分好段，你可以从头看到尾，复盘和交接时都能讲清楚。

- 回响按 git 提交里的版本号、手动压缩和 Claude 的回顾给对话分段；点左侧要点栏就跳到当时，鼠标停在上面能看全文
- 标题栏写着会话名，下面一行写你正读到哪个版本
- 右侧「我的消息」按天列出你发过的每一条，点一条就定位到那里
- 思考过程和工具调用默认收成一行，需要时再点开

## 全局搜索

你记得聊过某件事，但记不得在哪个会话里，按 ⌥⌘F 搜一下就能找到。

- 能搜会话名、你说的话、阶段总结和 AI 的回复，会话名命中的排在最前面
- 搜索结果按会话分组，点一处就停在那句话上，关键词会标亮
- 全文索引存在本机，每次备份完自动更新，几千个会话也能在几毫秒内搜完

<p align="center"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/search-dark.png"><img src="docs/search-light.png" width="100%" alt="左栏搜索「备份」，按会话列出命中处，正文里标亮"></picture></p>

## ech：给 AI 用的回响

新开一个会话说「接着上次那个做」，AI 自己去回响里查上次做到哪，你不用再交代一遍背景。

- 装好回响就有 `ech` 命令和配套的 skill，Claude Code 和 Codex 都能用
- 你问「上次聊到哪了」「以前为什么这么定」，AI 会自己去查；这些查询只读，不改任何东西
- ech 输出纯文本，比让 AI 直接读原会话文件快得多，也省 Token

<p align="center"><img src="docs/how-ech.svg" width="100%" alt="你说接着上次那个做，AI 用 ech 在回响里查到上次的回顾，接着往下做"></p>

写周报也一样：一句话，AI 用 `ech list` 拿到一周里几台电脑、几家 AI 的全部会话、提交和版本，按项目写出来。

<p align="center"><img src="docs/how-weekly.svg" width="100%" alt="在 Claude Code 里说写一下上周的周报，AI 用 ech list 拿到两台电脑上 Claude Code、Codex 一周的会话、提交和版本，按项目写成周报"></p>


## 会话目录管理

给文件夹改名或挪位置后，里面的会话会跟着过去，Claude Code 在新位置照样能 `/resume`。

- 在左栏的目录上右键，可以改名或移动到别处；也可以把会话拖到别的文件夹
- 如果你在访达或 NAS 上改过文件夹名，左栏会标出「已不存在」；右键选「找到新位置…」，回响按名字找到新文件夹，一步接上
- Codex 的会话也能移动；AI 整理目录时用 `ech mv`，会把会话一起带走
- 会话可以改名和删除，删除的会话都移到废纸篓，随时能放回

<p align="center"><img src="docs/folders.png" width="100%" alt="「旧官网」在访达里改了名，左栏标出已不存在；右键「找到新位置…」匹配到「官网改版」，确认后把 2 个会话移过去"></p>

## 总览

总览里能看到每天用了多少 Token、折合多少钱、AI 干了多久，以及做了哪些提交和版本。

- 卡片上写着本周的 Token、消息数、AI 时长和提交数，以及和上周比涨了还是跌了
- 从日历上一眼能看出哪几天最忙，点一天就展开那天的会话
- 回响把 git 提交和版本挂到对应的会话上；会话删掉了，统计照样算在总览里

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
