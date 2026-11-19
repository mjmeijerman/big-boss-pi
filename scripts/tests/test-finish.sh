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
# only way a worker's space goes away; `herdr-app ls` is the window's own list, the one place a
# space's name and its id sit together, so FAKE_HERDR_LS is that answer.
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s/publish-calls"\nexit "${FAKE_PUBLISH_RC:-0}"\n' "$work" \
	>"$work/stub/publish"
# The gate step runs before publish. finish finds `preflight` on PATH first, so this stub is the
# gate: its exit code is the case, and its log is how "finish ran the gate before it published" is
# read instead of believed.
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s/preflight-calls"\nexit "${FAKE_PREFLIGHT_RC:-0}"\n' "$work" \
	>"$work/stub/preflight"
printf '#!/usr/bin/env bash\nif [ "${1:-}" = ls ]; then [ -n "${FAKE_HERDR_LS:-}" ] && printf "%%s\\n" "$FAKE_HERDR_LS"; exit 0; fi\nprintf "%%s\\n" "$*" >>"%s/herdr-calls"\nexit 0\n' "$work" \
	>"$work/stub/herdr-app"
# `hc ls --all --json` is herdr's own answer about what still runs; FAKE_HC_LS is that answer, so a
# case can show a terminal that is gone and one that is still there. No answer (empty) means hc
# could not be read, and the record stands. FAKE_HC_RC is a herdr that refuses outright.
printf '#!/usr/bin/env bash\ncase " $* " in *" ls "*) [ -n "${FAKE_HC_LS:-}" ] && printf "%%s\\n" "$FAKE_HC_LS" ;; esac\nexit "${FAKE_HC_RC:-0}"\n' \
	>"$work/stub/hc"
chmod +x "$work/stub/publish" "$work/stub/preflight" "$work/stub/herdr-app" "$work/stub/hc"
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
	: >"$work/preflight-calls"
	: >"$work/herdr-calls"
	unset FAKE_PREFLIGHT_RC
	: >"$PI_BOSS_ROOT/state/decisions.jsonl"
	unset FAKE_HC_LS FAKE_HERDR_LS FAKE_HC_RC
	printf '{"w1":{"space":"space-w1","cwd":"","branch":""}}\n' \
		>"$PI_BOSS_ROOT/state/delegations.json"
	cat >"$PI_BOSS_ROOT/reports/w1.md" <<'REPORT'
# Worker w1

Mission: one command does the tail of a worker.

## What now works

`delegate finish` publishes, wipes and closes in one turn.

## Evidence

$ bin/preflight — 5/5 passed
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

# The gate's own line in state/decisions.jsonl: how many there are, and the reason it carries.
decision_rows() { # <command>
	[ -f "$PI_BOSS_ROOT/state/decisions.jsonl" ] || { printf '0'; return; }
	node -e '
		const fs = require("fs");
		const rows = fs.readFileSync(process.argv[1], "utf8").split("\n").filter(Boolean)
			.map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
		process.stdout.write(String(rows.filter((r) => r.command === process.argv[2] && r.slug === "w1").length));' \
		"$PI_BOSS_ROOT/state/decisions.jsonl" "$1"
}
decision_reason() { # <command>
	node -e '
		const fs = require("fs");
		const rows = fs.readFileSync(process.argv[1], "utf8").split("\n").filter(Boolean)
			.map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
		const r = rows.filter((x) => x.command === process.argv[2] && x.slug === "w1").pop();
		process.stdout.write(r ? String(r.reason || "") : "");' \
		"$PI_BOSS_ROOT/state/decisions.jsonl" "$1"
}

# 0a. The gate runs first and its refusal is the whole run: a branch that does not pass the checks
#     CI would run is not published, so the wipe never records a step over work nobody can see and
#     the space stays open for a follow-up worker. The report is untouched — that is the point.
reset
FAKE_PREFLIGHT_RC=1 run finish w1
if [ "$RC" = 0 ]; then
	fail "finish with a failing preflight exited 0, wanted nonzero — $OUT"
elif ! printf '%s' "$OUT" | grep -qE 'step 1 of 4 \(preflight\)'; then
	fail "finish did not name the preflight step as the failing one — $OUT"
elif [ -s "$work/publish-calls" ]; then
	fail "finish published past a failing preflight: $(tr '\n' ';' <"$work/publish-calls")"
elif [ "$(decision_rows wipe)" != 0 ] || closed_space; then
	fail "finish wiped or closed after a failing preflight"
elif [ "$(open_workers)" != 1 ]; then
	fail "finish dropped the delegation entry after a failing preflight"
elif ! printf '%s' "$OUT" | grep -qF -- '--skip-preflight'; then
	fail "the refusal does not name the way to record a broken check — $OUT"
else
	pass "a failing preflight stops the run before publish: no push, no wipe, no close"
fi

# 0b. The escape hatch: a check genuinely broken on this machine is recorded, with its reason, the
#     way a wipe skip is — and it stands in for the run the report could not paste.
reset
awk '!/bin\/preflight/' "$PI_BOSS_ROOT/reports/w1.md" >"$work/r" && mv "$work/r" "$PI_BOSS_ROOT/reports/w1.md"
run finish w1 --skip-preflight "semgrep is broken on this machine"
if [ "$RC" != 0 ]; then
	fail "finish --skip-preflight did not finish: exit $RC — $OUT"
elif ! grep -qF "w1" "$work/publish-calls"; then
	fail "finish --skip-preflight did not publish: $(tr '\n' ';' <"$work/publish-calls")"
elif [ -s "$work/preflight-calls" ]; then
	fail "finish --skip-preflight ran the gate anyway: $(tr '\n' ';' <"$work/preflight-calls")"
elif [ "$(decision_rows preflight)" != 1 ]; then
	fail "finish --skip-preflight recorded $(decision_rows preflight) preflight line(s), wanted exactly 1"
elif [ "$(decision_reason preflight)" != "semgrep is broken on this machine" ]; then
	fail "the recorded reason reads '$(decision_reason preflight)', wanted the one that was given"
else
	pass "--skip-preflight publishes and records its reason in state/decisions.jsonl"
fi

# 0c. A skip with no reason is refused before the gate, the publish or anything else: the reason is
#     the only thing that tells a broken check from a forgotten one.
reset
run finish w1 --skip-preflight ""
if [ "$RC" = 0 ]; then
	fail "finish --skip-preflight with an empty reason exited 0, wanted nonzero — $OUT"
elif ! printf '%s' "$OUT" | grep -qF -- "--skip-preflight needs a reason"; then
	fail "finish --skip-preflight with an empty reason did not say what was missing — $OUT"
elif [ -s "$work/publish-calls" ] || [ -s "$work/preflight-calls" ]; then
	fail "finish ran a step before refusing an empty --skip-preflight"
elif [ "$(decision_rows preflight)" != 0 ]; then
	fail "an empty --skip-preflight still recorded a line"
else
	pass "--skip-preflight without a reason is refused before anything runs"
fi

# 1. Publish fails: nothing else runs. The report has no PR, so the wipe would record a step over
#    work nobody can see and the close would throw the space away — the one state that must not be
#    reachable. Says which step, and that the space is still open.
reset
FAKE_PUBLISH_RC=1 run finish w1
if [ "$RC" = 0 ]; then
	fail "finish with a failing publish exited 0, wanted nonzero — $OUT"
elif ! printf '%s' "$OUT" | grep -qE 'step 2 of 4 \(publish\)'; then
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
elif ! printf '%s' "$OUT" | grep -qE 'step 3 of 4 \(wipe\)'; then
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
elif ! printf '%s' "$OUT" | grep -qE 'step 4 of 4 \(close\)'; then
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

# 7. A worker whose space was closed is not a working worker. The record says what spawn wrote;
#    `hc ls --all --json` says what herdr still runs, and the list has to say which state it found:
#    `gone` once the terminal is gone and no report was written, `working` only while herdr still
#    lists it. Without this the list printed `working` for minutes after space.close answered ok.
tracked() { # <terminal> — one tracked worker carrying that terminal, with no report yet
	printf '{"w1":{"space":"space-w1","terminal":"%s","cwd":"","branch":""}}\n' "$1" \
		>"$PI_BOSS_ROOT/state/delegations.json"
	rm -f "$PI_BOSS_ROOT/reports/w1.md"
}

reset
tracked t1
export FAKE_HC_LS='{"hidden_finished":0,"terminals":[{"id":"t9","name":"somebody-else"}]}'
run list
if [ "$RC" != 0 ]; then
	fail "delegate list exited $RC — $OUT"
elif ! printf '%s' "$OUT" | grep -qE '^w1 .* gone '; then
	fail "delegate list still reads a worker with no terminal as working — $OUT"
else
	pass "a worker whose herdr terminal is gone is listed as gone, not working"
fi

# herdr answering `[]` while the record names terminals is a herdr this side cannot see (another
# core, a socket from a sandbox), not every worker dying: the record stands, so a sandboxed boss
# does not call live workers dead.
reset
tracked t1
export FAKE_HC_LS='{"hidden_finished":0,"terminals":[]}'
run list
if printf '%s' "$OUT" | grep -qE '^w1 .* gone '; then
	fail "an empty herdr answer read every worker as gone — $OUT"
else
	pass "an empty herdr answer leaves the record standing rather than calling it gone"
fi

reset
tracked t1
export FAKE_HC_LS='{"hidden_finished":0,"terminals":[{"id":"t1","name":"delegate-truth-2"}]}'
run list
if printf '%s' "$OUT" | grep -qE '^w1 .* working '; then
	pass "a worker herdr still lists, with no report, is working"
else
	fail "delegate list did not read a live terminal as working — $OUT"
fi

# 8. And `delegate wait` says it at once instead of sitting out its timeout, because a worker with
#    no terminal will never write the report the wait is waiting for.
reset
tracked t1
export FAKE_HC_LS='{"hidden_finished":0,"terminals":[{"id":"t9","name":"somebody-else"}]}'
out=$(timeout 20 "$delegate" wait w1 --timeout 300 2>&1) && RC=0 || RC=$?
OUT=$out
if [ "$RC" = 0 ]; then
	fail "delegate wait on a gone worker exited 0 — $OUT"
elif ! printf '%s' "$OUT" | grep -qF 'is gone'; then
	fail "delegate wait on a gone worker did not say it is gone — $OUT"
else
	pass "delegate wait on a worker whose terminal is gone fails now, not after the timeout"
fi

# 9. The `learn-*` spaces self-learn opens per compaction pile up and nobody closes them. A
#    finished one is closed where herdr is already being talked to — at the top of a finish — with
#    the id the window names, and a space that is not a finished `learn-*` is left alone.
reset
export FAKE_HC_LS='{"hidden_finished":0,"terminals":[
{"address":"t1","status":"done","where":"learn-00-13 / learn-00-13"},
{"address":"t2","status":"idle","where":"learn-00-13 / learn-00-13"},
{"address":"t3","status":"done","where":"learner-gaps-rebase / learner-gaps-rebase"}]}'
export FAKE_HERDR_LS='{"spaces":[
{"id":"sp-learn","name":"learn-00-13","folder":"/tmp/pi"},
{"id":"sp-other","name":"learner-gaps-rebase","folder":"/tmp/pi"}]}'
run finish w1
if [ "$RC" != 0 ]; then
	fail "finish with a finished learn space exited $RC — $OUT"
elif ! grep -qF "space.close --id sp-learn --confirmed true" "$work/herdr-calls"; then
	fail "the finished learn space was not closed: $(tr '\n' ';' <"$work/herdr-calls")"
elif grep -qF "space.close --id sp-other" "$work/herdr-calls"; then
	fail "a space that is not a finished learn-* was closed: $(tr '\n' ';' <"$work/herdr-calls")"
elif ! grep -qF "space.close --id space-w1" "$work/herdr-calls"; then
	fail "the reap replaced the worker's own close: $(tr '\n' ';' <"$work/herdr-calls")"
elif ! printf '%s' "$OUT" | grep -qF "reap: closed learn-00-13 (2 terminals, all done or idle)"; then
	fail "the reap did not report itself in one line — $OUT"
else
	pass "a finished learn space is reaped with the id herdr names, and nothing else is closed"
fi

# 10. One terminal still working is one learner still running: the whole space stays. A reap that
#     guessed here would end somebody's work, which is worse than a leftover space.
reset
export FAKE_HC_LS='{"hidden_finished":0,"terminals":[
{"address":"t1","status":"done","where":"learn-00-14 / learn-00-14"},
{"address":"t2","status":"working","where":"learn-00-14 / learn-00-14"}]}'
export FAKE_HERDR_LS='{"spaces":[{"id":"sp-learn2","name":"learn-00-14","folder":"/tmp/pi"}]}'
run finish w1
if [ "$RC" != 0 ]; then
	fail "finish with a live learner exited $RC — $OUT"
elif grep -qF "sp-learn2" "$work/herdr-calls"; then
	fail "a learn space with a working terminal was closed: $(tr '\n' ';' <"$work/herdr-calls")"
elif printf '%s' "$OUT" | grep -qF "reap: closed"; then
	fail "the reap claimed a close it did not make — $OUT"
else
	pass "one working terminal keeps the whole learn space open"
fi

# 11. A learn slug that is a live delegation is somebody's worker, whatever its terminals say.
reset
printf '{"w1":{"space":"space-w1","cwd":"","branch":""},"learn-00-15":{"space":"sp-learn3","cwd":"","branch":""}}\n' \
	>"$PI_BOSS_ROOT/state/delegations.json"
export FAKE_HC_LS='{"hidden_finished":0,"terminals":[{"address":"t1","status":"done","where":"learn-00-15 / learn-00-15"}]}'
export FAKE_HERDR_LS='{"spaces":[{"id":"sp-learn3","name":"learn-00-15","folder":"/tmp/pi"}]}'
run finish w1
if [ "$RC" != 0 ]; then
	fail "finish with a tracked learn slug exited $RC — $OUT"
elif grep -qF "sp-learn3" "$work/herdr-calls"; then
	fail "the reap closed a learn space that is a live delegation: $(tr '\n' ';' <"$work/herdr-calls")"
else
	pass "a learn space recorded in state/delegations.json survives the reap"
fi

# 12. hc refusing is not evidence about anything: nothing is closed, and the command still does
#     its own job. One warning line names the skip, and no fake count is printed.
reset
export FAKE_HC_LS='{"hidden_finished":0,"terminals":[{"address":"t1","status":"done","where":"learn-00-16 / learn-00-16"}]}'
export FAKE_HERDR_LS='{"spaces":[{"id":"sp-learn4","name":"learn-00-16","folder":"/tmp/pi"}]}'
export FAKE_HC_RC=1
run finish w1
if [ "$RC" != 0 ]; then
	fail "a failing hc changed finish's exit status: $RC — $OUT"
elif grep -qF "sp-learn4" "$work/herdr-calls"; then
	fail "the reap closed a space on an hc that never answered: $(tr '\n' ';' <"$work/herdr-calls")"
elif ! printf '%s' "$OUT" | grep -qF "reap: skipped"; then
	fail "the skip was silent — $OUT"
else
	pass "a failing hc closes nothing and leaves the command's own exit status alone"
fi

# 13. The reap is opt-out for anything that must see the ordinary paths untouched.
reset
export FAKE_HC_LS='{"hidden_finished":0,"terminals":[{"address":"t1","status":"done","where":"learn-00-17 / learn-00-17"}]}'
export FAKE_HERDR_LS='{"spaces":[{"id":"sp-learn5","name":"learn-00-17","folder":"/tmp/pi"}]}'
out=$(env DELEGATE_NO_REAP=1 "$delegate" finish w1 2>&1) && RC=0 || RC=$?
OUT=$out
if [ "$RC" != 0 ]; then
	fail "finish with DELEGATE_NO_REAP=1 exited $RC — $OUT"
elif grep -qF "sp-learn5" "$work/herdr-calls"; then
	fail "DELEGATE_NO_REAP=1 still closed a learn space: $(tr '\n' ';' <"$work/herdr-calls")"
elif printf '%s' "$OUT" | grep -qF "reap:"; then
	fail "DELEGATE_NO_REAP=1 still reported a reap — $OUT"
else
	pass "DELEGATE_NO_REAP=1 makes no close call and says nothing"
fi

# 14. `space.close` answering ok is not the space being gone. This is the exact shape that bit a
#     person: `delegate close ci-wiring` printed `closed`, `finish` printed `3/3 close`, the
#     delegation entry was deleted — and the Herdr space was still there with a live idle pi in it.
#     So the close is confirmed against `herdr-app ls`, the window's own list, and a space still on
#     that list is a warning that names its id, with the worker kept so closing it again is possible.
reset
export FAKE_HERDR_LS='{"spaces":[{"id":"space-w1","name":"w1","folder":"/tmp/big-boss-pi"}]}'
run finish w1
if [ "$RC" = 0 ]; then
	fail "finish called a worker closed while herdr still listed its space, wanted a refusal — $OUT"
elif ! printf '%s' "$OUT" | grep -qE 'step 4 of 4 \(close\)'; then
	fail "finish did not name the close step as the failing one — $OUT"
elif ! printf '%s' "$OUT" | grep -qF "space space-w1 (w1) is still open"; then
	fail "the warning does not name the space and its id — $OUT"
elif [ "$(grep -cF 'space.close --id space-w1 --confirmed true' "$work/herdr-calls")" -lt 2 ]; then
	fail "the stubborn space was not retried: $(tr '
' ';' <"$work/herdr-calls")"
elif [ "$(open_workers)" != 1 ]; then
	fail "a close that could not confirm the space dropped the delegation entry anyway, so it cannot be closed again"
else
	pass "a space herdr still lists is a warning naming its id, and the worker stays closeable"
fi

# 15. And the confirmation does not block the ordinary close: a space herdr no longer lists is gone,
#     whatever space.close's own exit code said.
reset
export FAKE_HERDR_LS='{"spaces":[{"id":"sp-other","name":"somebody-else","folder":"/tmp/pi"}]}'
run finish w1
if [ "$RC" != 0 ]; then
	fail "finish with a space herdr no longer lists exited $RC — $OUT"
elif printf '%s' "$OUT" | grep -qF "is still open"; then
	fail "a space herdr no longer lists was reported as still open — $OUT"
elif [ "$(open_workers)" != 0 ]; then
	fail "the confirmed close kept the delegation entry"
else
	pass "a space herdr no longer lists is a confirmed close"
fi

if [ "$fails" != 0 ]; then
	printf '\nfinish: %d case(s) failed\n' "$fails" >&2
	exit 1
fi
printf '\nfinish: ok\n'
