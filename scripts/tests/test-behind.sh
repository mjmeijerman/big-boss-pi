#!/usr/bin/env bash
# test-behind.sh — the `behind` check: a branch cut from a stale trunk is caught here, before the
# publish, instead of arriving on GitHub as `CONFLICTING`.
#
# The case that made it: #68 was spawned at 19:27:52Z, #67 merged at 19:32:04Z, and #68 arrived
# CONFLICTING with AGENTS.md and README.md colliding. Nothing else in the gate can see that —
# syntax, semgrep, the scrub and the body gate all pass on a stale base.
#
# Every case is a throwaway repo with a bare origin on disk, so "behind" is real git ancestry and
# not a stub's opinion, and the fetch the check runs has somewhere to go without a network. What
# happened is read from the refs and from HEAD's own sha, never from what the run said about
# itself — with one exception that cannot be read any other way: the offline case, where the line
# the check prints IS the behaviour.
#
# The cases a bypass would have to get past:
#   A. behind trunk, a touched path also moved on trunk: FAIL, and it names the count, the
#      colliding path and the rebase;
#   B. level with trunk: pass;
#   C. ahead of trunk: pass — that is every branch mid-work;
#   D. origin unreachable: PASS, with the line that says behind-ness was not checked;
#   E. trunk is `master` and origin/HEAD says so: `origin/master` is what it compares against, even
#      with an `origin/main` sitting at the branch's own level as a decoy;
#   F. behind but no path collides, so a rebase would be trivial: still refused, and HEAD is left
#      exactly where it was — the gate does not rebase.
#
#   bash scripts/tests/test-behind.sh      exit 0 = every case held
set -uo pipefail

root=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/../.." && pwd)
pf=$root/bin/preflight

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export PI_BOSS_ROOT=$work/root
unset PI_MASTER_ROOT
mkdir -p "$PI_BOSS_ROOT/reports" "$PI_BOSS_ROOT/state" "$PI_BOSS_ROOT/specs"

# Hermetic git: no user config, no hooks, no gpg, no prompts. Nothing here needs the machine's.
export GIT_AUTHOR_NAME=T GIT_AUTHOR_EMAIL=t@example.com
export GIT_COMMITTER_NAME=T GIT_COMMITTER_EMAIL=t@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_TERMINAL_PROMPT=0

fails=0
skips=0
pass() { printf '  ok    %s\n' "$*"; }
skip() { printf '  skip  %s\n' "$*"; skips=$((skips + 1)); }
fail() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }

OUT=""
RC=0
run() {
	OUT=$("$@" 2>&1) && RC=0 || RC=$?
}
said() { printf '%s\n' "$OUT" | grep -qF -- "$1"; }
said_re() { printf '%s\n' "$OUT" | grep -qE -- "$1"; }

# --- the fixture -------------------------------------------------------------------------------

REPO=""
reset_case() { # <name> [trunk branch]
	local trunk=${2:-main}
	CASE=$work/$1
	rm -rf "$CASE"
	mkdir -p "$CASE"
	REPO=$CASE/repo
	git init -q --bare -b "$trunk" "$CASE/origin.git"
	git init -q -b "$trunk" "$REPO"
	git -C "$REPO" remote add origin "$CASE/origin.git"
	printf 'the trunk\n' >"$REPO/README.md"
	printf 'notes\n' >"$REPO/NOTES.md"
	git -C "$REPO" add -A
	git -C "$REPO" commit -q -m "trunk: the first commit"
	git -C "$REPO" push -q origin "$trunk"
	TRUNK=$trunk
	git -C "$REPO" checkout -q -b feat/w1
}

trunk_commit() { # <file> <text> — one commit on trunk, pushed, so the branch is one commit behind
	git -C "$REPO" checkout -q "$TRUNK"
	printf '%s\n' "$2" >"$REPO/$1"
	git -C "$REPO" add -A
	git -C "$REPO" commit -q -m "trunk: $1 moves"
	git -C "$REPO" push -q origin "$TRUNK"
	git -C "$REPO" checkout -q feat/w1
}

branch_commit() { # <file> <text>
	printf '%s\n' "$2" >"$REPO/$1"
	git -C "$REPO" add -A
	git -C "$REPO" commit -q -m "feat(w1): $1"
}

head_sha() { git -C "$REPO" rev-parse HEAD; }

check_behind() { run "$pf" --only behind --cwd "$REPO" feat/w1; }

# --- A. behind, and a path this branch touched moved on trunk ----------------------------------

reset_case collide
branch_commit AGENTS.md "this branch's paragraph"
trunk_commit AGENTS.md "the merged paragraph"
trunk_commit README.md "a trunk-only line"
before=$(head_sha)
check_behind
if [ "$RC" = 0 ]; then
	fail "a branch 2 commits behind a colliding trunk passed the behind check — $OUT"
elif ! said_re '^FAIL +behind'; then
	fail "the failing check is not named as the behind one — $OUT"
elif ! said "2 commit(s) behind origin/main"; then
	fail "the check does not say how far behind — $OUT"
elif ! said "AGENTS.md"; then
	fail "the colliding path is not named — $OUT"
elif said "README.md"; then
	fail "a trunk-only path this branch never touched was reported as a collision — $OUT"
elif ! said "Fix: git -C $REPO rebase origin/main"; then
	fail "the remedy is not the rebase, by name — $OUT"
elif [ "$(head_sha)" != "$before" ]; then
	fail "the check moved HEAD: a gate that rewrites history is worse than one that refuses"
else
	pass "a branch behind a colliding trunk fails, naming the count, the colliding path and the rebase"
fi

# --- B. level with trunk ------------------------------------------------------------------------

reset_case level
branch_commit AGENTS.md "one line"
check_behind
if [ "$RC" != 0 ]; then
	fail "a branch level with trunk was refused — $OUT"
elif ! said "origin/main is in feat/w1"; then
	fail "the passing line does not say what was compared — $OUT"
else
	pass "a branch level with trunk passes"
fi

# --- C. ahead of trunk --------------------------------------------------------------------------

reset_case ahead
branch_commit AGENTS.md "a line on the branch"
branch_commit NOTES.md "another line on the branch"
check_behind
if [ "$RC" != 0 ]; then
	fail "a branch that is ahead of trunk was refused — $OUT"
elif said "behind origin/main"; then
	fail "a branch ahead of trunk was reported as behind — $OUT"
else
	pass "a branch ahead of trunk (every branch mid-work) passes"
fi

# --- D. origin unreachable: pass, and say what was not checked ----------------------------------

reset_case offline
branch_commit AGENTS.md "one line"
git -C "$REPO" remote set-url origin "$CASE/no-such-origin.git"
check_behind
if [ "$RC" != 0 ]; then
	fail "an unreachable origin refused the branch — a gate that blocks on a flaky network gets bypassed: $OUT"
elif ! said "could not reach origin; behind-ness unchecked"; then
	fail "the offline pass does not say that behind-ness was not checked — $OUT"
elif said "origin/main is in feat/w1"; then
	fail "an unchecked branch read as a checked one — $OUT"
else
	pass "an unreachable origin passes with the named skip, never as a checked pass"
fi

# --- E. the trunk is `master`, and origin/HEAD says so -------------------------------------------
#
# The decoy is the point: origin/main sits at the branch's own level, so a hardcoded `main` would
# pass this branch silently while origin/master is a commit ahead of it.

reset_case master-detect master
branch_commit README.md "the branch's line"
trunk_commit README.md "a colliding line on master"
git -C "$REPO" push -q origin feat/w1:refs/heads/main
git -C "$REPO" remote set-head origin master >/dev/null 2>&1 || git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master
before=$(head_sha)
check_behind
if [ "$RC" = 0 ]; then
	fail "a branch behind origin/master passed: the trunk was read as main from origin/main (the decoy) — $OUT"
elif ! said "behind origin/master"; then
	fail "the check did not compare against origin/master — $OUT"
elif said "origin/main"; then
	fail "the check named origin/main while trunk is master — $OUT"
elif ! said "README.md"; then
	fail "the colliding path under master is not named — $OUT"
elif ! said "Fix: git -C $REPO rebase origin/master"; then
	fail "the remedy does not name origin/master — $OUT"
elif [ "$(head_sha)" != "$before" ]; then
	fail "the check moved HEAD while refusing"
else
	pass "with origin/HEAD on master the check compares against origin/master, not a hardcoded main"
fi

# --- F. behind, but a rebase would be trivial: still refused, HEAD untouched --------------------

reset_case trivial
trunk_commit README.md "a trunk-only line"
before=$(head_sha)
before_count=$(git -C "$REPO" rev-list --count HEAD)
check_behind
if [ "$RC" = 0 ]; then
	fail "a branch behind trunk passed because the rebase would have been clean — $OUT"
elif ! said "1 commit(s) behind origin/main"; then
	fail "the count is not named — $OUT"
elif ! said "no path this branch touched moved on trunk"; then
	fail "the clean-rebase case is not said out loud — $OUT"
elif ! said "Fix: git -C $REPO rebase origin/main"; then
	fail "the remedy is not printed — $OUT"
elif [ "$(head_sha)" != "$before" ] || [ "$(git -C "$REPO" rev-list --count HEAD)" != "$before_count" ]; then
	fail "the gate rebased the branch itself, which is exactly what it must not do"
elif [ -n "$(git -C "$REPO" status --porcelain)" ]; then
	fail "the gate left the worktree dirty: $(git -C "$REPO" status --porcelain)"
else
	pass "a behind branch is refused even when its rebase is trivial, and the tree is left alone"
fi

# --- summary -----------------------------------------------------------------------------------

printf '\n'
if [ "$fails" -ne 0 ]; then
	printf 'behind: %d case(s) failed, %d skipped\n' "$fails" "$skips" >&2
	exit 1
fi
printf 'behind: ok\n'
