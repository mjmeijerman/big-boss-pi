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
 *
 * Exit codes: 0 yes/answered, 1 no, 3 unsure or model unreachable (ask the user).
 * --json prints {"decision":…,"reason":…} instead of one line.
 */
import process from "node:process";

const MODEL = process.env.JEV_MODEL || "qwen3.8:27b";
const ENDPOINT = process.env.JEV_ENDPOINT || "http://localhost:11434/api/chat";
const TIMEOUT = Number(process.env.JEV_TIMEOUT || 180000);

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
		else if (!opts.kind && ["ask", "permit", "mode", "count"].includes(arg)) opts.kind = arg;
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
};

const PROMPTS = {
	ask: (text) => `Question: ${text}\n\nShould this go ahead? Answer yes, no, or unsure.`,
	permit: (text) =>
		`A sandboxed worker asks for this permission:\n${text}\n\nAllow it, or send it to the human? Answer yes (allow), no (refuse), or unsure (ask the human).`,
	mode: (text) =>
		`A worker will be started for this task:\n${text}\n\nWhich mode: bare, sandboxed, or no-net?`,
	count: (text) =>
		`Task:\n${text}\n\nHow many parallel workers does this need? Answer an integer 1 to 4.`,
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
if (!opts.kind) fail("usage: jev ask|permit|mode|count <text> [--json]", 2);
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

const decision = String(answer.decision || "").trim().toLowerCase();
if (!["yes", "no", "unsure"].includes(decision) || low)
	emit("unsure — ask the user", { decision: "unsure", reason, confidence }, 3);
if (decision === "yes") emit("yes", { decision, reason, confidence }, 0);
if (decision === "no") emit("no", { decision, reason, confidence }, 1);
emit("unsure — ask the user", { decision: "unsure", reason, confidence }, 3);
