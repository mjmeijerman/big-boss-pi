#!/usr/bin/env bash
# test-nothing.sh — a worker that legitimately landed nothing has a way to close, and only on
# the terms that make the no-op checkable.
#
# The gap: `delegate close` refused every report that records no commit sha, so a worker whose
# PR merged before it finished, or whose change turned out to be unnecessary, was tracked
# forever. `close --nothing "<reason>"` is that exit, and it is narrow on purpose:
#
#   1. a reason of 20 characters or more, printed on the close and written to
#      state/decisions.jsonl, so an accepted no-op is auditable instead of invisible;
#   2. an Evidence block, because "nothing landed" is still a claim;
#   3. no commit named at all — a report that records a sha that resolves is refused, and told
#      to close the normal way, so --nothing cannot become a way around provenance;
#   4. the wipe step, like every other close.
#
# Every case drives the real `delegate close` against a temporary PI_BOSS_ROOT, a throwaway git
# repo and a stub herdr-app: no model, no desktop app, no real workspace.
#
#   bash scripts/test-nothing.sh      exit 0 = every case held
set -uo pipefail

root=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd)
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

repo=$work/repo
mkdir -p "$repo"
git -C "$repo" init -q -b main
git -C "$repo" config user.email worker@example.invalid
git -C "$repo" config user.name worker
git -C "$repo" commit -q --allow-empty -m "feat: a change"
sha=$(git -C "$repo" rev-parse HEAD)

# decisions <slug> <decision> — the reason recorded for that slug, empty when there is no row.
decisions() {
	[ -f "$PI_BOSS_ROOT/state/decisions.jsonl" ] || return 0
	node -e '
		const fs=require("fs");
		const rows=fs.readFileSync(process.argv[1],"utf8").split("\n").filter(Boolean);
		for(const l of rows){let d;try{d=JSON.parse(l)}catch{continue}
			if(d.command===process.argv[2]&&d.slug===process.argv[3])
				process.stdout.write(String(d.decision)+"\t"+String(d.reason||""))}' \
		"$PI_BOSS_ROOT/state/decisions.jsonl" "$1" "$2"
}

OUT=""
RC=0
# closed <slug> — true when the real close got as far as closing that worker's space. The stub
# herdr-app logs every call, so "the space went away" is observed, not inferred from the prose.
closed() {
	grep -qF -- "space.close --id space-$1" "$work/herdr-calls" 2>/dev/null
}
# run_close <cwd> <slug> [args...] — writes the report from stdin, registers the worker with
# that cwd, runs the real close, and sets OUT/RC.
run_close() {
	local cwd=$1 slug=$2
	shift 2
	mkdir -p "$PI_BOSS_ROOT/reports"
	cat >"$PI_BOSS_ROOT/reports/$slug.md"
	node -e '
		const fs=require("fs");
		const [file,slug,space,cwd]=process.argv.slice(1);
		let j={};try{j=JSON.parse(fs.readFileSync(file,"utf8"))}catch{}
		j[slug]={slug,space,cwd,branch:""};
		fs.writeFileSync(file,JSON.stringify(j,null,2)+"\n")' \
		"$PI_BOSS_ROOT/state/delegations.json" "$slug" "space-$slug" "$cwd"
	local out
	out=$("$bin/delegate" close "$slug" "$@" 2>&1) && RC=0 || RC=$?
	OUT=$out
}

# wipe <slug> — pre-record the consolidation step, for the cases that are not about it.
wipe() {
	printf '{"timestamp":"%s","command":"wipe","task":"%s","decision":"done","reason":null,"overridden":false,"slug":"%s"}\n' \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$1" >>"$PI_BOSS_ROOT/state/decisions.jsonl"
}

reason='the PR merged before this worker finished, so nothing was ever committed'

# 1. The exit that was missing: no commit, a written reason, evidence, wipe recorded -> closes,
#    prints the reason it accepted, and records it.
wipe landed-nothing
run_close "$repo" landed-nothing --nothing "$reason" <<REPORT
# Report

Mission: a worker that lands nothing can be closed and the record says why.

## What now works

Nothing landed on purpose: the pull request merged before the work finished.

## Evidence

$ bin/preflight — 5/5 passed
\$ git -C ~/.pi log --oneline -1 origin/trunk
1c624f1 ci(scripts-test): run every bash gate test from make scripts-test (#68)
REPORT
row=$(decisions nothing landed-nothing)
if [ "$RC" != 0 ]; then
	fail "nothing landed: exit $RC, wanted 0 — $OUT"
elif ! printf '%s' "$OUT" | grep -qF "$reason"; then
	fail "nothing landed: the close does not print the reason it accepted — $OUT"
elif [ "$row" != "accepted	$reason" ]; then
	fail "nothing landed: decisions.jsonl row is '$row', wanted 'accepted<TAB>$reason'"
elif ! closed landed-nothing; then
	fail "nothing landed: the space was never closed — $OUT"
else
	pass "a report that landed nothing closes with --nothing, prints and records the reason"
fi

# 2. No reason: refused before anything is touched, and the message names the flag it needs.
run_close "$repo" no-reason --nothing <<'REPORT'
# Report

Mission: nothing landed and nobody said why.

## Evidence

$ bin/preflight — 5/5 passed
$ true
REPORT
if [ "$RC" != 1 ] || ! printf '%s' "$OUT" | grep -qF -- "--nothing needs a reason"; then
	fail "no reason: exit $RC, wanted 1 with '--nothing needs a reason' — $OUT"
elif closed no-reason; then
	fail "no reason: the space was closed anyway"
else
	pass "a --nothing close with no reason refuses, and stays open"
fi

# 3. A reason too short to say anything: refused, and the length is named so the fix is obvious.
run_close "$repo" short-reason --nothing "nothing landed" <<'REPORT'
# Report

Mission: a reason is a sentence, not a shrug.

## Evidence

$ bin/preflight — 5/5 passed
$ true
REPORT
if [ "$RC" != 1 ] || ! printf '%s' "$OUT" | grep -qF "no-op close needs 20 or more"; then
	fail "short reason: exit $RC, wanted 1 with the 20-character rule — $OUT"
elif ! printf '%s' "$OUT" | grep -qF 'is 14 characters'; then
	fail "short reason: the refusal does not name the length it measured — $OUT"
else
	pass "a reason under 20 characters refuses, and says how long it is"
fi

# 4. The backdoor case: a report that names a commit which resolves is refused, and pointed at
#    the normal close, so --nothing never gets around the provenance check.
wipe with-commit
run_close "$repo" with-commit --nothing "$reason" <<REPORT
# Report

Mission: a landed commit is closed on its provenance, never as a no-op.

Commit: $sha

## Evidence

$ bin/preflight — 5/5 passed
\$ git log -1 --format=%H
$sha
REPORT
if [ "$RC" != 1 ]; then
	fail "resolvable commit with --nothing: exit $RC, wanted 1 — $OUT"
elif ! printf '%s' "$OUT" | grep -qF "that commit resolves"; then
	fail "resolvable commit with --nothing: the refusal does not say the commit resolves — $OUT"
elif [ -n "$(decisions nothing with-commit)" ]; then
	fail "resolvable commit with --nothing: a decisions.jsonl row was written for a refused close"
elif closed with-commit; then
	fail "resolvable commit with --nothing: the space was closed anyway"
else
	pass "a report naming a resolvable commit refuses --nothing and keeps the provenance path"
fi

# 5. A sha that does not resolve is still a report that named a commit: refused, with the two
#    fixes named (record the real sha, or drop the line and say why nothing landed).
run_close "$repo" bad-sha --nothing "$reason" <<'REPORT'
# Report

Mission: a made-up sha is not the same thing as nothing landed.

Commit: ffffffffffffffffffffffffffffffffffffffff

## Evidence

$ bin/preflight — 5/5 passed
$ git log -1 --format=%H
REPORT
if [ "$RC" != 1 ] || ! printf '%s' "$OUT" | grep -qF "names commit"; then
	fail "unresolvable sha with --nothing: exit $RC, wanted 1 naming the commit — $OUT"
elif closed bad-sha; then
	fail "unresolvable sha with --nothing: the space was closed anyway"
else
	pass "a report naming a sha that does not resolve still refuses --nothing"
fi

# 6. "Nothing landed" is a claim too: no Evidence block, no close.
wipe no-evidence
run_close "$repo" no-evidence --nothing "$reason" <<'REPORT'
# Report

Mission: a no-op with nothing to show for it is a guess.

## What now works

Nothing.
REPORT
if [ "$RC" != 1 ] || ! printf '%s' "$OUT" | grep -qF "has no Evidence block"; then
	fail "no evidence with --nothing: exit $RC, wanted 1 with 'has no Evidence block' — $OUT"
else
	pass "a --nothing close without an Evidence block refuses"
fi

# 7. The wipe step stays mandatory on the no-op path: the reason explains the close, not the
#    skipped consolidation.
run_close "$repo" no-wipe --nothing "$reason" <<'REPORT'
# Report

Mission: a no-op worker is still a space that has to be consolidated.

## Evidence

$ bin/preflight — 5/5 passed
$ true
REPORT
if [ "$RC" != 1 ] || ! printf '%s' "$OUT" | grep -qF "no wipe step recorded"; then
	fail "no wipe with --nothing: exit $RC, wanted 1 with 'no wipe step recorded' — $OUT"
elif [ -n "$(decisions nothing no-wipe)" ]; then
	fail "no wipe with --nothing: the reason was recorded for a refused close"
else
	pass "a --nothing close without a wipe step refuses, and records nothing"
fi

# 8. A worker given a plain folder has no repo to resolve a sha against: --nothing works there
#    too, so a non-repo worker is not stuck with the same gap.
plain=$work/plain
mkdir -p "$plain"
wipe plain-folder
run_close "$plain" plain-folder --nothing "$reason" <<'REPORT'
# Report

Mission: a worker in a folder with no repo can also close with nothing landed.

## Evidence

$ bin/preflight — 5/5 passed
$ ls
REPORT
if [ "$RC" != 0 ]; then
	fail "plain folder with --nothing: exit $RC, wanted 0 — $OUT"
else
	pass "a --nothing close works for a worker whose cwd is not a git repo"
fi

# 9. --nothing and --merged answer the same question with opposite findings: asking both is a
#    mistake, refused by name.
run_close "$repo" both-flags --nothing "$reason" --merged 68 <<'REPORT'
# Report

Mission: the two escapes cannot both be true.

## Evidence

$ bin/preflight — 5/5 passed
$ true
REPORT
if [ "$RC" != 1 ] || ! printf '%s' "$OUT" | grep -qF "cannot be combined"; then
	fail "--nothing with --merged: exit $RC, wanted 1 with 'cannot be combined' — $OUT"
else
	pass "--nothing and --merged together are refused"
fi

# 10. The old refusal is untouched for every other close path: a report with no sha and no
#     --nothing still refuses, in the same words as before.
wipe plain-close
run_close "$repo" plain-close <<'REPORT'
# Report

Mission: the no-op exit does not replace the provenance check.

## Evidence

$ bin/preflight — 5/5 passed
$ true
REPORT
if [ "$RC" != 1 ] || ! printf '%s' "$OUT" | grep -qF "records no commit sha"; then
	fail "no --nothing, no sha: exit $RC, wanted 1 with 'records no commit sha' — $OUT"
elif printf '%s' "$OUT" | grep -qF -- "--nothing"; then
	fail "no --nothing, no sha: the refusal now mentions --nothing, so the old path changed — $OUT"
else
	pass "a close without --nothing still refuses a report that records no sha"
fi

printf '\n%s\n' "$([ "$fails" = 0 ] && echo "nothing: ok" || echo "nothing: $fails failure(s)")"
[ "$fails" = 0 ]
