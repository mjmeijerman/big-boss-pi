#!/usr/bin/env bash
# test-open-pr-update.sh — an open PR for the branch is the destination, not a stop sign.
#
# A second worker on a branch that already has an open pull request used to be stranded: the
# duplicate guard found the PR and stopped *before* the push, printed the URL and exited 0, so
# `delegate finish` said `published` while the new commit sat on the local branch only and the PR
# body still described the first worker. That happened for real on mjmeijerman/pi#183: the body
# kept the first worker's `Review tier: Medium` over a `sandbox/` diff, and only the tier gate
# caught it.
#
# Every case here drives the real `bin/publish` against a temporary PI_BOSS_ROOT, a throwaway git
# repo with a local bare `origin`, and a stub `gh` that records its argv: no network, no GitHub,
# no real workspace. The `git` shim records every call and then runs the real git, so "the push
# came before the body edit" is read from one ordered log instead of from the command's word.
#
#   bash scripts/test-open-pr-update.sh      exit 0 = every case held
set -uo pipefail

root=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd)
bin=$root/bin
publish=$bin/publish

work=$(mktemp -d)
# OPEN_PR_UPDATE_KEEP=1 leaves the throwaway root and the recorded git/gh argv on disk, so the
# ordering that the assertions read can be looked at by a person too.
keep=${OPEN_PR_UPDATE_KEEP:-}
trap '[ -n "$keep" ] || rm -rf "$work"' EXIT
unset PI_MASTER_ROOT
export HOME=$work/home
mkdir -p "$HOME" "$work/stub"
real_git=$(command -v git)

# git: record the argv, then do what git does. Nothing here is faked — the pushes are real pushes
# into a bare repo one directory over — only the call log is.
cat >"$work/stub/git" <<SHIM
#!/usr/bin/env bash
printf 'git %s\n' "\$*" >>"\${FAKE_LOG:-/dev/null}"
exec "$real_git" "\$@"
SHIM

# gh: records the argv, and answers the three questions publish asks — the repo's own name, the
# branch's pull requests, and the body edit. FAKE_LIST_FAIL is the missing login.
cat >"$work/stub/gh" <<'STUB'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >>"${FAKE_LOG:-/dev/null}"
case " $* " in
*" pr list "*)
	if [ "${FAKE_LIST_FAIL:-0}" = 1 ]; then
		printf 'gh: To get started with GitHub CLI, please run: gh auth login\n' >&2
		exit 1
	fi
	printf '%s\n' "${FAKE_PR_JSON:-[]}"
	;;
*" pr edit "*)
	prev=""
	for a in "$@"; do
		[ "$prev" = --body-file ] && cp "$a" "${FAKE_BODY_OUT:-/dev/null}"
		prev=$a
	done
	;;
*" pr create "*)
	prev=""
	for a in "$@"; do
		[ "$prev" = --body-file ] && cp "$a" "${FAKE_BODY_OUT:-/dev/null}"
		prev=$a
	done
	printf '%s\n' "${FAKE_PR_URL:-https://github.com/example/repo/pull/900}"
	;;
*" repo view "*)
	printf 'example/repo\n'
	;;
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

# One throwaway repo per case: a bare `origin`, a trunk commit, an `origin/main` ref and a worker
# branch carrying its `Agent-Slug:` trailer. setup <slug> <branch> [<on-trunk>] — with
# <on-trunk> the branch is trunk itself, which is what "merged, nothing ahead" looks like.
REPO=""
setup() { # <slug> <branch> [trunk]
	local slug=$1 branch=$2 on_trunk=${3:-}
	REPO=$work/repo-$slug
	rm -rf "$REPO" "$REPO.git"
	"$real_git" init -q --bare "$REPO.git"
	"$real_git" init -q -b main "$REPO"
	"$real_git" -C "$REPO" config user.email worker@example.invalid
	"$real_git" -C "$REPO" config user.name worker
	printf 'one\n' >"$REPO/file.txt"
	"$real_git" -C "$REPO" add file.txt
	"$real_git" -C "$REPO" commit -q -m "chore: base" -m "Agent-Slug: $slug"
	"$real_git" -C "$REPO" remote add origin "$REPO.git"
	"$real_git" -C "$REPO" push -q -u origin main
	"$real_git" -C "$REPO" fetch -q origin
	"$real_git" -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
	if [ -z "$on_trunk" ]; then
		"$real_git" -C "$REPO" checkout -q -b "$branch"
		printf 'two\n' >>"$REPO/file.txt"
		"$real_git" -C "$REPO" commit -q -am "feat: the worker's change" -m "Agent-Slug: $slug" \
			-m "Spec: /home/mark/big-boss-pi/specs/publish-open-pr.md"
	else
		# A merged PR's branch was pushed before it was merged, so origin holds it: the publish
		# reads origin's head to confirm that nothing of this branch is missing there.
		"$real_git" -C "$REPO" branch --no-track "$branch" refs/remotes/origin/main
		"$real_git" -C "$REPO" push -q origin "$branch"
	fi
	mkdir -p "$PI_BOSS_ROOT/reports" "$PI_BOSS_ROOT/state"
	cat >"$PI_BOSS_ROOT/reports/$slug.md" <<REPORT
# Worker \\\`$slug\\\`

Mission: an open pull request gets the second worker's commit, in the repo and in its description.

Now possible: finishing a worker on a branch that already has a pull request updates that pull request instead of stranding the commit.

Review tier: High — bin/publish is harness code.

Test change: scripts/tests/test-publish.sh pinned an open PR as a stop sign; it now pins the push and the body refresh.

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

export PI_BOSS_ROOT=$work/root
case_no=0
fresh_log() { # <name> — a new argv log and body file, so a second run does not overwrite the first
	FAKE_LOG=$work/$1.log
	FAKE_BODY_OUT=$work/$1.body
	: >"$FAKE_LOG"
	rm -f "$FAKE_BODY_OUT"
	export FAKE_LOG FAKE_BODY_OUT
}
new_case() { # <slug> <branch> [trunk]
	case_no=$((case_no + 1))
	setup "$@"
	fresh_log "case$case_no"
	unset FAKE_PR_JSON FAKE_LIST_FAIL FAKE_PR_URL
	out=""
	err=""
	rc=0
}
run() { # <slug> — the real publish, stdout and stderr kept apart
	out=$("$publish" "$1" 2>"$work/stderr") && rc=0 || rc=$?
	err=$(cat "$work/stderr")
}
url_of() { printf 'https://github.com/example/repo/pull/%s' "$1"; }

# --- 1. open PR + a new commit: push first, then refresh the body ------------------------------
new_case worker worker
export FAKE_PR_JSON='[{"number":183,"state":"OPEN","url":"https://github.com/example/repo/pull/183"}]'
run worker
if [ "$rc" -eq 0 ]; then pass "an open PR with a new commit exits 0"; else fail "an open PR with a new commit exits 0 (exit $rc: $err)"; fi
check "  ...it says updated #183, not published" printed 'updated #183'
check "  ...and names the commit it pushed" bash -c "printf '%s' '$out' | grep -qE 'updated #183 \(pushed [0-9a-f]{7},'"
check "  ...the body came from this worker's report" bash -c "printf '%s' '$out' | grep -qF 'body from reports/worker.md'"
check "  ...nothing was created" bash -c "! grep -q 'pr create' '$FAKE_LOG'"
if [ "$("$real_git" -C "$REPO" rev-parse refs/heads/worker)" = "$("$real_git" -C "$REPO.git" rev-parse refs/heads/worker)" ]; then
	pass "  ...origin now holds the commit the branch is at"
else
	fail "  ...origin does not hold the branch's commit"
fi
check "  ...the push came before the body edit" bash -c "[ \$(grep -n ' push ' '$FAKE_LOG' | head -n1 | cut -d: -f1) -lt \$(grep -n 'pr edit 183' '$FAKE_LOG' | head -n1 | cut -d: -f1) ]"
check "  ...after the PR was listed, so the guard still runs before anything is pushed" bash -c "[ \$(grep -n 'pr list' '$FAKE_LOG' | head -n1 | cut -d: -f1) -lt \$(grep -n ' push ' '$FAKE_LOG' | head -n1 | cut -d: -f1) ]"
check "  ...and one edit, not a second pull request" bash -c "[ \$(grep -c 'pr edit 183' '$FAKE_LOG') -eq 1 ]"
check "  ...the edited body carries this worker's tier" bash -c "grep -qxF 'Review tier: High' '$FAKE_BODY_OUT'"
check "  ...and this worker's Evidence, not the first worker's" bash -c "grep -qxF 'worker: ok' '$FAKE_BODY_OUT'"
check "  ...the PR URL is printed" printed "$(url_of 183)"
[ -z "$keep" ] || printf 'case 1 printed: %s\n' "$(printf '%s' "$out" | tr '\n' ' ')"

# --- 2. the same again with nothing new: no second push, body still edited, exit 0 -------------
fresh_log case1-second
run worker
if [ "$rc" -eq 0 ]; then pass "a second finish with nothing new still exits 0"; else fail "a second finish with nothing new still exits 0 (exit $rc: $err)"; fi
check "  ...nothing was pushed a second time" bash -c "! grep -q ' push ' '$FAKE_LOG'"
check "  ...the description was still refreshed once" bash -c "[ \$(grep -c 'pr edit 183' '$FAKE_LOG') -eq 1 ]"
check "  ...and it says so instead of claiming a push" printed 'updated #183 (no new commits'
check "  ...the body is the report's" bash -c "grep -qxF 'worker: ok' '$FAKE_BODY_OUT'"

# --- 3. gh cannot list: nothing is pushed and the refusal is unchanged -------------------------
new_case worker worker
export FAKE_PR_JSON='[]' FAKE_LIST_FAIL=1
run worker
if [ "$rc" -ne 0 ]; then pass "a gh that cannot list pull requests refuses"; else fail "a gh that cannot list pull requests refuses (exit $rc: $err)"; fi
check "  ...the refusal still names the login" said 'gh could not list pull requests for worker (is it authenticated?)'
check "  ...and says nothing was pushed" said 'so nothing was pushed'
check "  ...and nothing was pushed" bash -c "! grep -q ' push ' '$FAKE_LOG'"
check "  ...no PR was opened" bash -c "! grep -q 'pr create' '$FAKE_LOG'"
check "  ...nothing was edited either" bash -c "! grep -q 'pr edit' '$FAKE_LOG'"

# --- 4. closed unmerged: a new PR, with this worker's body ------------------------------------
new_case worker worker
export FAKE_PR_JSON='[{"number":9,"state":"CLOSED","url":"https://github.com/example/repo/pull/9"}]'
run worker
if [ "$rc" -eq 0 ]; then pass "a closed, unmerged PR still publishes (exit 0)"; else fail "a closed, unmerged PR still publishes (exit $rc: $err)"; fi
check "  ...the old number is named" said '#9 was closed without merge'
check "  ...the branch was pushed" calls ' push .*origin worker'
check "  ...a new PR was opened" calls 'pr create .*--base main'
check "  ...carrying this worker's body" bash -c "grep -qxF 'worker: ok' '$FAKE_BODY_OUT'"
check "  ...and nothing was edited" bash -c "! grep -q 'pr edit' '$FAKE_LOG'"

# --- 5. merged with nothing ahead: still nothing to publish, nothing pushed --------------------
new_case merged merged on-trunk
export FAKE_PR_JSON='[{"number":11,"state":"MERGED","url":"https://github.com/example/repo/pull/11"}]'
run merged
if [ "$rc" -eq 0 ]; then pass "a merged branch with nothing ahead exits 0"; else fail "a merged branch with nothing ahead exits 0 (exit $rc: $err)"; fi
check "  ...it says already merged as #11" said 'merged is already merged as #11'
check "  ...and that there is nothing to publish" said 'nothing to publish'
check "  ...nothing was pushed" bash -c "! grep -q ' push ' '$FAKE_LOG'"
check "  ...and nothing was edited" bash -c "! grep -q 'pr edit' '$FAKE_LOG'"

if [ -n "$keep" ]; then printf 'kept: %s\n' "$work"; fi
printf '\n%s\n' "$([ "$fails" = 0 ] && echo "open PR update: ok" || echo "open PR update: $fails failure(s)")"
[ "$fails" = 0 ]
