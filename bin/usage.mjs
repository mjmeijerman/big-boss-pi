/**
 * usage — the one place a local model call gets recorded.
 *
 * Both halves of the local model write here: bin/jev.mjs (the decision engine, kind "jev")
 * and bin/local-run.mjs (the local worker, kind "local-run"). It is the file that answers
 * "is the local model actually used" without inferring it from the absence of something else.
 *
 * One JSON object per call, appended to state/usage.jsonl:
 *
 *   ts          ISO timestamp of when the call started
 *   kind        "jev" | "local-run"
 *   command     jev's subcommand (ask, route, mode, count, thinking, permit) or "run"
 *   model       the model id from bin/jev-model.mjs, i.e. what actually answered
 *   latency_ms  wall time from before the request to after the answer (or the failure)
 *   ok          did the model answer at all
 *   error       one class word when ok is false: unreachable, http, empty, non-json, no-answer
 *   context     the caller's slug or context when it has one (PI_BOSS_CONTEXT), else null
 *   task        the task text, clipped to 200 characters and redacted
 *
 * What is deliberately not logged: environment variables, credentials, endpoints with user
 * info, and the full task text. A task can be long and can contain anything a person typed,
 * so only the first 200 characters survive, after the cheap redaction below. Recording must
 * never break the call it records: a failed write is swallowed.
 */
import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

export const TASK_LIMIT = 200;

const ROOT =
	process.env.PI_BOSS_ROOT ||
	process.env.PI_MASTER_ROOT ||
	path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

export const USAGE_FILE = path.join(ROOT, "state", "usage.jsonl");

// Cheap redaction: key-shaped tokens and Authorization headers go, everything else stays. It
// is a guard against the obvious accident, not a classification of what is secret.
const REDACTIONS = [
	/\b(sk|rk|pk|ghp|gho|ghs|xox[baprs])[-_][A-Za-z0-9_-]{8,}/g,
	/\bBearer\s+[A-Za-z0-9._~+/=-]{8,}/gi,
	/\b(api[_-]?key|token|secret|password|passwd|pwd)\s*[=:]\s*\S+/gi,
];

/** clipTask — one line, at most TASK_LIMIT characters, key-shaped values redacted. */
export function clipTask(text) {
	let out = String(text || "").replace(/\s+/g, " ").trim();
	for (const re of REDACTIONS) out = out.replace(re, "[redacted]");
	if (out.length > TASK_LIMIT) out = `${out.slice(0, TASK_LIMIT - 1)}…`;
	return out;
}

/**
 * logUsage — append one call record. Never throws: a logging failure must not fail the call
 * it was recording, and a workspace without a writable state/ directory is not an error worth
 * stopping the model for.
 */
export function logUsage({ kind, command, model, started, latency_ms, ok, error, context, task }) {
	const line = {
		ts: new Date(started ?? Date.now()).toISOString(),
		kind: String(kind || "unknown"),
		command: String(command || ""),
		model: String(model || ""),
		latency_ms: Math.max(0, Math.round(Number(latency_ms) || 0)),
		ok: Boolean(ok),
		error: ok ? null : String(error || "unknown"),
		context: context ? clipTask(context) : null,
		task: clipTask(task),
	};
	try {
		fs.mkdirSync(path.dirname(USAGE_FILE), { recursive: true });
		fs.appendFileSync(USAGE_FILE, `${JSON.stringify(line)}\n`);
	} catch {
		// Deliberate no-op; see the docstring.
	}
	return line;
}

/** context — the caller's slug or context, passed down the environment, never invented. */
export function context() {
	return process.env.PI_BOSS_CONTEXT || "";
}
