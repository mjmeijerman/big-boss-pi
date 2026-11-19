#!/usr/bin/env bash
# test-close-provenance.sh — which sha the close reads, when the report names more than one.
#
# The bug this pins: a report cites another branch's commit as evidence — that is what evidence
# is — and `delegate close` read the FIRST line carrying the word "commit", took the longest hex
# on it, and refused because that sha carries no `Agent-Slug` trailer and never will. Worker
# `learner-proof` (big-boss-pi PR #164) quoted the learner's `6dbff2f38d8c` from PR #159; its own
# commits were `caaa222` and `460ec13`, both carrying `Agent-Slug: learner-proof`, and the report
# listed them. The space stayed open for hours, and the refusal told its reader to amend a commit
# the worker does not own.
#
# So the reader looks for the sha that belongs to THIS worker before it refuses:
#
#   1. only another branch's sha mentioned            -> still refuses, and names it;
#   2. that sha first, then `Commit: <own>`           -> closes on the own sha;
#   3. the own sha in backticks in "What changed"     -> closes, with no `Commit:` line at all;
#   4. two other workers' shas, neither this slug     -> still refuses, and says which names whom;
#   5. a `Commit:` line quoting the learner, own sha in the commit list -> closes on the own sha;
#   6. no sha anywhere                                -> still refuses: nothing ties the change.
#
# Every case drives the real `delegate close` against a temporary PI_BOSS_ROOT, a throwaway git
# repo with three commits (a learner's, this worker's, another worker's) and a stub herdr-app, so
# there is no model, no desktop app and no real workspace involved.
#
#   bash scripts/tests/test-close-provenance.sh      exit 0 = every case held
set -uo pipefail

root=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/../.." && pwd)
bin=$root/bin

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export PI_BOSS_ROOT=$work/root
export HOME=$work/home
mkdir -p "$PI_BOSS_ROOT/reports" "$PI_BOSS_ROOT/state" "$PI_BOSS_ROOT/specs" "$PI_BOSS_ROOT/bin" "$work/stub" "$HOME"
unset PI_MASTER_ROOT

# A herdr-app that always answers and records its calls, so "the space went away" is observed
# rather than inferred from the prose.
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s/herdr-calls"\nprintf "{\\"space\\":\\"s1\\",\\"tab\\":\\"t1\\",\\"pane\\":\\"p1\\",\\"terminal\\":\\"term1\\"}\\n"\n' "$work" \
	>"$work/stub/herdr-app"
chmod +x "$work/stub/herdr-app"
export PATH=$work/stub:$PATH

fails=0
pass() { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }

# Three commits in one repo, the shape of the bug: a quoted learner commit with no trailer, a
# commit per worker that closes here, and one belonging to another worker.
repo=$work/repo
mkdir -p "$repo"
git -C "$repo" init -q -b main
git -C "$repo" config user.email worker@example.invalid
git -C "$repo" config user.name worker
git -C "$repo" commit -q --allow-empty -m "chore(learn): the learner publishes its own proposal"
learner=$(git -C "$repo" rev-parse --short=12 HEAD)
# commit_for <slug> — one commit carrying that worker's Agent-Slug trailer; prints its short sha.
commit_for() {
	git -C "$repo" commit -q --allow-empty -m "feat: the change $1 was sent for" \
		-m "Agent-Slug: $1" -m "Spec: specs/$1.md"
	git -C "$repo" rev-parse --short=7 HEAD
}
own_worker=$(commit_for own-worker)
own_quoted=$(commit_for quoted-then-labeled)
own_list=$(commit_for backticked-list)
own_learnerproof=$(commit_for learner-proof-shape)
other=$(commit_for other-worker)
if [ "$learner" = "$own_worker" ] || [ "$own_quoted" = "$own_list" ] || [ "$own_list" = "$other" ]; then
	printf 'fixture broken: the shas must differ (%s %s %s %s)\n' "$learner" "$own_worker" "$own_list" "$other" >&2
	exit 1
fi

OUT=""
RC=0
# run_close <slug> [args...] — writes the report from stdin, registers the worker against the
# throwaway repo, runs the real close, and sets OUT/RC.
run_close() {
	local slug=$1
	shift
	mkdir -p "$PI_BOSS_ROOT/reports"
	cat >"$PI_BOSS_ROOT/reports/$slug.md"
	node -e '
		const fs=require("fs");
		const [file,slug,space,cwd]=process.argv.slice(1);
		let j={};try{j=JSON.parse(fs.readFileSync(file,"utf8"))}catch{}
		j[slug]={slug,space,cwd,branch:""};
		fs.writeFileSync(file,JSON.stringify(j,null,2)+"\n")' \
		"$PI_BOSS_ROOT/state/delegations.json" "$slug" "space-$slug" "$repo"
	local out
	out=$("$bin/delegate" close "$slug" "$@" 2>&1) && RC=0 || RC=$?
	OUT=$out
}

# wipe <slug> — pre-record the consolidation step, for the cases the report is not about.
wipe() {
	printf '{"timestamp":"%s","command":"wipe","task":"%s","decision":"done","reason":null,"overridden":false,"slug":"%s"}\n' \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$1" >>"$PI_BOSS_ROOT/state/decisions.jsonl"
}

# closed <slug> — true when the real close got as far as closing that worker's space.
closed() {
	grep -qF -- "space.close --id space-$1" "$work/herdr-calls" 2>/dev/null
}

# 1. Only the learner's commit is mentioned: the refusal stays, names that sha, and the note says
#    why it is not provenance instead of pointing at an amendment of a commit nobody here owns.
run_close quoted-only <<REPORT
# Report

Mission: the learner ran, and this sha is how you can tell.

The learner published its proposal as commit $learner, which is the evidence that the path works.

## Evidence

$ bin/preflight — 5/5 passed
\$ git -C /home/mark/.pi log --oneline -1 learn/learn-17-01
$learner chore(learn): the learner publishes its own proposal
REPORT
if [ "$RC" != 1 ]; then
	fail "only another branch's sha: exit $RC, wanted 1 — $OUT"
elif ! printf '%s' "$OUT" | grep -qF "records commit $learner"; then
	fail "only another branch's sha: the refusal does not name $learner — $OUT"
elif ! printf '%s' "$OUT" | grep -qF "$learner  no Agent-Slug trailer"; then
	fail "only another branch's sha: the note does not say that sha has no trailer — $OUT"
elif closed quoted-only; then
	fail "only another branch's sha: the space was closed anyway"
else
	pass "a report quoting only another branch's sha still refuses, and names that sha (exit 1)"
fi

# 2. The same report with the own commit named on a `Commit:` line below it: the label wins over
#    document order, so the worker closes on the commit that carries its work.
wipe quoted-then-labeled
run_close quoted-then-labeled <<REPORT
# Report

Mission: the evidence is the learner's sha; the work is this worker's own commit.

The learner published its proposal as commit $learner; this worker's change is $own_quoted.

Commit: $own_quoted

## Evidence

$ bin/preflight — 5/5 passed
\$ bash scripts/tests/test-close-provenance.sh — ok
REPORT
if [ "$RC" != 0 ]; then
	fail "learner's sha first, Commit: own below: exit $RC, wanted 0 — $OUT"
elif ! closed quoted-then-labeled; then
	fail "learner's sha first, Commit: own below: the space was never closed — $OUT"
else
	pass "a report quoting the learner's sha first closes on the own sha on its Commit: line (exit 0)"
fi

# 3. No `Commit:` line at all: the own sha is in backticks in the "What changed" list, which is
#    how a report writes its commit list. It is a name, so the reader finds it.
wipe backticked-list
run_close backticked-list <<REPORT
# Report

Mission: the reader finds the commit a report lists, not only the one it labels.

What changed

- Commit: \`$own_list\` — the change this worker was sent for
- the learner's \`$learner\` is quoted as evidence that the path runs

## Evidence

$ bin/preflight — 5/5 passed
\$ bash scripts/tests/test-close-provenance.sh — ok
REPORT
if [ "$RC" != 0 ]; then
	fail "own sha in backticks in What changed: exit $RC, wanted 0 — $OUT"
elif ! closed backticked-list; then
	fail "own sha in backticks in What changed: the space was never closed — $OUT"
else
	pass "the own sha is found in backticks in the commit list, with no Commit: line (exit 0)"
fi

# 4. Two commits, both belonging to other workers: a trailer that names someone else ties the
#    change to that worker and says nothing about this one, so the refusal stays — and the note
#    says which sha names whom, so the next reader is not sent to guess.
run_close two-others <<REPORT
# Report

Mission: a sha from another worker is not this worker's provenance.

Two other workers landed things: commit $learner and commit $other.

## Evidence

$ bin/preflight — 5/5 passed
\$ bash scripts/tests/test-close-provenance.sh — ok
REPORT
if [ "$RC" != 1 ]; then
	fail "two other workers' shas: exit $RC, wanted 1 — $OUT"
elif ! printf '%s' "$OUT" | grep -qF "$other  Agent-Slug: other-worker (not this worker)"; then
	fail "two other workers' shas: the note does not say $other belongs to other-worker — $OUT"
elif ! printf '%s' "$OUT" | grep -qF "names 2 commit sha"; then
	fail "two other workers' shas: the note does not count the shas it looked at — $OUT"
elif closed two-others; then
	fail "two other workers' shas: the space was closed anyway"
else
	pass "two shas that belong to other workers still refuse, and the note names each owner (exit 1)"
fi

# 5. The real case, reproduced: reports/learner-proof.md without its `Commit:` line. The learner's
#    sha is quoted in the prose as evidence, the worker's own sha sits in the commit list, and the
#    close has to reach the own one. The report body below is the real shape, cut to its lines.
wipe learner-proof-shape
run_close learner-proof-shape <<REPORT
# learner-proof — report

Mission: the learner's end-to-end path is a dated fact in docs/radar-conformance.md row 18.

What now works

- node --test scripts/tests/learn-publish.test.mjs -> 17 pass, 0 fail.

What changed

- Commit: \`$own_learnerproof\` — scripts/learn-publish.sh, agent/prompts/learn.md
- the learner published 6dbff2f38d8c as PR #159 and $learner as PR #162, both from the broker space

## Evidence

$ bin/preflight — 5/5 passed
\$ node --test scripts/tests/learn-publish.test.mjs 2>&1 | tail -8
# pass 17
REPORT
if [ "$RC" != 0 ]; then
	fail "learner-proof shape, no Commit: line for the learner: exit $RC, wanted 0 — $OUT"
elif ! closed learner-proof-shape; then
	fail "learner-proof shape: the space was never closed — $OUT"
else
	pass "the learner-proof report closes on its own backticked commit, learner sha quoted in prose (exit 0)"
fi

# 6. The gate itself is not loosened: a report naming no commit at all still refuses, because
#    nothing ties the change to this worker.
run_close no-sha <<'REPORT'
# Report

Mission: a report that names nothing cannot be checked.

## Evidence

$ bin/preflight — 5/5 passed
$ bash scripts/tests/test-close-provenance.sh — ok
REPORT
if [ "$RC" != 1 ] || ! printf '%s' "$OUT" | grep -qF "records no commit sha"; then
	fail "no sha at all: exit $RC, wanted 1 with 'records no commit sha' — $OUT"
elif closed no-sha; then
	fail "no sha at all: the space was closed anyway"
else
	pass "a report naming no commit still refuses (exit 1)"
fi

if [ "$fails" -ne 0 ]; then
	printf 'close-provenance: %d case(s) failed\n' "$fails"
	exit 1
fi
printf 'close-provenance: ok (%d cases)\n' 6
