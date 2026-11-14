#!/usr/bin/env node
/**
 * stats — what the local model actually did.
 *
 * `delegate stats [--since DURATION] [--json]` runs this. It reads the two append-only files
 * and prints one screen: which questions jev answered and how, where the route sent the work,
 * how often a caller overruled jev, and whether the local work path (bin/local-run) ever ran.
 *
 * The point is the last line. Until now "is the local model used" could only be inferred from
 * the absence of something else; state/usage.jsonl makes it a count.
 *
 * The futures panel is the newest block and the reason it sits at the top: the three numbers
 * that make the futures the harness buys back visible — how many finished reports name what they
 * threw away, how many say they ran two or more cycles, and how many carry a checkable Evidence
 * block. All three are credit. They are read from reports/ alone, so a report that exists and is
 * not empty is a finished one, and a missing reports/ directory is zero, not an error.
 *
 * The review queue is the other number worth having: how many workers have reported and nobody has
 * read the report, and how old the oldest one is. It is current state, not a windowed count — an
 * unread report from three days ago is exactly the problem — so it reads state/delegations.json and
 * state/read/ directly and ignores --since. Age is the report file's mtime: when the worker wrote
 * it. That is the queue the in-flight cap in `delegate spawn` protects, made visible without gh and
 * without the network.
 *
 * Both files are read defensively: a line that is not JSON is skipped and counted, a missing
 * file is an empty one, and a row written before a field existed is read without it. Older
 * decision rows carry a spawn-wide `overridden` flag (see `delegate spawn`); those rows are
 * counted and reported as legacy rather than re-interpreted.
 *
 * DURATION is <number><s|m|h|d|w>; the default window is the last 7 days.
 */
import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const ROOT =
	process.env.PI_BOSS_ROOT ||
	process.env.PI_MASTER_ROOT ||
	path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const DECISIONS = path.join(ROOT, "state", "decisions.jsonl");
const USAGE = path.join(ROOT, "state", "usage.jsonl");
const DELEGATIONS = path.join(ROOT, "state", "delegations.json");
const READ_MARKS = path.join(ROOT, "state", "read");
const REPORTS = path.join(ROOT, "reports");

const UNITS = { s: 1_000, m: 60_000, h: 3_600_000, d: 86_400_000, w: 604_800_000 };
const DEFAULT_WINDOW = "7d";

function die(message) {
	process.stderr.write(`stats: ${message}\n`);
	process.exit(2);
}

/** parseSince — "<number><s|m|h|d|w>" to milliseconds. Anything else is a usage error. */
function parseSince(text) {
	const m = /^(\d+)([smhdw])$/.exec(String(text || "").trim());
	if (!m) die(`--since takes a duration like 24h, 7d or 2w, not '${text}'`);
	const ms = Number(m[1]) * UNITS[m[2]];
	if (!Number.isFinite(ms) || ms <= 0) die(`--since must be a positive duration, not '${text}'`);
	return { ms, label: `${m[1]}${m[2]}` };
}

/** readJsonl — [{...}] plus how many lines were unreadable. A missing file is empty. */
function readJsonl(file) {
	let raw = "";
	try {
		raw = fs.readFileSync(file, "utf8");
	} catch {
		return { rows: [], unreadable: 0 };
	}
	const rows = [];
	let unreadable = 0;
	for (const line of raw.split("\n")) {
		if (!line.trim()) continue;
		try {
			const row = JSON.parse(line);
			if (row && typeof row === "object") rows.push(row);
			else unreadable += 1;
		} catch {
			unreadable += 1;
		}
	}
	return { rows, unreadable };
}

/** ts — milliseconds for a row's timestamp, or NaN when it has none. */
function ts(row) {
	const value = row.timestamp || row.ts;
	const t = Date.parse(String(value || ""));
	return Number.isNaN(t) ? Number.NaN : t;
}

function median(values) {
	const sorted = values.filter((v) => Number.isFinite(v)).sort((a, b) => a - b);
	if (!sorted.length) return null;
	const mid = Math.floor(sorted.length / 2);
	return sorted.length % 2 ? sorted[mid] : Math.round((sorted[mid - 1] + sorted[mid]) / 2);
}

/**
 * section — the body of a "## <heading>" section, or null when the report has none.
 * A heading line ends the section; the text below it is the body either way.
 */
function section(text, heading) {
	const lines = String(text).split("\n");
	let start = -1;
	for (let i = 0; i < lines.length; i += 1) {
		const m = /^##\s+(.+?)\s*$/.exec(lines[i]);
		if (m && m[1].toLowerCase() === heading) {
			start = i + 1;
			break;
		}
	}
	if (start < 0) return null;
	const body = [];
	for (let i = start; i < lines.length; i += 1) {
		if (/^#{1,2}\s/.test(lines[i])) break;
		body.push(lines[i]);
	}
	return body.join("\n");
}

/** filled — a section body counts when some line carries text. "nothing" counts: it is written down. */
const filled = (body) => body !== null && body.split("\n").some((line) => line.trim() !== "");

const NUMBER_WORDS = {
	one: 1,
	two: 2,
	three: 3,
	four: 4,
	five: 5,
	six: 6,
	seven: 7,
	eight: 8,
	nine: 9,
	ten: 10,
};

/**
 * statedCycles — the highest cycle count a report states, 0 when it states none.
 * A report says it in prose ("ran 3 cycles", "it took two cycles"); the spec boilerplate a
 * worker sometimes pastes back ("expect two or more cycles") is not the report saying it ran
 * them, so a line carrying "expect ... cycles" is skipped.
 */
function statedCycles(text) {
	let best = 0;
	for (const line of String(text).split("\n")) {
		if (/expect\b.*\bcycles?\b/i.test(line)) continue;
		const seen = [];
		for (const m of line.matchAll(/\bcycles?\s*[:=]\s*(\d+)/gi)) seen.push(Number(m[1]));
		for (const m of line.matchAll(/\b(\d+)\s*\+?\s*cycles?\b/gi)) seen.push(Number(m[1]));
		for (const m of line.matchAll(/\b([a-z]+)\s*\+?\s*cycles?\b/gi)) {
			const n = NUMBER_WORDS[m[1].toLowerCase()];
			if (n) seen.push(n);
		}
		for (const n of seen) if (Number.isFinite(n) && n > best) best = n;
	}
	return best;
}

/**
 * futures — the three numbers nobody was counting: what the harness bought back.
 * Throwing work away is the only way an iteration shows up as progress, so a non-empty
 * "## Thrown away" section is credit. A report stating two or more cycles is the same credit
 * on the other axis: the first attempt was allowed to be wrong. The Evidence share says how
 * much of the finished work a reader can check without re-running it. Reports are the only
 * input; a report present and non-empty is a finished one, and a missing directory is zero.
 */
function collectFutures() {
	let files = [];
	try {
		files = fs.readdirSync(REPORTS).filter((f) => f.endsWith(".md")).sort();
	} catch {
		files = [];
	}
	let finished = 0;
	const allSlugs = [];
	const thrownAway = [];
	const twoCycles = [];
	const withEvidence = [];
	const byCycles = [];
	for (const file of files) {
		let text = "";
		try {
			text = fs.readFileSync(path.join(REPORTS, file), "utf8");
		} catch {
			continue;
		}
		if (!text.trim()) continue;
		finished += 1;
		const slug = file.replace(/\.md$/, "");
		allSlugs.push(slug);
		if (filled(section(text, "thrown away"))) thrownAway.push(slug);
		if (filled(section(text, "evidence"))) withEvidence.push(slug);
		const cycles = statedCycles(text);
		if (cycles >= 2) twoCycles.push(slug);
		if (cycles) byCycles.push({ slug, cycles });
	}
	return {
		finished_reports: finished,
		thrown_away: {
			count: thrownAway.length,
			share: percent(thrownAway.length, finished),
			reports: thrownAway,
		},
		two_or_more_cycles: {
			count: twoCycles.length,
			share: percent(twoCycles.length, finished),
			reports: twoCycles,
		},
		evidence: {
			count: withEvidence.length,
			share: percent(withEvidence.length, finished),
			reports_without: allSlugs.filter((s) => !withEvidence.includes(s)),
		},
		cycles_stated: byCycles,
	};
}

const tally = (list, keyFn) => {
	const out = {};
	for (const item of list) {
		const k = keyFn(item);
		if (!k) continue;
		out[k] = (out[k] || 0) + 1;
	}
	return out;
};
const sum = (obj) => Object.values(obj).reduce((a, b) => a + b, 0);
const percent = (part, whole) => (whole ? Math.round((part / whole) * 1000) / 10 : 0);

function collect(sinceMs, windowLabel) {
	const now = Date.now();
	const cutoff = now - sinceMs;
	const decisions = readJsonl(DECISIONS);
	const usage = readJsonl(USAGE);

	const inWindow = (row) => {
		const t = ts(row);
		return Number.isFinite(t) && t >= cutoff && t <= now;
	};
	const dRows = decisions.rows.filter(inWindow);
	const uRows = usage.rows.filter(inWindow);

	const byCommand = tally(dRows, (r) => r.command);
	const routeSplit = {};
	const modeSplit = {};
	const thinkingSplit = {};
	for (const row of dRows) {
		if (row.command === "route") routeSplit[row.decision] = (routeSplit[row.decision] || 0) + 1;
		if (row.command === "mode") modeSplit[row.decision] = (modeSplit[row.decision] || 0) + 1;
		if (row.command === "thinking") thinkingSplit[row.decision] = (thinkingSplit[row.decision] || 0) + 1;
	}

	// The override flag: correctly set from now on (only the decision that was actually
	// overturned, and it now carries jev's original answer in `jev`). A row without `jev`
	// predates that fix and its flag is spawn-wide, so it is counted, not re-read. The
	// obviously-wrong ones are named: a route jev answered remote was never an override.
	// An `in-flight` line records the spawn cap, not a jev answer, so it has no `jev` field by
	// design and is never a legacy row.
	const overridden = dRows.filter((r) => r.overridden === true);
	const legacy = overridden.filter((r) => r.jev === undefined && r.command !== "in-flight");
	const legacySuspect = legacy.filter((r) => r.command === "route" && r.decision === "remote");

	// Usage rows: the local model calls themselves. Old files may predate `kind`, so a row
	// without one is treated as a decision-engine call (jev) rather than dropped.
	const kindOf = (r) => (r.kind ? String(r.kind) : r.command === "run" ? "local-run" : "jev");
	const jevCalls = uRows.filter((r) => kindOf(r) === "jev");
	const runs = uRows.filter((r) => kindOf(r) === "local-run");
	const okRuns = runs.filter((r) => r.ok === true);
	const runLatencies = okRuns.map((r) => Number(r.latency_ms)).filter((v) => Number.isFinite(v));
	const jevLatencies = jevCalls.filter((r) => r.ok === true).map((r) => Number(r.latency_ms));
	const lastRun = runs.length ? runs[runs.length - 1].ts || runs[runs.length - 1].timestamp || null : null;

	// The review queue: reported workers whose report no read marker covers. See the header.
	const unread = [];
	let delegations = {};
	try {
		delegations = JSON.parse(fs.readFileSync(DELEGATIONS, "utf8")) || {};
	} catch {
		delegations = {};
	}
	for (const [slug, entry] of Object.entries(delegations)) {
		const report = entry && entry.report;
		if (!slug || !report) continue;
		let st;
		try {
			st = fs.statSync(report);
		} catch {
			continue; // no report yet: still working, not unread
		}
		if (!st.size) continue;
		try {
			fs.statSync(path.join(READ_MARKS, slug));
			continue; // marked read
		} catch {}
		unread.push({ slug, report, age_seconds: Math.max(0, Math.round((now - st.mtimeMs) / 1000)) });
	}
	unread.sort((a, b) => b.age_seconds - a.age_seconds);

	return {
		window: { since: new Date(cutoff).toISOString(), until: new Date(now).toISOString(), duration: windowLabel },
		decisions: {
			total: dRows.length,
			unreadable: decisions.unreadable,
			by_command: byCommand,
			route: routeSplit,
			mode: modeSplit,
			thinking: thinkingSplit,
			override: {
				count: overridden.length,
				rate: percent(overridden.length, dRows.length),
				legacy_rows: legacy.length,
				legacy_route_remote: legacySuspect.length,
			},
			// Counted so a row that carries no usable timestamp is visible instead of silently
			// dropped by the window: the files are append-only, and holes are worth knowing.
			outside_window: decisions.rows.length - dRows.length,
		},
		local_model: {
			jev_calls: jevCalls.length,
			jev_failed: jevCalls.filter((r) => r.ok !== true).length,
			jev_median_latency_ms: median(jevLatencies),
			error_classes: tally(jevCalls.filter((r) => r.ok !== true), (r) => r.error || "unknown"),
		},
		local_run: {
			invocations: runs.length,
			ok: okRuns.length,
			failed: runs.length - okRuns.length,
			total_latency_ms: runLatencies.reduce((a, b) => a + b, 0),
			median_latency_ms: median(runLatencies),
			last: lastRun,
			error_classes: tally(runs.filter((r) => r.ok !== true), (r) => r.error || "unknown"),
		},
		local_work_path: {
			used: runs.length > 0,
			invocations: runs.length,
			last: lastRun,
			summary: runs.length
				? `local work path: ${runs.length} invocation${runs.length === 1 ? "" : "s"} (last: ${lastRun})`
				: "local work path: never used",
		},
		review_queue: {
			unread_reports: unread.length,
			oldest_age_seconds: unread.length ? unread[0].age_seconds : null,
			oldest_slug: unread.length ? unread[0].slug : null,
			unread: unread.map((u) => ({ slug: u.slug, age_seconds: u.age_seconds, report: u.report })),
		},
		usage: { rows: uRows.length, unreadable: usage.unreadable },
		futures: collectFutures(),
	};
}

function render(stats) {
	const out = [];
	const d = stats.decisions;
	const pct = (obj) => {
		const entries = Object.entries(obj).sort((a, b) => b[1] - a[1]);
		return entries.length ? entries.map(([k, v]) => `${k} ${v}`).join("  ") : "none";
	};
	const ms = (v) => (v === null || v === undefined ? "—" : `${(v / 1000).toFixed(1)}s`);
	// Seconds to something a reader can compare with a workday: m under 90 minutes, h above.
	const age = (v) =>
		v === null || v === undefined ? "—" : v < 90 ? `${v}s` : v < 5400 ? `${Math.round(v / 60)}m` : `${(v / 3600).toFixed(1)}h`;
	// The futures panel goes above the usage numbers: it is the one block a reader acts on,
	// and a number that needs scrolling past call latencies to find does not get read.
	const f = stats.futures;
	const futuresLines = [
		"futures bought back (credit, not cost):",
		`  thrown away:  ${f.thrown_away.count} of ${f.finished_reports} finished reports (${f.thrown_away.share}%)`,
		`  two+ cycles:  ${f.two_or_more_cycles.count} of ${f.finished_reports} finished reports (${f.two_or_more_cycles.share}%)`,
		`  evidence:     ${f.evidence.count} of ${f.finished_reports} finished reports (${f.evidence.share}%)`,
	];
	const q = stats.review_queue;
	const queueLine = q.unread_reports
		? `review queue: ${q.unread_reports} unread report${q.unread_reports === 1 ? "" : "s"} (oldest ${age(q.oldest_age_seconds)}, ${q.oldest_slug})`
		: "review queue: 0 unread reports";

	out.push(`window: last ${stats.window.duration} (${stats.window.since} → ${stats.window.until})`);
	out.push("");
	out.push(...futuresLines);
	if (!d.total && !stats.usage.rows) {
		out.push("");
		out.push("no local model activity in this window");
		out.push(queueLine);
		out.push(stats.local_work_path.summary);
		return out.join("\n");
	}

	out.push("");
	out.push(`jev decisions: ${d.total} rows${d.unreadable ? ` (+${d.unreadable} unreadable)` : ""}`);
	const commands = Object.entries(d.by_command).sort((a, b) => b[1] - a[1]);
	for (const [cmd, n] of commands) out.push(`  ${cmd.padEnd(10)} ${n}`);
	out.push(`route:     ${pct(d.route)}`);
	out.push(`mode:      ${pct(d.mode)}`);
	out.push(`thinking:  ${pct(d.thinking)}`);
	out.push(
		`overrides: ${d.override.count} of ${d.total} (${d.override.rate}%)` +
			(d.override.legacy_rows ? ` — ${d.override.legacy_rows} legacy rows, spawn-wide flag` : "") +
			(d.override.legacy_route_remote ? `, ${d.override.legacy_route_remote} of them route→remote` : ""),
	);
	out.push("");
	out.push(
		`local model calls: ${stats.local_model.jev_calls} (jev, ${stats.local_model.jev_failed} failed, median ${ms(stats.local_model.jev_median_latency_ms)})`,
	);
	out.push(
		`local-run:         ${stats.local_run.invocations} invocations, ${stats.local_run.ok} ok, ${stats.local_run.failed} failed — total ${ms(stats.local_run.total_latency_ms)}, median ${ms(stats.local_run.median_latency_ms)}`,
	);
	out.push("");
	out.push(queueLine);
	out.push(stats.local_work_path.summary);
	return out.join("\n");
}

let since = DEFAULT_WINDOW;
let json = false;
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i += 1) {
	const arg = argv[i];
	if (arg === "--json") json = true;
	else if (arg === "--since") since = argv[++i] ?? "";
	else if (arg.startsWith("--since=")) since = arg.slice("--since=".length);
	else die(`unknown argument '${arg}' (usage: delegate stats [--since DURATION] [--json])`);
}
if (since === "" || since === undefined) die("--since needs a duration like 24h or 7d");

const { ms: sinceMs, label } = parseSince(since);
const stats = collect(sinceMs, label);
process.stdout.write(`${json ? JSON.stringify(stats, null, 2) : render(stats)}\n`);
