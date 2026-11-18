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
*" symbolic-ref --quiet --short HEAD"*)
	# The checkout's own branch: what publish compares the published branch against.
	[ -n "${FAKE_HEAD_BRANCH:-}" ] || exit 1
	printf '%s\n' "$FAKE_HEAD_BRANCH"
	;;
*" rev-parse --verify "*)
	[ "${FAKE_NO_BRANCH:-0}" = 1 ] && exit 1
	# The branch's own head: publish reads it before the push and compares it with what origin
	# answers afterwards, so a silent no-op push is caught.
	printf '%s\n' "${FAKE_LOCAL_HEAD:-0123456789abcdef0123456789abcdef01234567}"
	;;
*" ls-remote "*)
	# origin's answer, asked after every push. FAKE_REMOTE_HEAD different from FAKE_LOCAL_HEAD is a
	# push the remote did not take — the case that printed a URL and pushed nothing.
	if [ "${FAKE_LS_REMOTE_FAIL:-0}" = 1 ]; then
		printf 'fatal: could not read from remote repository\n' >&2
		exit 128
	fi
	printf '%s\trefs/heads/branch\n' "${FAKE_REMOTE_HEAD:-${FAKE_LOCAL_HEAD:-0123456789abcdef0123456789abcdef01234567}}"
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
*" rev-list --count "*)
	# Existence only: the merged decision is the `git cherry` line below, because this repo
	# squash-merges and a merged branch is never an ancestor of trunk.
	[ "${FAKE_CHERRY_FAIL:-0}" = 1 ] && exit 128
	printf '0\n'
	;;
*" cherry "*)
	[ "${FAKE_CHERRY_FAIL:-0}" = 1 ] && exit 128
	printf '%s\n' "${FAKE_CHERRY:-- 0123456789abcdef0123456789abcdef01234567}"
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
	# The duplicate guard asks for JSON across every state; the older open-only form is kept
	# working so the fakes stay honest about what publish actually calls.
	if [[ " $* " == *" --json "* ]]; then
		printf '%s\n' "${FAKE_PR_JSON:-[]}"
		exit 0
	fi
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
	unset FAKE_HEAD_BRANCH FAKE_NOT_REPO FAKE_PR_URL FAKE_PR_JSON FAKE_CHERRY FAKE_CHERRY_FAIL FAKE_TRAILERS FAKE_TITLE FAKE_ORIGIN_HEAD FAKE_NEW_PR_URL FAKE_NO_BRANCH FAKE_GH_FAIL FAKE_BRANCHES FAKE_WORKER_BRANCH FAKE_SLUG \
		FAKE_LOCAL_HEAD FAKE_REMOTE_HEAD FAKE_LS_REMOTE_FAIL
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
said() { grep -qF -- "$1" "$CASE/err" 2>/dev/null; }
printed() { printf '%s\n' "$out" | grep -qF -- "$1"; }

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

# --- the tier survives the markdown the report is written in -----------------------------------
#
# A report is markdown, so the tier arrives wearing it: `**Medium**`, `` `low` ``, `"High"`, a
# trailing period, a reason after it. The body carries the bare word — a body gate should not have
# to parse decoration to find the tier — and the one thing still refused is a value that is not a
# tier at all.

tier_case() { # <name> <tier line> — the good report with exactly that review-tier line
	new_case "$1"
	{
		printf '**Mission**: the tier survives the markdown it was written in.\n\n'
		printf 'Review tier: %s\n\n' "$2"
		printf '## Evidence\n\n```\ntest-publish: ok\n```\n'
	} >"$REPORTER"
	run worker
}

tier_publishes() { # <name> <tier line> <the bare word the body must carry>
	tier_case "$1" "$2"
	if [ "$rc" -eq 0 ]; then pass "a report saying '$2' publishes"; else fail "a report saying '$2' publishes (exit $rc: $err)"; fi
	check "  ...the body carries '$3'" bash -c "grep -qxF 'Review tier: $3' '$FAKE_BODY_OUT'"
	check "  ...and it is the only tier line in the body" bash -c "[ \$(grep -c '^Review tier:' '$FAKE_BODY_OUT') -eq 1 ]"
}

tier_publishes bolded '**Medium**' Medium
tier_publishes underscored '__high__' High
tier_publishes backticked '`low`' Low
tier_publishes quoted '"High"' High
tier_publishes lowercase 'medium' Medium
tier_publishes trailing-period 'Low.' Low
tier_publishes with-reason 'High — one script plus its suite' High
tier_publishes real-report-form '**medium** (script plus tests)' Medium

tier_case made-up-tier 'Whatever'
refused "a made-up tier value is refused" "Review tier"
check "  ...the refusal names what it read" bash -c "printf '%s' \"$err\" | grep -q 'Whatever'"
check "  ...and nothing was pushed" bash -c '! grep -q "git push" "$FAKE_LOG"'
check "  ...and no PR was created" bash -c '! grep -q "pr create" "$FAKE_LOG"'

tier_case empty-tier ''
refused "an empty tier value is refused" "Review tier"
check "  ...and nothing was pushed" bash -c '! grep -q "git push" "$FAKE_LOG"'

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
check "  ...and the duplicate guard says it was skipped, once" bash -c "[ \$(printf '%s' '$err' | grep -c 'duplicate guard skipped') -eq 1 ]"
check "  ...naming the reason" bash -c "printf '%s' '$err' | grep -qF 'duplicate guard skipped — gh is not on PATH'"
check "  ...and nothing was pushed" bash -c '! grep -q "git push" "$FAKE_LOG"'
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
check "the body carries the Review tier line" bash -c "grep -qxF 'Review tier: Medium' '$FAKE_BODY_OUT'"
check "the body carries the Evidence block" bash -c "grep -qF 'test-publish: ok' '$FAKE_BODY_OUT'"
check "the body carries the Thrown away section" bash -c "grep -qF '## Thrown away' '$FAKE_BODY_OUT'"
check "nothing was merged" bash -c '! grep -q "pr merge" "$FAKE_LOG"'
check "trunk was never pushed" bash -c '! grep -qE "push .*( main| master| trunk)$" "$FAKE_LOG"'
check "no force-push flag" bash -c '! grep -q -- "--force" "$FAKE_LOG"'

# A gate that diffs the branch it is told about cannot verify a checkout that stays on trunk: it
# needs `BRANCH=<the worker branch>` beside BODY, or it compares trunk with itself and refuses
# `unverifiable: no changed files`. The form is chosen per repo, so a target that never mentions
# BRANCH still gets the plain call — including one that dies on an unknown variable.

new_case branch-arg-gate
cat >"$REPO/Makefile" <<'EOF'
pr-check:
	@test -n "$(BODY)" || { echo "no BODY"; exit 1; }
	@test -n "$(BRANCH)" || { echo "no BRANCH"; exit 1; }
	@printf '%s\n' "$(BRANCH)" >"$$GATE_LOG"
	@echo "body gate: green"
EOF
export GATE_LOG=$CASE/gate.log
run worker
unset GATE_LOG
if [ "$rc" -eq 0 ]; then pass "a gate whose recipe expands BRANCH publishes green (exit 0)"; else fail "a gate whose recipe expands BRANCH publishes (exit $rc: $err)"; fi
check "  ...it was given the worker's branch" bash -c "grep -qxF 'feat/worker' '$CASE/gate.log'"
check "  ...and the form is named" bash -c "printf '%s' '$err' | grep -q 'expands BRANCH'"
check "  ...the branch was pushed to origin" calls '^git .*push .*origin feat/worker'

new_case gate-rejects-branch
cat >"$REPO/Makefile" <<'EOF'
pr-check:
	@echo "body gate: green"
EOF
mkdir -p "$CASE/rejectmake"
cat >"$CASE/rejectmake/make" <<'FAKE'
#!/usr/bin/env bash
printf 'make %s\n' "$*" >>"${FAKE_LOG:-/dev/null}"
case " $* " in
*" BRANCH="*)
	printf 'make: unknown variable BRANCH\n' >&2
	exit 2
	;;
esac
printf 'body gate: green\n'
FAKE
chmod +x "$CASE/rejectmake/make"
out=$(PATH=$CASE/rejectmake:$PATH "$script" worker 2>"$CASE/err")
rc=$?
err=$(cat "$CASE/err")
if [ "$rc" -eq 0 ]; then pass "a gate that rejects BRANCH is still called with BODY alone (exit 0)"; else fail "a gate that rejects BRANCH still publishes (exit $rc: $err)"; fi
check "  ...the call that ran carried no BRANCH=" bash -c "grep -E '^make .*pr-check' \"\$FAKE_LOG\" | grep -vq 'BRANCH='"
check "  ...and the plain form is what was announced" bash -c "printf '%s' '$err' | grep -qx 'publish: body gate: make -C $REPO pr-check'"
check "  ...the branch was still pushed" calls '^git .*push .*origin feat/worker'

new_case red-make-gate
cat >"$REPO/Makefile" <<'EOF'
pr-check:
	@echo "body gate: red — no Mission line" >&2
	@exit 1
EOF
run worker
if [ "$rc" -ne 0 ]; then pass "a red make pr-check stops the publish"; else fail "a red make pr-check stops the publish (exit 0)"; fi
check "  ...the refusal names the gate" bash -c "printf '%s' '$err' | grep -q 'body gate (make pr-check) failed'"
check "  ...and nothing was pushed" bash -c '! grep -q "git push" "$FAKE_LOG"'
check "  ...and no PR was created" bash -c '! grep -q "pr create" "$FAKE_LOG"'


# --- the body gate has to see the worker's diff, not the checkout's ----------------------------
#
# The gate reads the changed files from the checkout it runs in. A publish from a worktree finds the
# boss's tree on trunk and the worker's commits on its own branch, so a plain `make pr-check` diffed
# trunk against trunk, said `unverifiable: no changed files`, and refused every publish — the bug
# this file exists to keep fixed. The branch is named to the gate exactly when the checkout is not
# on it, and never in a way that blesses a diff nobody looked at.

gate_makefile() { # a gate that records the BODY and the BRANCH it was handed
	cat >"$REPO/Makefile" <<'EOF'
pr-check:
	@test -n "$(BODY)" || { echo "no BODY"; exit 1; }
	@printf 'BODY=%s BRANCH=%s\n' "$(BODY)" "$(BRANCH)" >>"$(GATE_LOG)"
	@echo "body gate: green"
EOF
}

new_case gate-worktree-branch
export FAKE_HEAD_BRANCH=trunk GATE_LOG=$CASE/gate.log
gate_makefile
run worker
if [ "$rc" -eq 0 ]; then pass "a branch the checkout is not on still publishes (exit 0)"; else fail "a branch the checkout is not on still publishes (exit $rc: $err)"; fi
check "  ...the gate is handed the branch" bash -c "grep -q ' BRANCH=feat/worker$' '$GATE_LOG'"
check "  ...and the note says why" bash -c "printf '%s' \"$err\" | grep -q 'not feat/worker'"
check "  ...nothing was merged" bash -c '! grep -q "pr merge" "$FAKE_LOG"'

new_case gate-checked-out
export FAKE_HEAD_BRANCH=feat/worker GATE_LOG=$CASE/gate.log
gate_makefile
run worker
if [ "$rc" -eq 0 ]; then pass "a checkout already on the branch publishes (exit 0)"; else fail "a checkout already on the branch publishes (exit $rc: $err)"; fi
check "  ...the gate is handed no BRANCH" bash -c "grep -q ' BRANCH=$' '$GATE_LOG'"

new_case gate-unverifiable-diff
# What the real gate prints when it cannot see a diff. Naming the branch is another way to see the
# diff, not a way to skip it: an unverifiable run still refuses the publish.
export FAKE_HEAD_BRANCH=trunk
cat >"$REPO/Makefile" <<'EOF'
pr-check:
	@echo "pr-gate: unverifiable: no changed files" >&2
	@exit 2
EOF
run worker
refused "an unverifiable diff still refuses the publish" "body gate"
check "  ...and nothing was pushed" bash -c '! grep -q "git push" "$FAKE_LOG"'
check "  ...and no PR was created" bash -c '! grep -q "pr create" "$FAKE_LOG"'

new_case gate-fallback-branch
# No Makefile: the fallback script gets the same treatment, as a flag — but only a script that
# parses one is handed it, so the fake declares `--branch` the way a real gate would.
export FAKE_HEAD_BRANCH=trunk GATE_LOG=$CASE/gate.log
rm -f "$REPO/Makefile"
mkdir -p "$REPO/scripts"
cat >"$REPO/scripts/pr-gate.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GATE_LOG"
while [ $# -gt 0 ]; do
	case $1 in
	--branch) shift 2 ;;
	--body) shift 2 ;;
	*) shift ;;
	esac
done
echo "body gate: green"
EOF
chmod +x "$REPO/scripts/pr-gate.sh"
run worker
if [ "$rc" -eq 0 ]; then pass "the fallback gate publishes a worktree branch (exit 0)"; else fail "the fallback gate publishes a worktree branch (exit $rc: $err)"; fi
check "  ...it is handed --branch" bash -c "grep -q -- '--branch feat/worker' '$GATE_LOG'"

new_case gate-fallback-no-flag
# A pr-gate.sh that never mentions --branch is not a script to hand an unknown flag to: it is called
# with --body alone, exactly as before the branch was ever named. This is the same care the `make -n`
# probe takes for BRANCH=.
export FAKE_HEAD_BRANCH=trunk GATE_LOG=$CASE/gate.log
rm -f "$REPO/Makefile"
mkdir -p "$REPO/scripts"
cat >"$REPO/scripts/pr-gate.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GATE_LOG"
while [ $# -gt 0 ]; do
	case $1 in
	--body) shift 2 ;;
	*) shift ;;
	esac
done
echo "body gate: green"
EOF
chmod +x "$REPO/scripts/pr-gate.sh"
run worker
if [ "$rc" -eq 0 ]; then pass "a fallback gate with no --branch still publishes (exit 0)"; else fail "a fallback gate with no --branch still publishes (exit $rc: $err)"; fi
check "  ...it is handed --body alone" bash -c "grep -q -- '--body ' '$GATE_LOG'"
check "  ...and no --branch it never parsed" bash -c "! grep -q -- '--branch' '$GATE_LOG'"
check "  ...the plain form is what was announced" bash -c "printf '%s' '$err' | grep -qx 'publish: body gate: $REPO/scripts/pr-gate.sh --body'"

new_case gate-fallback-checked-out
export FAKE_HEAD_BRANCH=feat/worker GATE_LOG=$CASE/gate.log
run worker
check "  ...and no --branch when the checkout is the branch" bash -c "! grep -q -- '--branch' '$GATE_LOG'"
rm -rf "$REPO/scripts"

# --- a target repo's test-change gate gets the worker's own reason ---------------------------------
#
# `make pr-check` here (and in /home/mark/.pi) asks why a test changed beside its source, and a
# body with that line is the only thing that answers it. The worker is the only one who knows, so
# the report's line is carried into the body; when the report has none, the body has none, and the
# gate that wants one still refuses. Nothing here invents a reason.

new_case test-change-carried
export FAKE_HEAD_BRANCH=trunk GATE_LOG=$CASE/gate.log
gate_makefile
sed -i 's|^Review tier:|**Test change:** the retry needed a fake clock, so the retry test fakes one.\n\nReview tier:|' "$REPORTER"
run worker
if [ "$rc" -eq 0 ]; then pass "a report with a Test change line publishes"; else fail "a report with a Test change line publishes (exit $rc: $err)"; fi
check "  ...the body carries the bare label and the reason" bash -c "grep -qxF 'Test change: the retry needed a fake clock, so the retry test fakes one.' '$FAKE_BODY_OUT'"
check "  ...and only once" bash -c "[ \$(grep -c '^Test change:' '$FAKE_BODY_OUT') -eq 1 ]"

new_case test-change-absent
export FAKE_HEAD_BRANCH=trunk GATE_LOG=$CASE/gate.log
gate_makefile
run worker
if [ "$rc" -eq 0 ]; then pass "a report with no Test change line still publishes"; else fail "a report with no Test change line still publishes (exit $rc: $err)"; fi
check "  ...and puts no Test change line in the body" bash -c "! grep -q '^Test change:' '$FAKE_BODY_OUT'"

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
export FAKE_PR_JSON='[{"number":5,"state":"OPEN","url":"https://github.com/example/repo/pull/5"}]'
run worker
if [ "$rc" -eq 0 ]; then pass "an existing PR exits 0"; else fail "an existing PR exits 0 (exit $rc: $err)"; fi
check "  ...its URL is printed" bash -c "printf '%s' '$out' | grep -qF 'https://github.com/example/repo/pull/5'"
check "  ...nothing was pushed" bash -c '! grep -q "git push" "$FAKE_LOG"'
check "  ...no second PR was created" bash -c '! grep -q "pr create" "$FAKE_LOG"'

# --- one PR per branch, before anything is pushed ----------------------------------------------
#
# A proof run on a branch that was already merged opened a second pull request, which a person had
# to close. The branch is now asked about once, across every state, before the push: an open PR or an
# already-merged one stops the publish, a closed one is named so nobody reads the new PR as the first,
# and a merged branch that carries further commits still publishes them.

pr_case() { # <name> <the JSON gh answers with>
	new_case "$1"
	export FAKE_PR_JSON=$2
	: >"$FAKE_LOG"
}

pr_case pr-open '[{"number":12,"state":"OPEN","url":"https://github.com/example/repo/pull/12"}]'
run worker
if [ "$rc" -eq 0 ]; then pass "a branch with an open PR exits 0"; else fail "a branch with an open PR exits 0 (exit $rc: $err)"; fi
check "  ...the open PR is named by number and branch" said '#12 is already open for feat/worker'
check "  ...its URL is printed" printed 'https://github.com/example/repo/pull/12'
check "  ...nothing was pushed" bash -c '! grep -q "git push" "$FAKE_LOG"'
check "  ...no second PR was created" bash -c '! grep -q "pr create" "$FAKE_LOG"'
check "  ...the branch was asked about across every state" calls '^gh pr list .*--state all'

pr_case pr-merged '[{"number":11,"state":"MERGED","url":"https://github.com/example/repo/pull/11"}]'
run worker
if [ "$rc" -eq 0 ]; then pass "a branch already merged exits 0"; else fail "a branch already merged exits 0 (exit $rc: $err)"; fi
check "  ...it says already merged and names the PR" said 'feat/worker is already merged as #11'
check "  ...it says there is nothing to publish" said 'nothing to publish'
check "  ...nothing was pushed" bash -c '! grep -q "git push" "$FAKE_LOG"'
check "  ...no second PR was created" bash -c '! grep -q "pr create" "$FAKE_LOG"'

pr_case pr-merged-new-commits '[{"number":11,"state":"MERGED","url":"https://github.com/example/repo/pull/11"}]'
export FAKE_CHERRY='+ 1111111111111111111111111111111111111111
+ 2222222222222222222222222222222222222222'
run worker
if [ "$rc" -eq 0 ]; then pass "a merged branch with new commits still publishes (exit 0)"; else fail "a merged branch with new commits still publishes (exit $rc: $err)"; fi
check "  ...it names the PR it builds on" said 'was merged as #11'
check "  ...and the new commits" said '2 commit(s)'
check "  ...the branch was pushed" calls '^git .*push .*origin feat/worker'
check "  ...and a PR was opened" calls '^gh pr create .*--base main'

pr_case pr-merged-squashed '[{"number":10,"state":"MERGED","url":"https://github.com/example/repo/pull/10"}]'
# A squash merge: the branch's commit is not an ancestor of trunk, but `git cherry` marks its patch
# `-` because the change is upstream under the landing sha. This is the shape that opened a duplicate
# PR in the first place, so it is the case that must refuse.
run worker
if [ "$rc" -eq 0 ]; then pass "a squash-merged branch exits 0"; else fail "a squash-merged branch exits 0 (exit $rc: $err)"; fi
check "  ...it is read as already merged" said 'feat/worker is already merged as #10'
check "  ...nothing was pushed" bash -c '! grep -q "git push" "$FAKE_LOG"'

pr_case pr-merged-cannot-tell '[{"number":8,"state":"MERGED","url":"https://github.com/example/repo/pull/8"}]'
export FAKE_CHERRY_FAIL=1
run worker
if [ "$rc" -eq 0 ]; then pass "a merge git cannot read still publishes (exit 0)"; else fail "a merge git cannot read still publishes (exit $rc: $err)"; fi
check "  ...the guard says it cannot tell" said 'cannot tell whether it carries work'
check "  ...and the branch is pushed" calls '^git .*push .*origin feat/worker'

pr_case pr-closed '[{"number":9,"state":"CLOSED","url":"https://github.com/example/repo/pull/9"}]'
run worker
if [ "$rc" -eq 0 ]; then pass "a closed, unmerged PR still publishes (exit 0)"; else fail "a closed, unmerged PR still publishes (exit $rc: $err)"; fi
check "  ...the old number is named" said '#9 was closed without merge'
check "  ...the branch was pushed" calls '^git .*push .*origin feat/worker'
check "  ...and a new PR was opened" calls '^gh pr create .*--base main'

pr_case pr-open-wins '[{"number":3,"state":"CLOSED","url":"https://github.com/example/repo/pull/3"},{"number":4,"state":"OPEN","url":"https://github.com/example/repo/pull/4"}]'
run worker
if [ "$rc" -eq 0 ]; then pass "an old closed PR beside an open one exits 0"; else fail "an old closed PR beside an open one exits 0 (exit $rc: $err)"; fi
check "  ...the open one is the answer" printed '/pull/4'
check "  ...nothing was pushed" bash -c '! grep -q "git push" "$FAKE_LOG"'

# --- the push has to be proved, not announced ---------------------------------------------------
#
# Twice a publish printed a URL and exited 0 while `git ls-remote origin <branch>` still showed the
# old head (fix/agent-pane-sandbox-pi at 0c9e28a, then fix/agent-pane-delta at 24e464f), and pushing
# the same branch by hand worked immediately: the remote, the auth and the branch were all fine, the
# publish had simply never asked whether its push landed. So the head is read before the push and
# origin is asked for it afterwards, and a publish that skips the push because the guard answered
# reads the remote too, because a URL on its own used to read as `published`.
new_case push-approved
export FAKE_LOCAL_HEAD=0123456789abcdef0123456789abcdef01234567 FAKE_REMOTE_HEAD=0123456789abcdef0123456789abcdef01234567
run worker
if [ "$rc" -eq 0 ]; then pass "a push the remote confirms still publishes"; else fail "a push the remote confirms still publishes (exit $rc: $err)"; fi
check "  ...origin was asked for the branch head afterwards" calls '^git .*ls-remote .*origin refs/heads/feat/worker'
check "  ...and the confirmed commit is named" said 'is at 0123456, the commit just pushed'

new_case push-silent-noop
export FAKE_LOCAL_HEAD=0123456789abcdef0123456789abcdef01234567 FAKE_REMOTE_HEAD=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
run worker
if [ "$rc" -ne 0 ]; then pass "a push the remote never took fails the publish"; else fail "a push the remote never took fails the publish (exit $rc: $err)"; fi
check "  ...the refusal names what origin holds" said 'origin/feat/worker is at deadbee'
check "  ...and the commit it pushed" said 'not 0123456'
check "  ...and says nothing was published" said 'nothing was published'
check "  ...no PR was opened" bash -c '! grep -q "pr create" "$FAKE_LOG"'
check "  ...and no PR URL is printed" bash -c "! printf '%s' \"$out\" | grep -q 'pull/'"

new_case push-unconfirmed
export FAKE_LS_REMOTE_FAIL=1
run worker
if [ "$rc" -ne 0 ]; then pass "a push whose head cannot be read back fails the publish"; else fail "a push whose head cannot be read back fails the publish (exit $rc: $err)"; fi
check "  ...and the refusal says the push is unconfirmed" said 'unconfirmed'
check "  ...no PR was opened" bash -c '! grep -q "pr create" "$FAKE_LOG"'

new_case open-pr-behind
export FAKE_PR_JSON='[{"number":12,"state":"OPEN","url":"https://github.com/example/repo/pull/12"}]'
export FAKE_LOCAL_HEAD=0123456789abcdef0123456789abcdef01234567 FAKE_REMOTE_HEAD=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
run worker
if [ "$rc" -ne 0 ]; then pass "an open PR whose branch is not on the remote is not a publish"; else fail "an open PR whose branch is not on the remote is not a publish (exit $rc: $err)"; fi
check "  ...the open PR is still named" said '#12 is already open for feat/worker'
check "  ...the branch head is named too" said 'the branch is at 0123456'
check "  ...and nothing was pushed there" bash -c '! grep -q "git push" "$FAKE_LOG"'

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
check "  ...the body still carries the Review tier" bash -c "grep -qxF 'Review tier: Medium' '$FAKE_BODY_OUT'"
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
