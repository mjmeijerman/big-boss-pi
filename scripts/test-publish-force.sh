#!/usr/bin/env bash
# test-publish-force.sh — a rebased branch is re-pushed under a lease; a branch with foreign
# commits is refused.
#
# `bin/preflight`'s `behind` check tells a worker to `git rebase origin/main`, and the rebase gives
# every commit a new sha. Origin still holds the branch's old tip, so the publish's plain push is
# rejected `non-fast-forward` and the worker's work stays on a local branch (mjmeijerman/pi#69:
# rebased, 5/5 preflight green, publish refused, a person force-pushed by hand). Failing blindly is
# one wrong answer; forcing blindly is the other, because the same rejection means "somebody else
# pushed to this branch" and a force would delete their commit.
#
# So both halves are pinned here, against a real bare `origin` and a stub `gh`: a rewrite this tree
# made is pushed with `--force-with-lease=<branch>:<the exactly read remote sha>` and says so in one
# line naming both shas; a remote tip that is somebody else's commit is refused with the commit
# named and nothing pushed; a plain fast-forward is a plain push with no force in argv at all, and
# no push ever carries `--force-with-lease` without the lease value in the same argument.
#
#   bash scripts/test-publish-force.sh      exit 0 = every case held
set -uo pipefail

root=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd)
bin=$root/bin
publish=$bin/publish

work=$(mktemp -d)
# PUBLISH_FORCE_KEEP=1 leaves the throwaway root and the recorded git/gh argv on disk, so the push
# arguments the assertions read can be looked at by a person too.
keep=${PUBLISH_FORCE_KEEP:-}
trap '[ -n "$keep" ] || rm -rf "$work"' EXIT
unset PI_MASTER_ROOT
export HOME=$work/home
mkdir -p "$HOME" "$work/stub"
real_git=$(command -v git)

# git: record the argv, then do what git does. Nothing is faked — the pushes are real pushes into a
# bare repo one directory over — only the call log is, so "what was pushed, with which flags" is
# read from one ordered list instead of from the command's word.
cat >"$work/stub/git" <<SHIM
#!/usr/bin/env bash
printf 'git %s\n' "\$*" >>"\${FAKE_LOG:-/dev/null}"
exec "$real_git" "\$@"
SHIM

# gh: records the argv and answers the three questions publish asks — the repo's own name, the
# branch's pull requests, and the body edit/create.
cat >"$work/stub/gh" <<'STUB'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >>"${FAKE_LOG:-/dev/null}"
case " $* " in
*" pr list "*) printf '%s\n' "${FAKE_PR_JSON:-[]}" ;;
*" pr edit "* | *" pr create "*)
	prev=""
	for a in "$@"; do
		[ "$prev" = --body-file ] && cp "$a" "${FAKE_BODY_OUT:-/dev/null}"
		prev=$a
	done
	case " $* " in
	*" pr create "*) printf '%s\n' "${FAKE_PR_URL:-https://github.com/example/repo/pull/900}" ;;
	esac
	;;
*" repo view "*) printf 'example/repo\n' ;;
esac
exit 0
STUB
chmod +x "$work/stub/git" "$work/stub/gh"
export PATH=$work/stub:$PATH

fails=0
pass() { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }
check() { # <description> <command...>
	local d=$1
	shift
	if "$@"; then pass "$d"; else fail "$d"; fi
}
said() { printf '%s' "$err" | grep -qF -- "$1"; }
printed() { printf '%s' "$out" | grep -qF -- "$1"; }
calls() { grep -qE -- "$1" "$FAKE_LOG"; }

# setup <slug> <branch> — a bare `origin`, a trunk commit, a worker branch that origin already
# holds (that is the branch that gets rewritten). The bare repo is the remote; the repo is the
# worker's tree.
REPO=""
setup() { # <slug> <branch>
	local slug=$1 branch=$2
	REPO=$work/repo-$slug
	rm -rf "$REPO" "$REPO.git"
	"$real_git" init -q --bare "$REPO.git"
	"$real_git" init -q -b main "$REPO"
	"$real_git" -C "$REPO" config user.email worker@example.invalid
	"$real_git" -C "$REPO" config user.name worker
	printf 'one\n' >"$REPO/file.txt"
	"$real_git" -C "$REPO" add file.txt
	"$real_git" -C "$REPO" commit -q -m "chore: base"
	"$real_git" -C "$REPO" remote add origin "$REPO.git"
	"$real_git" -C "$REPO" push -q -u origin main
	"$real_git" -C "$REPO" fetch -q origin
	"$real_git" -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
	"$real_git" -C "$REPO" checkout -q -b "$branch"
	printf 'two\n' >>"$REPO/file.txt"
	"$real_git" -C "$REPO" commit -q -am "feat: the worker's change" -m "Agent-Slug: $slug" \
		-m "Spec: specs/publish-force.md"
	"$real_git" -C "$REPO" push -q -u origin "$branch"
	mkdir -p "$PI_BOSS_ROOT/reports" "$PI_BOSS_ROOT/state"
	cat >"$PI_BOSS_ROOT/reports/$slug.md" <<REPORT
# Worker \\\`$slug\\\`

Mission: a rebased branch publishes under a lease, and a branch carrying somebody else's commit is refused.

Now possible: rebasing onto trunk no longer strands a finished worker behind a rejected push.

Review tier: High — bin/publish is harness code.

Test change: none — this file is new, and it pins the lease for a rewrite, the refusal for a foreign commit, and the plain push for a fast-forward.

## Evidence

$ bin/preflight — 5/5 passed
\\\`\\\`\\\`
${slug}: ok
\\\`\\\`\\\`

## Thrown away

nothing
REPORT
	printf '{"%s":{"space":"s1","cwd":"%s","branch":"%s","report":"%s/reports/%s.md"}}\n' \
		"$slug" "$REPO" "$branch" "$PI_BOSS_ROOT" "$slug" >"$PI_BOSS_ROOT/state/delegations.json"
}

# rebase_onto_new_trunk — trunk gains a commit and the worker branch is rebased onto it, which is
# the exact shape `preflight`'s `behind` check asks for: every local sha is new, origin still holds
# the old tip.
rebase_onto_new_trunk() { # <branch>
	local branch=$1
	"$real_git" -C "$REPO" checkout -q main
	printf 'three\n' >>"$REPO/other.txt"
	"$real_git" -C "$REPO" add other.txt
	"$real_git" -C "$REPO" commit -q -m "chore: trunk moves"
	"$real_git" -C "$REPO" push -q origin main
	"$real_git" -C "$REPO" checkout -q "$branch"
	"$real_git" -C "$REPO" rebase -q main
}

# foreign_commit — somebody else pushes a commit onto the branch, so origin's tip is a commit this
# tree never had. Read from a clone, exactly as a second person's push would arrive.
foreign_commit() { # <branch> <subject>
	local branch=$1 subject=$2
	rm -rf "$work/other"
	"$real_git" clone -q "$REPO.git" "$work/other"
	"$real_git" -C "$work/other" config user.email other@example.invalid
	"$real_git" -C "$work/other" config user.name other
	"$real_git" -C "$work/other" checkout -q "$branch"
	printf 'theirs\n' >"$work/other/theirs.txt"
	"$real_git" -C "$work/other" add theirs.txt
	"$real_git" -C "$work/other" commit -q -m "$subject"
	"$real_git" -C "$work/other" push -q origin "$branch"
}

export PI_BOSS_ROOT=$work/root
case_no=0
fresh_log() { # <name> — a new argv log and body file, so a second run does not overwrite the first
	FAKE_LOG=$work/$1.log
	FAKE_BODY_OUT=$work/$1.body
	: >"$FAKE_LOG"
	rm -f "$FAKE_BODY_OUT"
	export FAKE_LOG FAKE_BODY_OUT
}
new_case() { # <slug> <branch>
	case_no=$((case_no + 1))
	setup "$@"
	fresh_log "case$case_no"
	unset FAKE_PR_JSON FAKE_PR_URL
	out=""
	err=""
	rc=0
}
run() { # <slug> — the real publish, stdout and stderr kept apart
	out=$("$publish" "$1" 2>"$work/stderr") && rc=0 || rc=$?
	err=$(cat "$work/stderr")
}
remote_sha() { "$real_git" -C "$REPO.git" rev-parse "refs/heads/$1"; }
local_sha() { "$real_git" -C "$REPO" rev-parse "refs/heads/$1"; }
push_lines() { grep -E '^git .* push ' "$FAKE_LOG" || true; }

# --- 1. a rewrite (the rebase) is pushed under a lease, into the open PR ------------------------
new_case worker worker
export FAKE_PR_JSON='[{"number":183,"state":"OPEN","url":"https://github.com/example/repo/pull/183"}]'
old_tip=$(remote_sha worker)
rebase_onto_new_trunk worker
new_tip=$(local_sha worker)
if [ "$old_tip" != "$new_tip" ]; then pass "setup: the rebase rewrote the branch ($old_tip -> $new_tip)"; else fail "setup: the rebase did not rewrite the branch"; fi
run worker
if [ "$rc" -eq 0 ]; then pass "a rebased branch publishes into its open PR (exit 0)"; else fail "a rebased branch publishes into its open PR (exit $rc: $err)"; fi
check "  ...origin now holds the rewritten tip" bash -c "[ \"\$(git -C '$REPO.git' rev-parse refs/heads/worker)\" = '$new_tip' ]"
check "  ...the push carried a lease on the old tip" bash -c "grep -qE -- '--force-with-lease=worker:$old_tip' '$FAKE_LOG'"
check "  ...and no bare --force" bash -c "! grep -qE -- '(^| )(--force|-f)( |$)' '$FAKE_LOG'"
check "  ...one line names both shas" bash -c "printf '%s' '$err' | grep -qE 'forced the rewrite of origin/worker deliberately: $old_tip was the previous head, $new_tip is the rewritten one'"
check "  ...and the line is one line" bash -c "[ \"\$(printf '%s' '$err' | grep -c 'forced the rewrite')\" = 1 ]"
check "  ...the body was rebuilt from this worker's report" bash -c "grep -qxF 'worker: ok' '$FAKE_BODY_OUT'"
check "  ...with this worker's tier" bash -c "grep -qxF 'Review tier: High' '$FAKE_BODY_OUT'"
check "  ...the PR was updated, not duplicated" printed 'updated #183'
check "  ...and nothing was created" bash -c "! grep -q 'pr create' '$FAKE_LOG'"
[ -z "$keep" ] || printf 'case 1 printed: %s\n' "$(printf '%s' "$out" | tr '\n' ' ')"

# --- 2. a foreign commit on the branch is refused, and nothing is pushed ------------------------
new_case worker worker
old_tip=$(remote_sha worker)
foreign_commit worker "feat: somebody else's work"
foreign_tip=$(remote_sha worker)
run worker
if [ "$rc" -ne 0 ]; then pass "a remote tip this tree never had is refused"; else fail "a remote tip this tree never had is refused (exit $rc)"; fi
check "  ...the refusal names what would be lost" said "feat: somebody else's work"
check "  ...and says nothing was pushed" said 'Nothing was pushed'
check "  ...no force of any kind in argv" bash -c "! grep -qE -- '--force' '$FAKE_LOG'"
check "  ...every push attempt was a plain one" bash -c "[ \"\$(grep -E '^git .* push ' '$FAKE_LOG' | grep -cE -- '--force|lease')\" = 0 ]"
check "  ...origin still holds the foreign commit" bash -c "[ \"\$(git -C '$REPO.git' rev-parse refs/heads/worker)\" = '$foreign_tip' ]"
check "  ...and no PR was opened" bash -c "! grep -q 'pr create' '$FAKE_LOG'"

# --- 3. a fast-forward is a plain push, with no force anywhere in argv --------------------------
new_case worker worker
printf 'more\n' >>"$REPO/file.txt"
"$real_git" -C "$REPO" commit -q -am "feat: one more commit" -m "Agent-Slug: worker"
new_tip=$(local_sha worker)
run worker
if [ "$rc" -eq 0 ]; then pass "a fast-forward publishes (exit 0)"; else fail "a fast-forward publishes (exit $rc: $err)"; fi
check "  ...origin holds the new tip" bash -c "[ \"\$(git -C '$REPO.git' rev-parse refs/heads/worker)\" = '$new_tip' ]"
check "  ...the push was plain" bash -c "[ \"\$(grep -E '^git .* push ' '$FAKE_LOG' | grep -c -- '--force')\" = 0 ]"
check "  ...and nothing claimed a rewrite" bash -c "! printf '%s' '$err' | grep -q 'forced the rewrite'"
check "  ...a new PR was opened from the report" bash -c "grep -q 'pr create' '$FAKE_LOG'"
check "  ...carrying this worker's Evidence" bash -c "grep -qxF 'worker: ok' '$FAKE_BODY_OUT'"

# --- 4. the rule about the lease itself: never without the value, never without a lease ---------
leases=$(grep -hoE -- '--force-with-lease=[^ ]*' "$work"/*.log 2>/dev/null || true)
if [ -n "$leases" ]; then pass "some push did carry a lease (so the rule below is not vacuous)"; else fail "no push carried a lease, so case 1 proves nothing"; fi
bad=$(printf '%s\n' "$leases" | grep -vE '^--force-with-lease=worker:[0-9a-f]{40}$' || true)
if [ -z "$bad" ]; then pass "every lease names the branch and the exactly read sha"; else fail "a lease came without its value: $bad"; fi
check "no push used a blanket --force-with-lease" bash -c "! grep -qE -- '--force-with-lease( |$)' '$work'/*.log"
check "no --force and no -f on any push" bash -c "! grep -qE -- '(^| )(--force|-f)( |$)' '$work'/*.log"

if [ -n "$keep" ]; then printf 'kept: %s\n' "$work"; fi
printf '\n%s\n' "$([ "$fails" = 0 ] && echo "publish force: ok" || echo "publish force: $fails failure(s)")"
[ "$fails" = 0 ]
