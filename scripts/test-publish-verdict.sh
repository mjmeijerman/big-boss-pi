#!/usr/bin/env bash
# test-publish-verdict.sh — a publish is believed only when the pull request itself shows it.
#
# Three failures of the same shape came out of one round: `publish` printed a verdict without
# checking the thing it claimed. Worker `rebase-188` left its rebased commit `d4c2d26` on
# `guard-hidden-rebase` and left `guard-hidden` at `1b6af4e`, `delegate finish` printed
# `preflighted, published, wiped, closed`, and mjmeijerman/pi#188 was still CONFLICTING at
# `1b6af4e` — the gate, the body rebuild, the wipe and the close had all run over a push that put
# nothing where the pull request reads. So the cases here pin four things:
#
#   - a push the remote does not take is a failure, with both shas named;
#   - a push that lands while GitHub still reports the old head is a failure too, because the pull
#     request is the artefact, not the push;
#   - a branch origin already holds at the worker's head says `nothing new to push` and never
#     `published`, and still refreshes the body;
#   - a branch the delegation record does not name, and that the report's `Agent-Slug:` trailer
#     does not name either, is refused before `git push` is ever called.
#
# Every case drives the real `bin/publish` against a temporary PI_BOSS_ROOT, a throwaway git repo
# with a local bare `origin`, and a stub `gh`: no network, no GitHub, no real workspace. The git
# shim records every call and then runs the real git, so "the push never happened" is read from one
# ordered log instead of from the command's word.
#
#   bash scripts/test-publish-verdict.sh      exit 0 = every case held
set -uo pipefail

root=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd)
bin=$root/bin
publish=$bin/publish

work=$(mktemp -d)
# VERDICT_KEEP=1 leaves the throwaway root and the recorded git/gh argv on disk.
keep=${VERDICT_KEEP:-}
trap '[ -n "$keep" ] || rm -rf "$work"' EXIT
unset PI_MASTER_ROOT PI_MASTER_ROOT
export HOME=$work/home
mkdir -p "$HOME" "$work/stub"
real_git=$(command -v git)

# No sleep between reads: the re-read is what is under test here, not how long it takes.
export PUBLISH_READBACK_TRIES=2 PUBLISH_READBACK_SLEEP=0

# git: record the argv, then do what git does. FAKE_LS_SHA makes `ls-remote` answer with a head of
# its own — the remote that accepted the push and still serves the old commit.
cat >"$work/stub/git" <<SHIM
#!/usr/bin/env bash
printf 'git %s\n' "\$*" >>"\${FAKE_LOG:-/dev/null}"
case " \$* " in
*" ls-remote "*)
	if [ -n "\${FAKE_LS_SHA:-}" ]; then
		printf '%s\trefs/heads/%s\n' "\$FAKE_LS_SHA" "\${FAKE_LS_BRANCH:-${branch:-x}}"
		exit 0
	fi
	;;
esac
exec "$real_git" "\$@"
SHIM

# gh: records the argv and answers what publish asks — the repo's own name, the branch's pull
# requests, the body edit, and the one question this file exists for: what the pull request now
# points at. FAKE_VIEW_SHA unset is a gh that cannot answer `pr view`.
cat >"$work/stub/gh" <<'STUB'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >>"${FAKE_LOG:-/dev/null}"
case " $* " in
*" pr view "*)
	[ -n "${FAKE_VIEW_SHA:-}" ] || exit 1
	printf '%s\t%s\t%s\n' "$FAKE_VIEW_SHA" "${FAKE_VIEW_STATE:-OPEN}" "${FAKE_VIEW_MERGEABLE:-MERGEABLE}"
	;;
*" pr list "*)
	printf '%s\n' "${FAKE_PR_JSON:-[]}"
	;;
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

# setup <slug> <branch> <trailer-slug> [pushed] — a bare `origin`, a trailer-free trunk commit, and
# a worker branch carrying `Agent-Slug: <trailer-slug>`. `pushed` puts the branch on origin, which
# is what "the head origin already holds" looks like.
REPO=""
setup() { # <slug> <branch> <trailer-slug> [pushed]
	local slug=$1 branch=$2 trailer=$3 put=${4:-}
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
	"$real_git" -C "$REPO" commit -q -am "feat: the worker's change" -m "Agent-Slug: $trailer"
	[ -z "$put" ] || "$real_git" -C "$REPO" push -q -u origin "$branch"
	mkdir -p "$PI_BOSS_ROOT/reports" "$PI_BOSS_ROOT/state"
	cat >"$PI_BOSS_ROOT/reports/$slug.md" <<REPORT
# Worker \\\`$slug\\\`

Mission: a publish is only a publish when the pull request itself shows the commit.

Now possible: a finished worker no longer reads as published while its pull request still points at the old commit.

Review tier: High — bin/publish is harness code.

Test change: this file is new; it pins the read-back verdict, the nothing-new line and the refusal to push a branch the delegation record does not name.

## Evidence

$ bin/preflight — 5/5 passed
\\\`\\\`\\\`
${slug}: ok
\\\`\\\`\\\`
REPORT
	cat >"$PI_BOSS_ROOT/state/delegations.json" <<JSON
{"$slug":{"slug":"$slug","cwd":"$REPO","branch":"$branch","report":"$PI_BOSS_ROOT/reports/$slug.md"}}
JSON
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
new_case() { # <slug> <branch> <trailer-slug> [pushed]
	case_no=$((case_no + 1))
	setup "$@"
	fresh_log "case$case_no"
	unset FAKE_PR_JSON FAKE_VIEW_SHA FAKE_VIEW_STATE FAKE_VIEW_MERGEABLE FAKE_LS_SHA FAKE_LS_BRANCH FAKE_PR_URL
	out=""
	err=""
	rc=0
	HEAD_SHA=$("$real_git" -C "$REPO" rev-parse "refs/heads/$2")
	BASE_SHA=$("$real_git" -C "$REPO" rev-parse refs/heads/main)
}
run() { # <slug> — the real publish, stdout and stderr kept apart
	out=$("$publish" "$1" 2>"$work/stderr") && rc=0 || rc=$?
	err=$(cat "$work/stderr")
}
open_pr() { export FAKE_PR_JSON="[{\"number\":$1,\"state\":\"OPEN\",\"url\":\"https://github.com/example/repo/pull/$1\"}]"; }

# --- 1. the push runs, origin's head does not move: refused, both shas named --------------------
new_case verdict-worker feat/moved verdict-worker
open_pr 5
export FAKE_LS_SHA=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef FAKE_LS_BRANCH=feat/moved
run verdict-worker
if [ "$rc" -ne 0 ]; then pass "a push origin does not take fails the publish"; else fail "a push origin does not take fails the publish (exit $rc)"; fi
check "  ...the refusal names what origin holds" said 'origin/feat/moved is at deadbee'
check "  ...and the commit that was meant to be there" said "not ${HEAD_SHA:0:7} (the commit just pushed)"
check "  ...and says nothing was published" said 'nothing was published'
check "  ...no verdict line claims it" bash -c "! grep -q '^published ' <<<'$out'"

# --- 2. the push lands, GitHub still reports the old head: refused, both shas named -------------
new_case verdict-worker feat/stale verdict-worker
open_pr 9
export FAKE_VIEW_SHA=$BASE_SHA FAKE_VIEW_STATE=OPEN FAKE_VIEW_MERGEABLE=CONFLICTING
run verdict-worker
if [ "$rc" -ne 0 ]; then pass "a push GitHub has not caught up with fails the publish"; else fail "a push GitHub has not caught up with fails the publish (exit $rc: $err)"; fi
check "  ...the refusal names the head GitHub reports" said "$BASE_SHA"
check "  ...and the head it was meant to show" said "$HEAD_SHA"
check "  ...and says the pull request does not carry the work" said 'does not carry this work'
check "  ...no verdict line claims it" bash -c "! grep -q '^published ' <<<'$out'"
check "  ...and #9's body was not touched over it" bash -c "! grep -q 'pr edit 9' '$FAKE_LOG'"

# --- 3. origin already holds the head: nothing new to push, never published, body still edited --
new_case verdict-worker feat/same verdict-worker pushed
open_pr 7
export FAKE_VIEW_SHA=$HEAD_SHA FAKE_VIEW_STATE=OPEN FAKE_VIEW_MERGEABLE=MERGEABLE
run verdict-worker
if [ "$rc" -eq 0 ]; then pass "a branch origin already holds exits 0"; else fail "a branch origin already holds exits 0 (exit $rc: $err)"; fi
check "  ...it says nothing new to push, with the sha" printed "nothing new to push: #7 is already at ${HEAD_SHA:0:7}"
check "  ...and never says published" bash -c "! grep -q '^published ' <<<'$out'"
check "  ...nothing was pushed" bash -c "! grep -q ' push ' '$FAKE_LOG'"
check "  ...the description was still refreshed, from this report" bash -c "[ \$(grep -c 'pr edit 7' '$FAKE_LOG') -eq 1 ]"
check "  ...with this worker's Evidence" bash -c "grep -qxF 'verdict-worker: ok' '$FAKE_BODY_OUT'"

# --- 4. a branch the delegation record does not name and the trailer does not either: refused ---
new_case verdict-worker feature-a someone-else
# The record says feature-a; this tree has feature-b, whose commit names another worker.
export PI_BOSS_ROOT=$PI_BOSS_ROOT
cat >"$PI_BOSS_ROOT/state/delegations.json" <<JSON
{"verdict-worker":{"slug":"verdict-worker","cwd":"$REPO","branch":"feature-a","report":"$PI_BOSS_ROOT/reports/verdict-worker.md"}}
JSON
"$real_git" -C "$REPO" branch -q -m feature-b
open_pr 3
export FAKE_VIEW_SHA=$HEAD_SHA
run verdict-worker
if [ "$rc" -ne 0 ]; then pass "a branch neither the record nor the trailer names is refused"; else fail "a branch neither the record nor the trailer names is refused (exit $rc: $err)"; fi
check "  ...the refusal names the branch the record holds" said 'names feature-a for verdict-worker'
check "  ...and the branch that was in front of it" said 'feature-b'
check "  ...git push was never called" bash -c "! grep -q ' push ' '$FAKE_LOG'"
check "  ...and no pull request was touched" bash -c "! grep -qE 'pr (edit|create)' '$FAKE_LOG'"

# --- 5. the normal case: one verdict line, with the sha, the state and mergeable ----------------
new_case verdict-worker feat/normal verdict-worker
open_pr 11
export FAKE_VIEW_SHA=$HEAD_SHA FAKE_VIEW_STATE=OPEN FAKE_VIEW_MERGEABLE=MERGEABLE
run verdict-worker
if [ "$rc" -eq 0 ]; then pass "a publish GitHub confirms exits 0"; else fail "a publish GitHub confirms exits 0 (exit $rc: $err)"; fi
check "  ...the verdict line names the worker, the PR and the sha" printed "published verdict-worker: #11 now at ${HEAD_SHA:0:7}"
check "  ...and carries the state and mergeable value" printed '(OPEN, MERGEABLE)'
check "  ...the pull request's own state was asked for" calls 'pr view 11 --json headRefOid,state,mergeable'
check "  ...the branch was pushed first" calls ' push .*origin feat/normal'
check "  ...and no nothing-new line" bash -c "! grep -q 'nothing new to push' <<<'$out'"

if [ -n "$keep" ]; then printf 'kept: %s\n' "$work"; fi
printf '\n%s\n' "$([ "$fails" = 0 ] && echo "publish verdict: ok" || echo "publish verdict: $fails failure(s)")"
[ "$fails" = 0 ]
