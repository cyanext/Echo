# 回响

个人的 AI 记忆和上下文存档，Mac 应用。立项方案（已归档）见 [需求文档/归档/方案.md](需求文档/归档/方案.md)，各版本的需求见 `需求文档/版本需求/`，更新记录见 [CHANGELOG.md](CHANGELOG.md)。

```text
需求文档/     版本需求/（一个版本一篇）、设计规范/、归档/（立项方案）、.pm-doc/（写文档用的项目档案）
设计/         设计稿，一个主题一个文件夹，每个文件夹一份说明
代码/应用/    Mac 应用：App/ 源码（Echo*.swift）、Web/ 对话页面、tests/、tools/、build.sh
代码/原型/    Python 和网页原型，瘦身和消息显示以它为准，测试拿它比对
样例/         一个会话的瘦身结果和浏览页面（会话内容不进 git）
备份/         应用生成的备份，iCloud 同步，不进 git
```

## 开发

- 编译：`zsh 代码/应用/build.sh`，输出 `代码/应用/dist/回响.app`，临时签名。`zsh 代码/应用/build.sh install` 装到 `~/Applications` 并重新打开。版本号改 build.sh 开头的 `VERSION`、`BUILD`。
- 测试：`zsh 代码/应用/tests/run.sh [会话.jsonl…]`，瘦身和消息显示和原型现场生成的结果比对，改了 `EchoSlim`、`EchoExport`、`EchoBackup` 必跑。
- 验收全量备份：编出测试程序后运行 `test --backup <临时目录>`，跑两遍，看大小、文件数和耗时。
