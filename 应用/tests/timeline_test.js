// 时间轴取点的回归测试：git 提交怎么认、说明怎么取，阶段总结的说明取哪句（压缩前最后一条有内容的消息，没有时从摘要取）。由 tests/run.sh 用 node 运行
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
const turns = [
  { role: "user", ts: "2026-11-20T01:00:00Z", text: "把阶段总结做成时间轴上的点" },
  { role: "assistant", ts: "2026-11-20T01:01:00Z", blocks: [bash('git commit -q -m "0.1.0：第一版"'), { kind: "text", text: "ok" }] },
  { role: "user", ts: "2026-11-20T01:30:00Z", text: "做吧" },
  { role: "user", ts: "2026-11-20T01:31:00Z", text: "/compact" },
  { role: "summary", ts: "2026-11-20T02:00:00Z", text: "Summary:\n1. Primary Request and Intent\n摘要第一节每次都差不多" },
  { role: "summary", ts: "2026-11-20T03:00:00Z", text: "Summary:\n1. Primary Request and Intent\n   The user wants a timeline." },
  { role: "session", ts: "2026-11-21T01:00:00Z", text: "另一个会话" },
];
const keys = keyPoints(turns);
eq(keys.map((k) => `${k.kind}:${k.label}`).join(" | "), "commit:0.1.0：第一版 | compact:阶段总结 | compact:阶段总结 | part:另一个会话", "关键点顺序和种类");
eq(keys[1].sub, "把阶段总结做成时间轴上的点", "阶段总结取压缩前最后一条有内容的消息，跳过短确认和命令");
eq(keys[2].sub, "The user wants a timeline.", "两次压缩之间没有消息时从摘要里取");

console.log(`  时间轴 ${count} 项`);
if (failed) { console.log(`失败 ${failed} 项`); process.exit(1); }
