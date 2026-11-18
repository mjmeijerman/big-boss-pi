#!/usr/bin/env bash
# test-prune-refs.sh — scripts/prune-refs.sh deletes only what it can prove is dead.
#
# This command deletes branches and worktree entries, so the cases are mostly refusals. Each one is
# a throwaway repo under a temporary directory with its own bare origin, and a stub `gh` on PATH, so
# nothing here touches a real checkout, a real remote or the network.
#
#   A. Dry run by default: a merged branch and a squash-merged branch are listed as `would delete`,
#      an unpushed commit, a partially merged branch, an open PR and the current branch are kept
#      with their reason, and nothing is deleted.
#   B. --apply without --yes on a non-interactive stdin refuses with usage, exit 2, nothing deleted.
#   C. gh unable to answer: proven-dead branches are printed as kept, and the dead worktree is still
#      pruned (a missing directory cannot come back through a pull request).
#   D. --apply --yes deletes exactly the branches it listed and prunes exactly the worktree whose
#      directory is gone, while the live worktree stays.
#   E. Nothing left: exit 0, not an error.
#   F. One --apply finishes: a merged branch held only by a worktree entry whose directory is gone
#      is deleted by the same run that prunes the entry, and the run after it has nothing to do.
#   G. The third proof: a PR the host squash-merged deletes a branch the two patch proofs cannot see
#      (the branch commits were rewritten on trunk), a commit written after that merge keeps the
#      branch and is named, and a `gh` that answers nothing keeps it too.
#
#   bash scripts/tests/test-prune-refs.sh      exit 0 = every case held
set -uo pipefail

root=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/../.." && pwd)
script=$root/scripts/prune-refs.sh

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export HOME=$work/home
mkdir -p "$HOME"

fails=0
pass() { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }

out=""
rc=0
# run [env...] -- <args...> : prune-refs.sh against the fixture repo, stdin closed.
run() {
	local -a envs=()
	while [ $# -gt 0 ] && [ "$1" != "--" ]; do
		envs+=("$1")
		shift
	done
	[ "${1:-}" = "--" ] && shift
	out=$(env "PATH=$stub:$PATH" "${envs[@]+"${envs[@]}"}" bash "$script" "$@" </dev/null 2>&1)
	rc=$?
}
want_rc() { # <want> <description>
	if [ "$rc" = "$1" ]; then pass "$2 (exit $rc)"; else fail "$2: exit $rc, wanted $1 — $out"; fi
}
want_text() { # <text> <description>
	if printf '%s' "$out" | grep -qF -- "$1"; then
		pass "$2"
	else
		fail "$2: no '$1' in output: $(printf '%s' "$out" | tr '\n' '|')"
	fi
}
want_no_text() { # <text> <description>
	if printf '%s' "$out" | grep -qF -- "$1"; then
		fail "$2: found '$1' in output: $(printf '%s' "$out" | tr '\n' '|')"
	else
		pass "$2"
	fi
}
has_branch() { git -C "$1" rev-parse --verify --quiet "refs/heads/$2" >/dev/null; }
want_branch() { want_branch_in "$repo" "$1" "$2"; }
want_branch_in() { # <repo> <name> <present|gone>
	if has_branch "$1" "$2"; then
		if [ "$3" = present ]; then
			pass "branch $2 is present"
		else
			fail "branch $2 is still there, wanted gone"
		fi
	elif [ "$3" = gone ]; then
		pass "branch $2 is gone"
	else
		fail "branch $2 is gone, wanted present"
	fi
}

# --- stub gh: one call, four answers ----------------------------------------------------------

# The bulk `pr list` is what the script asks once for every branch. A `pr list --head BRANCH` is the
# third proof's question about one branch, and the dates below are what its commit dates are measured
# against: squash-clean's commits are older than its merge, squash-new has one written after it.
stub=$work/stub
mkdir -p "$stub"
cat >"$stub/gh" <<'STUB'
#!/usr/bin/env bash
case $* in
*"pr list"*) ;;
*) exit 0 ;;
esac
head=""
prev=""
for arg in "$@"; do
	[ "$prev" = --head ] && head=$arg
	prev=$arg
done
mode=${GH_MODE:-ok}
if [ -n "$head" ]; then
	case $mode in
	ok)
		case $head in
		squash-clean) printf '21\tMERGED\t2020-01-02T00:00:00Z\n' ;;
		squash-new) printf '22\tMERGED\t2019-12-31T00:00:00Z\n' ;;
		*) ;;
		esac
		;;
	head-empty) ;;
	*)
		printf 'gh: HTTP 502: Bad Gateway\n' >&2
		exit 1
		;;
	esac
	exit 0
fi
case $mode in
ok | head-empty | head-fail)
	printf '11\topen-pr\tOPEN\n'
	printf '12\tmerged-ff\tMERGED\n'
	printf '13\tsquashed\tMERGED\n'
	printf '21\tsquash-clean\tMERGED\n'
	printf '22\tsquash-new\tMERGED\n'
	;;
*)
	printf 'gh: HTTP 401: Bad credentials\n' >&2
	exit 1
	;;
esac
STUB
chmod +x "$stub/gh"

# --- the fixture: a bare origin, a clone, and one branch per answer ----------------------------

repo=$work/repo
git init -q --bare -b main "$work/origin.git"
git clone -q "$work/origin.git" "$repo"
git -C "$repo" config user.email worker@example.invalid
git -C "$repo" config user.name Test
git -C "$repo" config push.default simple
printf 'base\n' >"$repo/README"
git -C "$repo" add README
git -C "$repo" commit -qm "base"
git -C "$repo" push -q origin main

# merged-ff: an ancestor of origin/main, so `git branch --merged` sees it.
git -C "$repo" checkout -qb merged-ff
printf 'a\n' >"$repo/a"
git -C "$repo" add a
git -C "$repo" commit -qm "ff work"
git -C "$repo" push -q origin merged-ff
git -C "$repo" checkout -q main
git -C "$repo" merge -q --ff-only merged-ff
git -C "$repo" push -q origin main

# squashed and open-pr: merged by squash, so patch-identical to origin/main but never an ancestor.
# open-pr is the same shape with an open pull request on top, and must be kept anyway.
for branch in squashed open-pr; do
	git -C "$repo" checkout -qb "$branch"
	printf '%s\n' "$branch" >"$repo/$branch.file"
	git -C "$repo" add "$branch.file"
	git -C "$repo" commit -qm "$branch work"
	git -C "$repo" push -q origin "$branch"
	git -C "$repo" checkout -q main
	git -C "$repo" merge -q --squash "$branch"
	git -C "$repo" commit -qm "$branch work (#merged)"
	git -C "$repo" push -q origin main
done

# partial: the first commit is in trunk by patch, the second is not, so it is not dead.
git -C "$repo" checkout -qb partial
printf 'e\n' >"$repo/e"
git -C "$repo" add e
git -C "$repo" commit -qm "partial one"
printf 'f\n' >"$repo/f"
git -C "$repo" add f
git -C "$repo" commit -qm "partial two"
git -C "$repo" push -q origin partial
git -C "$repo" checkout -q main
git -C "$repo" merge -q --squash partial~1
git -C "$repo" commit -qm "partial one (#merged)"
git -C "$repo" push -q origin main

# pending: one commit that is on no remote and in no trunk.
git -C "$repo" checkout -qb pending
printf 'd\n' >"$repo/d"
git -C "$repo" add d
git -C "$repo" commit -qm "pending work"
git -C "$repo" checkout -q main

# Two worktrees: live-wt stays, wt-dead is deleted from disk and its entry is what prune removes.
git -C "$repo" worktree add -q "$work/live-wt" -b live-branch
printf 'h\n' >"$work/live-wt/h"
git -C "$work/live-wt" add h
git -C "$work/live-wt" commit -qm "live worktree work"
git -C "$repo" worktree add -q "$work/wt-dead" -b wt-dead
printf 'g\n' >"$work/wt-dead/g"
git -C "$work/wt-dead" add g
git -C "$work/wt-dead" commit -qm "worktree work"
rm -rf "$work/wt-dead"

# --- A. dry run is the default, and it proves everything before printing a plan ----------------

run -- --cwd "$repo"
want_rc 0 "dry run"
want_text "prune-refs: $repo, trunk origin/main" "trunk is read from origin/HEAD"
want_text "would delete branch merged-ff (ff work): merged into origin/main; PR #12 MERGED" \
	"a branch merged into trunk is listed with its subject and PR"
want_text "would delete branch squashed (squashed work): patch-identical to origin/main" \
	"a squash-merged branch is listed although it is not an ancestor"
want_text "kept branch pending (pending work): 1 commit(s) not in origin/main" \
	"a branch with an unpushed commit is kept with the reason"
want_text "kept branch partial (partial two): 1 commit(s) not in origin/main" \
	"a partially merged branch is kept with the reason"
want_text "kept branch open-pr (open-pr work): PR #11 is open" "a branch with an open PR is kept"
want_text "would prune worktree $work/wt-dead" "a worktree whose directory is gone is listed"
want_no_text "would prune worktree $work/live-wt" "a live worktree is not listed"
want_text "nothing changed" "the dry run says it changed nothing"
want_branch merged-ff present
want_branch squashed present
want_branch pending present

# A2. the current branch is never a candidate, even when it is dead by both proofs.
git -C "$repo" worktree add -q "$work/cur-wt" merged-ff
run -- --cwd "$work/cur-wt"
want_text "kept branch merged-ff (ff work): it is the current branch" \
	"the current branch is kept, in the worktree it is checked out in"
git -C "$repo" worktree remove --force "$work/cur-wt"

# --- B. --apply needs the second yes when nobody can answer a prompt ---------------------------

run -- --cwd "$repo" --apply
want_rc 2 "--apply with a non-interactive stdin"
want_text "--apply needs --yes" "the refusal names the flag that is missing"
want_branch merged-ff present
want_branch squashed present

# --- C. gh cannot answer: no branch is deleted, and it says which ones it would have checked ---

run GH_MODE=fail -- --cwd "$repo" --apply --yes
want_rc 0 "gh failing is not an error"
want_text "open-PR status unknown" "gh failing is reported"
want_text "kept branch squashed (squashed work): dead (patch-identical to origin/main (git cherry: all -))" \
	"a proven-dead branch is named as kept when open-PR status is unknown"
want_branch merged-ff present
want_branch squashed present
# A directory that no longer exists cannot come back through a pull request, so the worktree half is
# not gated on gh: it is pruned even here, and the test pins that on purpose.
want_text "pruned worktree $work/wt-dead" "a dead worktree is pruned even when gh cannot answer"
want_branch wt-dead present

# A second dead worktree, so the apply case below still has one to prune.
git -C "$repo" worktree add -q "$work/wt-dead2" -b wt-dead2
printf 'i\n' >"$work/wt-dead2/i"
git -C "$work/wt-dead2" add i
git -C "$work/wt-dead2" commit -qm "worktree work two"
rm -rf "$work/wt-dead2"

# --- D. --apply --yes deletes exactly the plan, and prunes exactly the dead worktree -----------

run -- --cwd "$repo" --apply --yes
want_rc 0 "apply with --yes"
want_text "deleted branch merged-ff (ff work)" "the merged branch is deleted"
want_text "deleted branch squashed (squashed work)" "the squash-merged branch is deleted"
want_text "pruned worktree $work/wt-dead2" "the dead worktree entry is pruned"
want_text "summary: deleted 2 branch(es), pruned 1 worktree(s)" "the summary counts what happened"
want_branch merged-ff gone
want_branch squashed gone
want_branch open-pr present
want_branch partial present
want_branch pending present
want_branch wt-dead present
if [ -d "$work/live-wt" ] && git -C "$repo" worktree list --porcelain | grep -qx "worktree $work/live-wt"; then
	pass "the live worktree and its directory are untouched"
else
	fail "the live worktree was pruned or its directory removed"
fi

# --- E. a second run finds nothing, and that is not an error ----------------------------------

run -- --cwd "$repo"
want_rc 0 "nothing left to do"
want_text "summary: 0 branch(es) and 0 worktree(s) would be deleted" "the second run lists nothing"
want_no_text "would delete" "the second run prints no plan"
want_no_text "would prune" "the second run prunes nothing"

# --- F. one --apply finishes: a merged branch held only by a dead worktree entry ---------------

# The worktree entry outlives its directory, so `git branch -D` still refuses the branch. Pruning
# the entry is what makes the deletion possible, so the apply phase prunes first and deletes after:
# one run, not two.
repo2=$work/repo2
git init -q --bare -b main "$work/origin2.git"
git clone -q "$work/origin2.git" "$repo2"
git -C "$repo2" config user.email worker@example.invalid
git -C "$repo2" config user.name Test
printf 'base\n' >"$repo2/README"
git -C "$repo2" add README
git -C "$repo2" commit -qm "base"
git -C "$repo2" push -q origin main
git -C "$repo2" worktree add -q "$work/held-wt" -b held-merged
printf 'x\n' >"$work/held-wt/x"
git -C "$work/held-wt" add x
git -C "$work/held-wt" commit -qm "held work"
git -C "$repo2" merge -q --ff-only held-merged
git -C "$repo2" push -q origin main
rm -rf "$work/held-wt"

run -- --cwd "$repo2" --apply --yes
want_rc 0 "one-pass apply"
want_no_text "git refused" "the branch is not left behind by a stale worktree entry"
want_text "deleted branch held-merged (held work)" \
	"a branch held only by a dead worktree entry is deleted in the same run"
want_text "pruned worktree $work/held-wt" "the dead worktree entry is pruned in that run"
if git -C "$repo2" worktree list --porcelain | grep -qx "worktree $work/held-wt"; then
	fail "the dead worktree entry is still registered"
else
	pass "the dead worktree entry is gone after one run"
fi
if git -C "$repo2" rev-parse --verify --quiet refs/heads/held-merged >/dev/null; then
	fail "branch held-merged is still there after one run, wanted gone"
else
	pass "branch held-merged is gone after one run"
fi
run -- --cwd "$repo2" --apply --yes
want_rc 0 "a second apply on the same repo"
want_text "summary: nothing deleted" "the second run reports nothing to do"

# --- G. the third proof: the pull request the host squash-merged --------------------------------

# squash-clean and squash-new are the case `git cherry` cannot answer: two commits squashed into one
# on trunk, so neither commit is on trunk by patch and both proofs fail. The pull request is the
# evidence, and the committer dates below are what its mergedAt is compared against.
repo3=$work/repo3
git init -q --bare -b main "$work/origin3.git"
git clone -q "$work/origin3.git" "$repo3"
git -C "$repo3" config user.email worker@example.invalid
git -C "$repo3" config user.name Test
# commit_at <date> <message>: a commit written on <date>, so the merge has a fixed order to compare.
commit_at() {
	GIT_COMMITTER_DATE="$1" GIT_AUTHOR_DATE="$1" git -C "$repo3" commit -qm "$2"
}

printf 'base\n' >"$repo3/README"
git -C "$repo3" add README
# Every branch carries this commit, so it is dated before every pull request below tells about: a
# commit written after the merge is what keeps a branch, and that is what these cases test.
commit_at "2019-12-29T00:00:00 +0000" "base"
git -C "$repo3" push -q origin main

# squash-clean: two commits in, one squashed commit on trunk, nothing written afterwards.
git -C "$repo3" checkout -qb squash-clean
for step in one two; do
	printf '%s\n' "$step" >"$repo3/clean-$step.file"
	git -C "$repo3" add "clean-$step.file"
	commit_at "2019-12-30T00:00:00 +0000" "squash-clean $step"
done
git -C "$repo3" push -q origin squash-clean
git -C "$repo3" checkout -q main
git -C "$repo3" merge -q --squash squash-clean
git -C "$repo3" commit -qm "squash-clean one and two (#21)"
git -C "$repo3" push -q origin main

# squash-new: the same shape, plus one commit written after its pull request had already merged.
git -C "$repo3" checkout -qb squash-new
for step in one two; do
	printf '%s\n' "$step" >"$repo3/new-$step.file"
	git -C "$repo3" add "new-$step.file"
	commit_at "2019-12-30T01:00:00 +0000" "squash-new $step"
done
git -C "$repo3" push -q origin squash-new
git -C "$repo3" checkout -q main
git -C "$repo3" merge -q --squash squash-new
git -C "$repo3" commit -qm "squash-new one and two (#22)"
git -C "$repo3" push -q origin main
git -C "$repo3" checkout -q squash-new
printf 'late\n' >"$repo3/new-late.file"
git -C "$repo3" add new-late.file
commit_at "2020-01-01T12:00:00 +0000" "squash-new late step"
git -C "$repo3" push -q origin squash-new
git -C "$repo3" checkout -q main
late_sha=$(git -C "$repo3" rev-parse --short squash-new)

run -- --cwd "$repo3"
want_rc 0 "the third proof on a dry run"
want_text "would delete branch squash-clean (squash-clean two): PR #21 MERGED 2020-01-02T00:00:00Z, head pushed, no commit after the merge" \
	"a branch whose pull request merged before its last commit is listed for deletion"
want_text "kept branch squash-new (squash-new late step)" \
	"a commit written after the merge keeps the branch"
want_text "commit $late_sha dated 2020-01-01T12:00:00Z was written after PR #22 merged at 2019-12-31T00:00:00Z" \
	"the kept branch names the commit that was written after the merge"
want_branch_in "$repo3" squash-clean present

# G2. gh cannot answer about one head: the branch stays, and the reason says gh gave nothing. Both
# shapes are pinned, an error and an empty answer, because "no output" must never read as "no pull
# request, so the merge is unopposed".
for mode in head-fail head-empty; do
	run GH_MODE=$mode -- --cwd "$repo3"
	want_rc 0 "gh silent about one head ($mode)"
	want_text "kept branch squash-clean (squash-clean two): 2 commit(s) not in origin/main, by patch (git cherry: +); gh gave nothing for this head" \
		"a head gh cannot answer about is kept and says so ($mode)"
done

# G3. and when it can answer, exactly that branch is deleted.
run -- --cwd "$repo3" --apply --yes
want_rc 0 "the third proof on --apply"
want_text "deleted branch squash-clean (squash-clean two): PR #21 MERGED 2020-01-02T00:00:00Z" \
	"the squash-merged branch is deleted with its pull request named"
want_branch_in "$repo3" squash-clean gone
want_branch_in "$repo3" squash-new present

printf '\n'
if [ "$fails" = 0 ]; then
	printf 'prune-refs: ok\n'
	exit 0
fi
printf 'prune-refs: %d FAILED\n' "$fails"
exit 1
