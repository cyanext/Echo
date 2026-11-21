// 定位条取点的回归测试：git 提交怎么认、说明怎么取，阶段总结的说明取哪句（压缩前最后一条有内容的消息，没有时从摘要取）。由 tests/run.sh 用 node 运行
const { commitMessage, summaryLine, keyPoints } = require(process.argv[2]);
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
// 定位条只标三类：手动压缩、每个「模块 + 版本号」的第一次提交、合集里的会话开头
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
   "commit:0.1.0：第一版 | commit:后台接口 v0.14.2：认人 | commit:会议 v0.14.2：录音 | compact:手动压缩 | compact:手动压缩 | part:另一个会话",
   "只标手动压缩、每个模块加版本号的第一次提交、会话开头；自动压缩和不带版本号的提交不标");
eq(keys[3].sub, "把阶段总结做成定位条上的点", "手动压缩的说明取压缩前最后一条有内容的消息，跳过短确认和命令");
eq(keys[4].sub, "The user wants a timeline.", "两次压缩之间没有消息时从摘要里取");
eq(keys.map((k) => k.id).join(","), "k0,k1,k2,k3,k4,k5", "关键点编号连续");
eq(keyPoints([{ role: "assistant", ts: "2026-11-20T01:00:00Z", blocks: [bash('git commit -m "Merge origin/main into lib-v0.8.0"'), bash('git commit -m "0.8.0：公共层"')] }]).map((k) => k.label).join(" | "),
   "0.8.0：公共层", "解决冲突后的合并提交不标");
const plain = keyPoints([{ role: "assistant", ts: "2026-11-20T01:00:00Z", blocks: [bash('git commit -m "改 A"'), bash('git commit -m "改 B"')] }]);
eq(plain.map((k) => k.label).join(" | "), "改 A | 改 B", "会话里一次版本提交都没有时，每次提交都标");

console.log(`  定位条 ${count} 项`);
if (failed) { console.log(`失败 ${failed} 项`); process.exit(1); }
