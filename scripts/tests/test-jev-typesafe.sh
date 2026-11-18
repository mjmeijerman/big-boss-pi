#!/usr/bin/env bash
# test-jev-typesafe.sh — jev is a typed, calibrated decision model now, and every one of its
# answers is still a gate: it answers, it is unsure out loud, or it is dead, and never a default.
#
# The TypeSafe API is a fake on a loopback port. It answers from a fixture file, refuses a request
# without the key, and records every request body, so "one request, four questions" and "the key
# was sent" are read from the bytes that left — not from the code that claims them.
#
#   A. Happy plan: four confident answers in ONE request, exit 0, four usable fields, the response's
#      own model id on the one usage line, and the key nowhere in the output.
#   B. A field whose probability is under the threshold takes the conservative default: exit 0,
#      the field is the default value, the default line on stderr names the field and its
#      probability, "defaults" names it in --json, and the other three keep jev's own answers. All
#      four weak at once default together. JEV_MIN_CONFIDENCE moves the threshold.
#   C. An answer outside the offered options is unusable, not passed through: exit 3.
#   D. 401 is exit 3 and names the key, not the key's value.
#   E. A timeout is exit 3 "unreachable" — the contract bin/delegate reads.
#   F. A malformed body is exit 3, never a default answer.
#   G. No key at all is exit 3 with the fix in the message; the JEV_KEY_FILE form of the key works,
#      including the `export TYPESAFE_API_KEY=` line this machine actually uses.
#   H. ask and permit: a Noul and a three-way Choice, mapped onto the same exit codes as before.
#   I. bin/local-run still sends its ollama keep_alive and still retries without it on 400 — the
#      half of the retired warm-model suite that tested a transport which still exists.
#
# Every case asserts the exit code, so the gate is what is tested, and that the key string never
# appears on stdout or stderr.
#
#   bash scripts/tests/test-jev-typesafe.sh      exit 0 = every case held
set -uo pipefail

root=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/../.." && pwd)
bin=$root/bin

work=$(mktemp -d)
export HOME=$work/home
export PI_BOSS_ROOT=$work/root
mkdir -p "$HOME" "$PI_BOSS_ROOT/state"
unset PI_MASTER_ROOT JEV_MODEL JEV_TIMEOUT JEV_MIN_CONFIDENCE JEV_KEY_FILE TYPESAFE_API_KEY LOCAL_MODEL LOCAL_TIMEOUT LOCAL_KEEP_ALIVE LOCAL_ENDPOINT

# A key-shaped string the test can grep for. It is not a key: it authenticates nothing.
TEST_KEY=ts-test-NOT-A-REAL-KEY-4f9a1c
export TEST_KEY

fails=0
pass() { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }

usage=$PI_BOSS_ROOT/state/usage.jsonl
mode_file=$work/mode
answers_file=$work/answers.json
log=$work/requests.log
port_file=$work/port
: >"$log"
printf 'ok\n' >"$mode_file"

# A fake System One endpoint in TypeSafe's shape. <mode-file> <answers-file> <log-file> <port-file>
cat >"$work/fake-typesafe.mjs" <<'JS'
import fs from "node:fs";
import http from "node:http";
const [modeFile, answersFile, logFile, portFile] = process.argv.slice(2);
const key = process.env.TEST_KEY || "";
const mode = () => fs.readFileSync(modeFile, "utf8").trim();
const server = http.createServer((req, res) => {
	let raw = "";
	req.on("data", (chunk) => (raw += chunk));
	req.on("end", () => {
		let body = null;
		try {
			body = JSON.parse(raw);
		} catch {
			body = null;
		}
		// The key itself is never written: only whether the header carried it.
		fs.appendFileSync(
			logFile,
			`${JSON.stringify({ path: req.url, method: req.method, auth: req.headers.authorization === `Bearer ${key}`, body })}\n`,
		);
		const answer = () => {
			res.writeHead(200, { "content-type": "application/json" });
			res.end(
				JSON.stringify({
					model: "jev-test-1.14.0",
					answers: JSON.parse(fs.readFileSync(answersFile, "utf8")),
					usage: { input_tokens: 120, output_tokens: 30 },
				}),
			);
		};
		switch (mode()) {
			case "401":
				res.writeHead(401, { "content-type": "application/json" });
				res.end(JSON.stringify({ detail: "Invalid or missing API key." }));
				return;
			case "slow":
				setTimeout(answer, 3000);
				return;
			case "malformed":
				res.writeHead(200, { "content-type": "application/json" });
				res.end('{"model":"jev-test-1.14.0","answers": ');
				return;
			default:
				answer();
		}
	});
});
server.listen(0, "127.0.0.1", () => fs.writeFileSync(portFile, String(server.address().port)));
JS
node "$work/fake-typesafe.mjs" "$mode_file" "$answers_file" "$log" "$port_file" &
typesafe_pid=$!
trap 'kill "$typesafe_pid" "$ollama_pid" 2>/dev/null; rm -rf "$work"' EXIT
ollama_pid=""
for _ in $(seq 1 100); do [ -s "$port_file" ] && break; sleep 0.05; done
[ -s "$port_file" ] || {
	printf 'fake endpoints never started\n' >&2
	exit 1
}
export JEV_ENDPOINT=http://127.0.0.1:$(cat "$port_file")/v1/systemone
export TYPESAFE_API_KEY=$TEST_KEY
export JEV_TIMEOUT=10000

# case <name> <want-code> <want-text|-> [<want-absent-text|->] -- <command...>
# Asserts the exit code, the text that must appear and the text that must not — the key is
# checked on every case without asking each one to remember.
case_run() {
	local name=$1 want=$2 text=$3 absent=$4
	shift 5
	local out rc
	out=$(timeout 30 "$@" 2>&1) && rc=0 || rc=$?
	if printf '%s' "$out" | grep -qF -- "$TEST_KEY"; then
		fail "$name: the API key appeared in the output"
		return
	fi
	if [ "$rc" != "$want" ]; then
		fail "$name: exit $rc, wanted $want — $out"
	elif [ "$text" != - ] && ! printf '%s' "$out" | grep -qF -- "$text"; then
		fail "$name: no '$text' in output — $out"
	elif [ "$absent" != - ] && printf '%s' "$out" | grep -qF -- "$absent"; then
		fail "$name: found '$absent' in output, wanted it absent — $out"
	else
		pass "$name (exit $want)"
	fi
}

# payload_field <json> <dotted key> — the value as JSON, or null.
payload_field() {
	printf '%s' "$1" | node -e '
		let raw = "";
		process.stdin.on("data", (c) => (raw += c)).on("end", () => {
			let j = {};
			try { j = JSON.parse(raw); } catch {}
			const v = process.argv[1].split(".").reduce((a, k) => a?.[k], j);
			process.stdout.write(JSON.stringify(v === undefined ? null : v));
		});' "$2"
}

answer_choices() { # <count-choice> <count-p> <mode-choice> <mode-p> <route-choice> <route-p> <thinking-choice> <thinking-p>
	node -e '
		const [c, cp, m, mp, r, rp, t, tp] = process.argv.slice(1);
		const dist = (chosen, p, others) => {
			const out = {};
			for (const o of others) out[o] = Math.round(((1 - Number(p)) / others.length) * 100) / 100;
			out[chosen] = Number(p);
			return out;
		};
		const answers = {
			count: { type: "choice", choice: c, confidence: Number(cp), probabilities: dist(c, cp, ["1", "2", "3", "4"].filter((x) => x !== c)) },
			mode: { type: "choice", choice: m, confidence: Number(mp), probabilities: dist(m, mp, ["bare", "sandboxed", "no-net"].filter((x) => x !== m)) },
			route: { type: "choice", choice: r, confidence: Number(rp), probabilities: dist(r, rp, ["local", "remote"].filter((x) => x !== r)) },
			thinking: { type: "choice", choice: t, confidence: Number(tp), probabilities: dist(t, tp, ["low", "medium", "high"].filter((x) => x !== t)) },
		};
		process.stdout.write(JSON.stringify(answers));
	' "$@"
}

# --- A. the happy path: one request, four confident answers -----------------------------------
: >"$usage"
: >"$log"
printf 'ok\n' >"$mode_file"
answer_choices 2 0.9 sandboxed 0.95 remote 0.9 medium 0.8 >"$answers_file"
out=$(timeout 30 "$bin/jev" plan "rename one helper" --json 2>&1) && rc=0 || rc=$?
if [ "$rc" = 0 ]; then pass "plan, four confident answers (exit 0)"; else fail "plan happy path: exit $rc — $out"; fi
want='{"count":2,"mode":"sandboxed","route":"remote","thinking":"medium"}'
got="{\"count\":$(payload_field "$out" count),\"mode\":$(payload_field "$out" mode),\"route\":$(payload_field "$out" route),\"thinking\":$(payload_field "$out" thinking)}"
if [ "$got" = "$want" ]; then
	pass "the four fields are the four answers"
else
	fail "plan payload: $got, wanted $want"
fi
# One request, carrying all four questions, with the key on the header and no key in the body.
requests=$(wc -l <"$log")
questions=$(node -e '
	const fs = require("node:fs");
	const lines = fs.readFileSync(process.argv[1], "utf8").trim().split("\n").filter(Boolean);
	const r = JSON.parse(lines[0] || "{}");
	process.stdout.write(`${r.auth === true}:${Object.keys(r.body?.questions || {}).sort().join(",")}:${r.body?.model || ""}`);' "$log")
if [ "$requests" = 1 ] && [ "$questions" = "true:count,mode,route,thinking:jev-latest" ]; then
	pass "one request, four questions, the key on the header, the model alias in the body"
else
	fail "request shape: $requests request(s), $questions"
fi
line=$(tail -1 "$usage")
if [ "$(printf '%s' "$line" | node -e '
	let raw = "";
	process.stdin.on("data", (c) => (raw += c)).on("end", () => {
		let j = {};
		try { j = JSON.parse(raw); } catch {}
		process.stdout.write(`${j.kind}:${j.command}:${j.model}:${j.ok}`);
	});')" = "jev:plan:jev-test-1.14.0:true" ]; then
	pass "one usage line, naming the model that answered (not the alias)"
else
	fail "usage line: $line"
fi
if [ "$(wc -l <"$usage")" = 1 ]; then
	pass "plan writes exactly one usage line"
else
	fail "usage lines after one plan: $(wc -l <"$usage")"
fi

# --- B. a weak field takes the conservative default; the plan still succeeds --------------------
: >"$usage"
answer_choices 2 0.35 sandboxed 0.95 remote 0.9 medium 0.9 >"$answers_file"
out=$(timeout 30 "$bin/jev" plan "rename one helper" --json 2>"$work/stderr-plan") && rc=0 || rc=$?
err=$(cat "$work/stderr-plan")
if [ "$rc" = 0 ] && [ "$(payload_field "$out" count)" = 1 ] && [ "$(payload_field "$out" mode)" = '"sandboxed"' ] &&
	[ "$(payload_field "$out" thinking)" = '"medium"' ]; then
	pass "plan, a 0.35 count is exit 0 with count 1, and the other fields keep jev's answer"
else
	fail "plan low-probability count: exit $rc — $out"
fi
if [ "$(payload_field "$out" defaults)" = '["count"]' ] && [ "$(payload_field "$out" answered.count)" = '"2"' ]; then
	pass 'the payload names the defaulted field and keeps the answer it replaced: "defaults":["count"], answered.count "2"'
else
	fail "defaults payload: $(payload_field "$out" defaults) / answered $(payload_field "$out" answered.count) — $out"
fi
if printf '%s' "$err" | grep -qF "jev: defaulted count 0.35"; then
	pass "stderr names the defaulted field and its probability"
else
	fail "no default line on stderr: $err"
fi
# The same answer at a lower threshold is decisive: nothing defaults and the count is jev's own.
out=$(env JEV_MIN_CONFIDENCE=0.3 timeout 30 "$bin/jev" plan "rename one helper" --json 2>/dev/null) && rc=0 || rc=$?
if [ "$rc" = 0 ] && [ "$(payload_field "$out" count)" = 2 ] && [ "$(payload_field "$out" defaults)" = '[]' ]; then
	pass "JEV_MIN_CONFIDENCE=0.3 acts on the same answer, and nothing defaults"
else
	fail "JEV_MIN_CONFIDENCE override: exit $rc — $out"
fi
# All four weak: every field takes its default, the plan still succeeds, and each is named.
answer_choices 3 0.2 bare 0.3 local 0.25 high 0.3 >"$answers_file"
out=$(timeout 30 "$bin/jev" plan "rename one helper" --json 2>/dev/null) && rc=0 || rc=$?
if [ "$rc" = 0 ] && [ "$(payload_field "$out" count)" = 1 ] && [ "$(payload_field "$out" mode)" = '"sandboxed"' ] &&
	[ "$(payload_field "$out" route)" = '"remote"' ] && [ "$(payload_field "$out" thinking)" = '"medium"' ] &&
	[ "$(payload_field "$out" defaults)" = '["count","mode","route","thinking"]' ]; then
	pass "all four weak default together to 1, sandboxed, remote, medium (exit 0)"
else
	fail "all four default: exit $rc — $out"
fi

# --- C. an answer outside the offered options is unusable --------------------------------------
printf '%s' '{"count":{"type":"choice","choice":"2","confidence":0.9,"probabilities":{"1":0.05,"2":0.9,"3":0.03,"4":0.02}},"mode":{"type":"choice","choice":"sandboxed","confidence":0.9,"probabilities":{"bare":0.05,"sandboxed":0.9,"no-net":0.05}},"route":{"type":"choice","choice":"both","confidence":0.99,"probabilities":{"both":0.99,"local":0.01}},"thinking":{"type":"choice","choice":"low","confidence":0.9,"probabilities":{"low":0.9,"medium":0.05,"high":0.05}}}' >"$answers_file"
out=$(timeout 30 "$bin/jev" plan "rename one helper" 2>&1) && rc=0 || rc=$?
if [ "$rc" = 3 ] && printf '%s' "$out" | grep -qF "route unusable"; then
	pass "an option jev was not offered is unsure, not passed through (exit 3)"
else
	fail "unoffered option, in words: exit $rc — $out"
fi
out=$(timeout 30 "$bin/jev" plan "rename one helper" --json 2>&1) && rc=0 || rc=$?
if [ "$(payload_field "$out" route)" = null ] && [ "$(payload_field "$out" mode)" = '"sandboxed"' ]; then
	pass "the unoffered field is null and the others survive"
else
	fail "unoffered option payload: $out"
fi

# --- D. a refused key is exit 3, and names the variable, never the value -----------------------
printf '401\n' >"$mode_file"
case_run "401 names the key, not its value" 3 "refused the API key (HTTP 401)" "$TEST_KEY" -- "$bin/jev" ask "ship it?"
case_run "401 keeps the exit-3 contract for plan" 3 "HTTP 401" "$TEST_KEY" -- "$bin/jev" plan "rename one helper"
printf 'ok\n' >"$mode_file"

# --- E. a timeout is "unreachable": the word bin/delegate turns into a refusal ----------------
printf 'slow\n' >"$mode_file"
answer_choices 1 0.9 sandboxed 0.9 remote 0.9 low 0.9 >"$answers_file"
out=$(env JEV_TIMEOUT=400 timeout 30 "$bin/jev" plan "rename one helper" 2>&1) && rc=0 || rc=$?
if [ "$rc" = 3 ] && printf '%s' "$out" | grep -qF "decision model unreachable" && printf '%s' "$out" | grep -qF "timed out"; then
	pass "a timeout is exit 3 and says unreachable (exit 3)"
else
	fail "timeout: exit $rc — $out"
fi
printf 'ok\n' >"$mode_file"

# --- F. a malformed body is exit 3, never a default answer -------------------------------------
printf 'malformed\n' >"$mode_file"
case_run "a malformed body is unsure, not a guess" 3 "outside JSON" - -- "$bin/jev" plan "rename one helper"
printf 'ok\n' >"$mode_file"

# --- G. no key at all: the fix in the message, the key's value nowhere --------------------------
: >"$work/empty.env"
out=$(env -u TYPESAFE_API_KEY JEV_KEY_FILE=$work/empty.env timeout 30 "$bin/jev" ask "ship it?" 2>&1) && rc=0 || rc=$?
if [ "$rc" = 3 ] && printf '%s' "$out" | grep -qF "no API key"; then
	pass "no key is exit 3 and says what to do (exit 3)"
else
	fail "no key: exit $rc — $out"
fi
if [ -n "$out" ] && ! printf '%s' "$out" | grep -qF "$TEST_KEY"; then
	pass "no key in the message about the missing key"
else
	fail "the missing-key message is empty or leaked the key — $out"
fi
# The key file is the form this machine uses: an `export TYPESAFE_API_KEY=` line, read silently.
printf 'export TYPESAFE_API_KEY=%s\n' "$TEST_KEY" >"$work/key.env"
answer_choices 1 0.9 sandboxed 0.95 remote 0.95 low 0.9 >"$answers_file"
out=$(env -u TYPESAFE_API_KEY JEV_KEY_FILE=$work/key.env timeout 30 "$bin/jev" plan "rename one helper" 2>&1) && rc=0 || rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -qF "count=1"; then
	pass "the key file's export line is enough to answer (exit 0)"
else
	fail "key file: exit $rc — $out"
fi

# --- H. ask and permit keep their exit codes ---------------------------------------------------
printf '%s' '{"decision":{"type":"noul","noul":0.88}}' >"$answers_file"
case_run "ask, a clear yes" 0 "jev: yes" - -- "$bin/jev" ask "is this read-only?"
printf '%s' '{"decision":{"type":"noul","noul":0.1}}' >"$answers_file"
case_run "ask, a clear no is exit 1" 1 "jev: no" - -- "$bin/jev" ask "does this delete the branch?"
printf '%s' '{"decision":{"type":"noul","noul":0.52}}' >"$answers_file"
case_run "ask, a coin flip is exit 3" 3 "unsure" - -- "$bin/jev" ask "is this a good idea?"
printf '%s' '{"permission":{"type":"choice","choice":"allow","confidence":0.9,"probabilities":{"allow":0.9,"deny":0.05,"ask":0.05}}}' >"$answers_file"
case_run "permit, allow is yes" 0 "jev: yes" - -- "$bin/jev" permit "read README.md"
printf '%s' '{"permission":{"type":"choice","choice":"deny","confidence":0.95,"probabilities":{"allow":0.02,"deny":0.95,"ask":0.03}}}' >"$answers_file"
case_run "permit, deny is no" 1 "jev: no" - -- "$bin/jev" permit "read ~/.ssh/id_ed25519"
printf '%s' '{"permission":{"type":"choice","choice":"ask","confidence":0.8,"probabilities":{"allow":0.1,"deny":0.1,"ask":0.8}}}' >"$answers_file"
case_run "permit, ask is unsure" 3 "unsure" - -- "$bin/jev" permit "write outside the worker's directory"
# Every permit answer leaves a decision row. A permission call is the highest-consequence decision
# jev makes, and `delegate stats` can only count it if it is in the log; before this, permit was
# answered and never recorded, so the scorecard had no row for it at all. `ask` is deliberately not
# written here — `delegate ask` owns those rows, and two writers would count one question twice.
permit_rows=$(node -e '
	const fs = require("fs");
	const rows = fs.readFileSync(process.argv[1], "utf8").split("\n").filter(Boolean)
		.map((l) => { try { return JSON.parse(l); } catch { return null; } })
		.filter((r) => r && r.command === "permit");
	process.stdout.write(`${rows.length} ${rows.map((r) => r.decision).join(",")} ${rows.every((r) => r.jev === r.decision) ? "jev" : "no-jev"}`);' \
	"$PI_BOSS_ROOT/state/decisions.jsonl" 2>/dev/null || echo missing)
[ "$permit_rows" = "3 allow,deny,unsure jev" ] &&
	pass "each permit answer is one decision row (allow, deny, unsure)" ||
	fail "permit decision rows: got '$permit_rows', wanted '3 allow,deny,unsure jev'"

# --- I. bin/local-run keeps its ollama transport -----------------------------------------------
# The retired warm-model suite covered this and only this half still has a transport to cover: a
# local chat model with keep_alive, and one retry without it when an endpoint refuses the field.
printf '{"message":{"content":"ok"}}' >"$work/ollama-answer.json"
: >"$work/ollama.log"
ollama_port=$work/ollama-port
cat >"$work/fake-ollama.mjs" <<'JS'
import fs from "node:fs";
import http from "node:http";
const [answerFile, portFile, logFile] = process.argv.slice(2);
const server = http.createServer((req, res) => {
	let raw = "";
	req.on("data", (chunk) => (raw += chunk));
	req.on("end", () => {
		fs.appendFileSync(logFile, `${raw}\n`);
		// An endpoint that refuses the field: anything carrying keep_alive is refused, so the one
		// retry without it is the only request that can succeed, whatever the request count.
		if (fs.existsSync(`${logFile}.refuse`) && raw.includes("keep_alive")) {
			res.writeHead(400, { "content-type": "application/json" });
			res.end(JSON.stringify({ error: "unknown field: keep_alive" }));
			return;
		}
		res.writeHead(200, { "content-type": "application/json" });
		res.end(fs.readFileSync(answerFile, "utf8"));
	});
});
server.listen(0, "127.0.0.1", () => fs.writeFileSync(portFile, String(server.address().port)));
JS
node "$work/fake-ollama.mjs" "$work/ollama-answer.json" "$ollama_port" "$work/ollama.log" &
ollama_pid=$!
for _ in $(seq 1 100); do [ -s "$ollama_port" ] && break; sleep 0.05; done
[ -s "$ollama_port" ] || {
	printf 'fake ollama never started\n' >&2
	fails=$((fails + 1))
}
export LOCAL_ENDPOINT=http://127.0.0.1:$(cat "$ollama_port" 2>/dev/null || echo 1)/api/chat
export LOCAL_TIMEOUT=10000

body_field() { # <log> <index> <field> — the field as JSON, or "absent"
	node -e '
		const fs = require("node:fs");
		const lines = fs.readFileSync(process.argv[1], "utf8").trim().split("\n").filter(Boolean);
		const body = JSON.parse(lines[Number(process.argv[2])] || "null");
		if (!body || !(process.argv[3] in body)) process.stdout.write("absent");
		else process.stdout.write(JSON.stringify(body[process.argv[3]]));' "$1" "$2" "$3"
}

: >"$work/ollama.log"
out=$(timeout 30 "$bin/local-run" "say ok" 2>&1) && rc=0 || rc=$?
if [ "$rc" = 0 ] && [ "$(body_field "$work/ollama.log" 0 keep_alive)" = '"30m"' ] && [ "$(wc -l <"$work/ollama.log")" = 1 ]; then
	pass "local-run still carries keep_alive=30m in one request"
else
	fail "local-run keep_alive: exit $rc, $(body_field "$work/ollama.log" 0 keep_alive) — $out"
fi
: >"$work/ollama.log"
out=$(env LOCAL_KEEP_ALIVE=2h timeout 30 "$bin/local-run" "say ok" 2>&1) && rc=0 || rc=$?
if [ "$rc" = 0 ] && [ "$(body_field "$work/ollama.log" 0 keep_alive)" = '"2h"' ]; then
	pass "LOCAL_KEEP_ALIVE=2h moves the value, and nothing else"
else
	fail "LOCAL_KEEP_ALIVE override: exit $rc, $(body_field "$work/ollama.log" 0 keep_alive) — $out"
fi
: >"$work/ollama.log"
: >"$work/ollama.log.refuse"
errfile=$work/stderr-local
out=$(timeout 30 "$bin/local-run" "say ok" 2>"$errfile") && rc=0 || rc=$?
if [ "$rc" = 0 ] && [ "$(wc -l <"$work/ollama.log")" = 2 ] && [ "$(body_field "$work/ollama.log" 1 keep_alive)" = absent ]; then
	pass "local-run retries once without keep_alive on 400, and still answers"
else
	fail "local-run 400 retry: exit $rc, $(wc -l <"$work/ollama.log") request(s) — $(cat "$errfile")"
fi
rm -f "$work/ollama.log.refuse"

printf '\n%s\n' "$([ "$fails" = 0 ] && echo "jev/typesafe: ok" || echo "jev/typesafe: $fails failure(s)")"
[ "$fails" = 0 ]
