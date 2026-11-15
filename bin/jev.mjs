#!/usr/bin/env node
/**
 * jev — the local decision model.
 *
 * Radar Vol. 35, "Beyond frontier models": decision models like Jev, and model routing
 * instead of blanket frontier usage. This is that idea at the smallest useful size: a
 * local qwen model, a fixed policy, one narrow question per call, and an explicit
 * "unsure" that sends the question to the human instead of guessing.
 *
 *   jev ask "<question>"      yes | no | unsure
 *   jev permit "<request>"    allow a sandbox permission request, or escalate it
 *   jev mode "<worker task>"  bare | sandboxed | no-net
 *   jev count "<task>"        1..4 workers
 *   jev thinking "<task>"     low | medium | high — how much effort the worker needs
 *   jev plan "<task>"         count + mode + route + thinking in one call
 *
 * "plan" exists because a spawn asks the same model four times about the same task, and three
 * of those four answers are cheap variations on one judgement. One call answers all of them in
 * one JSON object, so a spawn costs one latency and one usage line instead of four. The rules
 * do not relax: every field is validated by the same check its own subcommand makes, and one
 * unusable field still means "unsure", which stops a spawn rather than guessing at that field
 * while trusting the other three. Exit 0 means all four are usable — the route is read from the
 * payload (a local route is still a refusal, made by the caller) — 3 means unsure or the model
 * is unreachable, 2 usage.
 *
 * "thinking" answers an abstract effort, never a pi level name: which levels the concrete
 * model supports is a fact about that model, not about the task, so the caller does the
 * mapping (bin/delegate reads the model catalogue and picks the nearest supported level).
 *
 * Exit codes: 0 yes, or a valid mode/count/thinking answer (route: 0 local, 1 remote),
 * 1 no, 3 unsure or model unreachable (ask the user), 2 usage.
 * --json prints {"decision":…,"reason":…} instead of one line.
 *
 * Every call is recorded in state/usage.jsonl (see bin/usage.mjs): kind "jev", the
 * subcommand, the model that answered, the latency and whether it answered at all. A caller
 * that has one sets PI_BOSS_CONTEXT (delegate sets the slug), which lands on the line too.
 */
import process from "node:process";
import { MODEL, ENDPOINT, TIMEOUT } from "./jev-model.mjs";
import { logUsage, context } from "./usage.mjs";

// Wall clock for the usage line: a decision model that takes 40s is a fact worth having.
const started = Date.now();
let command = "";

// record — one usage line for this call, ok or not. Callers exit straight after.
function record(ok, errorMsg) {
	if (!command) return;
	logUsage({
		kind: "jev",
		command,
		model: MODEL,
		started,
		latency_ms: Date.now() - started,
		ok,
		error: errorMsg,
		context: context(),
		task: opts.text,
	});
}

const POLICY = `You are Jev, a decision model inside a coding-agent harness. You answer one
narrow question at a time and you answer it in JSON. You are not a chatbot: no prose outside
the JSON, no alternatives, no hedging beyond the "unsure" option you are given.

Standing policy you must apply:
- Sandboxing is the default. "bare" is only right when the work needs host access the sandbox
  refuses: Herdr control sockets, a GUI, docker.
- Publishing is not a reason for bare: a worker commits and the boss publishes, so publish
  access never justifies bare mode.
- A worker that needs a model to run cannot use "no-net": no network means no model.
  "no-net" is for running untrusted repository scripts, nothing else.
- Read-only analysis, small edits, tests in a normal repository: "sandboxed".
- At most 4 parallel workers. Past 4 the human cannot review the output; answer 4 and say why.
- One worker is right when the task is a single thread of work. Do not inflate the count.
- A sandbox permission request: yes when it is read-only, or a write inside the directory the
  worker was given, or a path the sandbox simply did not mount and the task needs. No for
  credentials, ssh keys, cloud configs, writes outside the worker's directory, destructive
  commands, or network access to hosts the task does not need.
- Routing: decide whether the work runs local or remote before it starts. "Local" means
  summarise, classify, extract, tidy, translate, format, and short mechanical rewrites that
  need no repo knowledge and no tools. "Remote" means code changes, debugging, design
  decisions, multi-file reasoning, and anything that needs tools, tests, or repo knowledge.
  When in doubt, remote.
- Thinking effort for a worker: pick the lowest effort that still does the task. "low" for
  mechanical edits, renames, formatting, single-file tweaks. "high" for hard debugging,
  multi-file design, migrations, security-sensitive work. "medium" otherwise. The effort is
  abstract on purpose: it says how hard the task is, not which level of which model to use.
  A task text too thin to judge gets "unsure", not a middle-of-the-road guess.
- If the question is ambiguous, if answering it would be a guess, or if the safe answer is
  not clear: answer "unsure". A human will take it. That is a good outcome, not a failure.`;

function fail(message, code = 3, errorClass = "unreachable") {
	record(false, message.startsWith("decision model") ? errorClass : "usage");
	process.stdout.write(`jev: ${message}\n`);
	process.exit(code);
}

function parseArgs(argv) {
	const opts = { json: false, kind: "", text: "" };
	const rest = [];
	for (const arg of argv) {
		if (arg === "--json") opts.json = true;
		else if (!opts.kind && ["ask", "permit", "mode", "count", "route", "thinking", "plan"].includes(arg))
		opts.kind = arg;
		else rest.push(arg);
	}
	opts.text = rest.join(" ").trim();
	return opts;
}

const SHAPES = {
	ask: '{"decision":"yes|no|unsure","confidence":0.0-1.0,"reason":"one sentence"}',
	permit: '{"decision":"yes|no|unsure","confidence":0.0-1.0,"reason":"one sentence"}',
	mode: '{"mode":"bare|sandboxed|no-net","confidence":0.0-1.0,"reason":"one sentence"}',
	count: '{"count":1-4,"confidence":0.0-1.0,"reason":"one sentence"}',
	route: '{"route":"local|remote","confidence":0.0-1.0,"reason":"one sentence"}',
	thinking: '{"thinking":"low|medium|high","confidence":0.0-1.0,"reason":"one sentence"}',
	plan: '{"count":1-4,"mode":"bare|sandboxed|no-net","route":"local|remote","thinking":"low|medium|high","confidence":0.0-1.0,"reason":"one sentence"}',
};

const PROMPTS = {
	ask: (text) => `Question: ${text}\n\nShould this go ahead? Answer yes, no, or unsure.`,
	permit: (text) =>
		`A sandboxed worker asks for this permission:\n${text}\n\nAllow it, or send it to the human? Answer yes (allow), no (refuse), or unsure (ask the human).`,
	mode: (text) =>
		`A worker will be started for this task:\n${text}\n\nWhich mode: bare, sandboxed, or no-net?`,
	count: (text) =>
		`Task:\n${text}\n\nHow many parallel workers does this need? Answer an integer 1 to 4.`,
	route: (text) =>
		`Task:\n${text}\n\nShould this run local (a small local model, no repo, no tools) or remote (a coding agent with the repo and tools)? Answer local or remote.`,
	thinking: (text) =>
		`A worker will be started for this task:\n${text}\n\nHow much thinking effort does it need? Answer low, medium, or high — the effort the task needs, not a model's level name.`,
	plan: (text) =>
		`A worker will be started for this task:\n${text}\n\nAnswer all four in one JSON object, each by the rule its own question states: how many parallel workers it needs (an integer 1 to 4), which mode (bare, sandboxed or no-net), whether it runs local or remote, and how much thinking effort it needs (low, medium or high).`,
};

async function decide(kind, text) {
	const body = {
		model: MODEL,
		stream: false,
		format: "json",
		options: { temperature: 0.1, num_ctx: 8192 },
		messages: [
			{ role: "system", content: `${POLICY}\n\nAnswer with exactly this JSON shape:\n${SHAPES[kind]}` },
			{ role: "user", content: PROMPTS[kind](text) },
		],
	};

	let response;
	try {
		response = await fetch(ENDPOINT, {
			method: "POST",
			headers: { "content-type": "application/json" },
			body: JSON.stringify(body),
			signal: AbortSignal.timeout(TIMEOUT),
		});
	} catch (error) {
		fail(`decision model unreachable (${ENDPOINT}): ${error.message} — ask the user`, 3, "unreachable");
	}
	if (!response.ok) fail(`decision model returned HTTP ${response.status} — ask the user`, 3, "http");

	const payload = await response.json().catch(() => null);
	const content = payload?.message?.content;
	if (!content) fail("decision model returned nothing — ask the user", 3, "empty");

	let answer;
	try {
		answer = JSON.parse(content);
	} catch {
		fail(`decision model answered outside JSON (${String(content).slice(0, 120)}) — ask the user`, 3, "non-json");
	}
	return answer;
}

const opts = parseArgs(process.argv.slice(2));
command = opts.kind;
if (!opts.kind) fail("usage: jev ask|permit|mode|count|route|thinking|plan <text> [--json]", 2);
if (!opts.text) fail(`jev ${opts.kind}: needs the question text`, 2);

const answer = await decide(opts.kind, opts.text);
const confidence = typeof answer.confidence === "number" ? answer.confidence : null;
const reason = typeof answer.reason === "string" ? answer.reason : "";
const low = confidence !== null && confidence < 0.5;

function emit(line, payload, code) {
	// The model answered, whatever the harness makes of the answer: exit 3 for "unsure" is a
	// decision, not a failure of the local path.
	record(true);
	if (opts.json) process.stdout.write(`${JSON.stringify(payload)}\n`);
	else process.stdout.write(`jev: ${line}${reason ? ` — ${reason}` : ""}\n`);
	process.exit(code);
}

if (opts.kind === "plan") {
	// Same per-field checks as mode/count/route/thinking, in one pass. A field that fails is
	// null in the payload and named in the line, so a caller that overrides jev can see which
	// judgement it is overturning. One bad field is enough to stop the spawn.
	const count = Number(answer.count);
	const mode = String(answer.mode || "").trim().toLowerCase();
	const route = String(answer.route || "").trim().toLowerCase();
	const thinking = String(answer.thinking || "").trim().toLowerCase();
	const bad = [];
	if (!Number.isInteger(count) || count < 1 || count > 4) bad.push("count");
	if (!["bare", "sandboxed", "no-net"].includes(mode)) bad.push("mode");
	if (!["local", "remote"].includes(route)) bad.push("route");
	if (!["low", "medium", "high"].includes(thinking)) bad.push("thinking");
	if (low) bad.push("confidence");
	// A low-confidence answer doubts the whole judgement, not one field of it: every field goes
	// null, so the caller cannot take the three it likes and ignore the one it does not.
	const usable = (field) => !low && !bad.includes(field);
	const payload = {
		count: usable("count") ? count : null,
		mode: usable("mode") ? mode : null,
		route: usable("route") ? route : null,
		thinking: usable("thinking") ? thinking : null,
		reason,
		confidence,
	};
	if (bad.length) emit(`unsure how to plan this spawn (${bad.join(", ")} unusable) — ask the user`, payload, 3);
	emit(`count=${count} mode=${mode} route=${route} thinking=${thinking}`, payload, 0);
}

if (opts.kind === "mode") {
	const mode = String(answer.mode || "").trim().toLowerCase();
	if (!["bare", "sandboxed", "no-net"].includes(mode) || low)
		emit("unsure which mode — ask the user", { mode: null, reason, confidence }, 3);
	emit(mode, { mode, reason, confidence }, 0);
}

if (opts.kind === "count") {
	const count = Number(answer.count);
	if (!Number.isInteger(count) || count < 1 || count > 4 || low)
		emit("unsure how many workers — ask the user", { count: null, reason, confidence }, 3);
	emit(String(count), { count, reason, confidence }, 0);
}

if (opts.kind === "thinking") {
	const effort = String(answer.thinking || "").trim().toLowerCase();
	if (!["low", "medium", "high"].includes(effort) || low)
		emit("unsure how much thinking this needs — ask the user", { thinking: null, reason, confidence }, 3);
	emit(effort, { thinking: effort, reason, confidence }, 0);
}

if (opts.kind === "route") {
	const route = String(answer.route || "").trim().toLowerCase();
	if (!["local", "remote"].includes(route) || low)
		emit("unsure which route — ask the user", { route: null, reason, confidence }, 3);
	if (route === "local") emit("local", { route, reason, confidence }, 0);
	emit("remote", { route, reason, confidence }, 1);
}

const decision = String(answer.decision || "").trim().toLowerCase();
if (!["yes", "no", "unsure"].includes(decision) || low)
	emit("unsure — ask the user", { decision: "unsure", reason, confidence }, 3);
if (decision === "yes") emit("yes", { decision, reason, confidence }, 0);
if (decision === "no") emit("no", { decision, reason, confidence }, 1);
emit("unsure — ask the user", { decision: "unsure", reason, confidence }, 3);
