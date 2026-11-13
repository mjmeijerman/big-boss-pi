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
 *
 * "thinking" answers an abstract effort, never a pi level name: which levels the concrete
 * model supports is a fact about that model, not about the task, so the caller does the
 * mapping (bin/delegate reads the model catalogue and picks the nearest supported level).
 *
 * Exit codes: 0 yes, or a valid mode/count/thinking answer (route: 0 local, 1 remote),
 * 1 no, 3 unsure or model unreachable (ask the user), 2 usage.
 * --json prints {"decision":…,"reason":…} instead of one line.
 */
import process from "node:process";
import { MODEL, ENDPOINT, TIMEOUT } from "./jev-model.mjs";

const POLICY = `You are Jev, a decision model inside a coding-agent harness. You answer one
narrow question at a time and you answer it in JSON. You are not a chatbot: no prose outside
the JSON, no alternatives, no hedging beyond the "unsure" option you are given.

Standing policy you must apply:
- Sandboxing is the default. "bare" is only right when the work needs host access the sandbox
  refuses: Herdr control sockets, a GUI, docker, the ssh agent.
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

function fail(message, code = 3) {
	process.stdout.write(`jev: ${message}\n`);
	process.exit(code);
}

function parseArgs(argv) {
	const opts = { json: false, kind: "", text: "" };
	const rest = [];
	for (const arg of argv) {
		if (arg === "--json") opts.json = true;
		else if (!opts.kind && ["ask", "permit", "mode", "count", "route", "thinking"].includes(arg))
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
		fail(`decision model unreachable (${ENDPOINT}): ${error.message} — ask the user`);
	}
	if (!response.ok) fail(`decision model returned HTTP ${response.status} — ask the user`);

	const payload = await response.json().catch(() => null);
	const content = payload?.message?.content;
	if (!content) fail("decision model returned nothing — ask the user");

	let answer;
	try {
		answer = JSON.parse(content);
	} catch {
		fail(`decision model answered outside JSON (${String(content).slice(0, 120)}) — ask the user`);
	}
	return answer;
}

const opts = parseArgs(process.argv.slice(2));
if (!opts.kind) fail("usage: jev ask|permit|mode|count|route|thinking <text> [--json]", 2);
if (!opts.text) fail(`jev ${opts.kind}: needs the question text`, 2);

const answer = await decide(opts.kind, opts.text);
const confidence = typeof answer.confidence === "number" ? answer.confidence : null;
const reason = typeof answer.reason === "string" ? answer.reason : "";
const low = confidence !== null && confidence < 0.5;

function emit(line, payload, code) {
	if (opts.json) process.stdout.write(`${JSON.stringify(payload)}\n`);
	else process.stdout.write(`jev: ${line}${reason ? ` — ${reason}` : ""}\n`);
	process.exit(code);
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
