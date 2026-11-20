#!/usr/bin/env bash
# test-close-rewritten.sh — the close for a worker whose work IS a rebase.
#
# The bug this pins: worker `rebase-gate-reuse` rebased branch `gate-reuse` onto trunk. A rebase
# rewrites a commit without changing whose `Agent-Slug` trailer it is, so the new tip still says
# `Agent-Slug: gate-reuse`. Both close paths refused it — plain close because the trailer is not
# this worker's, `--nothing` because the report names a commit at all — and the space stayed open
# for a reason that is not the worker's fault. So there is a third exit, narrow on purpose:
#
#   `delegate close <slug> --rewritten <sha> "<why>"`, accepted only when
#
#   1. the report has an Evidence block, no placeholders, and a bin/preflight run (as before);
#   2. <sha> resolves in the worker's cwd, is not in origin/trunk, and carries an Agent-Slug
#      trailer that is NOT this slug;
#   3. it is the tip of the branch its own trailer names, and replaces a commit on that branch's
#      reflog with the same subject and author — a rewrite of somebody's commit, not an invention;
#   4. the reason is 20 characters or more, and it is printed and recorded like --nothing's.
#
# Cases:
#   A. the rebase case closes, and state/decisions.jsonl records kind provenance / decision
#      rewritten with the sha, the branch and the commit it replaces;
#   B. a sha carrying this worker's OWN trailer is refused, and the refusal says to use plain close;
#   C. a sha that does not resolve is refused, naming that;
#   D. a sha that resolves but is not the tip of its trailer's branch (the pre-rebase commit) is
#      refused, naming the branch;
#   E. --nothing's own rule is untouched: a report that names a resolvable commit is still refused.
#
# A throwaway repo with a bare origin, so `origin/main` is real and the "not in trunk" check is
# answered by git rather than by a stub. Stub herdr-app, temporary PI_BOSS_ROOT, no model.
#
#   bash scripts/tests/test-close-rewritten.sh      exit 0 = every case held
set -uo pipefail

root=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/../.." && pwd)
bin=$root/bin

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export PI_BOSS_ROOT=$work/root
export HOME=$work/home
mkdir -p "$PI_BOSS_ROOT/reports" "$PI_BOSS_ROOT/state" "$PI_BOSS_ROOT/specs" "$PI_BOSS_ROOT/bin" "$work/stub" "$HOME"
unset PI_MASTER_ROOT

printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s/herdr-calls"\nprintf "{\\"space\\":\\"s1\\",\\"tab\\":\\"t1\\",\\"pane\\":\\"p1\\",\\"terminal\\":\\"term1\\"}\\n"\n' "$work" \
	>"$work/stub/herdr-app"
chmod +x "$work/stub/herdr-app"
export PATH=$work/stub:$PATH

fails=0
pass() { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }

# --- the fixture: a branch another worker owns, rewritten by this worker -----------------------
repo=$work/repo
origin=$work/origin.git
git init -q --bare "$origin"
mkdir -p "$repo"
git -C "$repo" init -q -b main
git -C "$repo" config user.email worker@example.invalid
git -C "$repo" config user.name worker
git -C "$repo" remote add origin "$origin"
git -C "$repo" commit -q --allow-empty -m "chore: trunk before the branch"
git -C "$repo" push -q -u origin main

# gate-reuse's own commit, the one a rebase rewrites: same message, same author afterwards.
git -C "$repo" checkout -q -b gate-reuse
git -C "$repo" commit -q --allow-empty -m "feat: the gate reuses its receipt" \
	-m "Agent-Slug: gate-reuse" -m "Spec: specs/gate-reuse.md"
old_gate=$(git -C "$repo" rev-parse HEAD)

# Trunk moves while the branch exists, so the rebase below is a real one.
git -C "$repo" checkout -q main
git -C "$repo" commit -q --allow-empty -m "feat: trunk moved under the branch"
git -C "$repo" push -q origin main
git -C "$repo" fetch -q origin

# The worker's whole job: rebase gate-reuse onto trunk. New sha, same trailer.
git -C "$repo" checkout -q gate-reuse
git -C "$repo" rebase -q origin/main >/dev/null 2>&1
new_gate=$(git -C "$repo" rev-parse HEAD)
subject=$(git -C "$repo" log -1 --format=%s "$new_gate")
if [ "$old_gate" = "$new_gate" ] || [ "$subject" != "feat: the gate reuses its receipt" ]; then
	printf 'fixture broken: the rebase produced %s (subject %s)\n' "$new_gate" "$subject" >&2
	exit 1
fi
if git -C "$repo" merge-base --is-ancestor "$new_gate" refs/remotes/origin/main; then
	printf 'fixture broken: %s must not be in origin/main\n' "$new_gate" >&2
	exit 1
fi

# A commit this worker itself owns, for case B: its trailer names the closing worker.
git -C "$repo" checkout -q -b own-work origin/main
git -C "$repo" commit -q --allow-empty -m "feat: this worker own change" \
	-m "Agent-Slug: rebase-own" -m "Spec: specs/rebase-own.md"
own_sha=$(git -C "$repo" rev-parse HEAD)

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

wipe() {
	printf '{"timestamp":"%s","command":"wipe","task":"%s","decision":"done","reason":null,"overridden":false,"slug":"%s"}\n' \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$1" >>"$PI_BOSS_ROOT/state/decisions.jsonl"
}

closed() {
	grep -qF -- "space.close --id space-$1" "$work/herdr-calls" 2>/dev/null
}

# --- A. the rebase case closes, and the record says what was rewritten --------------------------
wipe rebase-gate-reuse
run_close rebase-gate-reuse --rewritten "$new_gate" \
	"rebased gate-reuse onto trunk; the tip is gate-reuse's commit, rewritten, so this worker's only commit is another worker's" <<REPORT
# rebase-gate-reuse — report

Mission: gate-reuse is rebased onto trunk and the branch publishes without a conflict.

What changed

- Commit: $new_gate — the rebased tip of branch gate-reuse

## Evidence

\$ bash bin/preflight — 6/6 passed
\$ bash scripts/tests/test-close-rewritten.sh — ok
REPORT
if [ "$RC" != 0 ]; then
	fail "the rebase case: exit $RC, wanted 0 — $OUT"
elif ! closed rebase-gate-reuse; then
	fail "the rebase case: the space was never closed — $OUT"
elif ! grep -qF '"command":"provenance","task":"rebase-gate-reuse","decision":"rewritten"' "$PI_BOSS_ROOT/state/decisions.jsonl"; then
	fail "the rebase case: no provenance/rewritten row in state/decisions.jsonl"
elif ! grep -qF "\"sha\":\"$new_gate\"" "$PI_BOSS_ROOT/state/decisions.jsonl"; then
	fail "the rebase case: the row does not carry the rewritten sha"
elif ! grep -qF '"replaces":"'"$old_gate"'"' "$PI_BOSS_ROOT/state/decisions.jsonl"; then
	fail "the rebase case: the row does not carry the commit it replaces"
elif ! printf '%s' "$OUT" | grep -qF "closing rebase-gate-reuse with --rewritten"; then
	fail "the rebase case: the accepted reason was not printed — $OUT"
else
	pass "a rebased branch's tip closes with --rewritten, and the row names both shas (exit 0)"
fi

# --- B. the sha carries this worker's own trailer: plain close is the path ---------------------
wipe rebase-own
run_close rebase-own --rewritten "$own_sha" \
	"this worker rebased its own commit onto trunk and the trailer names this worker itself" <<REPORT
# rebase-own — report

Mission: the trailer names this worker, so nothing was rewritten.

Commit: $own_sha

## Evidence

\$ bash bin/preflight — 6/6 passed
REPORT
if [ "$RC" != 1 ]; then
	fail "own trailer: exit $RC, wanted 1 — $OUT"
elif ! printf '%s' "$OUT" | grep -qF "carries Agent-Slug: rebase-own, this worker own trailer"; then
	fail "own trailer: the refusal does not say the trailer is this worker's — $OUT"
elif ! printf '%s' "$OUT" | grep -qF "close rebase-own"; then
	fail "own trailer: the refusal does not name the plain close — $OUT"
elif closed rebase-own; then
	fail "own trailer: the space was closed anyway"
else
	pass "a sha whose trailer is this worker's is refused, and plain close is named (exit 1)"
fi

# --- C. a sha that does not resolve ------------------------------------------------------------
wipe no-resolve
run_close no-resolve --rewritten 0123456789abcdef0123456789abcdef01234567 \
	"rebased the other worker's branch onto trunk and the tip is that worker's commit rewritten" <<REPORT
# no-resolve — report

Mission: a sha nobody can resolve proves nothing.

Commit: 0123456789ab

## Evidence

\$ bash bin/preflight — 6/6 passed
REPORT
if [ "$RC" != 1 ]; then
	fail "unresolvable sha: exit $RC, wanted 1 — $OUT"
elif ! printf '%s' "$OUT" | grep -qF "0123456789abcdef0123456789abcdef01234567 does not resolve in"; then
	fail "unresolvable sha: the refusal does not say it does not resolve — $OUT"
elif closed no-resolve; then
	fail "unresolvable sha: the space was closed anyway"
else
	pass "a sha that does not resolve is refused, and the refusal names it (exit 1)"
fi

# --- D. a sha that resolves but is not the tip of its trailer's branch -------------------------
wipe not-tip
run_close not-tip --rewritten "$old_gate" \
	"rebased the other worker's branch onto trunk and the tip is that worker's commit rewritten" <<REPORT
# not-tip — report

Mission: the pre-rebase commit is not the tip any more.

Commit: $old_gate

## Evidence

\$ bash bin/preflight — 6/6 passed
REPORT
if [ "$RC" != 1 ]; then
	fail "not the branch tip: exit $RC, wanted 1 — $OUT"
elif ! printf '%s' "$OUT" | grep -qF "is not the tip of gate-reuse"; then
	fail "not the branch tip: the refusal does not name gate-reuse as the branch it is not the tip of — $OUT"
elif closed not-tip; then
	fail "not the branch tip: the space was closed anyway"
else
	pass "a sha that resolves outside its branch's tip is refused, naming the branch (exit 1)"
fi

# --- E. --nothing keeps its rule: a report naming a resolvable commit is refused ---------------
wipe nothing-names-sha
run_close nothing-names-sha --nothing "the change turned out to be unnecessary, so nothing landed" <<REPORT
# nothing-names-sha — report

Mission: a --nothing close is for a report that names no commit at all.

Commit: $new_gate

## Evidence

\$ bash bin/preflight — 6/6 passed
REPORT
if [ "$RC" != 1 ]; then
	fail "--nothing with a named commit: exit $RC, wanted 1 — $OUT"
elif ! printf '%s' "$OUT" | grep -qF "a --nothing close is for a report that names no commit at all" \
	&& ! printf '%s' "$OUT" | grep -qF "and that commit resolves, so something did land"; then
	fail "--nothing with a named commit: the refusal no longer sends it to the normal close — $OUT"
elif closed nothing-names-sha; then
	fail "--nothing with a named commit: the space was closed anyway"
else
	pass "--nothing still refuses a report that names a resolvable commit (exit 1)"
fi

if [ "$fails" -ne 0 ]; then
	printf 'close-rewritten: %d case(s) failed\n' "$fails"
	exit 1
fi
printf 'close-rewritten: ok (%d cases)\n' 5
