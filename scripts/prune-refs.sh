#!/usr/bin/env bash
# prune-refs.sh — one command that lists the local branches and worktree entries in a checkout that
# nobody can use any more, and deletes exactly those when asked twice.
#
# Why it exists: a merged worker leaves its branch behind, and `git worktree list` keeps entries
# whose directory is long gone. Every `git branch`, `git status` and `git log --all` in the repo then
# reads them, so the next worker misleads itself with work that already landed.
#
#   bash scripts/prune-refs.sh --cwd ~/.pi                          list them, change nothing
#   bash scripts/prune-refs.sh --cwd ~/.pi --apply --yes            delete exactly what it listed
#
# Three proofs, and only three, make a branch dead — everything else is kept and says why:
#   * ancestry: `git branch --merged origin/<trunk>` lists it; or
#   * squash-equivalence: `git cherry origin/<trunk> <branch>` marks every one of its commits `-`,
#     meaning the patch is already upstream under another sha; or
#   * squash-merge: GitHub's pull request for that head is MERGED, the local head is the head that
#     pull request merged (its `headRefOid`), and none of the commits the branch has that trunk does
#     not was written after that merge.
# The second is not decoration: this repo squash-merges, so a branch merged through a PR is never an
# ancestor of trunk. It is the same check bin/publish's duplicate guard and `delegate close --merged`
# trust. One `+` line — a commit whose patch is not in trunk, pushed or not — and the branch stays.
#
# The third exists because the first two cannot answer a merge commit or a multi-commit pull request
# squashed into one: a merge commit has no patch to match, and the squashed commits were rewritten on
# trunk, so `git cherry` marks them `+` and the branch was kept forever. There the evidence is the
# pull request itself, and it has to promise three things at once — MERGED, the head here is the
# head it merged, and nothing the branch wrote itself was committed after the merge. The branch's own
# work is `git log <branch> --not origin/<trunk>`: the commits it has that trunk does not. The base
# commits it was cut from are trunk's history, and trunk's tip can be a squash commit dated after
# this branch's own mergedAt — dating the whole history read that as a late commit and kept a dead
# branch forever. The head comes from the pull request,
# not from `origin/<branch>`: the host deletes that remote branch when it merges, so a ref that is
# gone proves nothing — a live remote-tracking ref that still equals the local head is accepted too,
# because that is the common case and it means the same thing. Anything else the pull request cannot
# settle (`gh` missing or silent, no pull request, two or more, a state that is not MERGED, an
# unreadable `mergedAt`) keeps the branch and prints the clause that held it. It never falls through
# to the delete path.
#
# Never deleted, whatever the proofs say: the current branch, the trunk, a branch with an open pull
# request, and any branch at all while `gh` cannot answer (its open-PR status is then unknown, and
# the branches it would have checked are printed instead).
#
# A worktree entry is dead only when its directory does not exist; `git worktree prune` removes the
# entry, never a directory. That half is not gated on `gh`: a directory that is gone cannot come back
# through a pull request, so it is pruned even when the open-PR question went unanswered.
#
# A directory that is still there is a checkout, and a dead branch is often held by one: every worker
# that cut `.worktrees/SLUG` leaves its checkout behind, and `git branch -D` refuses the branch until
# that checkout is gone, so the same three branches came back on every run. --apply removes the
# checkout with `git worktree remove` in the same run, then deletes the branch. It never forces: a
# checkout with changes the tool would destroy (modified or untracked files) keeps its branch and
# names the worktree that held it.
#
# What outranks every proof is a live worker. state/delegations.json (`$PRUNE_DELEGATIONS`, default
# `<boss root>/state/delegations.json`) lists the workers cmd_close has not deleted yet; a worktree
# whose directory name or branch names one of them is kept, and so is a record of one whose directory
# is gone. A registry that exists and cannot be read stops the run rather than delete without
# protection. No registry file, no protection — a choice, and the run says so out loud.
#
# --apply prunes the dead worktree entries first and deletes the branches after: a merged branch can
# still be held by an entry whose directory is gone, and `git branch -D` refuses it until that entry
# is gone. One run finishes, where pruning last left the deletion for a second invocation.
#
#   exit 0  nothing to do, or the list was printed, or everything printed was deleted
#   exit 2  bad usage, no origin/<trunk> to compare against, --apply without the second yes, or a
#           worker registry that exists but cannot be read
set -uo pipefail

usage() {
	printf 'usage: bash scripts/prune-refs.sh [--cwd DIR] [--apply [--yes]]\n' >&2
	printf '  (no flags)   print what is dead; change nothing\n' >&2
	printf '  --cwd DIR    the checkout to look at (default: the current directory)\n' >&2
	printf '  --apply      delete the branches and worktrees listed; asks first\n' >&2
	printf '  --yes        skip the confirmation, for a script that has already decided\n' >&2
	printf '  PRUNE_DELEGATIONS=FILE  worker registry to keep clear of (default <boss root>/state/delegations.json);\n' >&2
	printf '               no registry, no protection: a file that is not there guards nothing\n' >&2
	exit 2
}

die() {
	printf 'prune-refs: %s\n' "$*" >&2
	exit 2
}

cwd=.
apply=0
yes=0
while [ $# -gt 0 ]; do
	case $1 in
	--cwd) [ $# -ge 2 ] || usage; cwd=$2; shift 2 ;;
	--cwd=*) cwd=${1#--cwd=}; shift ;;
	--apply) apply=1; shift ;;
	--yes) yes=1; shift ;;
	-h | --help) usage ;;
	*)
		printf 'prune-refs: unknown argument: %s\n' "$1" >&2
		usage
		;;
	esac
done
[ -n "$cwd" ] || usage
[ -d "$cwd" ] || die "no such directory: $cwd"
cwd=$(cd -- "$cwd" && pwd) || die "cannot read $cwd"
git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1 || die "not a git checkout: $cwd"

# --- what we compare against -------------------------------------------------------------------

# The trunk is whatever origin/HEAD points at, and the two checkouts here name it differently
# (`trunk` in ~/.pi, `main` here), so it is never hardcoded.
trunk=$(git -C "$cwd" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) || trunk=""
trunk=${trunk#origin/}
if [ -z "$trunk" ] || ! git -C "$cwd" rev-parse --verify --quiet "refs/remotes/origin/$trunk" >/dev/null; then
	trunk=""
	for candidate in trunk main master; do
		if git -C "$cwd" rev-parse --verify --quiet "refs/remotes/origin/$candidate" >/dev/null; then
			trunk=$candidate
			break
		fi
	done
fi
[ -n "$trunk" ] || die "no origin/<trunk> in $cwd to compare against: fetch, or the remote is not named origin"
upstream="refs/remotes/origin/$trunk"

current=$(git -C "$cwd" symbolic-ref --quiet --short HEAD 2>/dev/null) || current=""

printf 'prune-refs: %s, trunk origin/%s\n' "$cwd" "$trunk"

# --- which workers are still live ------------------------------------------------------------

# The boss root is the checkout the registry belongs to, not the checkout this copy of the script
# sits in: a worker runs its own worktree's script, and the workers being protected are the boss's.
# `git rev-parse --git-common-dir` is absolute from a worktree and `.git` from the main checkout, so
# the two spellings are the two cases.
script_dir=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")" && pwd)
common=$(git -C "$script_dir/.." rev-parse --git-common-dir 2>/dev/null) || common=""
case $common in
/*) root=$(dirname -- "$common") ;;
*) root=$(cd -- "$script_dir/.." && pwd) || root=$script_dir ;;
esac
delegations=${PRUNE_DELEGATIONS:-$root/state/delegations.json}

# A slug in the registry is a worker that has not been closed: cmd_close deletes the entry when it
# ends a space. Its checkout is the only directory that keeps the worker alive, so removing one of
# those is the mistake that cost two spaces earlier. The registry is read before anything is
# deleted, and unreadable means stopped, never unprotected.
declare -A live_slug=()
if [ -f "$delegations" ]; then
	if ! command -v node >/dev/null 2>&1; then
		die "cannot read the worker registry $delegations (node is not on PATH), so a live worker would not be protected"
	fi
	if ! live_slugs=$(node -e '
		const fs = require("fs");
		let j = {};
		try { j = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch (e) { process.exit(3); }
		Object.keys(j || {}).forEach((k) => process.stdout.write(k + "\n"));' "$delegations" 2>/dev/null); then
		die "the worker registry $delegations is not readable JSON, so a live worker would not be protected"
	fi
	while IFS= read -r slug; do
		[ -n "$slug" ] && live_slug[$slug]=1
	done <<<"$live_slugs"
fi

# live_worker_for <path> <branch> — the slug of a live worker holding this worktree, or nothing.
# A checkout is named after its slug (`<repo>/.worktrees/SLUG`, or the older `SLUG-worktree` beside
# the repo) and a worker's branch ends in it, so every one of those spellings is tried.
live_worker_for() {
	local path=$1 branch=$2 base cand
	base=$(basename -- "$path")
	for cand in "$base" "${base%-worktree}" "${branch##*/}"; do
		[ -n "$cand" ] || continue
		if [ -n "${live_slug[$cand]:-}" ]; then
			printf '%s' "$cand"
			return 0
		fi
	done
	return 0
}

# --- the open-PR question, asked once for every branch ------------------------------------------

declare -A pr_number=() pr_state=()
gh_unknown=""
if ! command -v gh >/dev/null 2>&1; then
	gh_unknown="gh is not on PATH"
else
	template='{{range .}}{{.number}}{{"\t"}}{{.headRefName}}{{"\t"}}{{.state}}{{"\n"}}{{end}}'
	if pr_lines=$(cd "$cwd" && gh pr list --state all --limit 500 \
		--json number,headRefName,state --template "$template" 2>&1); then
		while IFS=$'\t' read -r number head state; do
			[ -n "${head:-}" ] || continue
			pr_number[$head]=$number
			pr_state[$head]=$state
		done <<<"$pr_lines"
	else
		gh_unknown=$(printf '%s' "$pr_lines" | head -n 1)
		[ -n "$gh_unknown" ] || gh_unknown="gh pr list failed"
	fi
fi
if [ -n "$gh_unknown" ]; then
	printf 'prune-refs: open-PR status unknown (%s), so no branch is deleted\n' "$gh_unknown"
fi

# --- which branches are dead -------------------------------------------------------------------

# `git branch --merged` prints the current branch and the trunk too; both are filtered by name below
# rather than by trusting that list, so a detached checkout cannot smuggle either one in.
# squash_evidence <branch> — the third proof, on stdout as one tab-separated line:
# `ok<TAB><proof>` when the branch is provably squash-merged, `no<TAB><reason>` otherwise. Every
# ambiguity is a `no`, because guessing here deletes work.
squash_evidence() {
	local branch=$1 list n number state merged_at head_oid epoch local_head remote_head worst when after
	local template='{{range .}}{{.number}}{{"\t"}}{{.state}}{{"\t"}}{{.mergedAt}}{{"\t"}}{{.headRefOid}}{{"\n"}}{{end}}'
	if ! list=$(cd "$cwd" && gh pr list --head "$branch" --state all --limit 100 \
		--json number,state,mergedAt,headRefOid --template "$template" 2>&1); then
		printf 'no\tgh gave nothing for this head: %s' "$(printf '%s' "$list" | head -n 1)"
		return 0
	fi
	n=$(printf '%s\n' "$list" | grep -c . 2>/dev/null) || n=0
	if [ "$n" -eq 0 ]; then
		printf 'no\tgh gave nothing for this head: no pull request listed'
		return 0
	fi
	if [ "$n" -gt 1 ]; then
		printf 'no\t%s pull requests on this head, so which one merged is ambiguous' "$n"
		return 0
	fi
	IFS=$'\t' read -r number state merged_at head_oid <<<"$list"
	if [ "$state" != MERGED ]; then
		printf 'no\tPR #%s is %s, not MERGED' "$number" "${state:-unknown}"
		return 0
	fi
	epoch=$(date -u -d "$merged_at" +%s 2>/dev/null) || epoch=""
	if [ -z "$epoch" ]; then
		printf 'no\tPR #%s has no readable mergedAt (%s)' "$number" "${merged_at:-empty}"
		return 0
	fi
	# The head the pull request merged is the witness, because the merge deletes origin/<branch>.
	# A live remote-tracking ref that still equals the local head is the same clause by another road.
	local_head=$(git -C "$cwd" rev-parse --verify --quiet "refs/heads/$branch") || local_head=""
	remote_head=$(git -C "$cwd" rev-parse --verify --quiet "refs/remotes/origin/$branch") || remote_head=""
	if [ -n "$head_oid" ] && [ "$local_head" = "$head_oid" ]; then
		:
	elif [ -n "$remote_head" ] && [ "$local_head" = "$remote_head" ]; then
		:
	elif [ -z "$head_oid" ]; then
		printf 'no\tthe pull request does not report a head sha, so the merge cannot be matched to this head'
		return 0
	else
		printf "no\tmerged head %s is not this branch's head %s, so it carries work the merge never saw" \
			"$(printf '%s' "$head_oid" | cut -c1-7)" "$(printf '%s' "$local_head" | cut -c1-7)"
		return 0
	fi
	worst=$(git -C "$cwd" log --format='%ct %H' "$branch" --not "$upstream" 2>/dev/null |
		awk -v m="$epoch" '$1 > m { print $1 " " $2; exit }') || worst=""
	if [ -n "$worst" ]; then
		read -r when after <<<"$worst"
		printf 'no\tcommit %s dated %s was written after PR #%s merged at %s' \
			"$(printf '%s' "$after" | cut -c1-7)" \
			"$(date -u -d "@$when" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '%s' "$when")" \
			"$number" "$merged_at"
		return 0
	fi
	printf 'ok\tPR #%s %s %s, head is the merged head, no commit after the merge' \
		"$number" "$state" "$merged_at"
}

declare -A by_ancestry=()
while IFS= read -r name; do
	[ -n "$name" ] && by_ancestry[$name]=1
done < <(git -C "$cwd" branch --merged "$upstream" --format='%(refname:short)' 2>/dev/null)

# --- which worktree entries are dead, and which hold a branch -------------------------------------

# `git worktree list --porcelain` repeats `worktree <path>` and `branch refs/heads/<name>` per entry.
# A path whose directory is gone is the only thing `git worktree prune` removes. A path that is still
# there is a checkout, and a checkout is exactly what makes `git branch -D` refuse the branch it has.
wt_paths=()
wt_branches=()
wt_path=""
wt_branch=""
while IFS= read -r line; do
	case $line in
	worktree\ *)
		if [ -n "$wt_path" ]; then
			wt_paths+=("$wt_path")
			wt_branches+=("$wt_branch")
		fi
		wt_path=${line#worktree }
		wt_branch=""
		;;
	branch\ refs/heads/*) wt_branch=${line#branch refs/heads/} ;;
	esac
done < <(git -C "$cwd" worktree list --porcelain 2>/dev/null)
if [ -n "$wt_path" ]; then
	wt_paths+=("$wt_path")
	wt_branches+=("$wt_branch")
fi

kept=0
declare -A wt_holder=() live_holds=()
dead_worktrees=()
for i in "${!wt_paths[@]}"; do
	path=${wt_paths[$i]}
	branch=${wt_branches[$i]}
	slug=$(live_worker_for "$path" "$branch")
	if [ -e "$path" ]; then
		# The boss's own checkout is never removed here, whatever a proof says about its branch.
		[ "$path" = "$cwd" ] && continue
		[ -n "$slug" ] && live_holds[$path]=$slug
		[ -n "$branch" ] && wt_holder[$branch]=$path
	elif [ -n "$slug" ]; then
		# A record of a live worker whose directory is gone: the worker may still be writing into
		# it, and a pruned record is the one thing that makes the branch deletable. Keep it.
		printf 'kept worktree %s: live worker %s holds it, so it is kept\n' "$path" "$slug"
		kept=$((kept + 1))
	else
		dead_worktrees+=("$path")
	fi
done
if [ ! -f "$delegations" ] && [ ${#wt_paths[@]} -gt 0 ]; then
	printf 'prune-refs: no worker registry at %s, so no live worker is protected\n' "$delegations"
fi

dead_branches=()
declare -A dead_detail=() wt_remove=()
holder=""
for name in $(git -C "$cwd" for-each-ref --format='%(refname:short)' refs/heads/); do
	[ "$name" = "$trunk" ] && continue
	subject=$(git -C "$cwd" log -1 --format=%s "$name" 2>/dev/null) || subject=""
	[ -n "$subject" ] || subject="no commit subject"
	note=""
	if [ -n "${pr_number[$name]:-}" ]; then
		note="; PR #${pr_number[$name]} ${pr_state[$name]:-unknown}"
	fi
	if [ -n "$current" ] && [ "$name" = "$current" ]; then
		printf 'kept branch %s (%s): it is the current branch\n' "$name" "$subject"
		kept=$((kept + 1))
		continue
	fi
	if [ "${pr_state[$name]:-}" = OPEN ]; then
		printf 'kept branch %s (%s): PR #%s is open\n' "$name" "$subject" "${pr_number[$name]}"
		kept=$((kept + 1))
		continue
	fi
	proof=""
	reason=""
	if [ -n "${by_ancestry[$name]:-}" ]; then
		proof="merged into origin/$trunk"
	elif ! cherry=$(git -C "$cwd" cherry "$upstream" "$name" 2>/dev/null); then
		reason="git cherry could not compare it with origin/$trunk"
	elif [ -z "$cherry" ]; then
		reason="no commits to compare with origin/$trunk"
	else
		wanting=0
		while read -r mark _; do
			[ "$mark" = "+" ] && wanting=$((wanting + 1))
		done <<<"$cherry"
		if [ "$wanting" -gt 0 ]; then
			reason="$wanting commit(s) not in origin/$trunk, by patch (git cherry: +)"
		else
			proof="patch-identical to origin/$trunk (git cherry: all -)"
		fi
	fi
	# The third proof runs only where the first two failed and GitHub says this head merged: a
	# branch it cannot settle keeps the reason from above plus the clause that held it.
	if [ -z "$proof" ] && [ -z "$gh_unknown" ] && [ "${pr_state[$name]:-}" = MERGED ]; then
		squash=$(squash_evidence "$name")
		case $squash in
		ok$'\t'*)
			proof=${squash#ok$'\t'}
			note=""
			;;
		no$'\t'*)
			clause=${squash#no$'\t'}
			reason=${reason:+"$reason; "}$clause
			;;
		esac
	fi
	if [ -z "$proof" ]; then
		printf 'kept branch %s (%s): %s%s\n' "$name" "$subject" "$reason" "$note"
		kept=$((kept + 1))
		continue
	fi
	if [ -n "$gh_unknown" ]; then
		printf 'kept branch %s (%s): dead (%s), but open-PR status is unknown%s\n' \
			"$name" "$subject" "$proof" "$note"
		kept=$((kept + 1))
		continue
	fi
	# A branch a checkout still holds: the live worker comes first, then the changes git would
	# destroy, and only a clean checkout of a dead branch is removed with it in the apply phase.
	if [ -n "${wt_holder[$name]:-}" ]; then
		holder=${wt_holder[$name]}
		if [ -n "${live_holds[$holder]:-}" ]; then
			printf 'kept branch %s (%s): live worker %s holds %s, so it is kept\n' \
				"$name" "$subject" "${live_holds[$holder]}" "$holder"
			kept=$((kept + 1))
			continue
		fi
		if [ -n "$(git -C "$holder" status --porcelain 2>/dev/null)" ]; then
			printf 'kept branch %s (%s): worktree %s holds uncommitted changes, so the branch is kept\n' \
				"$name" "$subject" "$holder"
			kept=$((kept + 1))
			continue
		fi
		wt_remove[$name]=$holder
	fi
	dead_branches+=("$name")
	dead_detail[$name]="($subject): $proof$note"
done

# --- print the plan, or do it ------------------------------------------------------------------

nbranch=${#dead_branches[@]}
nworktree=${#dead_worktrees[@]}

if [ "$apply" = 0 ]; then
	for name in ${dead_branches[@]+"${dead_branches[@]}"}; do
		if [ -n "${wt_remove[$name]:-}" ]; then
			printf 'would delete branch %s %s and its worktree %s\n' \
				"$name" "${dead_detail[$name]}" "${wt_remove[$name]}"
		else
			printf 'would delete branch %s %s\n' "$name" "${dead_detail[$name]}"
		fi
	done
	for path in ${dead_worktrees[@]+"${dead_worktrees[@]}"}; do
		printf 'would prune worktree %s\n' "$path"
	done
	printf 'summary: %d branch(es) and %d worktree(s) would be deleted, %d kept; nothing changed\n' \
		"$nbranch" "$nworktree" "$kept"
	exit 0
fi

if [ "$yes" = 0 ]; then
	if [ -t 0 ]; then
		printf 'delete %d branch(es) and prune %d worktree(s) in %s? [y/N] ' \
			"$nbranch" "$nworktree" "$cwd" >&2
		answer=""
		read -r answer || answer=""
		case $answer in
		y | Y | yes | YES | Yes) ;;
		*)
			printf 'prune-refs: nothing deleted\n'
			exit 0
			;;
		esac
	else
		printf 'prune-refs: --apply needs --yes when stdin is not a terminal\n' >&2
		usage
	fi
fi

# The apply order matters: worktree entries first, branches second. A merged branch can still be
# held by a worktree entry whose directory is gone, and `git branch -D` refuses it until
# `git worktree prune` has dropped that entry — pruning afterwards would leave the deletion for a
# second run to finish.
pruned_worktrees=0
if [ "$nworktree" -gt 0 ]; then
	if out=$(git -C "$cwd" worktree prune 2>&1); then
		for path in "${dead_worktrees[@]}"; do
			printf 'pruned worktree %s\n' "$path"
			pruned_worktrees=$((pruned_worktrees + 1))
		done
	else
		printf 'kept worktrees: git worktree prune failed (%s)\n' "$(printf '%s' "$out" | head -n 1)"
		kept=$((kept + nworktree))
	fi
fi

# The clean checkout of a dead branch is removed here, after the dead records and before the
# branches: `git branch -D` refuses a branch a checkout holds, so the checkout goes first and one
# run still finishes. Never --force: a checkout that git would not remove is a keep, and the branch
# it holds is kept with it by the deletion below.
removed_worktrees=0
for name in ${dead_branches[@]+"${dead_branches[@]}"}; do
	path=${wt_remove[$name]:-}
	[ -n "$path" ] || continue
	if out=$(git -C "$cwd" worktree remove "$path" 2>&1); then
		printf 'removed worktree %s\n' "$path"
		removed_worktrees=$((removed_worktrees + 1))
	else
		printf 'kept worktree %s: git refused (%s)\n' "$path" "$(printf '%s' "$out" | head -n 1)"
	fi
done

# `git branch -D`, not -d: a squash-merged branch is not an ancestor of trunk, so -d refuses the
# very branches this command exists for. The proof above is what makes force safe here. A branch a
# live worktree still holds is a keep with git's own reason, not something to retry.
deleted_branches=0
for name in ${dead_branches[@]+"${dead_branches[@]}"}; do
	if out=$(git -C "$cwd" branch -D "$name" 2>&1); then
		printf 'deleted branch %s %s\n' "$name" "${dead_detail[$name]}"
		deleted_branches=$((deleted_branches + 1))
	else
		printf 'kept branch %s: git refused (%s)\n' "$name" "$(printf '%s' "$out" | head -n 1)"
		kept=$((kept + 1))
	fi
done

if [ "$deleted_branches" = 0 ] && [ "$pruned_worktrees" = 0 ] && [ "$removed_worktrees" = 0 ]; then
	printf 'summary: nothing deleted in %s, %d branch(es) kept\n' "$cwd" "$kept"
elif [ "$removed_worktrees" -gt 0 ]; then
	printf 'summary: deleted %d branch(es), pruned %d worktree(s), removed %d checkout(s), %d kept\n' \
		"$deleted_branches" "$pruned_worktrees" "$removed_worktrees" "$kept"
else
	printf 'summary: deleted %d branch(es), pruned %d worktree(s), %d kept\n' \
		"$deleted_branches" "$pruned_worktrees" "$kept"
fi
exit 0
