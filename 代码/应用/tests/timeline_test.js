// 要点栏取点的回归测试：git 提交怎么认、说明怎么取，阶段总结的说明取哪句（压缩前最后一条有内容的消息，没有时从摘要取）。由 tests/run.sh 用 node 运行
const { commitMessage, summaryLine, keyPoints, versionKey } = require(process.argv[2]);
let failed = 0, count = 0;
const eq = (got, want, what) => { count++; if (got !== want) { failed++; console.log(`  ✗ ${what}：得到 ${JSON.stringify(got)}，应为 ${JSON.stringify(want)}`); } };
const bash = (command, result = "", isError = false) => ({ kind: "tool", name: "Bash", input: { command }, result, isError });

eq(commitMessage(bash('git -c core.quotepath=off commit -q -m "立项：方案\n\n正文" && git log')), "立项：方案", "-m 双引号");
eq(commitMessage(bash("git commit -qam '单引号说明'")), "单引号说明", "-am 单引号");
eq(commitMessage(bash('cd x && git add -A && git commit -q -m "$(cat <<\'EOF\'\n0.4.0：heredoc\n\n正文\nEOF\n)"')), "0.4.0：heredoc", "-m 里套 heredoc");
eq(commitMessage(bash("git commit -F - <<EOF\n0.5.0：标准输入\nEOF")), "0.5.0：标准输入", "-F - heredoc");
eq(commitMessage(bash('git commit -m "带 \\"引号\\" 的说明"')), '带 "引号" 的说明', "说明里的转义引号");
eq(commitMessage(bash('git commit -m "x"', "nothing to commit, working tree clean")), null, "没东西可提交不算");
eq(commitMessage(bash('git commit -m "x"', "error", true)), null, "出错的不算");
eq(commitMessage(bash("python3 - <<'EOF'\ns = '''\ngit commit -m \"假的\"\n'''\nEOF")), null, "heredoc 脚本里写到的 git commit 不算");
eq(commitMessage(bash("grep -c 'git commit' a.log")), null, "参数里提到的 git commit 不算");
eq(commitMessage(bash("git log --grep commit")), null, "git log 不算");
eq(commitMessage({ kind: "tool", name: "Read", input: { command: 'git commit -m "x"' } }), null, "别的工具不算");

eq(summaryLine("This session is being continued from a previous conversation.\n\n<system-reminder>\n<tools-used-before-summary>Bash</tools-used-before-summary>\n</system-reminder>\nSummary:\n## 1. Primary Request and Intent\n\nThe user is setting up the company NAS."), "The user is setting up the company NAS.", "摘要兜底：跳过开场白、系统标签和标题");
// 要点栏只列三类：手动压缩、每个「模块 + 版本号」的最后一次提交（这一版的终点，说明取第一次那句）、合集里的会话开头
const turns = [
  { role: "user", ts: "2026-11-20T01:00:00Z", text: "把阶段总结做成定位条上的点" },
  { role: "assistant", ts: "2026-11-20T01:01:00Z", blocks: [bash('git commit -q -m "0.1.0：第一版"'), bash('git commit -q -m "0.1.0：补文档"'), bash('git commit -q -m "改注释"'), { kind: "text", text: "ok" }] },
  { role: "summary", ts: "2026-11-20T01:30:00Z", trigger: "auto", text: "Summary:\n1. Primary Request and Intent\n自动压缩" },
  { role: "assistant", ts: "2026-11-20T01:40:00Z", blocks: [bash('git commit -q -m "后台接口 v0.14.2：认人"'), bash('git commit -q -m "会议 v0.14.2：录音"'), bash('git commit -q -m "后台接口 v0.14.2：补测试"')] },
  { role: "user", ts: "2026-11-20T01:50:00Z", text: "做吧" },
  { role: "user", ts: "2026-11-20T01:51:00Z", text: "/compact" },
  { role: "summary", ts: "2026-11-20T02:00:00Z", trigger: "manual", text: "Summary:\n1. Primary Request and Intent\n摘要第一节每次都差不多" },
  { role: "summary", ts: "2026-11-20T03:00:00Z", trigger: "manual", text: "Summary:\n1. Primary Request and Intent\n   The user wants a timeline." },
  { role: "session", ts: "2026-11-21T01:00:00Z", text: "另一个会话" },
];
const keys = keyPoints(turns);
eq(keys.map((k) => `${k.kind}:${k.label}`).join(" | "),
   "commit:0.1.0：第一版 | commit:会议 v0.14.2：录音 | commit:后台接口 v0.14.2：认人 | compact:手动压缩 | compact:手动压缩 | part:另一个会话",
   "只标手动压缩、每个模块加版本号的最后一次提交（说明取第一次那句）、会话开头；自动压缩和不带版本号的提交不标");
eq(keys[3].sub, "把阶段总结做成定位条上的点", "手动压缩的说明取压缩前最后一条有内容的消息，跳过短确认和命令");
eq(keys[4].sub, "The user wants a timeline.", "两次压缩之间没有消息时从摘要里取");
eq(keys.map((k) => k.id).join(","), "k0,k1,k2,k3,k4,k5", "关键点编号连续");
// 号改过、同一个号后来给了别的事：两件事各标一条，不合成一条（回响 0.6.0 先是「删除后保留统计」，改号后给了「整理会话目录」）
eq(keyPoints([{ role: "assistant", ts: "2026-11-20T01:00:00Z", blocks: [bash('git commit -m "v0.6.0 删除后保留统计"'), bash('git commit -m "v0.6.1 展开按钮"'),
     bash('git commit -m "v0.7.0 会话移动"'), bash('git commit -m "拖动排序（待发）"'), bash('git commit -m "v0.6.0 整理会话目录"')] }]).map((k) => k.label).join(" | "),
   "v0.6.0 删除后保留统计 | v0.6.1 展开按钮 | v0.7.0 会话移动 | v0.6.0 整理会话目录", "同一个号后来给了别的事时各标一条");
eq(keyPoints([{ role: "assistant", ts: "2026-11-20T01:00:00Z", blocks: [bash('git commit -m "Merge origin/main into lib-v0.8.0"'), bash('git commit -m "0.8.0：公共层"')] }]).map((k) => k.label).join(" | "),
   "0.8.0：公共层", "解决冲突后的合并提交不标");
// 模块：只认说明开头的「模块 v版本号」；冒号、括号、句子中间的都不算
eq(versionKey("后台接口 v0.14.2：认人"), "后台接口 0.14.2", "开头的模块加版本号");
eq(versionKey("0.1.0：备份和浏览会话"), "0.1.0", "开头只有版本号时没有模块");
eq(versionKey("需求：v0.2.2 右键给同事授权"), "0.2.2", "冒号前面的不算模块");
eq(versionKey("合并会议列表接口（）和我的新消息（v0.7.0）的后台"), "0.7.0", "括号里的版本号没有模块");
eq(versionKey("改注释"), null, "没有版本号");
eq(versionKey("v0.3.1 回收站改为最近删除"), "0.3.1", "开头的 v 不算模块");
eq(versionKey("NAS 网站 v0.3.1：回收站"), "NAS 网站 0.3.1", "模块里可以有空格");
eq(versionKey("site-v0.3.0 合并"), "site 0.3.0", "模块末尾的连字符去掉");
eq(versionKey("统一文件查看页拆到文件管理 v0.4.0"), "0.4.0", "句子中间的版本号没有模块");
eq(versionKey("方案：论文知识库 v0.1 架构方案"), "论文知识库 0.1", "两段的 v0.1，前面可以有「方案：」前缀");
eq(versionKey("v0.2：初版跑通"), "0.2", "两段的 v0.2 在开头");
eq(versionKey("0.3.0：版本号兼容 v0.1，版本之后的无版本提交并进这个版本"), "0.3.0", "开头的版本号不当前缀，后面句子里的 v0.1 不算");
eq(versionKey("v0.2.2：右键给同事授权"), "0.2.2", "开头 v 加三段版本号");
eq(versionKey("模型从 3.5 升到 4.0"), null, "两段数字不带 v 不算版本");
eq(versionKey("方案：架构图箭头改为数据流向，v0.1 架构设计、v0.2 初版跑通"), null, "两段的版本号在句子中间不算");
// 版本之后没带版本号的提交并进这个版本：位置延到下一个版本之前的最后一次提交，说明取第一次那句
const ext = keyPoints([
  { role: "assistant", ts: "2026-11-20T01:00:00Z", blocks: [bash('git commit -m "方案：论文知识库 v0.1 架构方案"')] },
  { role: "assistant", ts: "2026-11-20T02:00:00Z", blocks: [bash('git commit -m "方案：按反馈改论文拆解"')] },
  { role: "assistant", ts: "2026-11-20T03:00:00Z", blocks: [bash('git commit -m "方案：多用架构图"')] },
  { role: "assistant", ts: "2026-11-20T04:00:00Z", blocks: [bash('git commit -m "v0.2：初版跑通"')] },
]);
eq(ext.map((k) => `${k.turn}:${k.label}`).join(" | "), "2:方案：论文知识库 v0.1 架构方案 | 3:v0.2：初版跑通", "版本之后的无版本提交并进这个版本");
const plain = keyPoints([{ role: "assistant", ts: "2026-11-20T01:00:00Z", blocks: [bash('git commit -m "改 A"'), bash('git commit -m "改 B"')] }]);
eq(plain.map((k) => k.label).join(" | "), "改 A | 改 B", "会话里一次版本提交都没有时，每次提交都标");

console.log(`  要点 ${count} 项`);
if (failed) { console.log(`失败 ${failed} 项`); process.exit(1); }
