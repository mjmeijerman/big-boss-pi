#!/usr/bin/env bash
# test-count-flag.sh — `delegate spawn --count N` asks for a number of workers and says so.
#
# Four facts the harness claims in prose and would otherwise never check:
#
#   A. --count is a caller's decision like --mode and --thinking: it is taken when it agrees with
#      jev, refused when it contradicts jev and no override came with it, and taken when
#      --override-jev --reason did come with it.
#   B. The count decision line tells the truth: `overridden: true` with jev's own number in `jev`
#      only when the caller overruled jev, and `overridden: false` on the agreeing and default
#      paths.
#   C. The range is 1..8, the live-space ceiling, and anything else refuses with a usage line that
#      names that ceiling and where it comes from.
#   D. --count belongs to spawn alone: wait, close, wipe and sweep refuse it as an unknown option.
#
# Stub jev, stub herdr-app, stub hc, stub runner: no model, no desktop app, no real space.
#
#   bash scripts/test-count-flag.sh      exit 0 = every case held
set -uo pipefail

root=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd)
bin=$root/bin

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export PI_BOSS_ROOT=$work/root
unset PI_MASTER_ROOT
mkdir -p "$PI_BOSS_ROOT/bin" "$PI_BOSS_ROOT/specs" "$PI_BOSS_ROOT/reports" "$PI_BOSS_ROOT/state" \
	"$work/stub" "$work/home"
export HOME=$work/home

fails=0
pass() { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }

cat >"$PI_BOSS_ROOT/bin/jev" <<'STUB'
#!/usr/bin/env bash
# One canned answer for every subcommand. The count is the fixture: it is what jev "answers".
case ${JEV_STUB_COUNT:-1} in
''|*[!0-9]*) n=1 ;;
*) n=${JEV_STUB_COUNT} ;;
esac
printf '{"count":%s,"mode":"sandboxed","route":"remote","thinking":"low","reason":"stub answer","confidence":0.9}\n' "$n"
exit 0
STUB
cat >"$work/stub/herdr-app" <<'STUB'
#!/usr/bin/env bash
# A distinct space per space.new, so three workers cannot silently share one space.
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
delegations=$PI_BOSS_ROOT/state/delegations.json
decisions=$PI_BOSS_ROOT/state/decisions.jsonl

spawn_out=""
spawn() {
	spawn_out=$(env JEV_STUB_COUNT=${JEV_STUB_COUNT:-1} PATH="$work/stub:$PATH" \
		timeout 60 "$bin/delegate" spawn "$@" 2>&1) && SPAWN_RC=0 || SPAWN_RC=$?
	return 0
}
reset() {
	rm -f "$delegations" "$decisions"
	rm -f "$PI_BOSS_ROOT"/specs/*.md "$PI_BOSS_ROOT"/reports/*.md 2>/dev/null
	printf '0\n' >"$HERDR_COUNTER"
}
slugs() {
	node -e '
		const fs=require("fs");let j={};try{j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"))}catch{}
		process.stdout.write(Object.keys(j).sort().join(","))' "$delegations"
}
# count_row — the last count line: "overridden|jev|decision".
count_row() {
	node -e '
		const fs=require("fs");
		let rows=[];
		try{rows=fs.readFileSync(process.argv[1],"utf8").trim().split("\n").map(l=>JSON.parse(l))}catch{}
		const r=rows.filter(x=>x.command==="count").pop()||{};
		process.stdout.write([r.overridden,String(r.jev||""),String(r.decision||"")].join("|"))' "$decisions"
}

# A1. --count 1, jev answering 1: no refusal, one space, and the line is not marked overridden.
reset
JEV_STUB_COUNT=1 spawn agree-task --cwd "$area" --count 1 "one small change"
if [ "$SPAWN_RC" = 0 ] && [ "$(slugs)" = "agree-task" ] &&
	[ "$(count_row)" = "false|1|1" ]; then
	pass "--count 1 with jev answering 1 spawns one space, count line not overridden"
else
	fail "agreeing --count 1: exit $SPAWN_RC, slugs '$(slugs)', row '$(count_row)' — $spawn_out"
fi

# A2/B2. --count 1 against jev's 2 and no override: refused, jev's number in the message, nothing
#        spawned — no spec, no report, no delegation entry.
reset
JEV_STUB_COUNT=2 spawn refuse-task --cwd "$area" --count 1 "two areas to change"
if [ "$SPAWN_RC" != 0 ] &&
	printf '%s' "$spawn_out" | grep -qF "jev wants 2 workers" &&
	printf '%s' "$spawn_out" | grep -qF -- "--count 1 --override-jev --reason" &&
	[ ! -f "$PI_BOSS_ROOT/specs/refuse-task.md" ] && [ ! -f "$delegations" ]; then
	pass "--count 1 against jev's 2 refuses with jev's number, and starts nothing"
else
	fail "refused --count 1: exit $SPAWN_RC, spec=$([ -f "$PI_BOSS_ROOT/specs/refuse-task.md" ] && echo yes || echo no), row '$(count_row)' — $spawn_out"
fi

# A3/B3. The same with --override-jev --reason: exactly one worker, and the count line says it was
#        overruled, with jev's own 2 beside it.
reset
JEV_STUB_COUNT=2 spawn over-task --cwd "$area" --count 1 --override-jev --reason "one worker is enough" "two areas to change"
row=$(count_row)
if [ "$SPAWN_RC" = 0 ] && [ "$(slugs)" = "over-task" ] && [ "$row" = "true|2|1" ]; then
	pass "--count 1 with --override-jev spawns one space and records overridden: true with jev's 2"
else
	fail "overridden --count 1: exit $SPAWN_RC, slugs '$(slugs)', row '$row' — $spawn_out"
fi
if grep -q "never started" "$PI_BOSS_ROOT/specs/over-task.md" 2>/dev/null; then
	pass "worker 1's spec says the other workers were not started"
else
	fail "worker 1's spec does not say the other workers were not started"
fi

# A4. The range is 1..8 and the refusal names the ceiling and where it comes from.
for bad in 9 0 two; do
	reset
	JEV_STUB_COUNT=1 spawn bad-$bad --cwd "$area" --count "$bad" "one small change"
	if [ "$SPAWN_RC" != 0 ] &&
		printf '%s' "$spawn_out" | grep -qF "from 1 to 8" &&
		printf '%s' "$spawn_out" | grep -qF "live-space ceiling" &&
		[ ! -f "$PI_BOSS_ROOT/specs/bad-$bad.md" ]; then
		pass "--count $bad refuses with the 1..8 ceiling, and starts nothing"
	else
		fail "--count $bad: exit $SPAWN_RC — $spawn_out"
	fi
done

# A5. --count 3 agreeing with jev starts three, named slug, slug-2, slug-3, each with its own spec
#     and its own report path.
reset
JEV_STUB_COUNT=3 spawn group-task --cwd "$area" --count 3 "three commands to add"
missing=""
for s in group-task group-task-2 group-task-3; do
	[ -f "$PI_BOSS_ROOT/specs/$s.md" ] || missing="$missing spec:$s"
	grep -qF "Report file: \`$PI_BOSS_ROOT/reports/$s.md\`" "$PI_BOSS_ROOT/specs/$s.md" 2>/dev/null ||
		missing="$missing report:$s"
done
if [ "$SPAWN_RC" = 0 ] && [ "$(slugs)" = "group-task,group-task-2,group-task-3" ] && [ -z "$missing" ]; then
	pass "--count 3 starts three spaces, each with its own spec and report path"
else
	fail "--count 3: exit $SPAWN_RC, slugs '$(slugs)', missing:$missing — $spawn_out"
fi

# A6/B6. No --count at all: jev's answer is honoured and the line is not marked overridden. The
#        flag did not change the default path.
reset
JEV_STUB_COUNT=2 spawn default-task --cwd "$area" "two areas to change"
if [ "$SPAWN_RC" = 0 ] && [ "$(slugs)" = "default-task,default-task-2" ] &&
	[ "$(count_row)" = "false|2|2" ]; then
	pass "no --count keeps jev's 2 and records overridden: false"
else
	fail "default path: exit $SPAWN_RC, slugs '$(slugs)', row '$(count_row)' — $spawn_out"
fi

# D7. --count belongs to spawn: the other subcommands refuse it as an unknown option.
reset
mkdir -p "$PI_BOSS_ROOT/state"
printf '{}\n' >"$delegations"
ok=""
for sub in "wait some-slug" "close some-slug" "wipe some-slug" "sweep"; do
	# shellcheck disable=SC2086
	out=$(env PATH="$work/stub:$PATH" timeout 60 "$bin/delegate" $sub --count 1 2>&1) && rc=0 || rc=$?
	if [ "$rc" = 0 ] || ! printf '%s' "$out" | grep -qF "unknown option --count"; then
		ok="$ok [$sub: exit $rc — $out]"
	fi
done
if [ -z "$ok" ]; then
	pass "wait, close, wipe and sweep refuse --count as an unknown option"
else
	fail "some subcommand swallowed --count:$ok"
fi

printf '\n%s\n' "$([ "$fails" = 0 ] && echo "all count-flag cases held" || echo "$fails case(s) failed")"
exit "$([ "$fails" = 0 ] && echo 0 || echo 1)"
