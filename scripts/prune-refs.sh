#!/usr/bin/env bash
# prune-refs.sh — one command that lists the local branches and worktree entries in a checkout that
# nobody can use any more, and deletes exactly those when asked twice.
#
# Why it exists: a merged worker leaves its branch behind, and `git worktree list` keeps entries
# whose directory is long gone. Every `git branch`, `git status` and `git log --all` in the repo then
# reads them, so the next worker misleads itself with work that already landed.
#
#   bash scripts/prune-refs.sh --cwd /home/mark/.pi                 list them, change nothing
#   bash scripts/prune-refs.sh --cwd /home/mark/.pi --apply --yes   delete exactly what it listed
#
# Two proofs, and only two, make a branch dead — everything else is kept and says why:
#   * ancestry: `git branch --merged origin/<trunk>` lists it; or
#   * squash-equivalence: `git cherry origin/<trunk> <branch>` marks every one of its commits `-`,
#     meaning the patch is already upstream under another sha.
# The second is not decoration: this repo squash-merges, so a branch merged through a PR is never an
# ancestor of trunk. It is the same check bin/publish's duplicate guard and `delegate close --merged`
# trust. One `+` line — a commit whose patch is not in trunk, pushed or not — and the branch stays.
#
# Never deleted, whatever the proofs say: the current branch, the trunk, a branch with an open pull
# request, and any branch at all while `gh` cannot answer (its open-PR status is then unknown, and
# the branches it would have checked are printed instead).
#
# A worktree entry is dead only when its directory does not exist; `git worktree prune` removes the
# entry, never a directory. That half is not gated on `gh`: a directory that is gone cannot come back
# through a pull request, so it is pruned even when the open-PR question went unanswered.
#
# --apply prunes the dead worktree entries first and deletes the branches after: a merged branch can
# still be held by an entry whose directory is gone, and `git branch -D` refuses it until that entry
# is gone. One run finishes, where pruning last left the deletion for a second invocation.
#
#   exit 0  nothing to do, or the list was printed, or everything printed was deleted
#   exit 2  bad usage, or no origin/<trunk> to compare against, or --apply without the second yes
set -uo pipefail

usage() {
	printf 'usage: bash scripts/prune-refs.sh [--cwd DIR] [--apply [--yes]]\n' >&2
	printf '  (no flags)   print what is dead; change nothing\n' >&2
	printf '  --cwd DIR    the checkout to look at (default: the current directory)\n' >&2
	printf '  --apply      delete the branches and worktrees listed; asks first\n' >&2
	printf '  --yes        skip the confirmation, for a script that has already decided\n' >&2
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
# (`trunk` in /home/mark/.pi, `main` here), so it is never hardcoded.
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
declare -A by_ancestry=()
while IFS= read -r name; do
	[ -n "$name" ] && by_ancestry[$name]=1
done < <(git -C "$cwd" branch --merged "$upstream" --format='%(refname:short)' 2>/dev/null)

dead_branches=()
declare -A dead_detail=()
kept=0
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
	dead_branches+=("$name")
	dead_detail[$name]="($subject): $proof$note"
done

# --- which worktree entries are dead -----------------------------------------------------------

# `git worktree list --porcelain` repeats a `worktree <path>` line per entry; a path whose directory
# is gone is the only thing `git worktree prune` removes, so that is the only test here.
dead_worktrees=()
while IFS= read -r line; do
	case $line in
	worktree\ *)
		path=${line#worktree }
		[ -e "$path" ] || dead_worktrees+=("$path")
		;;
	esac
done < <(git -C "$cwd" worktree list --porcelain 2>/dev/null)

# --- print the plan, or do it ------------------------------------------------------------------

nbranch=${#dead_branches[@]}
nworktree=${#dead_worktrees[@]}

if [ "$apply" = 0 ]; then
	for name in ${dead_branches[@]+"${dead_branches[@]}"}; do
		printf 'would delete branch %s %s\n' "$name" "${dead_detail[$name]}"
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

if [ "$deleted_branches" = 0 ] && [ "$pruned_worktrees" = 0 ]; then
	printf 'summary: nothing deleted in %s, %d branch(es) kept\n' "$cwd" "$kept"
else
	printf 'summary: deleted %d branch(es), pruned %d worktree(s), %d kept\n' \
		"$deleted_branches" "$pruned_worktrees" "$kept"
fi
exit 0
