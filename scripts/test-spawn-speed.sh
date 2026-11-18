#!/usr/bin/env bash
# test-spawn-speed.sh — a spawn asks jev once, starts the workers jev asked for, and blocks on
# the files an unread report actually touched.
#
# Four behaviours, each one a claim the harness makes in prose and would otherwise never check:
#
#   A. `jev plan` answers count, mode, route and thinking from one model call, validates each
#      field the way its own subcommand does, gives a weak field its conservative default and
#      names it, and stays unsure on an answer it was not offered. The model is a fake ollama on
#      a loopback port, so no real model is needed and the answer is the test's, not the machine's.
#   B. `delegate spawn` starts one space per worker jev asked for — the given slug, then SLUG-2
#      .. SLUG-N, each with its own spec and report — and refuses instead of collapsing when the
#      live ceiling would be crossed. Stub herdr-app, stub hc, stub jev, stub runner: no desktop
#      app, no model, no real space.
#   C. The in-flight block keys on touched paths, not on the whole --cwd: an unread report whose
#      branch diff overlaps the paths the task text names refuses, one that touches other files
#      goes through with a note, and --override-jev still records what it overruled. The fixture
#      is a throwaway repo with a bare origin, so the branch diff is a real branch diff.
#   D. The generated spec carries the report's Evidence scaffold, and a report copied from it
#      without filling it in is refused by the placeholder scan — opt-out, not opt-in.
#   E. A generated spec stays under a stated byte ceiling. The worker reads that file before it
#      reads the repo, so a template that grows back into a wall of prose is a slowdown nothing
#      would notice. The fixture paths are folded to one character, so the number is about the
#      template and not about where mktemp put the throwaway tree. The same fixture pins the
#      worktree path inside the repo: outside the sandbox's bind, a worker's files vanish.
#   F. A plan that could not be decided: a weak field spawns on its default and says so, a dead
#      model refuses without a flag and spawns with one, and the flag without a reason refuses.
#
#   bash scripts/test-spawn-speed.sh      exit 0 = every case held
set -uo pipefail

root=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd)
bin=$root/bin

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export PI_BOSS_ROOT=$work/root
unset PI_MASTER_ROOT
mkdir -p "$PI_BOSS_ROOT/bin" "$PI_BOSS_ROOT/specs" "$PI_BOSS_ROOT/reports" "$PI_BOSS_ROOT/state" \
	"$work/stub" "$work/stub-nospace" "$work/home"
export HOME=$work/home

fails=0
pass() { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }

# The plain-spec byte ceiling asserted in E, with the fixture paths folded to one character each.
# The template was ~6.1 KB before #36 halved it; the ceiling sits just above the halved size, so
# an addition has room and a paragraph of prose coming back does not.
SPEC_CEILING=3000

# ---------------------------------------------------------------------------------------------
# A. `jev plan`: one call, four answers, same validation.
#
# A fake System One endpoint reads the canned answers from a file and answers in TypeSafe's shape,
# on a port the kernel picks. That is what makes the model's disagreement testable: the fixture is
# a choice and a probability per question ({"count":["2",0.9],…}), and every case is about what
# jev does with an answer, not about what a model would say. The key is a placeholder the fake
# accepts and jev never prints.
# ---------------------------------------------------------------------------------------------
port_file=$work/port
answer_file=$work/answer.json
export TYPESAFE_API_KEY=ts-test-placeholder-key
cat >"$work/fake-typesafe.mjs" <<'JS'
import fs from "node:fs";
import http from "node:http";
const [answerFile, portFile] = process.argv.slice(2);
const server = http.createServer((req, res) => {
	req.resume();
	req.on("end", () => {
		// The fixture is {"question":["choice",probability]}; TypeSafe answers each question with the
		// chosen option and a distribution, and jev reads the chosen option's own probability.
		const fixture = JSON.parse(fs.readFileSync(answerFile, "utf8"));
		const answers = {};
		for (const [id, [choice, probability]] of Object.entries(fixture)) {
			answers[id] = { type: "choice", choice, confidence: probability, probabilities: { [choice]: probability } };
		}
		res.writeHead(200, { "content-type": "application/json" });
		res.end(JSON.stringify({ model: "jev-test-1.14.0", answers, usage: { input_tokens: 10, output_tokens: 5 } }));
	});
});
server.listen(0, "127.0.0.1", () => fs.writeFileSync(portFile, String(server.address().port)));
JS
node "$work/fake-typesafe.mjs" "$answer_file" "$port_file" &
model_pid=$!
trap 'kill "$model_pid" 2>/dev/null; rm -rf "$work"' EXIT
for _ in $(seq 1 100); do [ -s "$port_file" ] && break; sleep 0.05; done
[ -s "$port_file" ] || { printf 'fake model never started\n' >&2; exit 1; }
export JEV_ENDPOINT=http://127.0.0.1:$(cat "$port_file")/v1/systemone
export JEV_TIMEOUT=10000
usage=$PI_BOSS_ROOT/state/usage.jsonl

# plan_case <name> <answer-json> <want-exit> <want-text> [<dotted-key>=<json-value> ...]
plan_case() {
	local name=$1 answer=$2 want=$3 text=$4
	shift 4
	local out rc bad="" kv key val got
	: >"$usage"
	printf '%s' "$answer" >"$answer_file"
	# stderr apart from stdout: a defaulted field is named there, and stdout is the JSON.
	out=$(timeout 30 "$bin/jev" plan "rename one helper" --json 2>"$work/stderr-plan-case") && rc=0 || rc=$?
	if [ "$rc" != "$want" ]; then
		fail "$name: exit $rc, wanted $want — $out"
		return
	fi
	if [ "$text" != - ] && ! printf '%s' "$out" | grep -qF -- "$text"; then
		fail "$name: no '$text' in output — $out"
		return
	fi
	for kv in "$@"; do
		key=${kv%%=*}
		val=${kv#*=}
		got=$(printf '%s' "$out" | node -e '
			let raw = "";
			process.stdin.on("data", (c) => (raw += c)).on("end", () => {
				let j = {};
				try { j = JSON.parse(raw); } catch {}
				const v = process.argv[1].split(".").reduce((a, k) => a?.[k], j);
				process.stdout.write(JSON.stringify(v === undefined ? null : v));
			});' "$key")
		if [ "$got" != "$val" ]; then bad="$bad $key=$got wanted $val"; fi
	done
	if [ -n "$bad" ]; then
		fail "$name:$bad — $out"
		return
	fi
	pass "$name (exit $want)"
}

plan_case "plan, all four answers" \
	'{"count":["2",0.9],"mode":["sandboxed",0.9],"route":["remote",0.9],"thinking":["medium",0.8]}' \
	0 - 'count=2' 'mode="sandboxed"' 'route="remote"' 'thinking="medium"'
# One unusable field stops the spawn and names the field: a plan that guessed at the count while
# trusting the other three is the failure this check exists for.
plan_case "plan, count out of range is unsure" \
	'{"count":["9",0.9],"mode":["sandboxed",0.9],"route":["remote",0.9],"thinking":["low",0.9]}' \
	3 - 'count=null' 'mode="sandboxed"'
# A field jev answered weakly is not a refusal: it takes the conservative value for that field
# (one worker, the sandbox, remote, medium), the plan still exits 0, and the payload names it.
plan_case "plan, a weak count takes the default and still exits 0" \
	'{"count":["2",0.2],"mode":["sandboxed",0.9],"route":["remote",0.9],"thinking":["high",0.9]}' \
	0 - 'count=1' 'answered.count="2"' 'defaults=["count"]'
printf '%s' '{"count":["2",0.2],"mode":["sandboxed",0.9],"route":["remote",0.9],"thinking":["high",0.9]}' >"$answer_file"
out=$("$bin/jev" plan "rename one helper" --json 2>"$work/stderr-plan")
err=$(cat "$work/stderr-plan")
if printf '%s' "$err" | grep -qF "jev: defaulted count 0.2"; then
	pass "plan, the default line on stderr names the field and its probability"
else
	fail "plan, no default line on stderr: $err"
fi
# An answer jev was not offered is a broken answer, not a weak one: exit 3, and it is named.
printf '%s' '{"count":["9",0.9],"mode":["bare",0.9],"route":["remote",0.9],"thinking":["high",0.9]}' >"$answer_file"
out=$(timeout 30 "$bin/jev" plan "rename one helper" 2>&1)
rc=$?
if [ "$rc" = 3 ] && printf '%s' "$out" | grep -qF "unsure how to plan this spawn (count unusable)"; then
	pass "plan, an unusable field says which field it was, in words"
else
	fail "plan, unusable wording: exit $rc — $out"
fi
plan_case "plan, a route jev does not name is unsure" \
	'{"count":["1",0.9],"mode":["sandboxed",0.9],"route":["both",0.9],"thinking":["low",0.9]}' \
	3 - 'route=null'

# The dead model is not a default answer: exit 3, and the word the caller greps for.
out=$(env JEV_ENDPOINT=http://127.0.0.1:9/v1/systemone timeout 30 "$bin/jev" plan "do a thing" 2>&1)
rc=$?
if [ "$rc" = 3 ] && printf '%s' "$out" | grep -qF "decision model unreachable"; then
	pass "plan, model down is exit 3 and says unreachable"
else
	fail "plan, model down: exit $rc — $out"
fi

# One call, one usage line: that is the spawn-speed claim, and the file is where it is visible.
: >"$usage"
printf '%s' '{"count":["1",0.9],"mode":["sandboxed",0.9],"route":["remote",0.9],"thinking":["low",0.9]}' >"$answer_file"
timeout 30 "$bin/jev" plan "rename one helper" >/dev/null 2>&1
lines=$(grep -c '"command":"plan"' "$usage" 2>/dev/null || true)
if [ "${lines:-0}" = 1 ] && [ "$(wc -l <"$usage")" = 1 ]; then
	pass "plan writes exactly one usage line, and it is the plan call"
else
	fail "plan wrote ${lines:-0} plan usage lines out of $(wc -l <"$usage") — see $usage"
fi

# ---------------------------------------------------------------------------------------------
# B. N spaces for a count of N.
# ---------------------------------------------------------------------------------------------
export JEV_STUB_COUNT=1
JEV_CALLS=$work/jev-calls
export JEV_CALLS
: >"$JEV_CALLS"
cat >"$PI_BOSS_ROOT/bin/jev" <<'STUB'
#!/usr/bin/env bash
# One answer for any subcommand, and a record of every call: the "one jev call per spawn" claim
# is asserted from this file, not assumed from the code.
printf '%s\n' "$*" >>"${JEV_CALLS:-/dev/null}"
case ${JEV_STUB_COUNT:-1} in
''|*[!0-9]*) n=1 ;;
*) n=${JEV_STUB_COUNT} ;;
esac
printf '{"count":%s,"mode":"sandboxed","route":"remote","thinking":"low","reason":"stub answer","confidence":0.9}\n' "$n"
exit 0
STUB
cat >"$work/stub/herdr-app" <<'STUB'
#!/usr/bin/env bash
# A fresh space, tab, pane and terminal per space.new — distinct ids, so a second worker cannot
# silently reuse the first one's space. status answers a focusable view; ls answers the window's
# own list (FAKE_HERDR_LS), which is where a space's name and its id sit together; every `do` is
# logged when HERDR_LOG names a file, which is how a case reads what was actually closed.
case ${1:-} in
status) printf '{"space":"s0","tab":"t0"}\n' ;;
ls) [ -n "${FAKE_HERDR_LS:-}" ] && printf '%s\n' "$FAKE_HERDR_LS" ;;
do)
	[ -n "${HERDR_LOG:-}" ] && printf '%s\n' "$*" >>"$HERDR_LOG"
	case ${2:-} in
	space.new)
		n=$(cat "${HERDR_COUNTER:-/dev/null}" 2>/dev/null || echo 0)
		n=$((n + 1))
		printf '%s\n' "$n" >"${HERDR_COUNTER:-/dev/null}" 2>/dev/null || true
		printf '{"space":"s%s","tab":"t%s","pane":"p%s","terminal":"term%s"}\n' "$n" "$n" "$n" "$n"
		;;
	*) : ;;
	esac
	;;
esac
exit 0
STUB
cat >"$work/stub/hc" <<'STUB'
#!/usr/bin/env bash
# The banner marker immediately: the spawn's wait loop exits on its first read. `ls` answers herdr's
# terminal list instead, when a case cares about the leftover `learn-*` spaces.
case ${1:-} in
ls) [ -n "${FAKE_HC_LS:-}" ] && printf '%s\n' "$FAKE_HC_LS"; exit 0 ;;
esac
printf 'escape interrupt\n'
exit 0
STUB
printf '#!/usr/bin/env bash\nexit 0\n' >"$PI_BOSS_ROOT/bin/pi-sandboxed"
chmod +x "$work/stub/herdr-app" "$work/stub/hc" "$PI_BOSS_ROOT/bin/jev" "$PI_BOSS_ROOT/bin/pi-sandboxed"
export HERDR_COUNTER=$work/herdr-counter
printf '0\n' >"$HERDR_COUNTER"

area=$work/area
mkdir -p "$area"
spawn_out=""
spawn() {
	spawn_out=$(env JEV_STUB_COUNT=${JEV_STUB_COUNT:-1} PATH="$work/stub:$PATH" \
		timeout 60 "$bin/delegate" spawn "$@" 2>&1) && SPAWN_RC=0 || SPAWN_RC=$?
	return 0
}

# B1. A count of 3 starts three spaces, three specs and three report paths, one jev call.
rm -f "$PI_BOSS_ROOT/state/delegations.json" "$PI_BOSS_ROOT"/specs/*.md
JEV_STUB_COUNT=3 spawn group-task --cwd "$area" "add three commands to bin/tool"
if [ "$SPAWN_RC" = 0 ] && [ "$(grep -c '"jev_count":3' <<<"$spawn_out")" = 3 ]; then
	pass "count of 3 reports three spaces, each with jev_count 3"
else
	fail "count of 3: exit $SPAWN_RC — $spawn_out"
fi
names=$(node -e '
	const fs=require("fs");let j={};try{j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"))}catch{}
	process.stdout.write(Object.keys(j).sort().join(","))' "$PI_BOSS_ROOT/state/delegations.json")
if [ "$names" = "group-task,group-task-2,group-task-3" ]; then
	pass "slugs are group-task, group-task-2, group-task-3"
else
	fail "slugs were '$names'"
fi
missing=""
for s in group-task group-task-2 group-task-3; do
	[ -f "$PI_BOSS_ROOT/specs/$s.md" ] || missing="$missing spec:$s"
	grep -qF "Report file: \`$PI_BOSS_ROOT/reports/$s.md\`" "$PI_BOSS_ROOT/specs/$s.md" 2>/dev/null ||
		missing="$missing report-path:$s"
done
if [ -z "$missing" ]; then
	pass "each worker has its own spec and its own report path"
else
	fail "per-worker spec/report missing:$missing"
fi
if grep -q "worker 2 of 3" "$PI_BOSS_ROOT/specs/group-task-2.md" &&
	! grep -q "worker 2 of 3" "$PI_BOSS_ROOT/specs/group-task.md"; then
	pass "the task text carries the worker's position"
else
	fail "the position line is missing or on the wrong spec"
fi
calls=$(grep -c . "$JEV_CALLS" 2>/dev/null || true)
if [ "${calls:-0}" = 1 ] && grep -q "^plan" "$JEV_CALLS"; then
	pass "one spawn is one jev call, and it is plan"
else
	fail "spawn made ${calls:-0} jev call(s): $(tr '\n' ';' <"$JEV_CALLS" 2>/dev/null)"
fi

# B2. Count 1 keeps today's behaviour exactly: the given slug, one spec, no suffix.
rm -f "$PI_BOSS_ROOT/state/delegations.json"
JEV_STUB_COUNT=1 spawn solo-task --cwd "$area" "one small change"
names=$(node -e '
	const fs=require("fs");let j={};try{j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"))}catch{}
	process.stdout.write(Object.keys(j).sort().join(","))' "$PI_BOSS_ROOT/state/delegations.json")
if [ "$SPAWN_RC" = 0 ] && [ "$names" = "solo-task" ] && [ -f "$PI_BOSS_ROOT/specs/solo-task.md" ]; then
	pass "count 1 keeps the old slug and the old spec path"
else
	fail "count 1: exit $SPAWN_RC, slugs '$names' — $spawn_out"
fi

# B2b. A spawn reaps the learner space an earlier compaction left open: the `learn-*` space whose
#      terminals are all finished is closed with the id the window names, and the worker the spawn
#      actually starts still gets its space. Both, in one command.
rm -f "$PI_BOSS_ROOT/state/delegations.json"
export FAKE_HC_LS='{"hidden_finished":0,"terminals":[
{"address":"t1","status":"done","where":"learn-07-08 / learn-07-08"},
{"address":"t2","status":"done","where":"learn-07-08 / learn-07-08"}]}'
export FAKE_HERDR_LS='{"spaces":[{"id":"sp-learn","name":"learn-07-08","folder":"/home/mark/.pi"}]}'
: >"$work/herdr-log"
export HERDR_LOG=$work/herdr-log
JEV_STUB_COUNT=1 spawn reap-task --cwd "$area" "one small change"
if [ "$SPAWN_RC" != 0 ]; then
	fail "a spawn with a finished learn space exited $SPAWN_RC — $spawn_out"
elif ! grep -qF "space.close --id sp-learn --confirmed true" "$work/herdr-log"; then
	fail "the spawn did not reap the finished learn space: $(tr '\n' ';' <"$work/herdr-log")"
elif ! grep -qF "space.new --name reap-task" "$work/herdr-log"; then
	fail "the reap replaced the spawn's own space.new: $(tr '\n' ';' <"$work/herdr-log")"
elif ! printf '%s' "$spawn_out" | grep -qF "reap: closed learn-07-08 (2 terminals, all done)"; then
	fail "the reap did not report itself in one line — $spawn_out"
else
	pass "a spawn reaps the finished learn space and still starts its own worker"
fi
unset FAKE_HC_LS FAKE_HERDR_LS HERDR_LOG

# B3. The live ceiling refuses a count that would cross it, instead of starting one.
node -e '
	const fs=require("fs");
	const j={};
	for(let i=1;i<=7;i++)j["filler-"+i]={slug:"filler-"+i,space:"s"+i,cwd:process.argv[1],report:"",branch:""};
	fs.writeFileSync(process.argv[2],JSON.stringify(j,null,2));' "$area" "$PI_BOSS_ROOT/state/delegations.json"
JEV_STUB_COUNT=3 spawn ceiling-task --cwd "$area" "three more changes"
if [ "$SPAWN_RC" = 1 ] && printf '%s' "$spawn_out" | grep -qF "past the live ceiling of 8" &&
	[ ! -f "$PI_BOSS_ROOT/specs/ceiling-task.md" ]; then
	pass "a count that crosses the live ceiling refuses, and starts nothing"
else
	fail "ceiling: exit $SPAWN_RC, spec written=$([ -f "$PI_BOSS_ROOT/specs/ceiling-task.md" ] && echo yes || echo no) — $spawn_out"
fi

# B4. A count needs room for its suffixes in a 31-character slug; say so instead of truncating.
rm -f "$PI_BOSS_ROOT/state/delegations.json"
long_slug=$(printf 'a%.0s' $(seq 1 30))
JEV_STUB_COUNT=3 spawn "$long_slug" --cwd "$area" "three more changes"
if [ "$SPAWN_RC" = 1 ] && printf '%s' "$spawn_out" | grep -qF "at most 29 characters"; then
	pass "a count of 3 with a 30-character slug refuses and asks for a shorter one"
else
	fail "long slug: exit $SPAWN_RC — $spawn_out"
fi

# ---------------------------------------------------------------------------------------------
# C. The in-flight block keys on touched paths.
#
# A real branch in a real repo: main holds bin/thing.sh and README.md, branch old-worker changes
# only bin/thing.sh. That is the "unread report's paths" side; the task text is the other side.
# ---------------------------------------------------------------------------------------------
repo=$work/repo
git init -q --bare -b main "$work/remote.git"
git clone -q "$work/remote.git" "$repo" 2>/dev/null
git -C "$repo" config user.email worker@example.invalid
git -C "$repo" config user.name worker
mkdir -p "$repo/bin"
printf 'echo one\n' >"$repo/bin/thing.sh"
printf 'readme\n' >"$repo/README.md"
git -C "$repo" add -A
git -C "$repo" commit -q -m "feat: the base"
git -C "$repo" push -q origin main
git -C "$repo" checkout -q -b old-worker
printf 'echo two\n' >"$repo/bin/thing.sh"
git -C "$repo" commit -q -am "feat: thing, second line"
git -C "$repo" checkout -q main

# herdr-app that yields no space id: a spawn that gets past the queue dies right after, which is
# how a case asserts "the queue let it through" without starting anything.
cat >"$work/stub-nospace/herdr-app" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$work/stub-nospace/herdr-app"
cp "$work/stub/hc" "$work/stub-nospace/hc"

in_flight_setup() {
	rm -f "$PI_BOSS_ROOT"/state/read/*
	printf 'the report nobody read yet\n' >"$PI_BOSS_ROOT/reports/old-worker.md"
	cat >"$PI_BOSS_ROOT/state/delegations.json" <<DELEGATIONS
{"old-worker":{"slug":"old-worker","space":"s1","cwd":"$repo","report":"$PI_BOSS_ROOT/reports/old-worker.md","branch":"old-worker"}}
DELEGATIONS
}
queue_spawn() {
	spawn_out=$(env PATH="$work/stub-nospace:$PATH" timeout 60 "$bin/delegate" spawn "$@" 2>&1) && SPAWN_RC=0 || SPAWN_RC=$?
}

# C1. Overlap: the task names bin/thing.sh, the unread branch changed it.
in_flight_setup
queue_spawn new-thing --cwd "$repo" "rewrite bin/thing.sh so it prints three lines"
if [ "$SPAWN_RC" = 1 ] && printf '%s' "$spawn_out" | grep -qF "a report there is still unread" &&
	printf '%s' "$spawn_out" | grep -qF "touches: bin/thing.sh" &&
	printf '%s' "$spawn_out" | grep -qF "This task names: bin/thing.sh"; then
	pass "an overlapping unread report blocks, with both path lists"
else
	fail "overlap block: exit $SPAWN_RC — $spawn_out"
fi
if grep '"command":"in-flight"' "$PI_BOSS_ROOT/state/decisions.jsonl" 2>/dev/null |
	grep -q '"decision":"blocked".*bin/thing.sh'; then
	pass "the blocked decision is recorded with the paths"
else
	fail "no in-flight blocked line naming bin/thing.sh"
fi

# C2. No overlap: the task names a file the unread worker never touched.
in_flight_setup
queue_spawn new-readme --cwd "$repo" "expand README.md with a usage section"
if printf '%s' "$spawn_out" | grep -qF "touch no path this task names" &&
	! printf '%s' "$spawn_out" | grep -qF "a report there is still unread"; then
	pass "a non-overlapping unread report does not block, and the note says why"
else
	fail "non-overlap: exit $SPAWN_RC — $spawn_out"
fi
if grep '"command":"in-flight"' "$PI_BOSS_ROOT/state/decisions.jsonl" 2>/dev/null |
	grep -q '"decision":"allowed"'; then
	pass "the allowed decision is recorded, not silent"
else
	fail "no in-flight allowed line"
fi

# C3. A task that names no path at all: no overlap established, said out loud.
in_flight_setup
queue_spawn new-vague --cwd "$repo" "make the tool nicer to use"
if printf '%s' "$spawn_out" | grep -qF "the task names no path, so this is no overlap established"; then
	pass "a task naming no path is allowed, and the note says the overlap is unknown"
else
	fail "no-path task: exit $SPAWN_RC — $spawn_out"
fi

# C4. --override-jev still gets through, and still records what it overruled.
in_flight_setup
spawn_out=$(env PATH="$work/stub-nospace:$PATH" timeout 60 "$bin/delegate" spawn new-forced \
	--cwd "$repo" --override-jev --reason "the queue can wait, this is one line" \
	"rewrite bin/thing.sh so it prints three lines" 2>&1) && SPAWN_RC=0 || SPAWN_RC=$?
if printf '%s' "$spawn_out" | grep -qF "spawning because --override-jev --reason was given" &&
	grep '"command":"in-flight"' "$PI_BOSS_ROOT/state/decisions.jsonl" 2>/dev/null |
	grep -q '"decision":"override".*"overridden":true'; then
	pass "--override-jev gets past an overlapping report and records the override"
else
	fail "override: exit $SPAWN_RC — $spawn_out"
fi

# C5. The read marker is still the only thing that clears the block.
in_flight_setup
mkdir -p "$PI_BOSS_ROOT/state/read"
: >"$PI_BOSS_ROOT/state/read/old-worker"
queue_spawn new-read --cwd "$repo" "rewrite bin/thing.sh so it prints three lines"
if [ "$SPAWN_RC" = 1 ] && ! printf '%s' "$spawn_out" | grep -qF "a report there is still unread"; then
	pass "a read marker clears the overlap block"
else
	fail "read marker: exit $SPAWN_RC — $spawn_out"
fi

# ---------------------------------------------------------------------------------------------
# D. The Evidence scaffold is in the generated spec, and the placeholder scan catches it when a
#    worker copies it without filling it in.
# ---------------------------------------------------------------------------------------------
rm -f "$PI_BOSS_ROOT/state/read/old-worker"
spec=$PI_BOSS_ROOT/specs/group-task.md
if grep -q '^## Evidence$' "$spec" && grep -qF 'Command: <fill in:' "$spec"; then
	pass "the generated spec carries the prefilled Evidence scaffold"
else
	fail "no Evidence scaffold in $spec"
fi
# The two body lines a publish is refused without are handed over in the exact form the gate reads.
# `**Review tier:** Medium` and a bare `Review tier: Medium` are both read; a worker told the shape
# writes it first time, which is the whole cost of not saying it.
missing_lines=""
for anchor in 'Review tier: High' 'Test change: <why>'; do
	grep -qF -- "$anchor" "$spec" || missing_lines="$missing_lines '$anchor'"
done
if [ -n "$missing_lines" ]; then
	fail "the generated spec never names the body lines publish needs:$missing_lines"
else
	pass "the generated spec hands over the Review tier and Test change lines"
fi
# The scaffold as the worker sees it, copied verbatim into a report.
awk '/^````markdown$/{f=1;next} f&&/^````$/{exit} f' "$spec" >"$PI_BOSS_ROOT/reports/scaffold.md"
if [ -s "$PI_BOSS_ROOT/reports/scaffold.md" ]; then
	pass "the scaffold is a copyable block, fence included"
else
	fail "could not extract the scaffold block from $spec"
fi
cat >"$PI_BOSS_ROOT/state/delegations.json" <<DELEGATIONS
{"scaffold":{"slug":"scaffold","space":"s1","cwd":"$area","report":"$PI_BOSS_ROOT/reports/scaffold.md","branch":""}}
DELEGATIONS
out=$(PATH="$work/stub:$PATH" timeout 30 "$bin/delegate" close scaffold 2>&1) && rc=0 || rc=$?
if [ "$rc" = 1 ] && printf '%s' "$out" | grep -qF "still has fill-in placeholders"; then
	pass "a report copied from the scaffold unfilled is refused by close"
else
	fail "unfilled scaffold: exit $rc — $out"
fi

# E. The spec has a byte ceiling. A worker reads this file before it reads the repo, so a template
#    that grows back into a wall of prose is a slowdown no assertion would otherwise notice.
rm -f "$PI_BOSS_ROOT/state/delegations.json" "$PI_BOSS_ROOT"/specs/*.md
spawn slim-plain --cwd "$area" "edit one line in README.md"
plain=$PI_BOSS_ROOT/specs/slim-plain.md
if [ "$SPAWN_RC" != 0 ] || [ ! -f "$plain" ]; then
	fail "the ceiling fixture never wrote a spec: exit $SPAWN_RC — $spawn_out"
else
	plain_bytes=$(sed "s|$work|@|g" "$plain" | wc -c)
	if [ "$plain_bytes" -le "$SPEC_CEILING" ]; then
		pass "a plain spec is $plain_bytes bytes, ceiling $SPEC_CEILING"
	else
		fail "a plain spec is $plain_bytes bytes, over the $SPEC_CEILING-byte ceiling — the template grew: $plain"
	fi
	if grep -q '^## Acceptance mode$' "$plain"; then
		fail "the plain spec carries the acceptance block, which only --acceptance should inline"
	else
		pass "the plain spec carries no acceptance block"
	fi
	# The worktree lives inside the repo the worker works in. The sandbox binds the repo, not its
	# parent, so `../SLUG-worktree` is a directory that never exists on the host: three workers in
	# a row left a `prunable` entry that way. Pin the path, not just the prose around it.
	if grep -qF 'git worktree add .worktrees/' "$plain" && ! grep -qF '../SLUG-worktree' "$plain"; then
		pass "the spec cuts the worker's worktree inside the repo, at .worktrees/SLUG"
	else
		fail "the spec does not cut the worktree at .worktrees/SLUG — a worker outside the bind loses its files: $(grep -n 'worktree add' "$plain" | head -2)"
	fi
fi

# F. A plan that could not be decided. A weak field spawns on the conservative default and says
#    which field it was; a dead model still refuses without the flag and spawns on the same
#    defaults with it; the flag without a reason still refuses. The stub jev writes the payload,
#    so each case is about what delegate does with a plan, not about what a model would say.
cat >"$PI_BOSS_ROOT/bin/jev" <<'STUB'
#!/usr/bin/env bash
case ${JEV_STUB_MODE:-dead} in
weak)
	printf '{"count":1,"mode":"sandboxed","route":"remote","thinking":"medium","defaults":["count"],"answered":{"count":"2"},"reason":"count 0.35, mode 0.9, route 0.9, thinking 0.8","confidence":0.35}\n'
	exit 0
	;;
*)
	printf 'jev: decision model unreachable (http://127.0.0.1:9/v1/systemone): fetch failed — ask the user\n' >&2
	exit 3
	;;
esac
STUB
chmod +x "$PI_BOSS_ROOT/bin/jev"
rm -f "$PI_BOSS_ROOT/state/delegations.json" "$PI_BOSS_ROOT/specs/dead-plan.md" "$PI_BOSS_ROOT/specs/weak-plan.md"
export JEV_STUB_MODE=dead
spawn dead-plan --cwd "$area" "make it better"
if [ "$SPAWN_RC" = 1 ] && printf '%s' "$spawn_out" | grep -qF "jev is unreachable or broken" &&
	[ ! -f "$PI_BOSS_ROOT/specs/dead-plan.md" ] && [ ! -f "$PI_BOSS_ROOT/state/delegations.json" ]; then
	pass "a dead model stops the spawn and creates nothing"
else
	fail "dead model: exit $SPAWN_RC — $spawn_out"
fi
# The flag without a reason is still a refusal, and the message names what is missing.
spawn dead-plan --cwd "$area" --override-jev "make it better"
if [ "$SPAWN_RC" = 1 ] && printf '%s' "$spawn_out" | grep -qF "needs a non-empty --reason" &&
	[ ! -f "$PI_BOSS_ROOT/specs/dead-plan.md" ]; then
	pass "--override-jev without --reason still refuses"
else
	fail "override without a reason: exit $SPAWN_RC — $spawn_out"
fi
# With the flag and a reason the spawn goes through on the same defaults, and says so once.
rm -f "$PI_BOSS_ROOT/state/decisions.jsonl"
spawn dead-plan --cwd "$area" --override-jev --reason "the model is down and one worker is enough" "make it better"
if [ "$SPAWN_RC" = 0 ] &&
	printf '%s' "$spawn_out" | grep -qF "all four fields took their conservative default; using count=1 mode=sandboxed route=remote thinking=medium" &&
	[ -f "$PI_BOSS_ROOT/specs/dead-plan.md" ]; then
	pass "a dead model spawns on the defaults when --override-jev carries a reason"
else
	fail "dead model with override: exit $SPAWN_RC — $spawn_out"
fi
rows=$(grep -cF '"defaults":["count","mode","route","thinking"]' "$PI_BOSS_ROOT/state/decisions.jsonl" 2>/dev/null || true)
if [ "${rows:-0}" = 4 ]; then
	pass "all four decision rows name the four defaulted fields"
else
	fail "${rows:-0} of 4 decision rows carry the defaulted field names"
fi
if grep -qF 'Mode: `sandboxed` (defaulted)' "$PI_BOSS_ROOT/specs/dead-plan.md"; then
	pass "the spec header says the mode was defaulted, not chosen by jev"
else
	fail "the spec header still claims jev chose the mode"
fi
# A weak answer is not a dead model: the spawn continues with no flag, and only the weak field is
# named. jev's own answer stays on the row, so the log does not record the default as jev's.
rm -f "$PI_BOSS_ROOT/state/decisions.jsonl" "$PI_BOSS_ROOT/state/delegations.json" "$PI_BOSS_ROOT/specs/weak-plan.md"
export JEV_STUB_MODE=weak
spawn weak-plan --cwd "$area" "make it better"
if [ "$SPAWN_RC" = 0 ] &&
	printf '%s' "$spawn_out" | grep -qF "jev defaulted count 0.35; using count=1 mode=sandboxed route=remote thinking=medium" &&
	[ -f "$PI_BOSS_ROOT/specs/weak-plan.md" ]; then
	pass "a weak count spawns on the default, without a flag, and says which field defaulted"
else
	fail "weak count: exit $SPAWN_RC — $spawn_out"
fi
if grep '"command":"count"' "$PI_BOSS_ROOT/state/decisions.jsonl" 2>/dev/null |
	grep -q '"decision":"1".*"jev":"2".*"defaults":\["count"\]'; then
	pass "the count row records jev's 2, the default 1, and the defaulted field"
else
	fail "count row: $(grep '"command":"count"' "$PI_BOSS_ROOT/state/decisions.jsonl" 2>/dev/null | tail -1)"
fi
unset JEV_STUB_MODE

# G. The spec template is a heredoc, so a stray newline inside it splits a sentence and every
#    worker after that reads the broken line. The cheap version of the check: in a plain spec, a
#    line at column 0 has to start a block — heading, list item, fence, table row, quote, blank.
#    Anything else is prose that was cut in half by the template, not by the task. A deliberate
#    paragraph always follows a blank line; a wrapped break does not, which is what separates the
#    two without teaching the check to read English.
spec_strays() { # <spec> — the column-0 lines that split prose instead of starting a block
	awk '
		function block(l) {
			return l ~ /^[[:space:]]/ || l == "" || l ~ /^#/ || l ~ /^[-*+] / ||
			       l ~ /^[0-9]+\. / || l ~ /^```/ || l ~ /^\|/ || l ~ /^>/
		}
		/^```/ { fence = !fence; prev = ""; next }
		{ if (!fence && !block($0) && prev != "") printf "%d: %s\n", NR, $0; prev = $0 }
	' "$1"
}
for generated in "$PI_BOSS_ROOT/specs/slim-plain.md" "$PI_BOSS_ROOT/specs/weak-plan.md"; do
	if [ ! -f "$generated" ]; then
		fail "the lint fixture $generated was never written"
		continue
	fi
	if strays=$(spec_strays "$generated") && [ -z "$strays" ]; then
		pass "$(basename "$generated") has no column-0 line that starts no block"
	else
		fail "$(basename "$generated") has prose split across lines by the template: $strays"
	fi
done

printf '\n%s\n' "$([ "$fails" = 0 ] && echo "spawn speed: ok" || echo "spawn speed: $fails failure(s)")"
[ "$fails" = 0 ]
