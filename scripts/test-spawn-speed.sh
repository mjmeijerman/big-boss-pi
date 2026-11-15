#!/usr/bin/env bash
# test-spawn-speed.sh — a spawn asks jev once, starts the workers jev asked for, and blocks on
# the files an unread report actually touched.
#
# Four behaviours, each one a claim the harness makes in prose and would otherwise never check:
#
#   A. `jev plan` answers count, mode, route and thinking from one model call, validates each
#      field the way its own subcommand does, and is unsure or unreachable rather than guessing.
#      The model is a fake ollama on a loopback port, so no real model is needed and the answer
#      is the test's, not the machine's.
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

# ---------------------------------------------------------------------------------------------
# A. `jev plan`: one call, four answers, same validation.
#
# A fake ollama reads the canned answer from a file and answers in ollama's shape, on a port the
# kernel picks. That is what makes the model's disagreement testable: the answer below is the
# fixture, and every case is about what jev does with an answer, not about what a model would say.
# ---------------------------------------------------------------------------------------------
port_file=$work/port
answer_file=$work/answer.json
# A fake ollama: the canned answer comes from a file, so the model's disagreement is the fixture
# and every case is about what jev does with an answer, not about what a model would say.
cat >"$work/fake-ollama.mjs" <<'JS'
import fs from "node:fs";
import http from "node:http";
const [answerFile, portFile] = process.argv.slice(2);
const server = http.createServer((req, res) => {
	req.resume();
	req.on("end", () => {
		const answer = fs.readFileSync(answerFile, "utf8");
		res.writeHead(200, { "content-type": "application/json" });
		res.end(JSON.stringify({ message: { content: answer } }));
	});
});
server.listen(0, "127.0.0.1", () => fs.writeFileSync(portFile, String(server.address().port)));
JS
node "$work/fake-ollama.mjs" "$answer_file" "$port_file" &
model_pid=$!
trap 'kill "$model_pid" 2>/dev/null; rm -rf "$work"' EXIT
for _ in $(seq 1 100); do [ -s "$port_file" ] && break; sleep 0.05; done
[ -s "$port_file" ] || { printf 'fake model never started\n' >&2; exit 1; }
export JEV_ENDPOINT=http://127.0.0.1:$(cat "$port_file")/api/chat
export JEV_TIMEOUT=10000
usage=$PI_BOSS_ROOT/state/usage.jsonl

# plan_case <name> <answer-json> <want-exit> <want-text> [<dotted-key>=<json-value> ...]
plan_case() {
	local name=$1 answer=$2 want=$3 text=$4
	shift 4
	local out rc bad="" kv key val got
	: >"$usage"
	printf '%s' "$answer" >"$answer_file"
	out=$(timeout 30 "$bin/jev" plan "rename one helper" --json 2>&1) && rc=0 || rc=$?
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
	'{"count":2,"mode":"sandboxed","route":"remote","thinking":"medium","confidence":0.9,"reason":"two files"}' \
	0 - 'count=2' 'mode="sandboxed"' 'route="remote"' 'thinking="medium"'
# One unusable field stops the spawn and names the field: a plan that guessed at the count while
# trusting the other three is the failure this check exists for.
plan_case "plan, count out of range is unsure" \
	'{"count":9,"mode":"sandboxed","route":"remote","thinking":"low","confidence":0.9,"reason":"lots"}' \
	3 - 'count=null' 'mode="sandboxed"'
# In words, not only in JSON: the line a person reads names what was unusable.
printf '%s' '{"count":1,"mode":"sandboxed","route":"remote","thinking":"low","confidence":0.1,"reason":"unsure"}' >"$answer_file"
out=$(timeout 30 "$bin/jev" plan "rename one helper" 2>&1)
rc=$?
if [ "$rc" = 3 ] && printf '%s' "$out" | grep -qF "unsure how to plan this spawn (confidence unusable)"; then
	pass "plan, unsure says which field was unusable, in words"
else
	fail "plan, unsure wording: exit $rc — $out"
fi
plan_case "plan, low confidence is unsure" \
	'{"count":1,"mode":"bare","route":"remote","thinking":"high","confidence":0.2,"reason":"not sure"}' \
	3 - 'count=null' 'mode=null' 'thinking=null'
plan_case "plan, a route jev does not name is unsure" \
	'{"count":1,"mode":"sandboxed","route":"both","thinking":"low","confidence":0.9,"reason":"eh"}' \
	3 - 'route=null'

# The dead model is not a default answer: exit 3, and the word the caller greps for.
out=$(env JEV_ENDPOINT=http://127.0.0.1:9/api/chat timeout 30 "$bin/jev" plan "do a thing" 2>&1)
rc=$?
if [ "$rc" = 3 ] && printf '%s' "$out" | grep -qF "decision model unreachable"; then
	pass "plan, model down is exit 3 and says unreachable"
else
	fail "plan, model down: exit $rc — $out"
fi

# One call, one usage line: that is the spawn-speed claim, and the file is where it is visible.
: >"$usage"
printf '%s' '{"count":1,"mode":"sandboxed","route":"remote","thinking":"low","confidence":0.9,"reason":"one file"}' >"$answer_file"
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
# silently reuse the first one's space. status answers a focusable view; everything else is a no-op.
case ${1:-} in
status) printf '{"space":"s0","tab":"t0"}\n' ;;
do)
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
# The banner marker immediately: the spawn's wait loop exits on its first read.
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

# E. An unsure plan stops the spawn before anything exists: no spec, no space, no default count.
cat >"$PI_BOSS_ROOT/bin/jev" <<'STUB'
#!/usr/bin/env bash
printf '{"count":null,"mode":null,"route":null,"thinking":null,"reason":"the task is too thin","confidence":0.2}\n'
printf 'jev: unsure how to plan this spawn (confidence unusable) — ask the user\n' >&2
exit 3
STUB
chmod +x "$PI_BOSS_ROOT/bin/jev"
rm -f "$PI_BOSS_ROOT/state/delegations.json"
spawn unsure-task --cwd "$area" "make it better"
if [ "$SPAWN_RC" = 1 ] && printf '%s' "$spawn_out" | grep -qF "jev plan is unsure" &&
	[ ! -f "$PI_BOSS_ROOT/specs/unsure-task.md" ] && [ ! -f "$PI_BOSS_ROOT/state/delegations.json" ]; then
	pass "an unsure plan stops the spawn and creates nothing"
else
	fail "unsure plan: exit $SPAWN_RC — $spawn_out"
fi

printf '\n%s\n' "$([ "$fails" = 0 ] && echo "spawn speed: ok" || echo "spawn speed: $fails failure(s)")"
[ "$fails" = 0 ]
