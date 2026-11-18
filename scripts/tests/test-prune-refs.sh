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
#   G4. The head comes from the pull request, not from `origin/<branch>`: a branch whose remote was
#      deleted by the merge is deleted when its local head is the `headRefOid` the PR reports; a head
#      that differs from it, a PR that reports no head sha, and two PRs on one head are all kept,
#      each naming the clause that held it.
#   G5. Clause 3 dates the branch's own commits, not the trunk history it was cut from: a branch cut
#      from a squash commit that is itself dated after its pull request's mergedAt is deleted, and a
#      branch with one commit genuinely written after mergedAt is still kept and names it.
#   H. A dead branch held by a checkout that is still there: a clean one is removed with the branch in
#      one run and nothing is left for a second; a dirty one keeps its branch and names the worktree;
#      a live delegation for that slug keeps both and says which worker; a live delegation whose
#      directory is gone keeps the record instead of pruning it; a registry file that is not there
#      protects nothing, and one that is unreadable stops the run.
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
# Every run gets a registry path of its own, so a fixture can never be protected (or deleted) by the
# real registry of the checkout this test is run from. A case that wants one passes
# `PRUNE_DELEGATIONS=...` in its env list, and env's last assignment wins.
registry=$work/no-registry.json
# run [env...] -- <args...> : prune-refs.sh against the fixture repo, stdin closed.
run() {
	local -a envs=()
	while [ $# -gt 0 ] && [ "$1" != "--" ]; do
		envs+=("$1")
		shift
	done
	[ "${1:-}" = "--" ] && shift
	out=$(env "PATH=$stub:$PATH" "PRUNE_DELEGATIONS=$registry" "${envs[@]+"${envs[@]}"}" bash "$script" "$@" </dev/null 2>&1)
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
# The fourth column is the pull request's `headRefOid`, read back from the fixture itself when it has
# to equal the local head — the host deletes `origin/<branch>` on merge, so that sha, not the
# remote-tracking ref, is what proves the merge saw this branch.
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
	local_head=$(git rev-parse --verify --quiet "refs/heads/$head" 2>/dev/null) || local_head=""
	case $mode in
	ok)
		case $head in
		squash-clean) printf '21\tMERGED\t2020-01-02T00:00:00Z\t%s\n' "$local_head" ;;
		squash-gone) printf '31\tMERGED\t2020-01-02T00:00:00Z\t%s\n' "$local_head" ;;
		squash-new) printf '22\tMERGED\t2019-12-31T00:00:00Z\t%s\n' "$local_head" ;;
		squash-cut) printf '41\tMERGED\t2020-01-02T00:00:00Z\t%s\n' "$local_head" ;;
		squash-cut-late) printf '42\tMERGED\t2020-01-02T00:00:00Z\t%s\n' "$local_head" ;;
		head-mismatch) printf '33\tMERGED\t2020-01-02T00:00:00Z\t0123456789abcdef0123456789abcdef01234567\n' ;;
		head-none) printf '34\tMERGED\t2020-01-02T00:00:00Z\t\n' ;;
		head-two)
			printf '35\tMERGED\t2020-01-02T00:00:00Z\t%s\n' "$local_head"
			printf '36\tMERGED\t2020-01-03T00:00:00Z\t%s\n' "$local_head"
			;;
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
	printf '31\tsquash-gone\tMERGED\n'
	printf '33\thead-mismatch\tMERGED\n'
	printf '34\thead-none\tMERGED\n'
	printf '35\thead-two\tMERGED\n'
	printf '41\tsquash-cut\tMERGED\n'
	printf '42\tsquash-cut-late\tMERGED\n'
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
# The branches added below are cut from this commit, not from trunk's tip: a trunk commit dated after
# a pull request merged is not new work on the branch (see "Still open" in the report).
base_sha=$(git -C "$repo3" rev-parse main)

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

# squash-gone: the ordinary end of a merged branch. The host deletes origin/<branch> when it merges,
# so there is no remote-tracking ref left to compare the local head with; the pull request's own
# `headRefOid` is the only witness that the merge saw this branch.
git -C "$repo3" checkout -qb squash-gone "$base_sha"
for step in one two; do
	printf '%s\n' "$step" >"$repo3/gone-$step.file"
	git -C "$repo3" add "gone-$step.file"
	commit_at "2019-12-30T02:00:00 +0000" "squash-gone $step"
done
git -C "$repo3" push -q origin squash-gone
git -C "$repo3" checkout -q main
git -C "$repo3" merge -q --squash squash-gone
git -C "$repo3" commit -qm "squash-gone one and two (#31)"
git -C "$repo3" push -q origin main
git -C "$repo3" push -q origin --delete squash-gone

# head-mismatch, head-none and head-two: the three shapes where the pull request cannot say the head
# here is the head it merged. None is pushed, so nothing on a remote can rescue them.
for shape in mismatch none two; do
	git -C "$repo3" checkout -qb "head-$shape" "$base_sha"
	printf '%s\n' "$shape" >"$repo3/$shape.file"
	git -C "$repo3" add "$shape.file"
	commit_at "2019-12-30T03:00:00 +0000" "head-$shape work"
done
git -C "$repo3" checkout -q main
mismatch_head=$(git -C "$repo3" rev-parse --short head-mismatch)

run -- --cwd "$repo3"
want_rc 0 "the third proof on a dry run"
want_text "would delete branch squash-clean (squash-clean two): PR #21 MERGED 2020-01-02T00:00:00Z, head is the merged head, no commit after the merge" \
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

# --- G4. the merged head is read from the pull request, not from the ref the merge deletes -------

# The host deletes origin/<branch> when it merges, so clause 2 has to be satisfied by the head the
# pull request says it merged. squash-gone has no remote-tracking ref at all and is still deleted;
# the three head-* branches are the ways that clause refuses to answer.
run -- --cwd "$repo3"
want_rc 0 "the head comes from the pull request"
if git -C "$repo3" rev-parse --verify --quiet refs/remotes/origin/squash-gone >/dev/null; then
	fail "origin/squash-gone still exists, so the case does not test a deleted remote"
else
	pass "the fixture has no origin/squash-gone, as a merged branch has none"
fi
want_text "would delete branch squash-gone (squash-gone two): PR #31 MERGED 2020-01-02T00:00:00Z, head is the merged head, no commit after the merge" \
	"a merged branch whose remote is gone is deleted by the head the pull request reports"
want_branch_in "$repo3" squash-gone present
want_text "kept branch head-mismatch (head-mismatch work)" "a head that is not the merged head is kept"
want_text "merged head 0123456 is not this branch's head $mismatch_head, so it carries work the merge never saw" \
	"the refusal names both shas"
want_text "kept branch head-none (head-none work)" "a pull request with no head sha keeps the branch"
want_text "the pull request does not report a head sha" "the refusal says the head sha is missing"
want_text "kept branch head-two (head-two work)" "two pull requests on one head keep the branch"
want_text "2 pull requests on this head, so which one merged is ambiguous" \
	"the refusal says the two pull requests are ambiguous"
want_branch_in "$repo3" head-mismatch present
want_branch_in "$repo3" head-none present
want_branch_in "$repo3" head-two present

# G3. and when it can answer, exactly that branch is deleted.
run -- --cwd "$repo3" --apply --yes
want_rc 0 "the third proof on --apply"
want_text "deleted branch squash-clean (squash-clean two): PR #21 MERGED 2020-01-02T00:00:00Z" \
	"the squash-merged branch is deleted with its pull request named"
want_text "deleted branch squash-gone (squash-gone two): PR #31 MERGED 2020-01-02T00:00:00Z" \
	"the branch with no remote-tracking ref is deleted by the same proof"
want_branch_in "$repo3" squash-clean gone
want_branch_in "$repo3" squash-gone gone
want_branch_in "$repo3" squash-new present
want_branch_in "$repo3" head-mismatch present
want_branch_in "$repo3" head-none present
want_branch_in "$repo3" head-two present

# --- G5. clause 3 dates the branch's own commits, not the trunk it was cut from ------------------

# A branch is cut from trunk's tip, and that tip can be the squash commit of a pull request that
# merged *after* this branch's own pull request did. The base commit is then dated after this
# branch's mergedAt, and a proof that dates the branch's whole history calls it work written after
# the merge: a false keep. Only the commits the branch has that trunk does not are its own.
repo6=$work/repo6
git init -q --bare -b main "$work/origin6.git"
git clone -q "$work/origin6.git" "$repo6"
git -C "$repo6" config user.email worker@example.invalid
git -C "$repo6" config user.name Test
commit_at6() {
	GIT_COMMITTER_DATE="$1" GIT_AUTHOR_DATE="$1" git -C "$repo6" commit -qm "$2"
}
printf 'base\n' >"$repo6/README"
git -C "$repo6" add README
commit_at6 "2019-12-29T00:00:00 +0000" "base"
git -C "$repo6" push -q origin main

# The trunk commit every branch below is cut from: the squash of pull request #40, dated 2020-01-05,
# which is later than both of their mergedAt dates.
git -C "$repo6" checkout -qb cut-trunk
printf 't\n' >"$repo6/t.file"
git -C "$repo6" add t.file
commit_at6 "2019-12-30T00:00:00 +0000" "cut-trunk one"
git -C "$repo6" checkout -q main
git -C "$repo6" merge -q --squash cut-trunk
commit_at6 "2020-01-05T00:00:00 +0000" "cut-trunk one (#40)"
git -C "$repo6" push -q origin main
git -C "$repo6" branch -qD cut-trunk
cut_base=$(git -C "$repo6" rev-parse main)

# squash-cut: cut from that commit, nothing of its own written after its mergedAt (2020-01-02).
# Clause 3 must delete it; dating its whole history keeps it on the base commit's 2020-01-05.
git -C "$repo6" checkout -qb squash-cut "$cut_base"
for step in one two; do
	printf '%s\n' "$step" >"$repo6/cut-$step.file"
	git -C "$repo6" add "cut-$step.file"
	commit_at6 "2019-12-31T00:00:00 +0000" "squash-cut $step"
done
git -C "$repo6" push -q origin squash-cut
git -C "$repo6" checkout -q main

# squash-cut-late: the same cut, plus one commit genuinely written after mergedAt. That commit is
# the branch's own, so the narrowed clause still keeps it and still names the commit.
git -C "$repo6" checkout -qb squash-cut-late "$cut_base"
for step in one; do
	printf '%s\n' "$step" >"$repo6/late-$step.file"
	git -C "$repo6" add "late-$step.file"
	commit_at6 "2019-12-31T00:00:00 +0000" "squash-cut-late $step"
done
printf 'late\n' >"$repo6/late-late.file"
git -C "$repo6" add late-late.file
commit_at6 "2020-01-04T00:00:00 +0000" "squash-cut-late late step"
git -C "$repo6" push -q origin squash-cut-late
git -C "$repo6" checkout -q main
cut_late_sha=$(git -C "$repo6" rev-parse --short squash-cut-late)

run -- --cwd "$repo6"
want_rc 0 "the narrowed third proof on a dry run"
want_text "would delete branch squash-cut (squash-cut two): PR #41 MERGED 2020-01-02T00:00:00Z, head is the merged head, no commit after the merge" \
	"a branch cut from a later trunk commit is deleted, because that commit is not its own"
want_branch_in "$repo6" squash-cut present
want_text "kept branch squash-cut-late (squash-cut-late late step)" \
	"a branch with its own commit after the merge is still kept"
want_text "commit $cut_late_sha dated 2020-01-04T00:00:00Z was written after PR #42 merged at 2020-01-02T00:00:00Z" \
	"the narrowed clause still names the commit written after the merge"
want_branch_in "$repo6" squash-cut-late present

# and the apply phase deletes exactly the one it listed.
run -- --cwd "$repo6" --apply --yes
want_rc 0 "the narrowed third proof on --apply"
want_text "deleted branch squash-cut (squash-cut two): PR #41 MERGED 2020-01-02T00:00:00Z" \
	"the branch cut from a later trunk commit is deleted"
want_branch_in "$repo6" squash-cut gone
want_branch_in "$repo6" squash-cut-late present

# --- H. a dead branch held by a checkout that is still there -----------------------------------

# This is what every worker that cut `.worktrees/SLUG` leaves behind: a real directory holding a
# merged branch. `git branch -D` refuses it, so without this the same branches are listed as
# `would delete` on every run and never go away.
repo4=$work/repo4
git init -q --bare -b main "$work/origin4.git"
git clone -q "$work/origin4.git" "$repo4"
git -C "$repo4" config user.email worker@example.invalid
git -C "$repo4" config user.name Test
printf 'base\n' >"$repo4/README"
git -C "$repo4" add README
git -C "$repo4" commit -qm "base"
git -C "$repo4" push -q origin main

# held-clean: a clean checkout of a branch that is an ancestor of origin/main.
git -C "$repo4" worktree add -q "$work/held-clean" -b fix/held-clean
printf 'y\n' >"$work/held-clean/y"
git -C "$work/held-clean" add y
git -C "$work/held-clean" commit -qm "held clean work"
git -C "$repo4" merge -q --ff-only fix/held-clean
git -C "$repo4" push -q origin main

# H1. the listing says what the apply phase will do to the checkout, and one run does all of it.
run -- --cwd "$repo4"
want_rc 0 "a dead branch held by a clean checkout, dry run"
want_text "would delete branch fix/held-clean (held clean work): merged into origin/main and its worktree $work/held-clean" \
	"the plan names the worktree that is removed with the branch"
want_branch_in "$repo4" fix/held-clean present

run -- --cwd "$repo4" --apply --yes
want_rc 0 "one apply removes the checkout and the branch"
want_no_text "git refused" "the branch is not left behind by the checkout holding it"
want_text "removed worktree $work/held-clean" "the clean checkout is removed"
want_text "deleted branch fix/held-clean (held clean work)" "the branch it held is deleted in the same run"
if [ -d "$work/held-clean" ]; then
	fail "the checkout directory is still on disk"
else
	pass "the checkout directory is gone"
fi
if git -C "$repo4" worktree list --porcelain | grep -qx "worktree $work/held-clean"; then
	fail "the worktree entry is still registered"
else
	pass "the worktree entry is gone after one run"
fi
want_branch_in "$repo4" fix/held-clean gone

run -- --cwd "$repo4" --apply --yes
want_rc 0 "the second run on the same repo"
want_text "summary: nothing deleted" "the second run reprints nothing as deleted"

# --- H2. the same, but the checkout has work the removal would destroy ---------------------------

repo5=$work/repo5
git init -q --bare -b main "$work/origin5.git"
git clone -q "$work/origin5.git" "$repo5"
git -C "$repo5" config user.email worker@example.invalid
git -C "$repo5" config user.name Test
printf 'base\n' >"$repo5/README"
git -C "$repo5" add README
git -C "$repo5" commit -qm "base"
git -C "$repo5" push -q origin main

git -C "$repo5" worktree add -q "$work/held-dirty" -b fix/held-dirty
printf 'z\n' >"$work/held-dirty/z"
git -C "$work/held-dirty" add z
git -C "$work/held-dirty" commit -qm "held dirty work"
git -C "$repo5" merge -q --ff-only fix/held-dirty
git -C "$repo5" push -q origin main
# An untracked file is the shape git refuses to remove without --force, and the shape a worker leaves.
printf 'uncommitted\n' >"$work/held-dirty/local-notes.txt"

run -- --cwd "$repo5" --apply --yes
want_rc 0 "a dead branch held by a dirty checkout"
want_text "kept branch fix/held-dirty (held dirty work): worktree $work/held-dirty holds uncommitted changes, so the branch is kept" \
	"a dirty checkout keeps its branch and names the worktree"
want_no_text "removed worktree" "a dirty checkout is never removed, not even with --force"
want_branch_in "$repo5" fix/held-dirty present
if [ -d "$work/held-dirty" ] && [ -f "$work/held-dirty/local-notes.txt" ]; then
	pass "the dirty checkout and its untracked file are untouched"
else
	fail "the dirty checkout or its untracked file was removed"
fi

# --- H3. a live delegation outranks the delete proof -------------------------------------------

# The slug is what the directory and the branch both carry: `held-dirty` names
# `.worktrees/held-dirty` in the real checkout, and `fix/held-dirty` here.
printf '{\n  "held-dirty": {"slug": "held-dirty", "cwd": "%s"}\n}\n' "$repo5" >"$work/delegations.json"
run PRUNE_DELEGATIONS="$work/delegations.json" -- --cwd "$repo5" --apply --yes
want_rc 0 "a live worker holding the branch"
want_text "kept branch fix/held-dirty (held dirty work): live worker held-dirty holds $work/held-dirty, so it is kept" \
	"a live worker keeps its branch and is named"
want_no_text "removed worktree" "a live worker's checkout is not removed"
want_branch_in "$repo5" fix/held-dirty present
if [ -d "$work/held-dirty" ]; then pass "a live worker's checkout is still on disk"; else fail "a live worker's checkout was removed"; fi

# H3b. the same guard on the dead-entry half: a record whose directory is gone is kept, not pruned,
# because pruning it is what makes the branch deletable.
git -C "$repo5" worktree add -q "$work/held-gone" -b fix/held-gone
printf 'w\n' >"$work/held-gone/w"
git -C "$work/held-gone" add w
git -C "$work/held-gone" commit -qm "held gone work"
git -C "$repo5" merge -q --ff-only fix/held-gone
git -C "$repo5" push -q origin main
rm -rf "$work/held-gone"
printf '{\n  "held-dirty": {"slug": "held-dirty"},\n  "held-gone": {"slug": "held-gone"}\n}\n' >"$work/delegations.json"
run PRUNE_DELEGATIONS="$work/delegations.json" -- --cwd "$repo5" --apply --yes
want_rc 0 "a live worker whose directory is gone"
want_text "kept worktree $work/held-gone: live worker held-gone holds it, so it is kept" \
	"a live worker's dead worktree record is kept and named"
want_no_text "pruned worktree $work/held-gone" "a live worker's worktree record is not pruned"
want_text "kept branch fix/held-gone: git refused (error: cannot delete branch 'fix/held-gone' used by worktree at '$work/held-gone')" \
	"the branch that record holds stays, with git's own reason"
want_branch_in "$repo5" fix/held-gone present

# --- H4. no registry, no protection — and an unreadable one stops the run ------------------------

run PRUNE_DELEGATIONS="$work/not-a-registry.json" -- --cwd "$repo5" --apply --yes
want_rc 0 "a registry file that is not there"
want_text "no worker registry at $work/not-a-registry.json, so no live worker is protected" \
	"a missing registry is said out loud"
want_text "pruned worktree $work/held-gone" "a missing registry protects nothing: the record is pruned"
want_text "deleted branch fix/held-gone" "a missing registry protects nothing: the branch is deleted"
want_branch_in "$repo5" fix/held-gone gone
want_branch_in "$repo5" fix/held-dirty present
want_text "worktree $work/held-dirty holds uncommitted changes" \
	"the other branch is kept by its changes, not by a guard that does not exist"

printf 'nonsense, not json\n' >"$work/broken-registry.json"
run PRUNE_DELEGATIONS="$work/broken-registry.json" -- --cwd "$repo5" --apply --yes
want_rc 2 "a registry that exists and cannot be read"
want_text "is not readable JSON, so a live worker would not be protected" \
	"an unreadable registry stops the run and says why"
want_no_text "deleted branch" "an unreadable registry deletes nothing"

printf '\n'
if [ "$fails" = 0 ]; then
	printf 'prune-refs: ok\n'
	exit 0
fi
printf 'prune-refs: %d FAILED\n' "$fails"
exit 1
