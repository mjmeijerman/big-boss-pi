#!/usr/bin/env bash
# test-jev-warm.sh — jev asks ollama to keep the model resident, and a refusal of that field
# never costs a decision.
#
# Three claims the harness otherwise only asserts in prose:
#
#   A. Every request carries keep_alive, with the value bin/jev-model.mjs names — 30m by
#      default, so a spawn more than five minutes after the last one does not pay the model
#      load again.
#   B. JEV_KEEP_ALIVE overrides that value, without any other change to the request.
#   C. An endpoint that refuses the field with 400 gets one retry without it, the decision
#      still comes out, and stderr says the retry happened. A second refusal still fails loud
#      at exit 3, so the "unreachable" contract is unchanged.
#
# The model is a fake ollama on a loopback port that records every request body, so "the field
# was sent" and "the retry dropped it" are read from the bytes that left, not from the output.
#
#   bash scripts/tests/test-jev-warm.sh      exit 0 = every case held
set -uo pipefail

root=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/../.." && pwd)
bin=$root/bin

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export HOME=$work/home
export PI_BOSS_ROOT=$work/root
mkdir -p "$HOME" "$PI_BOSS_ROOT/state"
unset PI_MASTER_ROOT JEV_MODEL JEV_TIMEOUT JEV_KEEP_ALIVE

fails=0
pass() { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }

answer_file=$work/answer.json
printf '{"decision":"yes","confidence":0.9,"reason":"the request is read-only"}' >"$answer_file"

# A fake ollama: answers in ollama's shape, refuses on demand, and writes every request body it
# saw to a log file. <answer-file> <port-file> <log-file> <mode>
cat >"$work/fake-ollama.mjs" <<'JS'
import fs from "node:fs";
import http from "node:http";
const [answerFile, portFile, logFile, mode] = process.argv.slice(2);
let seen = 0;
const server = http.createServer((req, res) => {
	let raw = "";
	req.on("data", (chunk) => (raw += chunk));
	req.on("end", () => {
		seen += 1;
		let body = null;
		try {
			body = JSON.parse(raw);
		} catch {
			body = null;
		}
		fs.appendFileSync(logFile, `${JSON.stringify(body)}\n`);
		if (mode === "400-always" || (mode === "400-once" && seen === 1)) {
			res.writeHead(400, { "content-type": "application/json" });
			res.end(JSON.stringify({ error: "unknown field: keep_alive" }));
			return;
		}
		res.writeHead(200, { "content-type": "application/json" });
		res.end(JSON.stringify({ message: { content: fs.readFileSync(answerFile, "utf8") } }));
	});
});
server.listen(0, "127.0.0.1", () => fs.writeFileSync(portFile, String(server.address().port)));
JS

model_pid=""
start_model() { # <mode> — sets ENDPOINT, LOG and starts the fake on its own port
	local mode=$1
	stop_model
	# A fresh log and port per case: the request bodies of one case must not leak into another.
	LOG=$(mktemp "$work/bodies.XXXXXX")
	local port_file
	port_file=$(mktemp "$work/port.XXXXXX")
	rm -f "$LOG" "$port_file"
	touch "$LOG"
	node "$work/fake-ollama.mjs" "$answer_file" "$port_file" "$LOG" "$mode" &
	model_pid=$!
	for _ in $(seq 1 100); do [ -s "$port_file" ] && break; sleep 0.05; done
	[ -s "$port_file" ] || {
		printf 'fake model never started\n' >&2
		exit 2
	}
	ENDPOINT=http://127.0.0.1:$(cat "$port_file")/api/chat
}
stop_model() {
	[ -n "$model_pid" ] && kill "$model_pid" 2>/dev/null && wait "$model_pid" 2>/dev/null
	model_pid=""
}
trap 'stop_model; rm -rf "$work"' EXIT

# body_field <log> <index> <field> — the field as JSON, or "absent". Read from the logged bytes.
body_field() {
	node -e '
const fs = require("node:fs");
const lines = fs.readFileSync(process.argv[1], "utf8").trim().split("\n").filter(Boolean);
const body = JSON.parse(lines[Number(process.argv[2])] || "null");
if (!body || !(process.argv[3] in body)) process.stdout.write("absent");
else process.stdout.write(JSON.stringify(body[process.argv[3]]));
' "$1" "$2" "$3"
}

count_bodies() {
	local n=0 line
	while IFS= read -r line; do [ -n "$line" ] && n=$((n + 1)); done <"$1"
	printf '%s' "$n"
}

export JEV_TIMEOUT=10000

# --- A. the default: keep_alive is sent, with the value jev-model.mjs names -------------------
start_model ok
out=$(env JEV_ENDPOINT=$ENDPOINT timeout 30 "$bin/jev" ask "is this read-only?" 2>&1) && rc=0 || rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -qF "jev: yes"; then
	pass "a decision still comes out of the warm request (exit 0)"
else
	fail "default keep_alive case: exit $rc — $out"
fi
got=$(body_field "$LOG" 0 keep_alive)
if [ "$got" = '"30m"' ]; then
	pass "request body carries keep_alive=\"30m\" by default"
else
	fail "default keep_alive in the body: $got, wanted \"30m\""
fi
got=$(body_field "$LOG" 0 model)
if [ "$got" != absent ]; then
	pass "the rest of the body is unchanged (model still sent: $got)"
else
	fail "request body has no model field — the request was built wrong"
fi
stop_model

# --- B. JEV_KEEP_ALIVE moves the value, and only the value ------------------------------------
start_model ok
out=$(env JEV_ENDPOINT=$ENDPOINT JEV_KEEP_ALIVE=2h timeout 30 "$bin/jev" ask "is this read-only?" 2>&1) && rc=0 || rc=$?
got=$(body_field "$LOG" 0 keep_alive)
if [ "$got" = '"2h"' ] && [ "$(count_bodies "$LOG")" = 1 ]; then
	pass "JEV_KEEP_ALIVE=2h lands in the body as keep_alive=\"2h\", one request, no retry"
else
	fail "env override: keep_alive $got, $(count_bodies "$LOG") request(s), exit $rc — $out"
fi
stop_model

# --- C. a 400 on the field costs a retry, not the decision ------------------------------------
start_model 400-once
errfile=$work/stderr
out=$(env JEV_ENDPOINT=$ENDPOINT timeout 30 "$bin/jev" ask "is this read-only?" 2>"$errfile") && rc=0 || rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -qF "jev: yes"; then
	pass "a 400 on keep_alive still yields a decision (exit 0)"
else
	fail "400-once decision: exit $rc — $out"
fi
if [ "$(count_bodies "$LOG")" = 2 ]; then
	pass "exactly one retry was made"
else
	fail "retry count: $(count_bodies "$LOG") requests, wanted 2"
fi
if [ "$(body_field "$LOG" 0 keep_alive)" = '"30m"' ] && [ "$(body_field "$LOG" 1 keep_alive)" = absent ]; then
	pass "the retry dropped keep_alive and kept everything else"
else
	fail "retry body: first $(body_field "$LOG" 0 keep_alive), second $(body_field "$LOG" 1 keep_alive)"
fi
if [ "$(body_field "$LOG" 1 model)" != absent ]; then
	pass "the retried body is otherwise intact (model present)"
else
	fail "the retried body lost its model field"
fi
if grep -qF "refused keep_alive=30m (HTTP 400); retrying without it" "$errfile"; then
	pass "stderr says the field was refused and the retry happened"
else
	fail "no retry notice on stderr — $(cat "$errfile")"
fi
stop_model

# --- C2. a second refusal is still a dead model: exit 3, loud, no third try -------------------
start_model 400-always
out=$(env JEV_ENDPOINT=$ENDPOINT timeout 30 "$bin/jev" ask "is this read-only?" 2>&1) && rc=0 || rc=$?
if [ "$rc" = 3 ] && printf '%s' "$out" | grep -qF "HTTP 400"; then
	pass "a persistent 400 still fails loud at exit 3"
else
	fail "persistent 400: exit $rc — $out"
fi
if [ "$(count_bodies "$LOG")" = 2 ]; then
	pass "no third attempt after the retry was refused"
else
	fail "persistent 400 made $(count_bodies "$LOG") requests, wanted 2 (one retry, then stop)"
fi
stop_model

printf '\n%s\n' "$([ "$fails" = 0 ] && echo "jev keep-alive: ok" || echo "jev keep-alive: $fails failure(s)")"
[ "$fails" = 0 ]
