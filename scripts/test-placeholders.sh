#!/usr/bin/env bash
# test-placeholders.sh — the placeholder scan reads prose, not pasted output.
#
# `delegate close` refuses a report that still carries a fill-in placeholder, and that guard is
# only worth having if it does not bite the reports it exists for: a report quoting its own test
# run, where a line like `# todo 0` is the runner's summary and not an unfinished sentence. So
# every case below drives the real `delegate close`, against reports written into a temporary
# PI_BOSS_ROOT, and asserts the exit code, the message, and nothing else.
#
#   bash scripts/test-placeholders.sh      exit 0 = every case held
set -uo pipefail

root=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd)
bin=$root/bin

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export PI_BOSS_ROOT=$work/root
mkdir -p "$PI_BOSS_ROOT/reports" "$PI_BOSS_ROOT/state" "$work/stub"
unset PI_MASTER_ROOT

# A herdr-app that always succeeds: closing a fake space must not need the desktop app, and the
# assertion is the refusal that happens before any close is attempted.
printf '#!/usr/bin/env bash\nexit 0\n' >"$work/stub/herdr-app"
chmod +x "$work/stub/herdr-app"
export PATH=$work/stub:$PATH

fails=0
pass() { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }

# report_case <name> <want-exit> <want-text|-> — the report body comes on stdin.
# Registers one fake worker in the temporary root and runs the real close against it.
case_no=0
report_case() {
	local name=$1 want=$2 text=$3 slug out rc
	case_no=$((case_no + 1))
	slug="w$case_no"
	cat >"$PI_BOSS_ROOT/reports/$slug.md"
	printf '{"%s":{"space":"space-%s","cwd":"","branch":""}}\n' "$slug" "$slug" \
		>"$PI_BOSS_ROOT/state/delegations.json"
	# The wipe step is mandatory before a close, so every case here records it up front: these
	# cases are about the placeholder scan, and a refusal from the other guard would hide that.
	printf '{"timestamp":"%s","command":"wipe","task":"%s","decision":"done","reason":null,"overridden":false,"slug":"%s"}\n' \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$slug" "$slug" >>"$PI_BOSS_ROOT/state/decisions.jsonl"
	out=$("$bin/delegate" close "$slug" 2>&1) && rc=0 || rc=$?
	if [ "$rc" != "$want" ]; then
		fail "$name: exit $rc, wanted $want — $out"
	elif [ "$text" != - ] && ! printf '%s' "$out" | grep -qF -- "$text"; then
		fail "$name: no '$text' in output — $out"
	else
		pass "$name (exit $want)"
	fi
}

# 1. A written-out report closes.
report_case "clean report passes" 0 - <<'REPORT'
# Report

Mission: the person reading this report can act on it without asking a question.

## Evidence

$ bin/preflight — 5/5 passed
$ delegate close w1 — closed
REPORT

# 2. A placeholder in the prose still refuses, and still prints LINE:TEXT.
report_case "unfenced TODO refuses" 1 "still has fill-in placeholders" <<'REPORT'
# Report

Mission: TODO write the mission.

## Evidence

$ bin/preflight — 5/5 passed
$ delegate close w2 — closed
REPORT

# 3. The case that started this: a quoted test summary inside a fence is output, not a placeholder.
report_case "fenced '# todo 0' passes" 0 - <<'REPORT'
# Report

Mission: a report can quote its own test run without being refused.

## Evidence

$ bin/preflight — 5/5 passed
```
$ node --test
# tests 6
# pass 6
# todo 0
```
REPORT

# 4. Same for TBD and FIXME, in a tilde fence this time.
report_case "fenced TBD passes" 0 - <<'REPORT'
# Report

Mission: tilde fences are read the same way as backtick fences.

## Evidence

$ bin/preflight — 5/5 passed
~~~
TBD is what the log line said before the fix
FIXME and TODO appear here as data too
~~~
REPORT

# 5. A fence opened and never closed is fenced to end of file: no refusal over output, but one
#    warning line on stderr, so a fence typo is not silent.
report_case "unbalanced fence passes with a warning" 0 "unclosed ~~~ fence opened at line 8" <<'REPORT'
# Report

Mission: a missing closing fence costs one warning, not a refused report.

## Evidence

$ bin/preflight — 5/5 passed
~~~
# todo 0
still inside the fence, to the end of the file
REPORT

# 6. Angle-bracket placeholders outside a fence still refuse.
report_case "<fill in> outside a fence refuses" 1 "still has fill-in placeholders" <<'REPORT'
# Report

Mission: <fill in the mission here>

## Evidence

$ bin/preflight — 5/5 passed
$ delegate close w6 — closed
REPORT

# 6b. The skeleton `delegate spawn` writes, verbatim: every one of its five lines is a placeholder
#     until it is filled in, so an unfilled skeleton can never publish as it stands. This is the
#     case the skeleton exists for — the required lines before the worker writes prose.
report_case "the unfilled spawn skeleton refuses" 1 "still has fill-in placeholders" <<'REPORT'
# Report — w7

Mission: <fill in: who is better off and what shows it, in one line>

Review tier: <fill in: High|Medium|Low>

Test change: <fill in: what the test file pins, or "none: no test file changed">

## Evidence

`bin/preflight` ran once on this branch — paste it under the command below, by name, with its
summary line:

Command: <fill in: the exact command you ran, flags and all>

Output (last 20 lines):

```
<paste the last 20 lines of that command's output here>
```

Commit: <fill in: the sha on this branch>
REPORT

# 7. And the scan is not fooled the other way: a placeholder after a closed fence is prose again.
report_case "prose after a closed fence refuses" 1 "still has fill-in placeholders" <<'REPORT'
# Report

Mission: the scan picks up where the fence ends.

## Evidence

$ bin/preflight — 5/5 passed
```
# todo 0
```

TODO paste the commit sha here
REPORT

# 7b. The case that refused `delegate close ci-wiring` for hours: a report quoting the scaffold
#     it deleted, with the file:line right beside it. The placeholder is inside an inline code
#     span, so it is a quotation of the template, not an unfinished sentence.
report_case "quoted scaffold in a code span passes" 0 - <<'REPORT'
# Report

Mission: the report says which template line it is talking about, and closes.

## Thrown away

The first version of the lint flagged every column-0 line that starts no block
(the evidence scaffold's own `Command: <fill in: the exact command you ran, flags and all>` line,
`slim-plain.md:88`), which is the scaffold, not template damage. Deleted.

## Evidence

$ bin/preflight — 5/5 passed
$ delegate close w8 — closed
REPORT

# 7c. The same sentence without the backticks is the report using the template, and still refuses:
#     the fix above narrows the scan, it does not silence it.
report_case "the same line unquoted still refuses" 1 "still has fill-in placeholders" <<'REPORT'
# Report

Mission: the report says which template line it is talking about, and does not close.

## Thrown away

The first version of the lint flagged the evidence scaffold's own
Command: <fill in: the exact command you ran, flags and all> line, `slim-plain.md:88`.

## Evidence

$ bin/preflight — 5/5 passed
$ delegate close w9 — closed
REPORT

# 7d. One placeholder quoted and one used on the same line: the used one is still found, because
#     the scan removes the code span and reads the rest of the line.
report_case "prose beside a code span still refuses" 1 "still has fill-in placeholders" <<'REPORT'
# Report

Mission: `slim-plain.md:88` is quoted, <paste the tail of the run here> is not.

## Evidence

$ bin/preflight — 5/5 passed
$ delegate close w10 — closed
REPORT

# 8. The wipe step is mandatory, and the close guard is where it bites: a written-out report
#    still refuses when no wipe line names the worker, and the refusal names the command.
rm -f "$PI_BOSS_ROOT/state/decisions.jsonl"
printf '{"nowipe":{"space":"space-nowipe","cwd":"","branch":""}}\n' >"$PI_BOSS_ROOT/state/delegations.json"
cat >"$PI_BOSS_ROOT/reports/nowipe.md" <<'REPORT'
# Report

Mission: a clean report is still not a closed worker without the wipe step.

## Evidence

$ bin/preflight — 5/5 passed
$ delegate close nowipe — refused
REPORT
out=$("$bin/delegate" close nowipe 2>&1) && rc=0 || rc=$?
if [ "$rc" = 1 ] && printf '%s' "$out" | grep -qF "no wipe step recorded"; then
	pass "no wipe line refuses the close (exit 1)"
else
	fail "close without a wipe line: exit $rc — $out"
fi

printf '\n%s\n' "$([ "$fails" = 0 ] && echo "placeholder scan: ok" || echo "placeholder scan: $fails failure(s)")"
[ "$fails" = 0 ]
