#!/usr/bin/env bash
# test-finish.sh — `delegate finish <slug>` runs publish, wipe and close as one command, in that
# order, and stops at the first step that fails.
#
# The point of the command is fewer turns, not fewer gates: three steps that used to be three
# commands have to keep their own refusals, and a failure has to name the step and the state the
# worker is left in. So every case here drives the real `delegate finish` against a temporary
# PI_BOSS_ROOT with a fake `publish` on PATH and a fake `herdr-app` that logs every call: what
# happened is read from the decisions log, the delegation entry and the herdr log, never from
# what the command said about itself.
#
#   bash scripts/tests/test-finish.sh      exit 0 = every case held
set -uo pipefail

root=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/../.." && pwd)
bin=$root/bin
delegate=$bin/delegate

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export PI_BOSS_ROOT=$work/root
unset PI_MASTER_ROOT
mkdir -p "$PI_BOSS_ROOT/reports" "$PI_BOSS_ROOT/state" "$PI_BOSS_ROOT/specs" "$work/stub"

# The fakes. `publish` is the one command finish calls out to: its exit code is the case, and its
# log is how "nothing was published" is proved. `herdr-app` records the space.close, which is the
# only way a worker's space goes away.
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s/publish-calls"\nexit "${FAKE_PUBLISH_RC:-0}"\n' "$work" \
	>"$work/stub/publish"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s/herdr-calls"\nexit 0\n' "$work" \
	>"$work/stub/herdr-app"
printf '#!/usr/bin/env bash\nexit 0\n' >"$work/stub/hc"
chmod +x "$work/stub/publish" "$work/stub/herdr-app" "$work/stub/hc"
export PATH=$work/stub:$PATH

fails=0
pass() { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }

OUT=""
RC=0
run() {
	local out
	out=$("$delegate" "$@" 2>&1) && RC=0 || RC=$?
	OUT=$out
}

# reset — one tracked worker, an empty log, and a report that satisfies every gate. Called before
# each case so a case can change exactly one thing.
reset() {
	: >"$work/publish-calls"
	: >"$work/herdr-calls"
	: >"$PI_BOSS_ROOT/state/decisions.jsonl"
	printf '{"w1":{"space":"space-w1","cwd":"","branch":""}}\n' \
		>"$PI_BOSS_ROOT/state/delegations.json"
	cat >"$PI_BOSS_ROOT/reports/w1.md" <<'REPORT'
# Worker w1

Mission: one command does the tail of a worker.

## What now works

`delegate finish` publishes, wipes and closes in one turn.

## Evidence

Command: `bash scripts/tests/test-finish.sh`

Output (last 20 lines):

```
finish: ok
```

## Thrown away

nothing — the change is three lines and no code became unnecessary.
REPORT
}

wipe_lines() {
	[ -f "$PI_BOSS_ROOT/state/decisions.jsonl" ] || { printf '0'; return; }
	node -e '
		const fs = require("fs");
		const rows = fs.readFileSync(process.argv[1], "utf8").split("\n").filter(Boolean)
			.map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
		process.stdout.write(String(rows.filter((r) => r.command === "wipe" && r.slug === "w1").length));' \
		"$PI_BOSS_ROOT/state/decisions.jsonl"
}

open_workers() {
	node -e '
		const fs = require("fs");
		let j = {}; try { j = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch {}
		process.stdout.write(j.w1 ? "1" : "0");' "$PI_BOSS_ROOT/state/delegations.json"
}

closed_space() { grep -qF "space.close --id space-w1" "$work/herdr-calls"; }

# 1. Publish fails: nothing else runs. The report has no PR, so the wipe would record a step over
#    work nobody can see and the close would throw the space away — the one state that must not be
#    reachable. Says which step, and that the space is still open.
reset
FAKE_PUBLISH_RC=1 run finish w1
if [ "$RC" = 0 ]; then
	fail "finish with a failing publish exited 0, wanted nonzero — $OUT"
elif ! printf '%s' "$OUT" | grep -qE 'step 1 of 3 \(publish\)'; then
	fail "finish did not name the publish step as the failing one — $OUT"
elif ! printf '%s' "$OUT" | grep -qi 'space is still open'; then
	fail "finish did not say the space is still open — $OUT"
elif [ "$(wipe_lines)" != 0 ]; then
	fail "finish wiped a worker whose report never published ($(wipe_lines) wipe line(s))"
elif closed_space; then
	fail "finish closed the space after a failed publish: $(tr '\n' ';' <"$work/herdr-calls")"
elif [ "$(open_workers)" != 1 ]; then
	fail "finish dropped the delegation entry after a failed publish"
else
	pass "a failed publish stops the run: no wipe, no close, space open"
fi

# 2. Publish succeeds: the wipe is recorded and the space closes, and the publish ran first — the
#    order is the whole reason this is one command.
reset
run finish w1
if [ "$RC" != 0 ]; then
	fail "finish on a finished worker: exit $RC, wanted 0 — $OUT"
elif ! grep -qF "w1" "$work/publish-calls"; then
	fail "finish never called publish: $(tr '\n' ';' <"$work/publish-calls")"
elif [ "$(wipe_lines)" != 1 ]; then
	fail "finish recorded $(wipe_lines) wipe line(s), wanted exactly 1"
elif ! closed_space; then
	fail "finish did not close the space: $(tr '\n' ';' <"$work/herdr-calls")"
elif [ "$(open_workers)" != 0 ]; then
	fail "finish left the delegation entry behind"
else
	pass "a successful publish wipes, records and closes in one command"
fi

# 3. The wipe keeps its own gate: a report that exists but answers nothing is refused, after the
#    publish, and the space stays open. The answers are the point of the step.
reset
awk '/^## Thrown away$/ { exit } { print }' "$PI_BOSS_ROOT/reports/w1.md" >"$work/r" \
	&& mv "$work/r" "$PI_BOSS_ROOT/reports/w1.md"
run finish w1
if [ "$RC" = 0 ]; then
	fail "finish wiped a report with no '## Thrown away' block, wanted a refusal — $OUT"
elif ! printf '%s' "$OUT" | grep -qE 'step 2 of 3 \(wipe\)'; then
	fail "finish did not name the wipe step as the failing one — $OUT"
elif [ "$(wipe_lines)" != 0 ]; then
	fail "a refused wipe still recorded a line in state/decisions.jsonl"
elif closed_space; then
	fail "finish closed the space after a refused wipe"
elif [ "$(open_workers)" != 1 ]; then
	fail "finish dropped the delegation entry after a refused wipe"
else
	pass "a report with no '## Thrown away' block refuses the wipe and keeps the space open"
fi

# 4. A skip with no reason is refused before anything is published: the reason is the only thing
#    that tells a skipped wipe from a forgotten one.
reset
run finish w1 --skip ""
if [ "$RC" = 0 ]; then
	fail "finish --skip with an empty reason exited 0, wanted nonzero — $OUT"
elif ! printf '%s' "$OUT" | grep -qF -- "--skip needs a reason"; then
	fail "finish --skip with an empty reason did not say what was missing — $OUT"
elif [ -s "$work/publish-calls" ]; then
	fail "finish published before refusing an empty --skip: $(tr '\n' ';' <"$work/publish-calls")"
elif [ "$(wipe_lines)" != 0 ] || closed_space; then
	fail "finish wiped or closed after refusing an empty --skip"
else
	pass "--skip without a reason is refused before anything runs"
fi

# 5. The close keeps its own gate too, and it is last: publish and wipe happen, close refuses, the
#    space stays open and the message says which step. Closed-but-unpublished stays unreachable.
reset
awk '/^## Evidence$/ { skip = 1 } skip && /^## Thrown away$/ { skip = 0 } !skip' \
	"$PI_BOSS_ROOT/reports/w1.md" >"$work/r" && mv "$work/r" "$PI_BOSS_ROOT/reports/w1.md"
run finish w1
if [ "$RC" = 0 ]; then
	fail "finish closed a report with no Evidence block, wanted a refusal — $OUT"
elif ! printf '%s' "$OUT" | grep -qE 'step 3 of 3 \(close\)'; then
	fail "finish did not name the close step as the failing one — $OUT"
elif [ "$(wipe_lines)" != 1 ]; then
	fail "a refused close did not keep the wipe it already recorded ($(wipe_lines) line(s))"
elif closed_space; then
	fail "finish closed the space after a refused close"
elif [ "$(open_workers)" != 1 ]; then
	fail "finish dropped the delegation entry after a refused close"
else
	pass "a refused close is the last step: published and wiped, space still open"
fi

# 6. `delegate wait` hands the boss one command, not three: the four-turn tail is what the command
#    exists to remove, and the hint is where the boss reads it.
reset
run wait w1 --timeout 5
if [ "$RC" != 0 ]; then
	fail "delegate wait on a reported worker: exit $RC, wanted 0 — $OUT"
elif ! printf '%s' "$OUT" | grep -qF "delegate finish w1"; then
	fail "delegate wait does not point at delegate finish — $OUT"
elif printf '%s' "$OUT" | grep -qE 'delegate (wipe|close) w1'; then
	fail "delegate wait still prints the three-command tail — $OUT"
else
	pass "delegate wait's done-hint is the one finish command"
fi

if [ "$fails" != 0 ]; then
	printf '\nfinish: %d case(s) failed\n' "$fails" >&2
	exit 1
fi
printf '\nfinish: ok\n'
