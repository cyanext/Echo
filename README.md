# 回响

个人的 AI 记忆和上下文存档，Mac 应用。立项方案（已归档）见 [需求文档/归档/方案.md](需求文档/归档/方案.md)，各版本的需求见 `需求文档/版本需求/`，更新记录见 [CHANGELOG.md](CHANGELOG.md)。

```text
需求文档/     版本需求/（一类事一篇，开工时叫「待定-<主题>」，发版时改成「v<号>-<主题>」）、设计规范/、归档/（立项方案）、.pm-doc/
设计/         设计稿，一个主题一个文件夹，每个文件夹一份说明
代码/应用/    Mac 应用：App/ 源码（Echo*.swift，见下）、Web/ 对话页面和总览页面（overview.*，单价表 prices.json，两页共用的 base.*、缺省插画 blank-*.svg）、icon/ 应用图标（改图标跑 make_icon.py）、tests/、tools/、build.sh
代码/原型/    Python 和网页原型，瘦身和消息显示以它为准，测试拿它比对
样例/         真实会话和它的浏览页面（页面从 代码/原型/viewer/ 拷来，数据 export.py 生成），整个不进 git
```

备份默认在本目录旁边的 `../回响备份/<电脑名>/`（桌面在 iCloud 里，两台电脑共用），设置里能改；0.5.0 及以前在本目录的 `备份/`，新版打开时自动挪过去。

`代码/应用/App/` 各文件：

| 文件 | 管什么 |
|---|---|
| `EchoApp.swift` | 入口、主菜单、设置项（EchoPrefs）、全局状态（EchoState：备份、会话列表、总览、改名删除移动合集） |
| `EchoSources.swift` | 来源（Claude Code、Codex、WorkBuddy），备份里按应用分的文件夹，老布局挪进 `claude/` |
| `EchoBackup.swift` | 增量备份：Claude 从 `~/.claude/projects`，Codex 从 `~/.codex` 的 sessions、archived_sessions（解压后按日期放）；备份日志 |
| `EchoPrices.swift` | 模型单价：内置 `Web/prices.json`，每周从 LiteLLM 公开价格表拉一次覆盖 |
| `EchoSlim.swift` | 按行读文件（`.zst` 边读边解压，静态链接 Homebrew 的 libzstd，模块定义在 `tools/zstd/`）；写备份的规则（Claude、Codex 各一套）：去掉图片、请求记录，按保留期限换成占位，密钥打码 |
| `EchoClean.swift` | 清理备份：按保留期限重写到期的备份文件，旧文件进废纸篓；清理记录（本机）记每个文件最早到期，没到的跳过 |
| `EchoStorage.swift` | 设置「存储」页的数：备份各类占用、各应用消息数，Claude、Codex 会话数和占用 |
| `EchoOnboarding.swift` | 首次设置（第一次打开时的四步引导） |
| `EchoLibrary.swift` | 扫备份出会话列表、目录树，路径和时间的公共函数 |
| `EchoExport.swift` | 会话整理成对话页要的数据，规则以 `代码/原型/export.py` 为准 |
| `EchoEdit.swift` | 改名、合集、删除、移动（含移动记录）、自动清理不活跃的会话（Claude、Codex）、关闭 Claude 的自动清理 |
| `EchoStats.swift` | 总览的数：每天的消息、时长、Token（Claude、Codex），Git 提交按会话里的 git commit 挂到会话；备份页的汇总 |
| `EchoBrowser.swift` | 浏览窗口：左栏目录树、右栏切换、底部备份状态 |
| `EchoWeb.swift` | 右栏网页：对话、总览，`echo://app/` 取文件和数据 |
| `EchoTheme.swift` | 颜色、左栏的行、按钮等原生公共部件，自绘图标 |
| `EchoSettings.swift` | 设置窗口：通用、存储两页，各块也给首次设置用 |

## 开发

- 编译：`zsh 代码/应用/build.sh`，输出 `代码/应用/dist/回响.app`，临时签名。`zsh 代码/应用/build.sh install` 装到 `~/Applications` 并重新打开。
- 测试：`zsh 代码/应用/tests/run.sh [会话.jsonl…]`：瘦身和消息显示和原型现场生成的结果比对，备份规则、改名、合集、删除、移动、隐藏标记、总览统计，要点栏取点（node）。改了 `代码/应用/App/`、`Web/app.js` 必跑。看总览在真实备份上整理得对不对、要多久：测试程序带 `--overview <备份目录> <输出.json>`。
- 验收全量备份：编出测试程序后运行 `test --backup <临时目录>`，跑两遍，看大小、文件数和耗时。
- 测试程序的其他手动用法：`--backup-codex <目录>` 把本机 Codex 会话全量备份到临时目录（跑两遍）；`--slim-compare <会话> <原型瘦身结果>` 只比瘦身（Codex 会话用）；`--cat <文件>` 按行读出（`.zst` 解压），和 `zstd -dc` 比对；`--prices <LiteLLM 价格表>` 看解析留下哪些模型；`--slim <会话> <输出>` 按默认期限瘦身一个文件看用时；`--clean-estimate <电脑备份目录>` 估算按默认期限能释放多少；`--autodelete-preview <电脑备份目录> <天数>` 列出会被自动删除的会话（只列不删）；`--shot <settings-general|settings-storage|onboarding-0…3|browser> <输出.png> [dark] [等几秒]` 离屏截界面（不弹窗口、不装应用，图标要设 `ECHO_WEB=代码/应用/Web`；`browser` 读 `ECHO_SHOT_ROOT` 这个备份目录，`ECHO_SHOT_MENU=computer|app` 时展开那个筛选菜单）。
- 编译要先装 zstd：`brew install zstd`（静态链接进应用，装好的回响不依赖 Homebrew）。

## 版本和发版

版本号、需求怎么拆、什么时候给号、CHANGELOG 和更新说明，按 devguide（`~/.claude/skills/devguide/SKILL.md`）。回响是自用应用：合进 main 并装到本机就算一次发布。本项目特有的：

- 开发时分支工作区按主题起名（`.worktrees/<主题>`），`build.sh` 的 `VERSION` 保持上一个已发布的号，需求叫「待定-<主题>」。
- 发版步骤：
  1. 给号，`build.sh` 改 `VERSION`、`BUILD` 加一；这次发的需求改名「v<号>-<主题>」，页头写「已发布」和日期。
  2. `CHANGELOG.md` 最上面写一节 `## v<号>（日期）`，这次发的每篇需求一条；修已发版本的小问题写现象、原因、改法。
  3. 跑测试，`zsh 代码/应用/build.sh install` 装到本机。
  4. 合进 main，打 tag `app-v<号>`，删掉分支工作区，推远端（`git push origin main --tags`）。

## 待做

按主题排，不编号；开工时写「待定-<主题>」需求。

- 全局搜索：左栏顶上搜所有会话的内容，点结果定位到命中处。
- 分段和 `ech` 命令：会话按要点分段，给 Claude 用的只读查询命令（立项方案第十二节）。
- 界面减法待定项：合集的叠卡片图标、我的消息栏的条数、左栏底部的云图标、标题切换的淡入动画。
