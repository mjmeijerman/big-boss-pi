#!/usr/bin/env bash
# test-spawn-shape.sh — `delegate spawn` refuses a second measurement and writes the report skeleton.
#
# Two facts the harness claims and would otherwise never check:
#
#   A. A spec measures one thing. Two `Measure:` lines refuse the spawn with each line quoted, and so
#      does a task with no `Measure:` line that asks for before/after numbers in prose. Proof
#      proportional to the diff is the reason (AGENTS.md rule 10): a worker spent twenty minutes
#      after its commit landed on a matrix its own spec asked for, and no decision changed.
#   B. The escape is recorded, not silent: `--allow-matrix --reason '<why>'` spawns and lands a
#      `matrix` line in state/decisions.jsonl with `overridden: true`; without the reason it refuses.
#   C. The skeleton lands with all five lines — `Mission:`, `Review tier:`, `Test change:`,
#      `## Evidence` (asking for `bin/preflight` by name) and `Commit:` — and an unfilled one cannot
#      publish: `delegate close` refuses it as a placeholder, and `delegate wait` does not call it a
#      report. A worker is finished when its report is written, not when the file exists.
#
# Stub jev, stub herdr-app, stub hc, stub runner: no model, no desktop app, no real space.
#
#   bash scripts/tests/test-spawn-shape.sh      exit 0 = every case held
set -uo pipefail

root=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/../.." && pwd)
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
# One canned answer for every subcommand: the shape cases are about the task text, not the plan.
printf '{"count":1,"mode":"sandboxed","route":"remote","thinking":"low","reason":"stub answer","confidence":0.9}\n'
exit 0
STUB
cat >"$work/stub/herdr-app" <<'STUB'
#!/usr/bin/env bash
case ${1:-} in
status) printf '{"space":"s0","tab":"t0"}\n' ;;
do)
	case ${2:-} in
	space.new) printf '{"space":"s1","tab":"t1","pane":"p1","terminal":"term1"}\n' ;;
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

area=$work/area
mkdir -p "$area"
delegations=$PI_BOSS_ROOT/state/delegations.json
decisions=$PI_BOSS_ROOT/state/decisions.jsonl

spawn_out=""
SPAWN_RC=0
spawn() {
	spawn_out=$(env PATH="$work/stub:$PATH" timeout 60 "$bin/delegate" spawn "$@" 2>&1) && SPAWN_RC=0 || SPAWN_RC=$?
	return 0
}
reset() {
	rm -f "$delegations" "$decisions"
	rm -f "$PI_BOSS_ROOT"/specs/*.md "$PI_BOSS_ROOT"/reports/*.md 2>/dev/null
	return 0
}
slugs() {
	node -e '
		const fs=require("fs");let j={};try{j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"))}catch{}
		process.stdout.write(Object.keys(j).sort().join(","))' "$delegations"
}
# matrix_row — the last `matrix` line in the decisions log: "decision|overridden".
matrix_row() {
	node -e '
		const fs=require("fs");
		let rows=[];
		try{rows=fs.readFileSync(process.argv[1],"utf8").trim().split("\n").map(l=>JSON.parse(l))}catch{}
		const r=rows.filter(x=>x.command==="matrix").pop()||{};
		process.stdout.write([String(r.decision||""),r.overridden].join("|"))' "$decisions"
}

# --- A. two measurements declared: refused, both lines quoted, nothing spawned ------------------

reset
spawn two-measure --cwd "$area" "Fix the gate.
Measure: bash bin/preflight, before and after
Measure: bash scripts/tests/test-x.sh, twice"
if [ "$SPAWN_RC" = 0 ]; then
	fail "a task declaring two measurements spawned anyway — $spawn_out"
elif ! printf '%s' "$spawn_out" | grep -qF "declares 2 measurements"; then
	fail "the refusal does not count the measurements — $spawn_out"
elif ! printf '%s' "$spawn_out" | grep -qF "Measure: bash bin/preflight, before and after" ||
	! printf '%s' "$spawn_out" | grep -qF "Measure: bash scripts/tests/test-x.sh, twice"; then
	fail "the refusal does not quote the offending lines — $spawn_out"
elif ! printf '%s' "$spawn_out" | grep -qF -- "--allow-matrix --reason"; then
	fail "the refusal does not name the escape — $spawn_out"
elif [ -f "$PI_BOSS_ROOT/specs/two-measure.md" ] || [ -f "$PI_BOSS_ROOT/reports/two-measure.md" ] ||
	[ -f "$delegations" ]; then
	fail "a refused spawn left a spec, a report or a delegation entry behind"
elif [ "$(matrix_row)" != "refused|false" ]; then
	fail "the refusal is not recorded in state/decisions.jsonl — row '$(matrix_row)'"
else
	pass "two Measure: lines refuse the spawn, quoted, and start nothing"
fi

# --- B. one measurement: spawns, and the skeleton carries all five lines ------------------------

reset
spawn one-measure --cwd "$area" "Fix the gate.
Measure: bash bin/preflight, before and after"
skel=$PI_BOSS_ROOT/reports/one-measure.md
missing=""
if [ "$SPAWN_RC" = 0 ] && [ "$(slugs)" = "one-measure" ]; then
	for line in 'Mission:' 'Review tier:' 'Test change:' '## Evidence' 'Commit:'; do
		grep -qF -- "$line" "$skel" 2>/dev/null || missing="$missing [$line]"
	done
	grep -qF 'bin/preflight' "$skel" 2>/dev/null || missing="$missing [bin/preflight by name]"
	if [ -z "$missing" ]; then
		pass "one Measure: line spawns, and the report skeleton has all five lines"
	else
		fail "the report skeleton is missing:$(printf '%s' "$missing")"
	fi
else
	fail "a task with one Measure: line was refused: exit $SPAWN_RC, slugs '$(slugs)' — $spawn_out"
fi

# --- C. the skeleton cannot publish, and is not a report yet ------------------------------------
#
# Two questions of one file: `close` refuses it as a placeholder, and `wait` does not print it as
# finished. Without the second, every running worker would look finished the moment it started.

out=$("$bin/delegate" close one-measure 2>&1) && rc=0 || rc=$?
if [ "$rc" = 1 ] && printf '%s' "$out" | grep -qF "still has fill-in placeholders"; then
	pass "delegate close refuses the unfilled skeleton as a placeholder"
else
	fail "closing an unfilled skeleton: exit $rc — $out"
fi
out=$(timeout 30 "$bin/delegate" wait one-measure --timeout 4 2>&1) && rc=0 || rc=$?
if [ "$rc" = 1 ] && printf '%s' "$out" | grep -qF "has not reported after 4s"; then
	pass "delegate wait does not call a skeleton a finished report"
else
	fail "waiting on a skeleton: exit $rc — $out"
fi

# --- D. no Measure: line, prose asking for before/after numbers: refused ------------------------

reset
spawn prose-pair --cwd "$area" "Prove the gate runs faster.
Measure nothing formally: paste the before/after numbers for both configurations."
if [ "$SPAWN_RC" = 0 ]; then
	fail "prose asking for a before/after pair spawned anyway — $spawn_out"
elif ! printf '%s' "$spawn_out" | grep -qF "declares no Measure: line"; then
	fail "the refusal does not say the Measure: line is missing — $spawn_out"
elif ! printf '%s' "$spawn_out" | grep -qF "before/after numbers for both configurations"; then
	fail "the refusal does not quote the prose line — $spawn_out"
elif [ -f "$PI_BOSS_ROOT/specs/prose-pair.md" ] || [ -f "$delegations" ]; then
	fail "a refused spawn left a spec or a delegation entry behind"
else
	pass "prose asking for before/after numbers, with no Measure: line, refuses the spawn"
fi

# --- E. the escape needs its reason, and records one when it has it -----------------------------

reset
spawn escape-noreason --cwd "$area" --allow-matrix "Measure nothing: paste the before/after numbers."
if [ "$SPAWN_RC" != 0 ] && printf '%s' "$spawn_out" | grep -qF -- "--allow-matrix needs a non-empty --reason"; then
	pass "--allow-matrix without --reason refuses, naming the reason it needs"
else
	fail "--allow-matrix with no reason: exit $SPAWN_RC — $spawn_out"
fi

reset
spawn escape --cwd "$area" --allow-matrix --reason "two runtimes cannot be compared in one pair" \
	"Measure nothing: paste the before/after numbers."
if [ "$SPAWN_RC" = 0 ] && [ "$(slugs)" = "escape" ] && [ "$(matrix_row)" = "override|true" ]; then
	pass "--allow-matrix --reason spawns and records overridden: true in state/decisions.jsonl"
else
	fail "the recorded escape: exit $SPAWN_RC, slugs '$(slugs)', row '$(matrix_row)' — $spawn_out"
fi

printf '\n%s\n' "$([ "$fails" = 0 ] && echo "spawn shape: ok" || echo "spawn shape: $fails case(s) failed")"
exit "$([ "$fails" = 0 ] && echo 0 || echo 1)"
