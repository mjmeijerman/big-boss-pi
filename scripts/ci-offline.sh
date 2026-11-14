#!/usr/bin/env bash
# ci-offline.sh — prove the harness fails loud without ollama and without herdr-app.
#
# The interesting half of CI for this repo, because the two things every script talks to
# (a local ollama model, the Herdr desktop app) do not exist on a GitHub runner. So instead
# of mocking them, this runs the real scripts against a closed port and an empty PATH and
# checks that they refuse loudly, with the right exit code, instead of hanging or guessing.
#
# Everything runs against a temporary HOME and a temporary PI_BOSS_ROOT: no real workspace,
# no real systemd, no real state/ directory is touched. Guard is the one that could otherwise
# create a real Herdr space, so herdr-app is stripped from PATH for every case.
#
#   bash scripts/ci-offline.sh      exit 0 = all behaviours held
set -uo pipefail

root=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd)
bin=$root/bin

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export HOME=$work/home
export PI_BOSS_ROOT=$work/root
mkdir -p "$HOME" "$PI_BOSS_ROOT"
unset PI_MASTER_ROOT JEV_MODEL JEV_TIMEOUT

# PATH minus every directory that ships herdr-app, so guard and delegate cannot find it even
# on a machine (like a laptop) where it is installed.
safe_path=""
IFS=: read -r -a dirs <<<"${PATH:-/usr/local/bin:/usr/bin:/bin}"
for d in "${dirs[@]}"; do
	[ -x "$d/herdr-app" ] && continue
	safe_path+=${safe_path:+:}$d
done
if PATH=$safe_path command -v herdr-app >/dev/null 2>&1; then
	printf 'setup: herdr-app still on PATH; the guard test would create a real space\n' >&2
	exit 2
fi

# A port nothing listens on: 127.0.0.1:9 is the discard port and is closed on the runner.
closed=http://127.0.0.1:9/api/chat

fails=0
pass() { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }

# expect <name> <want-code> <want-text|-> -- <command...>
expect() {
	local name=$1 want=$2 text=$3
	shift 4 # name, code, text, --
	local out rc
	out=$(timeout 30 "$@" 2>&1) && rc=0 || rc=$?
	if [ "$rc" != "$want" ]; then
		fail "$name: exit $rc, wanted $want — $out"
	elif [ "$text" != - ] && ! printf '%s' "$out" | grep -qF -- "$text"; then
		fail "$name: no '$text' in output — $out"
	else
		pass "$name (exit $want)"
	fi
}

# 1. The model client: an unreachable model is exit 3 and says so. Exit 3 is the whole point
#    — it is the code that sends the question to the user instead of answering it.
expect "jev ask, model down" 3 "decision model unreachable" -- \
	env JEV_ENDPOINT=$closed "$bin/jev" ask "ship it?"
expect "jev route, model down" 3 "decision model unreachable" -- \
	env JEV_ENDPOINT=$closed "$bin/jev" route "summarise this"
# thinking is the newest decision kind and the one a spawn cannot do without: an unreachable
# model must stop the spawn, never fall back to a default level.
expect "jev thinking, model down" 3 "decision model unreachable" -- \
	env JEV_ENDPOINT=$closed "$bin/jev" thinking "rename a helper"
# local-run reports on stderr and exits 1: no answer is not the same as "ask the user".
expect "local-run, model down" 1 "local model unreachable" -- \
	env JEV_ENDPOINT=$closed "$bin/local-run" "say hi"
expect "jev with no question" 2 "needs the question text" -- \
	env JEV_ENDPOINT=$closed "$bin/jev" ask ""
expect "jev with no subcommand" 2 "usage: jev" -- \
	env JEV_ENDPOINT=$closed "$bin/jev"

# 2. delegate refuses a bad slug before it reaches out to anything. The slug check comes
#    before the herdr-app check, so a malformed slug must not mention herdr at all.
expect "delegate, bad slug" 1 "slug must match" -- \
	env PATH=$safe_path "$bin/delegate" spawn "Bad_Slug" --cwd "$work" "do a thing"
expect "delegate, missing --cwd" 1 "spawn needs --cwd" -- \
	env PATH=$safe_path "$bin/delegate" spawn "good-slug" "do a thing"
expect "delegate, no such directory" 1 "no such directory" -- \
	env PATH=$safe_path "$bin/delegate" spawn "good-slug" --cwd "$work/nope" "do a thing"
expect "delegate, bad thinking level" 1 "thinking must be off" -- \
	env PATH=$safe_path "$bin/delegate" spawn "good-slug" --cwd "$work" --thinking louder "do a thing"
expect "delegate, no subcommand" 1 "usage: delegate" -- \
	env PATH=$safe_path "$bin/delegate"

# 3. Without herdr-app, delegate says which binary is missing and stops. Nothing is spawned
#    and nothing is written into the temporary root's state directory.
expect "delegate spawn, herdr-app absent" 1 "herdr-app is not on PATH" -- \
	env PATH=$safe_path "$bin/delegate" spawn "good-slug" --cwd "$work" "do a thing"
[ -f "$PI_BOSS_ROOT/state/delegations.json" ] &&
	fail "delegate wrote state before it had a space" ||
	pass "no state/delegations.json written"

# 4. guard exits instead of looping or creating a space. It is silent on stdout — the reason
#    goes to its log — so this one is a code check plus a look at the log.
expect "guard, herdr-app absent" 0 - -- \
	env PATH=$safe_path "$bin/guard"
if grep -qF "herdr-app not on PATH; exiting" "$PI_BOSS_ROOT/state/guard.log" 2>/dev/null; then
	pass "guard said why in state/guard.log, in the temporary root"
else
	fail "guard wrote no 'herdr-app not on PATH; exiting' line to the temporary root"
fi

# 5. The temporary root is honoured, not read through to the real one.
expect "delegate list, empty temp root" 0 "no workers" -- \
	env PATH=$safe_path "$bin/delegate" list

# 5b. The close guard reads prose, not pasted output. It has its own script because every case
#     drives a real `delegate close` against its own temporary root; running it here is what
#     keeps those cases in CI without a second workflow step.
expect "placeholder scan over fenced reports" 0 "placeholder scan: ok" -- \
	bash "$root/scripts/test-placeholders.sh"
# 5c. The wipe step between features: five checklist lines, a loud refusal on an unknown slug,
#     and a skip recorded with its reason in state/decisions.jsonl. Same pattern, same reason
#     for a separate script: each case needs its own temporary root and a stub herdr-app.
expect "wipe checklist, refusal and skip log" 0 "wipe: ok" -- \
	bash "$root/scripts/test-wipe.sh"
# 5d. Provenance (Radar blips 79 and 82): a report's commit sha has to carry an Agent-Slug trailer
#     before the close goes through, a wiped spec moves into specs/archive/, and the spawn template
#     names both the archive and the trailers. Same pattern: the script owns a throwaway git repo
#     and a temporary root, so nothing here touches the real workspace.
expect "provenance trailers, spec archive and PR template" 0 "provenance: ok" -- \
	bash "$root/scripts/test-provenance.sh"
# 5e. The guard's repair path (Radar blip 20): a stale tab is resumed from its resume entry when
#     it has one, and only opened fresh when it never held pi — or when the resume did not start
#     pi. Fake herdr-app, fake resume map, fake resume script; no desktop app, no session, no
#     real space.
expect "guard resumes before it reopens a tab" 0 "guard-resume: ok" -- \
	bash "$root/scripts/test-guard-resume.sh"

# 6. Routing is a refusal, not a warning. delegate reads jev from $PI_BOSS_ROOT/bin, so a
#    fake jev there answers route=local without a model and without touching the real tree.
#    herdr-app, hc and the runner are stubs, so a spawn that gets past the refusal cannot
#    create a space. The runner exists because delegate checks for it before it logs anything.
stub=$work/stub
mkdir -p "$stub" "$PI_BOSS_ROOT/bin"
cat >"$stub/herdr-app" <<'STUB'
#!/usr/bin/env bash
printf 'stub herdr-app: %s\n' "$*"
exit 0
STUB
cat >"$stub/hc" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
cat >"$PI_BOSS_ROOT/bin/jev" <<'STUB'
#!/usr/bin/env bash
case $1 in
route) printf '{"route":"local","reason":"one sentence to translate"}\n' ;;
mode) printf '{"mode":"sandboxed","reason":"read-only work"}\n' ;;
count) printf '{"count":1,"reason":"one sentence"}\n' ;;
thinking) printf '{"thinking":"low","reason":"mechanical"}\n' ;;
*) printf '{"reason":"stub"}\n' ;;
esac
exit 0
STUB
printf '#!/usr/bin/env bash\nexit 0\n' >"$PI_BOSS_ROOT/bin/pi-sandboxed"
chmod +x "$stub/herdr-app" "$stub/hc" "$PI_BOSS_ROOT/bin/jev" "$PI_BOSS_ROOT/bin/pi-sandboxed"

expect "delegate spawn, jev route local refuses" 1 "bin/local-run" -- \
	env PATH=$stub:$safe_path "$bin/delegate" spawn "local-work" --cwd "$work" "translate one sentence to Dutch"

# The same task, forced through with a reason: the spawn proceeds and the route line in the
# decisions log records the override. It may fail later on the herdr-app stub; the log is the
# assertion, because that line is written before any space is asked for.
env PATH=$stub:$safe_path "$bin/delegate" spawn "local-override" --cwd "$work" --override-jev \
	--reason "needs a repo and tools" "translate one sentence to Dutch" >/dev/null 2>&1 || true
if grep '"command":"route"' "$PI_BOSS_ROOT/state/decisions.jsonl" 2>/dev/null | grep -q '"decision":"local".*"overridden":true'; then
	pass "route override recorded in state/decisions.jsonl"
else
	fail "no route line with decision local and overridden true in state/decisions.jsonl"
fi

# 6b. Work in flight is capped by review. A reported worker in a cwd whose report nobody marked
#     read blocks the next spawn there; the marker clears it and --override-jev --reason goes
#     through. Same stub harness, with jev answering remote so the route check is not what speaks.
cat >"$PI_BOSS_ROOT/bin/jev" <<'STUB'
#!/usr/bin/env bash
case $1 in
route) printf '{"route":"remote","reason":"code change"}\n'; exit 1 ;;
mode) printf '{"mode":"sandboxed","reason":"repo work"}\n' ;;
count) printf '{"count":1,"reason":"one worker"}\n' ;;
thinking) printf '{"thinking":"low","reason":"mechanical"}\n' ;;
*) printf '{"reason":"stub"}\n' ;;
esac
exit 0
STUB
chmod +x "$PI_BOSS_ROOT/bin/jev"
mkdir -p "$PI_BOSS_ROOT/reports" "$PI_BOSS_ROOT/state"
printf 'reported, waiting to be read\n' >"$PI_BOSS_ROOT/reports/old-worker.md"
cat >"$PI_BOSS_ROOT/state/delegations.json" <<DELEGATIONS
{"old-worker":{"slug":"old-worker","space":"s1","cwd":"$work","report":"$PI_BOSS_ROOT/reports/old-worker.md","branch":""}}
DELEGATIONS
expect "delegate spawn, unread report in the same cwd refuses" 1 "a report there is still unread" -- \
	env PATH=$stub:$safe_path "$bin/delegate" spawn "new-worker" --cwd "$work" "change one file"
if grep '"command":"in-flight"' "$PI_BOSS_ROOT/state/decisions.jsonl" 2>/dev/null | grep -q '"decision":"blocked"'; then
	pass "in-flight refusal recorded in state/decisions.jsonl"
else
	fail "no in-flight blocked line in state/decisions.jsonl"
fi
# A read marker is what clears it: the spawn then gets past the queue and dies later, on the stub
# herdr-app's missing space id. That line is the proof the refusal above came from the queue alone.
mkdir -p "$PI_BOSS_ROOT/state/read"
: >"$PI_BOSS_ROOT/state/read/old-worker"
expect "delegate spawn, read marker clears the block" 1 "could not read the new space id" -- \
	env PATH=$stub:$safe_path "$bin/delegate" spawn "new-worker" --cwd "$work" "change one file"
rm -f "$PI_BOSS_ROOT/state/read/old-worker"
env PATH=$stub:$safe_path "$bin/delegate" spawn "new-worker" --cwd "$work" --override-jev \
	--reason "the queue can wait, this is a one-line fix" "change one file" >/dev/null 2>&1 || true
if grep '"command":"in-flight"' "$PI_BOSS_ROOT/state/decisions.jsonl" 2>/dev/null | grep -q '"decision":"override".*"overridden":true'; then
	pass "in-flight override recorded with its reason in state/decisions.jsonl"
else
	fail "no in-flight override line with overridden true in state/decisions.jsonl"
fi
# `delegate wait` prints the report and marks it read in one go: the queue drains by reading, and
# nothing else marks a report read.
expect "delegate wait marks the report read" 0 "old-worker reported" -- \
	"$bin/delegate" wait old-worker --timeout 5
[ -f "$PI_BOSS_ROOT/state/read/old-worker" ] &&
	pass "delegate wait wrote state/read/old-worker" ||
	fail "delegate wait left no read marker for old-worker"

# 7. delegate stats: the aggregation over both files, with fixtures written into the
#    temporary root. The numbers below are the assertion: counts per command, the route split,
#    the override count (including one legacy row whose flag predates the per-line fix), and the
#    local work path line, which is the whole reason the usage file exists.
# The earlier cases really did call bin/jev and bin/local-run, and both write usage lines
# under PI_BOSS_ROOT. Start this section from nothing so the counts below are the fixtures.
rm -f "$PI_BOSS_ROOT/state/usage.jsonl"
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
cat >"$PI_BOSS_ROOT/state/decisions.jsonl" <<EOF
{"timestamp":"$now","command":"route","task":"t","decision":"remote","reason":"r","overridden":false,"slug":"a","jev":"remote"}
{"timestamp":"$now","command":"route","task":"t","decision":"remote","reason":"r","overridden":false,"slug":"b","jev":"remote"}
{"timestamp":"$now","command":"route","task":"t","decision":"local","reason":"r","overridden":true,"slug":"c","jev":"local"}
{"timestamp":"$now","command":"mode","task":"t","decision":"bare","reason":"r","overridden":true,"slug":"c","jev":"sandboxed"}
{"timestamp":"$now","command":"count","task":"t","decision":"1","reason":"r","overridden":false,"slug":"c","jev":"1"}
{"timestamp":"$now","command":"thinking","task":"t","decision":"low","reason":"r","overridden":false,"slug":"c","jev":"low"}
{"timestamp":"$now","command":"ask","task":"q","decision":"yes","reason":"r","overridden":false,"slug":"","jev":"yes"}
{"timestamp":"$now","command":"route","task":"t","decision":"remote","reason":"r","overridden":true,"slug":"old"}
{"timestamp":"2020-01-01T00:00:00.000Z","command":"route","task":"old","decision":"local","reason":"r","overridden":false,"slug":"x","jev":"local"}
this line is not json
EOF

# No usage file yet: the local worker side is honest about never having run.
expect "stats, no local-run yet" 0 "local work path: never used" -- \
	"$bin/delegate" stats

cat >"$PI_BOSS_ROOT/state/usage.jsonl" <<EOF
{"ts":"$now","kind":"jev","command":"route","model":"qwen3.8:27b","latency_ms":1000,"ok":true,"error":null,"context":"spawn:c","task":"t"}
{"ts":"$now","kind":"jev","command":"mode","model":"qwen3.8:27b","latency_ms":3000,"ok":true,"error":null,"context":"spawn:c","task":"t"}
{"ts":"$now","kind":"local-run","command":"run","model":"qwen3.8:27b","latency_ms":4000,"ok":true,"error":null,"context":null,"task":"summarise"}
{"ts":"$now","kind":"local-run","command":"run","model":"qwen3.8:27b","latency_ms":2000,"ok":true,"error":null,"context":null,"task":"tidy"}
{"ts":"$now","kind":"local-run","command":"run","model":"qwen3.8:27b","latency_ms":500,"ok":false,"error":"unreachable","context":null,"task":"x"}
{"ts":"2020-01-01T00:00:00.000Z","kind":"local-run","command":"run","model":"qwen3.8:27b","latency_ms":9999,"ok":true,"error":null,"context":null,"task":"old"}
EOF

expect "stats, local-run counted" 0 "local work path: 3 invocations" -- \
	"$bin/delegate" stats
expect "stats, legacy override named" 0 "1 legacy rows" -- \
	"$bin/delegate" stats
expect "stats, bad duration refused" 2 "--since takes a duration" -- \
	"$bin/delegate" stats --since 7

# The review queue is current state, not a window: two reported workers, one read, so one unread
# whose report was written two hours ago. The age printed must be the report's, not the run's.
mkdir -p "$PI_BOSS_ROOT/reports" "$PI_BOSS_ROOT/state/read"
printf 'reported\n' >"$PI_BOSS_ROOT/reports/queue-old.md"
printf 'reported\n' >"$PI_BOSS_ROOT/reports/queue-read.md"
: >"$PI_BOSS_ROOT/state/read/queue-read"
touch -d '2 hours ago' "$PI_BOSS_ROOT/reports/queue-old.md"
cat >"$PI_BOSS_ROOT/state/delegations.json" <<DELEGATIONS
{"queue-old":{"slug":"queue-old","space":"s1","cwd":"$work","report":"$PI_BOSS_ROOT/reports/queue-old.md"},
 "queue-read":{"slug":"queue-read","space":"s2","cwd":"$work","report":"$PI_BOSS_ROOT/reports/queue-read.md"},
 "queue-working":{"slug":"queue-working","space":"s3","cwd":"$work","report":"$PI_BOSS_ROOT/reports/queue-working.md"}}
DELEGATIONS
expect "stats, unread review queue" 0 "review queue: 1 unread report (oldest 2.0h, queue-old)" -- \
	"$bin/delegate" stats

# assert_stats '<json>' -- compare dotted paths in the stats JSON against the wanted values,
# read from stdin. Prints the mismatches and exits 1 when any disagree.
assert_stats() {
	node -e '
		const fs=require("fs");
		let s={};let raw="";
		try{s=JSON.parse(fs.readFileSync(0,"utf8"))}catch(e){console.log("not JSON: "+e.message);process.exit(1)}
		const want=JSON.parse(process.argv[1]);
		const bad=[];
		for(const [k,exp] of Object.entries(want)){
			const got=k.split(".").reduce((a,p)=>a?.[p],s);
			if(JSON.stringify(got)!==JSON.stringify(exp))bad.push(k+"="+JSON.stringify(got)+" wanted "+JSON.stringify(exp));
		}
		if(bad.length){console.log(bad.join(", "));process.exit(1)}
	' "$1"
}

stats_json=$("$bin/delegate" stats --json 2>&1) || true
if msg=$(printf '%s' "$stats_json" | assert_stats '{
	"decisions.total":8,
	"decisions.unreadable":1,
	"decisions.outside_window":1,
	"decisions.by_command.route":4,
	"decisions.by_command.mode":1,
	"decisions.route.remote":3,
	"decisions.route.local":1,
	"decisions.mode.bare":1,
	"decisions.thinking.low":1,
	"decisions.override.count":3,
	"decisions.override.legacy_rows":1,
	"decisions.override.legacy_route_remote":1,
	"local_model.jev_calls":2,
	"local_model.jev_median_latency_ms":2000,
	"local_run.invocations":3,
	"local_run.ok":2,
	"local_run.failed":1,
	"local_run.total_latency_ms":6000,
	"local_run.median_latency_ms":3000,
	"local_work_path.used":true,
	"local_work_path.invocations":3,
	"review_queue.unread_reports":1,
	"review_queue.oldest_slug":"queue-old"
}'); then
	pass "stats --json aggregation matches the fixtures"
else
	fail "stats --json aggregation: $msg"
fi
# The age of the queue is read off the report, and a worker with no report is still working, not
# unread — so the count above is one and the age is about two hours.
oldest=$(printf '%s' "$stats_json" | node -e '
	let d = "";
	process.stdin.on("data", (c) => (d += c)).on("end", () => {
		try { process.stdout.write(String(JSON.parse(d).review_queue.oldest_age_seconds)); } catch { process.stdout.write(""); }
	});')
if [ -n "$oldest" ] && [ "$oldest" -ge 7100 ] && [ "$oldest" -le 7400 ]; then
	pass "stats, oldest unread age is the report's age (${oldest}s)"
else
	fail "stats, oldest unread age: got '${oldest}', wanted about 7200"
fi

# 8. The wipe step between features: five questions on stdout, the run recorded in the log, a
#    skip recorded with its reason, and a skip with no reason refused. `delegate close` enforces
#    this, so a silent regression here lets every finished worker through unconsolidated.
wipe_root=$work/wiperoot
mkdir -p "$wipe_root/state" "$wipe_root/reports"
#    One JSON object, not one object per line: delegate parses the whole file as a single
#    document, so a fixtures file that parsed to {} would let a wipe of an unknown slug pass.
printf '{"wipe-one":{"space":"s1","cwd":"","branch":"wipe-one"},"wipe-none":{"space":"s2","cwd":"","branch":""}}\n' \
	>"$wipe_root/state/delegations.json"
expect "delegate wipe, five questions" 0 "Rewrite?" -- \
	env PI_BOSS_ROOT=$wipe_root "$bin/delegate" wipe wipe-one
if grep '"command":"wipe"' "$wipe_root/state/decisions.jsonl" 2>/dev/null | grep -q '"decision":"done"'; then
	pass "wipe run recorded in state/decisions.jsonl"
else
	fail "no wipe done line in state/decisions.jsonl"
fi
expect "delegate wipe, skip without a reason" 1 "--skip needs a reason" -- \
	env PI_BOSS_ROOT=$wipe_root "$bin/delegate" wipe wipe-none --skip "  "
expect "delegate wipe, skip recorded with its reason" 0 "skipped, reason recorded" -- \
	env PI_BOSS_ROOT=$wipe_root "$bin/delegate" wipe wipe-none --skip "docs only, no code to consolidate"
if grep '"command":"wipe"' "$wipe_root/state/decisions.jsonl" 2>/dev/null |
	grep -q '"decision":"skipped".*"reason":"docs only, no code to consolidate"'; then
	pass "wipe skip reason recorded in state/decisions.jsonl"
else
	fail "no wipe skipped line carrying the reason in state/decisions.jsonl"
fi
# A worker with no wipe line at all: the close refuses before it asks herdr-app for anything.
printf '{"nowiped":{"space":"s3","cwd":"","branch":""}}\n' >"$wipe_root/state/delegations.json"
expect "delegate close, no wipe step recorded" 1 "no wipe step recorded" -- \
	env PI_BOSS_ROOT=$wipe_root PATH=$safe_path "$bin/delegate" close nowiped
expect "delegate wipe, no slug" 1 "usage: delegate wipe" -- \
	env PI_BOSS_ROOT=$wipe_root "$bin/delegate" wipe

expect "futures panel: thrown away, cycles, evidence" 0 "futures stats: ok" -- \
	bash "$root/scripts/test-futures-stats.sh"
expect "acceptance mode, flag, generated spec and recorded mode" 0 "acceptance mode: ok" -- \
	bash "$root/scripts/test-acceptance.sh"

printf '\n%s\n' "$([ "$fails" = 0 ] && echo "offline behaviour: ok" || echo "offline behaviour: $fails failure(s)")"
[ "$fails" = 0 ]
