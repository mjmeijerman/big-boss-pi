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

# A decision row, so the usage numbers render and the panel's position can be checked.
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '{"timestamp":"%s","command":"ask","task":"q","decision":"yes","reason":"r","overridden":false,"jev":"yes"}\n' \
	"$now" >"$PI_BOSS_ROOT/state/decisions.jsonl"

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

printf '\n%s\n' "$([ "$fails" = 0 ] && echo "futures stats: ok" || echo "futures stats: $fails failure(s)")"
[ "$fails" = 0 ]
