#!/usr/bin/env bash
# test-publish.sh — `bin/publish` turns a finished worker into a PR, and refuses when the report
# cannot supply what the PR body must carry.
#
# Every case drives the real `bin/publish` against a temporary PI_BOSS_ROOT, a throwaway repo and
# fake `git` and `gh` on PATH: no network, no GitHub, no real workspace. The fakes log every call,
# so "no push happened" and "the body carried the tier" are read from what the command did, not
# from what it said.
#
#   bash scripts/tests/test-publish.sh      exit 0 = every case held
set -uo pipefail

root=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/../.." && pwd)
bin=$root/bin
script=$bin/publish

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
unset PI_MASTER_ROOT

fails=0
pass() { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }
check() { # <description> <command...>
	local d=$1
	shift
	if "$@"; then pass "$d"; else fail "$d"; fi
}

# --- fakes -----------------------------------------------------------------------------------

mkdir -p "$work/stub"
cat >"$work/stub/git" <<'FAKE'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >>"${FAKE_LOG:-/dev/null}"
if [ "${1:-}" = -C ]; then shift 2; fi
case " $* " in
*" rev-parse --verify "*)
	[ "${FAKE_NO_BRANCH:-0}" = 1 ] && exit 1
	exit 0
	;;
*" rev-parse "*)
	if [ "${FAKE_NOT_REPO:-0}" = 1 ]; then
		printf 'fatal: not a git repository\n' >&2
		exit 128
	fi
	printf '.git\n'
	;;
*" symbolic-ref "*)
	[ "${FAKE_ORIGIN_HEAD:-0}" = 1 ] || exit 1
	printf 'refs/remotes/origin/main\n'
	;;
*" show-ref "*)
	case " $* " in
	*" refs/remotes/origin/main "*) exit 0 ;;
	*) exit 1 ;;
	esac
	;;
*" --format=%s "*)
	printf '%s\n' "${FAKE_TITLE:-feat: a worker change}"
	;;
*" for-each-ref "*)
	for b in ${FAKE_BRANCHES:-}; do printf '%s\n' "$b"; done
	;;
*" --format=%B "*)
	if [ -n "${FAKE_WORKER_BRANCH:-}" ] && [[ "$*" == *"$FAKE_WORKER_BRANCH"* ]]; then
		printf 'Agent-Slug: %s\n' "${FAKE_SLUG:-worker}"
	else
		printf '%s\n' "${FAKE_TRAILERS-Agent-Slug: some-worker}"
	fi
	;;
*" push "*) printf '   pushed %s\n' "$*" ;;
*) exit 0 ;;
esac
FAKE
cat >"$work/stub/gh" <<'FAKE'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >>"${FAKE_LOG:-/dev/null}"
case " $* " in
*" pr list "*)
	[ "${FAKE_GH_FAIL:-0}" = 1 ] && exit 1
	[ -n "${FAKE_PR_URL:-}" ] && printf '%s\n' "$FAKE_PR_URL"
	exit 0
	;;
*" pr create "*)
	while [ $# -gt 0 ]; do
		if [ "$1" = --body-file ]; then cp "$2" "${FAKE_BODY_OUT:-/dev/null}"; fi
		shift
	done
	printf '%s\n' "${FAKE_NEW_PR_URL:-https://github.com/example/repo/pull/7}"
	exit 0
	;;
" pr merge "*)
	printf 'fake gh: merge is never allowed in this test\n' >&2
	exit 99
	;;
*) exit 0 ;;
esac
FAKE
chmod +x "$work/stub/git" "$work/stub/gh"
export PATH=$work/stub:$PATH

REPORT_OK='# a worker report

**Mission**: the person merges once instead of retyping the mission and the tier.

## What now works

- `bin/publish <slug>` prints a PR URL.

Review tier: **medium** (script plus tests)

## Still open

Nothing.

## Evidence

```
$ bash scripts/tests/test-publish.sh
  ok    a case
test-publish: ok
```

## Thrown away

Nothing yet.
'

# new_case <name> — a fresh PI_BOSS_ROOT and repo, with the known-good report written.
# Sets CASE, ROOTDIR, REPO, REPORTER; exports PI_BOSS_ROOT and the fake envs.
new_case() {
	CASE=$work/$1
	ROOTDIR=$CASE/root
	REPO=$CASE/repo
	REPORTER=$ROOTDIR/reports/worker.md
	rm -rf "$CASE"
	mkdir -p "$ROOTDIR/state" "$ROOTDIR/reports" "$REPO"
	export PI_BOSS_ROOT=$ROOTDIR
	export FAKE_LOG=$CASE/calls
	export FAKE_BODY_OUT=$CASE/body
	unset FAKE_NOT_REPO FAKE_PR_URL FAKE_TRAILERS FAKE_TITLE FAKE_ORIGIN_HEAD FAKE_NEW_PR_URL FAKE_NO_BRANCH FAKE_GH_FAIL FAKE_BRANCHES FAKE_WORKER_BRANCH FAKE_SLUG
	printf '%s' "$REPORT_OK" >"$REPORTER"
	cat >"$ROOTDIR/state/delegations.json" <<JSON
{"worker":{"slug":"worker","cwd":"$REPO","branch":"feat/worker","spec":"$ROOTDIR/specs/worker.md","report":"$REPORTER"}}
JSON
	: >"$FAKE_LOG"
}

run() { # capture stdout and stderr, keep the exit code in $rc
	out=$("$script" "$@" 2>"$CASE/err")
	rc=$?
	err=$(cat "$CASE/err")
}
refused() { # <description> <stderr fragment>
	if [ "$rc" -ne 0 ] && printf '%s' "$err" | grep -qF -- "$2"; then
		pass "$1"
	else
		fail "$1 (exit $rc, stderr: $(printf '%s' "$err" | head -n 2))"
	fi
}
calls() { grep -qE -- "$1" "$FAKE_LOG" 2>/dev/null; }

# --- refusals --------------------------------------------------------------------------------

new_case unknown
run nope
refused "an unknown slug is refused, not guessed at" "unknown worker slug"

new_case missing-report
rm -f "$REPORTER"
run worker
refused "a missing report is refused" "does not exist"

new_case no-evidence
cat >"$REPORTER" <<'EOF'
**Mission**: something.

Review tier: **medium**

## Still open

Everything.
EOF
run worker
refused "a report with no Evidence block is refused" "no Evidence block"
check "  ...and nothing was pushed" bash -c '! grep -q "git push" "$FAKE_LOG"'

new_case no-tier
sed '/^Review tier:/d' "$REPORTER" >"$CASE/r" && mv "$CASE/r" "$REPORTER"
run worker
refused "a report with no Review tier line is refused" "Review tier"

new_case no-trailer
export FAKE_TRAILERS='Subject only

No trailers here.'
run worker
refused "a branch with no Agent-Slug trailer is refused" "Agent-Slug"
check "  ...and nothing was pushed" bash -c '! grep -q "git push" "$FAKE_LOG"'

new_case no-branch
export FAKE_NO_BRANCH=1
run worker
refused "a branch that is not in the tree is refused by name" "is not a local branch"

new_case no-gh
nogh=$CASE/nogh
mkdir -p "$nogh"
for c in bash env dirname readlink node grep awk sed mktemp rm git cat head tail tr; do
	p=$(command -v "$c" 2>/dev/null) && ln -s "$p" "$nogh/$c"
done
out=$(PATH=$nogh "$script" worker 2>"$CASE/err")
rc=$?
err=$(cat "$CASE/err")
refused "no gh on PATH is refused" "gh is not on PATH"
check "  ...and that PATH really had no gh" bash -c "! PATH=$nogh command -v gh >/dev/null 2>&1"

new_case not-a-repo
export FAKE_NOT_REPO=1
run worker
refused "a tree that is not a git repo is refused" "not a git repository"

# --- a worker whose recorded branch is the boss checkout's trunk ------------------------------

set_branch() { sed -i "s|\"branch\":\"[^\"]*\"|\"branch\":\"$1\"|" "$ROOTDIR/state/delegations.json"; }

new_case trunk-branch-recorded
set_branch main
export FAKE_BRANCHES='feat/worker feat/other' FAKE_WORKER_BRANCH=feat/worker FAKE_TRAILERS=''
run worker
if [ "$rc" -eq 0 ]; then pass "a trunk branch in delegations publishes the branch its trailer names"; else fail "a trunk branch in delegations publishes by trailer (exit $rc: $err)"; fi
check "  ...the found branch is pushed" calls '^git .*push .*origin feat/worker'
check "  ...and the lookup is explained" bash -c "printf '%s' \"$err\" | grep -q 'found by its Agent-Slug trailer'"

new_case trunk-branch-nothing-found
set_branch main
export FAKE_BRANCHES='feat/other' FAKE_TRAILERS=''
run worker
refused "a trunk branch with no matching trailer anywhere is refused" "no branch in"
check "  ...and nothing was pushed" bash -c '! grep -q "git push" "$FAKE_LOG"'

new_case trunk-branch-ambiguous
set_branch main
export FAKE_BRANCHES='feat/one feat/two' FAKE_WORKER_BRANCH=feat FAKE_TRAILERS=''
run worker
refused "two branches carrying the same slug are refused, not guessed" "several branches in"

# --- the publish paths -----------------------------------------------------------------------

new_case green-gate
cat >"$REPO/Makefile" <<'EOF'
pr-check:
	@test -n "$(BODY)" || { echo "no BODY"; exit 1; }
	@echo "body gate: green"
EOF
run worker
if [ "$rc" -eq 0 ]; then pass "a green make pr-check publishes (exit 0)"; else fail "a green make pr-check publishes (exit $rc: $err)"; fi
check "the PR URL is printed" bash -c "printf '%s' '$out' | grep -qE '^https://github.com/.*/pull/[0-9]+'"
check "the branch was pushed to origin" calls '^git .*push .*origin feat/worker'
check "a PR was opened against main" calls '^gh pr create .*--base main'
check "the title came from the branch HEAD subject" bash -c 'grep -qF -- "--title feat: a worker change" "$FAKE_LOG"'
check "the body carries the Mission line" bash -c "grep -qF 'the person merges once instead of retyping the mission and the tier' '$FAKE_BODY_OUT'"
check "the body carries the Review tier line" bash -c "grep -qF 'Review tier: **medium** (script plus tests)' '$FAKE_BODY_OUT'"
check "the body carries the Evidence block" bash -c "grep -qF 'test-publish: ok' '$FAKE_BODY_OUT'"
check "the body carries the Thrown away section" bash -c "grep -qF '## Thrown away' '$FAKE_BODY_OUT'"
check "nothing was merged" bash -c '! grep -q "pr merge" "$FAKE_LOG"'
check "trunk was never pushed" bash -c '! grep -qE "push .*( main| master| trunk)$" "$FAKE_LOG"'
check "no force-push flag" bash -c '! grep -q -- "--force" "$FAKE_LOG"'

new_case red-gate
mkdir -p "$REPO/scripts"
cat >"$REPO/scripts/pr-gate.sh" <<'EOF'
#!/usr/bin/env bash
echo "body gate: red — no Mission line" >&2
exit 1
EOF
chmod +x "$REPO/scripts/pr-gate.sh"
run worker
if [ "$rc" -ne 0 ]; then pass "a red scripts/pr-gate.sh stops the publish"; else fail "a red scripts/pr-gate.sh stops the publish (exit 0)"; fi
check "  ...the refusal names the gate" bash -c "printf '%s' '$err' | grep -q 'body gate'"
check "  ...and nothing was pushed" bash -c '! grep -q "git push" "$FAKE_LOG"'
check "  ...and no PR was created" bash -c '! grep -q "pr create" "$FAKE_LOG"'

new_case skip-gate
rm -f "$REPO/Makefile"
rm -rf "$REPO/scripts"
run worker
if [ "$rc" -eq 0 ]; then pass "no gate present: publishes and says it skipped"; else fail "no gate present: publishes (exit $rc: $err)"; fi
check "  ...the skip is printed" bash -c "printf '%s' '$err' | grep -q 'body gate skipped'"

new_case gh-not-asking
export FAKE_GH_FAIL=1
run worker
refused "gh that cannot answer is refused, not read as no-PR" "could not list pull requests"
check "  ...and nothing was pushed" bash -c '! grep -q "git push" "$FAKE_LOG"'

new_case already-exists
export FAKE_PR_URL='https://github.com/example/repo/pull/5'
run worker
if [ "$rc" -eq 0 ]; then pass "an existing PR exits 0"; else fail "an existing PR exits 0 (exit $rc: $err)"; fi
check "  ...its URL is printed" bash -c "printf '%s' '$out' | grep -qF 'https://github.com/example/repo/pull/5'"
check "  ...nothing was pushed" bash -c '! grep -q "git push" "$FAKE_LOG"'
check "  ...no second PR was created" bash -c '! grep -q "pr create" "$FAKE_LOG"'

# --- a worker that was already wiped and closed -------------------------------------------------
#
# Closing drops the delegation entry, and the boss publishes after that, so the fallback is the
# ordinary path for a finished worker, not an edge case: state/delegations.json no longer names it,
# while reports/<slug>.md under the boss root and a branch carrying its `Agent-Slug:` trailer both
# still do. `--cwd` names the repo to look in.
new_closed_case() {
	new_case "$1"
	printf '%s' "$REPORT_OK" >"$ROOTDIR/reports/closed.md"
	cat >"$ROOTDIR/state/delegations.json" <<JSON
{"someone-else":{"slug":"someone-else","cwd":"$REPO","branch":"feat/other"}}
JSON
	: >"$FAKE_LOG"
}

new_closed_case closed-publishes
export FAKE_BRANCHES='feat/closed feat/other' FAKE_WORKER_BRANCH=feat/closed FAKE_SLUG=closed FAKE_TRAILERS=''
run closed --cwd "$REPO"
if [ "$rc" -eq 0 ]; then pass "a wiped and closed slug publishes via --cwd (exit 0)"; else fail "a wiped and closed slug publishes via --cwd (exit $rc: $err)"; fi
check "  ...the branch is found by its trailer" bash -c "printf '%s' \"$err\" | grep -q 'found by its Agent-Slug trailer'"
check "  ...and names the missing delegation entry" bash -c "printf '%s' \"$err\" | grep -q 'unknown worker slug'"
check "  ...the found branch is pushed" calls '^git .*push .*origin feat/closed'
check "  ...a PR is opened against main" calls '^gh pr create .*--base main'
check "  ...the body still carries the Review tier" bash -c "grep -qF 'Review tier: **medium**' '$FAKE_BODY_OUT'"
check "  ...and the Evidence block from reports/closed.md" bash -c "grep -qF 'test-publish: ok' '$FAKE_BODY_OUT'"
check "  ...nothing was merged" bash -c '! grep -q "pr merge" "$FAKE_LOG"'

new_closed_case closed-no-branch
export FAKE_BRANCHES='feat/other' FAKE_TRAILERS=''
run closed --cwd "$REPO"
refused "a closed slug no branch carries is refused" "no branch in"
check "  ...and nothing was pushed" bash -c '! grep -q "git push" "$FAKE_LOG"'

new_closed_case closed-ambiguous
export FAKE_BRANCHES='feat/one feat/two' FAKE_WORKER_BRANCH=feat FAKE_SLUG=closed FAKE_TRAILERS=''
run closed --cwd "$REPO"
refused "a closed slug with two matching branches is refused, not guessed" "several branches in"
check "  ...both branches are named" bash -c "printf '%s' \"$err\" | grep -q 'feat/one feat/two'"
check "  ...and nothing was pushed" bash -c '! grep -q "git push" "$FAKE_LOG"'

new_closed_case closed-bad-cwd
export FAKE_BRANCHES='feat/closed' FAKE_WORKER_BRANCH=feat/closed FAKE_SLUG=closed FAKE_TRAILERS=''
run closed --cwd "$CASE/not-a-dir"
refused "a --cwd that is not a directory is refused" "is not a directory"
check "  ...and nothing was pushed" bash -c '! grep -q "git push" "$FAKE_LOG"'

new_closed_case closed-no-evidence
printf '**Mission**: something.\n\nReview tier: **medium**\n' >"$ROOTDIR/reports/closed.md"
export FAKE_BRANCHES='feat/closed' FAKE_WORKER_BRANCH=feat/closed FAKE_SLUG=closed FAKE_TRAILERS=''
run closed --cwd "$REPO"
refused "a closed slug's report still needs an Evidence block" "no Evidence block"
check "  ...and nothing was pushed" bash -c '! grep -q "git push" "$FAKE_LOG"'

new_closed_case closed-no-tier
sed '/^Review tier:/d' "$ROOTDIR/reports/closed.md" >"$CASE/r" && mv "$CASE/r" "$ROOTDIR/reports/closed.md"
export FAKE_BRANCHES='feat/closed' FAKE_WORKER_BRANCH=feat/closed FAKE_SLUG=closed FAKE_TRAILERS=''
run closed --cwd "$REPO"
refused "a closed slug's report still needs a Review tier line" "Review tier"
check "  ...and nothing was pushed" bash -c '! grep -q "git push" "$FAKE_LOG"'

new_case known-slug-with-cwd
run worker --cwd "$CASE/nowhere"
if [ "$rc" -eq 0 ]; then pass "a recorded slug publishes with --cwd given (the entry's cwd wins)"; else fail "a recorded slug publishes with --cwd given (exit $rc: $err)"; fi
check "  ...and says the entry won" bash -c "printf '%s' \"$err\" | grep -q 'its recorded cwd is used'"
check "  ...the recorded branch is pushed" calls '^git .*push .*origin feat/worker'

# --- usage -------------------------------------------------------------------------------------

new_case usage
out=$("$script" 2>"$CASE/err")
rc=$?
if [ "$rc" -eq 2 ]; then pass "no slug prints usage and exits 2"; else fail "no slug prints usage (exit $rc)"; fi

if [ "$fails" -ne 0 ]; then
	printf 'test-publish: %d case(s) failed\n' "$fails" >&2
	exit 1
fi
printf 'test-publish: ok\n'
