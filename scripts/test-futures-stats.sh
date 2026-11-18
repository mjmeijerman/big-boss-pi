#!/usr/bin/env bash
# test-futures-stats.sh — the futures panel counts credit, and it counts it the same way twice.
#
# The three numbers say what the harness bought back: reports that name what they threw away,
# reports that state they ran two or more cycles, and reports a reader can check because the
# Evidence block is filled in. All three are read off reports/ alone, so every edge that matters
# is a shape of report file: a Thrown-away section with text, a Thrown-away heading with nothing
# under it, and no such heading at all. The counts have to tell those three apart, and the panel
# has to appear above the usage numbers where a reader sees it without scrolling.
#
# Fixtures are written into a temporary PI_BOSS_ROOT; nothing real is read or written.
#
#   bash scripts/test-futures-stats.sh      exit 0 = every case held
set -uo pipefail

root=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd)
stats="node $root/bin/stats.mjs"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export PI_BOSS_ROOT=$work/root
unset PI_MASTER_ROOT
mkdir -p "$PI_BOSS_ROOT/reports" "$PI_BOSS_ROOT/state"

fails=0
pass() { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }

# Decision rows, one per scorecard category: an answered-and-agreed mode row, an answered-and-
# overridden one, an answered count, a legacy route row with no `jev` field at all (unknown, its
# override carries no jev answer either), an answered thinking row, a thinking row whose `defaults`
# names two fields jev filled in under the caller, a permit row (jev's highest-consequence answer,
# which used to be logged nowhere), and an in-flight row that is a spawn cap rather than a jev
# answer. The two overridden rows name different slugs, only one of which has a report.
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
{
	printf '{"timestamp":"%s","command":"ask","task":"q","decision":"yes","reason":"r","overridden":false,"jev":"yes"}\n' "$now"
	printf '{"timestamp":"%s","command":"mode","task":"q","decision":"sandboxed","reason":"r","overridden":false,"slug":"filled","jev":"sandboxed"}\n' "$now"
	printf '{"timestamp":"%s","command":"mode","task":"q","decision":"bare","reason":"needed the sockets","overridden":true,"slug":"filled","jev":"sandboxed"}\n' "$now"
	printf '{"timestamp":"%s","command":"count","task":"q","decision":"1","reason":"r","overridden":false,"slug":"filled","jev":"1"}\n' "$now"
	printf '{"timestamp":"%s","command":"route","task":"q","decision":"remote","reason":"legacy row, no jev recorded","overridden":true,"slug":"never-written"}\n' "$now"
	printf '{"timestamp":"%s","command":"thinking","task":"q","decision":"low","reason":"r","overridden":false,"slug":"filled","jev":"low"}\n' "$now"
	printf '{"timestamp":"%s","command":"thinking","task":"q","decision":"medium","reason":"weak answer, defaults stand in","overridden":false,"slug":"defaulted","jev":"medium","defaults":["count","thinking"]}\n' "$now"
	printf '{"timestamp":"%s","command":"permit","task":"read README.md","decision":"allow","reason":"read-only","overridden":false,"slug":"perm","jev":"allow"}\n' "$now"
	printf '{"timestamp":"%s","command":"in-flight","task":"q","decision":"blocked","reason":"queue","overridden":false,"slug":"waiting"}\n' "$now"
} >"$PI_BOSS_ROOT/state/decisions.jsonl"

# Four finished reports: one section filled in, one heading left empty, one section absent, and
# one that writes "nothing" down instead of deleting the heading — which is still credit.
cat >"$PI_BOSS_ROOT/reports/filled.md" <<'EOF'
# filled

**Mission**: the reader can check the result.

## What now works

- it works

## Evidence

```
$ bash scripts/test-futures-stats.sh
futures: ok
```

## Thrown away

Rewrote the parser twice before the third shape held; the first two are gone.

## Cycles

It took three cycles and the second one was the useful one.
EOF

cat >"$PI_BOSS_ROOT/reports/empty.md" <<'EOF'
# empty

## Evidence

## Thrown away

## What I would do differently next time

Nothing to add.
EOF

cat >"$PI_BOSS_ROOT/reports/absent.md" <<'EOF'
# absent

## What now works

- a report with no Evidence and no Thrown away section at all
EOF

cat >"$PI_BOSS_ROOT/reports/written-down.md" <<'EOF'
# written-down

## Evidence

```
$ ls
ok
```

## Thrown away

nothing

## Notes

- **Iteration**: expect two or more cycles. You may throw this away.
- the pasted spec line says nothing about what this report did
EOF

# jget <dotted path> — the JSON field as compact JSON.
jget() {
	node -e '
		let d = "";
		process.stdin.on("data", (c) => (d += c)).on("end", () => {
			let v;
			try { v = JSON.parse(d); } catch (e) { console.log("not JSON: " + e.message); process.exit(1); }
			for (const p of process.argv[1].split(".")) v = v === undefined || v === null ? undefined : v[p];
			process.stdout.write(JSON.stringify(v));
		});' "$1"
}

json=$($stats --json 2>&1) || fail "stats --json exited nonzero: $json"

# One filled section, one empty heading, one absent, one that says "nothing": two count, two do
# not, and the empty heading is not a filled one just because the words are on the page.
got=$(printf '%s' "$json" | jget futures.thrown_away.count)
[ "$got" = "2" ] && pass "thrown away counted: 2 of 4 (filled + written down)" ||
	fail "futures.thrown_away.count: got $got, wanted 2"

got=$(printf '%s' "$json" | jget futures.finished_reports)
[ "$got" = "4" ] && pass "finished reports counted: 4" || fail "futures.finished_reports: got $got, wanted 4"

got=$(printf '%s' "$json" | jget futures.evidence.count)
[ "$got" = "2" ] && pass "evidence counted: 2 of 4 (filled + written down, not the empty heading)" ||
	fail "futures.evidence.count: got $got, wanted 2"

# Two reports state their cycles; the pasted spec boilerplate ("expect two or more cycles") is
# not a report saying it ran them, so it is not counted.
got=$(printf '%s' "$json" | jget futures.two_or_more_cycles.count)
[ "$got" = "1" ] && pass "two or more cycles: 1 of 4 ('three cycles', spec boilerplate ignored)" ||
	fail "futures.two_or_more_cycles.count: got $got, wanted 1"

# The panel is on screen, and it comes before the numbers it is worth more than.
screen=$($stats 2>&1) || fail "stats exited nonzero on the fixtures"
if printf '%s' "$screen" | grep -qF "thrown away:  2 of 4 finished reports"; then
	pass "screen names the thrown-away count"
else
	fail "screen has no 'thrown away:  2 of 4 finished reports' line"
fi
panel=$(printf '%s\n' "$screen" | grep -n "futures bought back" | cut -d: -f1)
usage=$(printf '%s\n' "$screen" | grep -n "local model calls" | cut -d: -f1)
if [ -n "$panel" ] && [ -n "$usage" ] && [ "$panel" -lt "$usage" ]; then
	pass "futures panel renders above the usage numbers (line $panel before line $usage)"
else
	fail "futures panel is not above the usage numbers (panel='$panel', usage='$usage')"
fi

# No reports directory at all: zeros, not a crash, and the panel still prints.
empty=$work/empty-root
mkdir -p "$empty/state"
printf '{"timestamp":"%s","command":"ask","task":"q","decision":"yes","reason":"r","overridden":false,"jev":"yes"}\n' \
	"$now" >"$empty/state/decisions.jsonl"
bare=$(PI_BOSS_ROOT=$empty $stats --json 2>&1) || fail "stats --json with no reports/ exited nonzero: $bare"
got=$(printf '%s' "$bare" | jget futures)
[ "$got" = '{"finished_reports":0,"thrown_away":{"count":0,"share":0,"reports":[]},"two_or_more_cycles":{"count":0,"share":0,"reports":[]},"evidence":{"count":0,"share":0,"reports_without":[]},"cycles_stated":[]}' ] &&
	pass "no reports/ reads as zeros" || fail "futures with no reports/: got $got"
if PI_BOSS_ROOT=$empty $stats 2>&1 | grep -qF "thrown away:  0 of 0 finished reports (0%)"; then
	pass "screen still renders the panel with no reports"
else
	fail "screen has no zero panel with no reports/"
fi

# The scorecard: an unknown-answer row must never be counted as agreement, so the legacy route
# row is unknown 1 with no override rate; the rate is overrides over rows, not decision === jev,
# which is the tautology `agreement_rate` used to print. A kind with no rows has a null rate, not 0.
got=$(printf '%s' "$json" | jget jev_scorecard.kinds.mode.answered)
[ "$got" = "2" ] && pass "scorecard: mode has 2 answered rows" || fail "jev_scorecard.kinds.mode.answered: got $got, wanted 2"

got=$(printf '%s' "$json" | jget jev_scorecard.kinds.mode.unknown)
[ "$got" = "0" ] && pass "scorecard: mode has no unknown rows" || fail "jev_scorecard.kinds.mode.unknown: got $got, wanted 0"

got=$(printf '%s' "$json" | jget jev_scorecard.kinds.mode.override_rate)
[ "$got" = "50" ] && pass "scorecard: mode override rate 50% (one row overruled jev)" ||
	fail "jev_scorecard.kinds.mode.override_rate: got $got, wanted 50"

got=$(printf '%s' "$json" | jget jev_scorecard.kinds.mode.copied)
[ "$got" = "1" ] && pass "scorecard: the copied row is counted as copied, not as agreement" ||
	fail "jev_scorecard.kinds.mode.copied: got $got, wanted 1"

got=$(printf '%s' "$json" | jget jev_scorecard.agreement.measurable)
[ "$got" = "false" ] && pass "scorecard: no agreement rate is claimed" ||
	fail "jev_scorecard.agreement.measurable: got $got, wanted false"

got=$(printf '%s' "$json" | jget jev_scorecard.kinds.route.unknown)
[ "$got" = "1" ] && pass "scorecard: a row without jev is unknown, not agreement" ||
	fail "jev_scorecard.kinds.route.unknown: got $got, wanted 1"

got=$(printf '%s' "$json" | jget jev_scorecard.kinds.permit.override_rate)
[ "$got" = "0" ] && pass "scorecard: a kind with rows and no overrides is 0%, not null" ||
	fail "jev_scorecard.kinds.permit.override_rate: got $got, wanted 0"

got=$(printf '%s' "$json" | jget jev_scorecard.kinds.in-flight.cap)
[ "$got" = "1" ] && pass "scorecard: in-flight row counted as a cap, not a jev answer" ||
	fail "jev_scorecard.kinds.in-flight.cap: got $got, wanted 1"

# `defaults` was written and never read: the fields jev filled in under the caller are now named.
got=$(printf '%s' "$json" | jget jev_scorecard.defaults.rows)
[ "$got" = "1" ] && pass "scorecard: one row carried defaulted fields" ||
	fail "jev_scorecard.defaults.rows: got $got, wanted 1"

got=$(printf '%s' "$json" | jget jev_scorecard.defaults.by_field.count)
[ "$got" = "1" ] && pass "scorecard: the defaulted field count is counted" ||
	fail "jev_scorecard.defaults.by_field.count: got $got, wanted 1"

got=$(printf '%s' "$json" | jget jev_scorecard.kinds.thinking.defaulted)
[ "$got" = "1" ] && pass "scorecard: thinking has one defaulted row" ||
	fail "jev_scorecard.kinds.thinking.defaulted: got $got, wanted 1"

# permit: answered by jev, logged as a decision row, and scored as recorded-but-unscored.
got=$(printf '%s' "$json" | jget jev_scorecard.permit.recorded)
[ "$got" = "true" ] && pass "scorecard: permit rows are recorded" ||
	fail "jev_scorecard.permit.recorded: got $got, wanted true"

got=$(printf '%s' "$json" | jget jev_scorecard.permit.verdicts.allow)
[ "$got" = "1" ] && pass "scorecard: the permit verdict is counted" ||
	fail "jev_scorecard.permit.verdicts.allow: got $got, wanted 1"

# A row with no `defaults` key at all must not crash or count: most rows above have none.
got=$(printf '%s' "$json" | jget jev_scorecard.kinds.mode.defaulted)
[ "$got" = "0" ] && pass "scorecard: rows without defaults contribute nothing" ||
	fail "jev_scorecard.kinds.mode.defaulted: got $got, wanted 0"

# A kind with no rows at all: no rate, not 0% — the empty-root fixture above has only an ask row.
got=$(printf '%s' "$bare" | jget jev_scorecard.kinds.mode.override_rate)
[ "$got" = "null" ] && pass "scorecard: a kind with no rows has no rate, not 0%" ||
	fail "jev_scorecard.kinds.mode.override_rate with no mode rows: got $got, wanted null"

# Overrides are per slug, not per row, and whether the worker reported decides which way they read.
got=$(printf '%s' "$json" | jget jev_scorecard.overrides.slugs)
[ "$got" = "2" ] && pass "scorecard: 2 override slugs" || fail "jev_scorecard.overrides.slugs: got $got, wanted 2"

got=$(printf '%s' "$json" | jget jev_scorecard.overrides.without_report)
[ "$got" = "1" ] && pass "scorecard: one override ended with no report" ||
	fail "jev_scorecard.overrides.without_report: got $got, wanted 1"

got=$(printf '%s' "$json" | jget jev_scorecard.overrides.entries.0.slug)
[ "$got" = '"never-written"' ] && pass "scorecard: the no-report override is named first" ||
	fail "jev_scorecard.overrides.entries.0.slug: got $got, wanted \"never-written\""

if printf '%s' "$screen" | grep -qE '^  mode +2/2 +0 +1 +50% +0$'; then
	pass "screen carries the mode scorecard row"
else
	fail "screen has no 'mode 2/2 ... 50% 0' scorecard row"
fi
if printf '%s' "$screen" | grep -qF "agreement: not measurable"; then
	pass "screen says the agreement rate is not measurable"
else
	fail "screen does not say the agreement rate is not measurable"
fi
if printf '%s' "$screen" | grep -qF "defaults: jev filled in 1 decision rows (count 1, thinking 1)"; then
	pass "screen names the defaulted fields"
else
	fail "screen does not name the defaulted fields"
fi
if printf '%s' "$screen" | grep -qF "permit: 1 row (allow 1)"; then
	pass "screen carries the permit row"
else
	fail "screen does not carry the permit row"
fi
if printf '%s' "$screen" | grep -qF "no report  never-written"; then
	pass "screen names the override with no report"
else
	fail "screen does not name the no-report override"
fi
panel=$(printf '%s\n' "$screen" | grep -n "jev scorecard" | cut -d: -f1)
usage=$(printf '%s\n' "$screen" | grep -n "local model calls" | cut -d: -f1)
if [ -n "$panel" ] && [ -n "$usage" ] && [ "$panel" -lt "$usage" ]; then
	pass "scorecard renders above the usage numbers (line $panel before line $usage)"
else
	fail "scorecard is not above the usage numbers (panel='$panel', usage='$usage')"
fi

printf '\n%s\n' "$([ "$fails" = 0 ] && echo "futures stats: ok" || echo "futures stats: $fails failure(s)")"
[ "$fails" = 0 ]
