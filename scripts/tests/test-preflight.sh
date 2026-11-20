#!/usr/bin/env bash
# test-preflight.sh — `bin/preflight` runs the checks CI would run, and `delegate finish` refuses to
# publish a branch that does not pass them.
#
# Red CI rounds are the workspace's biggest cost — #177 three rebases, #180 three rounds, #183 two,
# #66 and #184 one each — and every one of those failures was a check this machine answers in
# seconds. So the gate is checked the way it will be used: a throwaway PI_BOSS_ROOT, a throwaway
# repo with a bare origin, and stub `gh`, `herdr-app` and `hc` on PATH. What happened is read from
# the stubs' logs, the decisions log and origin's refs, never from what a command said about itself.
#
# The cases are the ones a bypass would have to get past:
#   A. every check passing publishes exactly as it does today — the branch reaches origin, the PR
#      body is the report's, the wipe and the close follow;
#   B. a syntax error in a changed shell file refuses the publish: no push, no `pr create`;
#   C. a semgrep finding refuses it;
#   D. a test that needs the developer's PATH passes here and fails under the scrub (the pi#66
#      shape), while a test that needs nothing of the sort passes both;
#   E. a docs-only diff takes the fast path, names why each check was skipped, and still refuses a
#      body the gate would refuse (a made-up review tier);
#   G. a pi-shaped checkout — no root AGENTS.md but a `pr-check` target — skips the docs budget by
#      name, keeps the body gate blocking, and exits nonzero only for a real body problem;
#   H. a checkout with neither a root AGENTS.md nor a body gate passes with two named skips;
#   F. `--skip-preflight "<reason>"` publishes and records the reason in state/decisions.jsonl;
#   I. the suites run each exactly once and side by side: an unrecognised scripts-test target is run
#      whole and exactly once, the two globs are run directly (the node suite never twice, which is
#      what the old shape did), every discovered suite is reported with its own time, the cap holds,
#      a failing suite fails the gate with its name, and a prose-only diff names both fast paths.
#   J. the body gate runs in the checkout that holds the branch: a worktree for a branch in a
#      worktree, in place for a main checkout that is on the branch, and a throwaway worktree for a
#      branch only a ref holds — removed afterwards, on the refused path too;
#   K. a branch cut before a pull request merged refuses the publish: the `behind` check's FAIL,
#      the rebase line, no push, the report still there and the space still open. #68's shape —
#      spawned 19:27:52Z, #67 merged 19:32:04Z, arrived CONFLICTING with AGENTS.md and README.md.
#   L. the receipts: a second run on an unchanged tree reuses every verdict and runs no check (the
#      stub suite is invoked once across both runs and the second run is much faster); a tracked
#      file edited, a changed check set, a changed bin/preflight and an expired TTL each invalidate;
#      --fresh re-runs; a cached FAIL still blocks with the transcript that failed; a check a fast
#      path skipped leaves no receipt behind.
#
#   bash scripts/tests/test-preflight.sh      exit 0 = every case held
set -uo pipefail

root=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/../.." && pwd)
pf=$root/bin/preflight
delegate=$root/bin/delegate

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export PI_BOSS_ROOT=$work/root
unset PI_MASTER_ROOT
mkdir -p "$PI_BOSS_ROOT/reports" "$PI_BOSS_ROOT/state" "$PI_BOSS_ROOT/specs" "$work/stub"

# Hermetic git: no user config, no hooks, no gpg, no prompts.
export GIT_AUTHOR_NAME=T GIT_AUTHOR_EMAIL=t@example.com
export GIT_COMMITTER_NAME=T GIT_COMMITTER_EMAIL=t@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_TERMINAL_PROMPT=0

# --- the fakes ---------------------------------------------------------------------------------

cat >"$work/stub/gh" <<'STUB'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >>"${GH_LOG:-/dev/null}"
case " $* " in
*" pr list "*)
	printf '%s\n' "${FAKE_PR_JSON:-[]}"
	exit 0
	;;
*" pr create "*)
	while [ $# -gt 0 ]; do
		[ "$1" = --body-file ] && cp "$2" "${GH_BODY:-/dev/null}"
		shift
	done
	printf 'https://github.com/example/repo/pull/11\n'
	exit 0
	;;
*" pr edit "*)
	printf 'gh pr edit was called\n' >>"${GH_LOG:-/dev/null}"
	exit 0
	;;
*) exit 0 ;;
esac
STUB
# herdr-app: `ls` answers with nothing, which space_close reads as "cannot tell", so the close stands
# on the record. Everything else is logged.
cat >"$work/stub/herdr-app" <<STUB
#!/usr/bin/env bash
if [ "\${1:-}" = ls ]; then exit 0; fi
printf '%s\n' "\$*" >>"$work/herdr-calls"
exit 0
STUB
printf '#!/usr/bin/env bash\nexit 0\n' >"$work/stub/hc"
chmod +x "$work/stub/gh" "$work/stub/herdr-app" "$work/stub/hc"
export PATH=$work/stub:$PATH
export GH_LOG=$work/gh.log GH_BODY=$work/gh-body

fails=0
skips=0
pass() { printf '  ok    %s\n' "$*"; }
skip() { printf '  skip  %s\n' "$*"; skips=$((skips + 1)); }
fail() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }

OUT=""
RC=0
run() { # run a command, capture both streams, keep the exit code
	OUT=$("$@" 2>&1) && RC=0 || RC=$?
}

# --- the fixture: a repo with a trunk, a branch and a report that satisfies every rule ----------

REPO=""
SHA=""
reset_case() { # <name>
	CASE=$work/$1
	rm -rf "$CASE"
	mkdir -p "$CASE"
	REPO=$CASE/repo
	git init -q --bare -b main "$CASE/origin.git"
	git init -q -b main "$REPO"
	git -C "$REPO" remote add origin "$CASE/origin.git"
	printf 'the trunk\n' >"$REPO/README.md"
	git -C "$REPO" add -A
	git -C "$REPO" commit -q -m "trunk: the first commit"
	git -C "$REPO" push -q origin main
	git -C "$REPO" checkout -q -b feat/w1
	: >"$CASE/gh.log"
	: >"$GH_LOG"
	: >"$work/herdr-calls"
	: >"$PI_BOSS_ROOT/state/decisions.jsonl"
	unset FAKE_PR_JSON FAKE_PREFLIGHT_RC
}

commit_branch() { # <subject>
	git -C "$REPO" add -A
	git -C "$REPO" commit -q -m "$1" -m "Agent-Slug: w1"
	SHA=$(git -C "$REPO" rev-parse HEAD)
}

write_report() { # <tier> <names-a-preflight-run: yes|no> [extra line]
	local tier=$1 names=$2 extra=${3:-}
	{
		printf '# Report\n\nMission: the gate runs before the publish, on this machine.\n\n'
		printf 'Review tier: %s\n\n' "$tier"
		printf 'Now possible: a branch that fails CI never reaches GitHub.\n\n'
		[ -z "$extra" ] || printf '%s\n\n' "$extra"
		printf '## What now works\n\n`bin/preflight` and a `finish` that refuses to publish past it.\n\n'
		printf 'Commit: %s\n\n' "$SHA"
		printf '## Evidence\n\n'
		if [ "$names" = yes ]; then
			printf '$ bin/preflight --slug w1\npreflight: 5/5 passed on feat/w1\n\n'
		fi
		if [ "$names" = yes ]; then
			printf '```\npreflight: 5/5 passed on feat/w1\n```\n\n'
		else
			printf '```\ndelegate finish: ok\n```\n\n'
		fi
		printf '## Thrown away\n\n1. Deleted? nothing.\n2. Duplicated? nothing.\n'
		printf '3. Next feature? yes.\n4. Learned? the gate is one script.\n5. Rewrite? nothing.\n'
	} >"$PI_BOSS_ROOT/reports/w1.md"
}

track_worker() { # a delegation entry pointing at the throwaway repo
	track_worker_at "$REPO" feat/w1
}

track_worker_at() { # <cwd> <branch>
	printf '{"w1":{"space":"space-w1","cwd":"%s","branch":"%s","report":"%s"}}\n' \
		"$1" "$2" "$PI_BOSS_ROOT/reports/w1.md" >"$PI_BOSS_ROOT/state/delegations.json"
}

pushed() { grep -qF -- "git push" "$1" 2>/dev/null; }
gh_calls() { grep -cE -- "^gh " "${GH_LOG:-/dev/null}" 2>/dev/null || printf '0'; }
gh_saw() { grep -qE -- "$1" "${GH_LOG:-/dev/null}" 2>/dev/null; }
origin_head() { git -C "$REPO" ls-remote origin refs/heads/feat/w1 | awk 'NR==1 { print $1 }'; }
said() { printf '%s\n' "$OUT" | grep -qF -- "$1"; }
decision_reason() { # <command>
	node -e '
		const fs = require("fs");
		let rows = [];
		try {
			rows = fs.readFileSync(process.argv[1], "utf8").split("\n").filter(Boolean)
				.map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
		} catch { process.exit(1); }
		const r = rows.filter((x) => x.command === process.argv[2] && x.slug === "w1").pop();
		if (!r) process.exit(1);
		process.stdout.write(String(r.reason || ""));' "$PI_BOSS_ROOT/state/decisions.jsonl" "$1"
}

# --- A. every check passing publishes exactly as it does today ---------------------------------

# A branch whose only change is a small shell script: syntax is the only check with work to do, the
# suites and the scrub are skipped by name, semgrep runs over one file.
reset_case green
mkdir -p "$REPO/scripts"
printf '#!/usr/bin/env bash\n# a changed script, and a clean one\nprintf "ok\\n"\n' >"$REPO/scripts/tool.sh"
chmod +x "$REPO/scripts/tool.sh"
commit_branch "feat(scripts): a small clean script"
write_report Medium yes
track_worker
have_semgrep=0
command -v semgrep >/dev/null 2>&1 && have_semgrep=1
run "$delegate" finish w1
if [ "$have_semgrep" = 0 ]; then
	# The scrub's PATH has no semgrep, and a changed code file with no semgrep is a FAIL by design
	# ("semgrep is not installed here, so this check cannot pass"), never a silent pass. That is
	# what this branch has to do here: refuse, and push nothing.
	if [ "$RC" = 0 ]; then
		fail "a changed code file published with no semgrep on this PATH — $OUT"
	elif ! said "semgrep is not installed"; then
		fail "no semgrep on this PATH was not named plainly — $OUT"
	elif gh_saw '^gh pr (create|edit) ' || [ -n "$(origin_head)" ]; then
		fail "a push or a pull request happened with no semgrep on this PATH"
	else
		pass "with no semgrep on this PATH a changed code file refuses the publish, and says so"
	fi
elif [ "$RC" != 0 ]; then
	fail "a green branch did not finish: exit $RC — $OUT"
elif [ "$have_semgrep" = 1 ] && [ "$(origin_head)" != "$SHA" ]; then
	fail "the branch did not reach origin at its own commit (origin has $(origin_head 2>/dev/null))"
elif [ "$have_semgrep" = 1 ] && ! gh_saw '^gh pr create '; then
	fail "no pull request was opened: $(tr '\n' ';' <"$GH_LOG")"
elif [ "$have_semgrep" = 1 ] && ! grep -q '^Review tier: Medium$' "$GH_BODY"; then
	fail "the PR body did not carry the tier"
elif [ "$have_semgrep" = 1 ] && { ! said "preflight" || { ! said "4/4" && ! said "5/5"; }; }; then
	fail "finish did not report the preflight step — $OUT"
elif [ "$have_semgrep" = 1 ] && [ ! -s "$PI_BOSS_ROOT/state/decisions.jsonl" ]; then
	fail "the wipe step recorded nothing"
else
	pass "a branch that passes every check publishes, wipes and closes as it did before"
fi
check_repro() { :; }

# --- B. a syntax error in a changed shell file refuses the publish ------------------------------

reset_case syntax
mkdir -p "$REPO/scripts"
printf '#!/usr/bin/env bash\nif [ 1 = 1 ]; then\nprintf "unclosed if\\n"\n' >"$REPO/scripts/broken.sh"
commit_branch "feat(scripts): a script with an unclosed if"
write_report Medium yes
track_worker
run "$delegate" finish w1
if [ "$RC" = 0 ]; then
	fail "a syntax error published anyway — $OUT"
elif ! said "FAIL" || ! said "syntax"; then
	fail "the failing check is not named as the syntax one — $OUT"
elif ! said "scripts/broken.sh"; then
	fail "the failing file is not named — $OUT"
elif ! said "preflight --only syntax"; then
	fail "the refusal does not carry the command that reproduces it — $OUT"
elif gh_saw '^gh pr (create|edit) '; then
	fail "a pull request was created or edited past a syntax failure"
elif [ -n "$(origin_head)" ]; then
	fail "the branch was pushed past a syntax failure"
elif [ -s "$PI_BOSS_ROOT/state/decisions.jsonl" ]; then
	fail "the run recorded a step past a syntax failure"
else
	pass "a syntax error stops the run before the push: no push, no pr create, no wipe"
fi

# --- C. a semgrep finding refuses it ------------------------------------------------------------

# The pinned local rules only (no registry, so no network): a `new RegExp()` built from a variable,
# which is the shape that reached CI as pi#183.
reset_case semgrep
printf 'export function match(input) {\n\treturn new RegExp(input).test("x");\n}\n' >"$REPO/match.mjs"
commit_branch "feat: a dynamic regexp"
write_report Medium yes
track_worker
if [ "$have_semgrep" = 0 ]; then
	skip "a semgrep finding needs semgrep on PATH, and this PATH has none (the scrub run)"
else
run env PREFLIGHT_SEMGREP_CONFIG="$root/scripts/semgrep-rules.yml" "$delegate" finish w1
if [ "$RC" = 0 ]; then
	fail "a semgrep finding published anyway — $OUT"
elif ! said "semgrep"; then
	fail "the semgrep check is not named — $OUT"
elif ! said "match.mjs"; then
	fail "the finding does not name the file — $OUT"
elif gh_saw '^gh pr (create|edit) ' || [ -n "$(origin_head)" ]; then
	fail "a pull request or a push happened past a semgrep finding"
else
	pass "a semgrep finding on a changed file refuses the publish"
fi
fi

# A checkout where semgrep is missing must not read as clean: the check fails and says so.
reset_case semgrep-missing
printf 'export const ok = 1;\n' >"$REPO/ok.mjs"
commit_branch "feat: one constant"
write_report Medium yes
track_worker
nopath=$CASE/nopath
mkdir -p "$nopath"
for c in bash env dirname readlink node grep awk sed mktemp rm cp cat head tail tr git date wc sort cut; do
	p=$(command -v "$c" 2>/dev/null) && ln -sf "$p" "$nopath/$c"
done
out=$(PATH=$nopath "$pf" --only semgrep --cwd "$REPO" feat/w1 2>&1) && rc=0 || rc=$?
if [ "$rc" = 0 ]; then
	fail "semgrep missing read as a passing check"
elif ! printf '%s' "$out" | grep -qF 'semgrep is not installed'; then
	fail "semgrep missing was not named plainly — $out"
else
	pass "semgrep missing is a FAIL that says so, never a silent pass"
fi

# --- D. the scrub: a test that needs the developer's PATH --------------------------------------

# The pi#66 shape. The probe needs a tool that is on this machine's PATH and not in /usr/bin:/bin,
# which is exactly what a runner has. It passes when the suite runs normally and fails under the
# scrub — that pair is the check, and either half alone would be a lie.
reset_case scrub
mkdir -p "$REPO/scripts/tests"
cat >"$REPO/scripts/tests/test-probe.sh" <<'STUB'
#!/usr/bin/env bash
# Needs a command this machine has and a runner does not.
command -v herdr-app >/dev/null 2>&1 || { printf 'no herdr-app on PATH\n' >&2; exit 1; }
printf 'probe: ok\n'
STUB
cat >"$REPO/scripts/tests/test-clean.sh" <<'STUB'
#!/usr/bin/env bash
# Needs nothing but the shell.
printf 'clean: ok\n'
STUB
chmod +x "$REPO/scripts/tests/test-probe.sh" "$REPO/scripts/tests/test-clean.sh"
commit_branch "test(scripts): a probe that needs PATH, and one that does not"
write_report Medium yes
track_worker
run env PATH="$PATH" bash "$REPO/scripts/tests/test-probe.sh"
probe_alone=$RC
run "$pf" --only scrub --cwd "$REPO" feat/w1
if [ "$probe_alone" != 0 ]; then
	fail "the probe does not pass with the developer's PATH, so this case proves nothing"
elif [ "$RC" = 0 ]; then
	fail "the scrub passed a test that needs the developer's PATH — $OUT"
elif ! said "the runner does not have your PATH"; then
	fail "the scrub does not say what it is — $OUT"
elif ! said "test-probe.sh"; then
	fail "the scrub does not name the failing test — $OUT"
elif said "test-clean.sh failed"; then
	fail "the scrub failed the test that needs nothing — $OUT"
else
	pass "a test that needs PATH passes normally and blocks under env -i (the pi#66 shape)"
fi

# --- E. a docs-only diff: the fast path, and a body the gate still refuses ---------------------

reset_case docs-only
printf 'the trunk\n\nOne more paragraph of documentation.\n' >"$REPO/README.md"
commit_branch "docs: one more paragraph"
write_report Whatever yes
track_worker
run "$pf" --slug w1
if [ "$RC" = 0 ]; then
	fail "a made-up review tier passed the body check — $OUT"
elif ! said "skip"; then
	fail "the docs-only path skipped nothing, so it ran the whole thing — $OUT"
elif ! said "no changed code file"; then
	fail "the skipped checks do not name why (no code changed) — $OUT"
elif ! said "Review tier"; then
	fail "the refusal does not name the tier line — $OUT"
else
	pass "a docs-only diff skips the code checks by name and still refuses a body the gate refuses"
fi
check_fast() {
	if ! printf '%s\n' "$OUT" | grep -qE '^skip .*scrub'; then
		fail "the scrub was not named as skipped on a docs-only diff — $OUT"
	fi
	if printf '%s\n' "$OUT" | grep -qE '^pass .*suites'; then
		fail "the suites check passed on a docs-only diff, so it was not skipped — $OUT"
	fi
}
check_fast

# ...and the same docs-only branch refuses the publish, so no body reaches GitHub.
run "$delegate" finish w1
if [ "$RC" = 0 ]; then
	fail "finish published a report whose tier the body gate refuses — $OUT"
elif gh_saw '^gh pr (create|edit) ' || [ -n "$(origin_head)" ]; then
	fail "a pull request or a push happened past a refused body"
else
	pass "a bad tier on a docs-only diff blocks the publish on the fast path"
fi

# --- G. a pi-shaped checkout: no root AGENTS.md, and the body gate still blocks -----------------

# The shape that found this: a pi checkout keeps its agent instructions at agent/AGENTS.md, so it has
# no root AGENTS.md and no docs budget — but its Makefile has a pr-check target, and that gate has to
# keep working. The budget half is a named skip, not a failure the branch cannot fix; a checkout that
# fails on its own shape is a checkout whose gate gets bypassed with --skip-preflight.
reset_case pi-shape
mkdir -p "$REPO/scripts/tests"
printf 'export const ok = 1;\n' >"$REPO/ok.mjs"
cat >"$REPO/scripts/tests/smoke.test.mjs" <<'TEST'
import { test } from "node:test";
test("smoke", () => {});
TEST
cat >"$REPO/Makefile" <<'MAKE'
pr-check:
	@bash $(CURDIR)/scripts/body-gate.sh "$(BODY)"

scripts-test:
	@node --test scripts/tests/*.test.mjs
MAKE
cat >"$REPO/scripts/body-gate.sh" <<'GATE'
#!/usr/bin/env bash
# The shape of a target repo's own body gate: it reads the body bin/publish would send.
body=${1:-}
[ -f "$body" ] || { printf 'pr-check: no body file\n' >&2; exit 1; }
grep -qE '^Review tier: ' "$body" || { printf 'pr-check: no Review tier: line\n' >&2; exit 1; }
grep -q '^## Evidence' "$body" || { printf 'pr-check: no Evidence section\n' >&2; exit 1; }
if [ -n "${GATE_WANTS_TEST_CHANGE:-}" ] && ! grep -qE '^Test change: ' "$body"; then
	printf 'pr-check: no Test change: line\n' >&2
	exit 1
fi
printf 'pr-check: body ok\n'
GATE
chmod +x "$REPO/scripts/body-gate.sh"
commit_branch "feat: a pi-shaped checkout, a body gate, and no root AGENTS.md"
track_worker

# G1. A body the gate refuses still refuses the run, and the budget is not blamed for it.
write_report Whatever yes
run "$pf" --only body --slug w1
if [ "$RC" = 0 ]; then
	fail "a made-up review tier passed the body check in a pi-shaped checkout — $OUT"
elif ! said "docs budget: no root AGENTS.md in this checkout — skipped"; then
	fail "the docs budget did not name itself as skipped — $OUT"
elif ! said "Review tier"; then
	fail "the refusal does not name the tier line — $OUT"
else
	pass "a pi-shaped checkout skips the docs budget by name and still refuses a body the gate refuses"
fi

# G2. A body the gate accepts passes, with the skip said out loud and the gate named.
write_report Medium yes
run "$pf" --only body --slug w1
if [ "$RC" != 0 ]; then
	fail "a pi-shaped checkout with a good body failed the body check: exit $RC — $OUT"
elif ! said "docs budget: no root AGENTS.md in this checkout — skipped"; then
	fail "the docs budget did not name itself as skipped — $OUT"
elif said "no pr-check target"; then
	fail "the body gate was skipped in a checkout that has one — $OUT"
elif ! said "body gate: make pr-check passed"; then
	fail "the body gate did not run and pass — $OUT"
else
	pass "a pi-shaped checkout passes with the budget skipped by name and its own pr-check gate run"
fi

# G3. The gate still blocks: a report publish accepts, refused by the checkout's own gate.
run env GATE_WANTS_TEST_CHANGE=1 "$pf" --only body --slug w1
if [ "$RC" = 0 ]; then
	fail "the checkout's own body gate refused a body and the check passed anyway — $OUT"
elif ! said "Test change"; then
	fail "the gate's refusal is not shown — $OUT"
elif ! said "docs budget: no root AGENTS.md in this checkout — skipped"; then
	fail "the docs budget did not name itself as skipped on the failing run — $OUT"
else
	pass "a pi-shaped checkout's own pr-check gate still blocks a body it refuses"
fi

# --- H. no root AGENTS.md and no body gate: two named skips, and the check passes --------------

reset_case no-gate
printf 'export const ok = 1;\n' >"$REPO/ok.mjs"
commit_branch "feat: a checkout with nothing to gate"
write_report Medium yes
track_worker
run "$pf" --only body --slug w1
if [ "$RC" != 0 ]; then
	fail "a checkout with no docs budget and no gate failed the body check: exit $RC — $OUT"
elif ! said "docs budget: no root AGENTS.md in this checkout — skipped"; then
	fail "the missing docs budget was not named as skipped — $OUT"
elif ! said "body: no pr-check target in this checkout — skipped"; then
	fail "the missing body gate was not named as skipped — $OUT"
else
	pass "no root AGENTS.md and no pr-check target: the body check passes with two named skips"
fi

# --- F. the escape hatch: --skip-preflight "<reason>" ------------------------------------------

# A check genuinely broken on this machine is the one case the run cannot happen. The reason is
# recorded the way a wipe skip is, and it stands in for the run the report could not paste: this
# report names no preflight run at all.
reset_case skip
printf '#!/usr/bin/env bash\nprintf "ok\\n"\n' >"$REPO/tool.sh"
chmod +x "$REPO/tool.sh"
commit_branch "feat: a script, and a gate that cannot run here"
write_report Medium no
track_worker
run "$delegate" finish w1 --skip-preflight "semgrep cannot reach the registry from this sandbox"
skip_reason=$(decision_reason preflight || true)
if [ "$RC" != 0 ]; then
	fail "--skip-preflight did not finish: exit $RC — $OUT"
elif [ "$(origin_head)" != "$SHA" ]; then
	fail "--skip-preflight did not publish the branch"
elif ! gh_saw '^gh pr create '; then
	fail "--skip-preflight opened no pull request"
elif [ "$skip_reason" != "semgrep cannot reach the registry from this sandbox" ]; then
	fail "--skip-preflight recorded '$skip_reason' instead of its reason"
elif ! said "skipped"; then
	fail "--skip-preflight did not say the gate was skipped — $OUT"
else
	pass "--skip-preflight publishes past a gate that cannot run and records the reason"
fi

# ...and without the skip the same report is refused, because it proves no preflight run.
reset_case no-preflight-evidence
printf '#!/usr/bin/env bash\nprintf "ok\\n"\n' >"$REPO/tool.sh"
chmod +x "$REPO/tool.sh"
commit_branch "feat: a script and a report that never ran the gate"
write_report Medium no
track_worker
run "$delegate" finish w1
if [ "$RC" = 0 ]; then
	fail "a report naming no preflight run was published — $OUT"
elif ! said "bin/preflight"; then
	fail "the refusal does not say what to paste — $OUT"
elif gh_saw '^gh pr (create|edit) ' || [ -n "$(origin_head)" ]; then
	fail "a pull request or a push happened for a report with no preflight run"
else
	pass "a report whose Evidence block names no bin/preflight run is refused, with what to paste"
fi

# --- I. the suites: once each, side by side, and every one of them reported --------------------

# I1. A superset whose recipe this check does not recognise is run as it is, exactly once. Guessing
# that every scripts-test is the two globs is how a gate quietly stops doing something the target
# does; running both the target and the globs is the double run this replaces.
reset_case superset-once
mkdir -p "$REPO/scripts/tests"
printf '#!/usr/bin/env bash\n# a changed script, and a clean one\nprintf "ok\\n"\n' >"$REPO/scripts/tool.sh"
printf '#!/usr/bin/env bash\nprintf "one: ok\\n"\n' >"$REPO/scripts/tests/one.test.sh"
cat >"$REPO/Makefile" <<'MAKE'
scripts-test:
	@printf 'run\n' >> "$(CURDIR)/superset.log"
	@bash "$(CURDIR)/scripts/tests/one.test.sh"
MAKE
commit_branch "test(scripts): a superset recipe nobody can guess at"
run "$pf" --only suites --cwd "$REPO" feat/w1
runs=$(grep -c . "$REPO/superset.log" 2>/dev/null || printf 0)
if [ "$RC" != 0 ]; then
	fail "a superset the check cannot recognise did not pass: exit $RC — $OUT"
elif [ "$runs" != 1 ]; then
	fail "the superset target ran $runs time(s), wanted exactly one — $OUT"
elif ! said "make scripts-test"; then
	fail "the run does not name the superset it ran — $OUT"
else
	pass "an unrecognised scripts-test target is run whole, exactly once, and named"
fi

# I2. The two globs: every discovered suite reported, every one of them run once, and the run
# shaped by the cap rather than by the number of suites. Each suite leaves its own start and end
# behind, so "ran once" and "ran side by side" are read from what happened, not from the output.
reset_case suites-parallel
mkdir -p "$REPO/scripts/tests"
printf '#!/usr/bin/env bash\nprintf "ok\\n"\n' >"$REPO/scripts/tool.sh"
cat >"$REPO/scripts/tests/mark.test.mjs" <<'TEST'
import { appendFileSync } from "node:fs";
import { test } from "node:test";
test("mark", () => {
	appendFileSync(`${process.env.SUITE_MARK}/mjs`, "x\n");
});
TEST
cat >"$REPO/Makefile" <<'MAKE'
scripts-test:
	@echo "== scripts-test: node --test scripts/tests/*.test.mjs"
	@node --test scripts/tests/*.test.mjs
	@for t in scripts/tests/*.test.sh; do \
		[ -e "$$t" ] || continue; \
		echo "== scripts-test: bash $$t"; \
		bash "$$t" || { status=$$?; echo "== scripts-test: FAILED $$t (exit $$status)" >&2; exit $$status; }; \
	done
	@echo "== scripts-test: every suite passed"
MAKE
for n in a b c d e; do
	{
		printf '#!/usr/bin/env bash\n'
		printf 'start=$(date +%%s%%N)\n'
		printf 'sleep 1\n'
		printf 'end=$(date +%%s%%N)\n'
		printf 'printf "%%s %%s\\n" "$start" "$end" >>"$SUITE_MARK/%s"\n' "$n"
	} >"$REPO/scripts/tests/test-$n.test.sh"
done
mkdir -p "$CASE/marks"
commit_branch "test(scripts): five bash suites and a node suite behind one Makefile"
run env SUITE_MARK="$CASE/marks" "$pf" --only suites --cwd "$REPO" feat/w1
shape=$(SUITE_MARK="$CASE/marks" node -e '
	const fs = require("fs");
	const dir = process.env.SUITE_MARK;
	const marks = fs.readdirSync(dir);
	const spans = marks.filter((m) => m !== "mjs").map((m) =>
		fs.readFileSync(`${dir}/${m}`, "utf8").trim().split(" ").map(Number));
	const twice = marks.filter((m) => fs.readFileSync(`${dir}/${m}`, "utf8").trim().split("\n").length !== 1);
	const points = spans.flatMap(([s, e]) => [[s, 1], [e, -1]]).sort((x, y) => x[0] - y[0] || x[1] - y[1]);
	let now = 0;
	let peak = 0;
	for (const [, d] of points) { now += d; peak = Math.max(peak, now); }
	process.stdout.write(`${marks.length} ${twice.length} ${peak}`);' 2>&1)
if [ "$RC" != 0 ]; then
	fail "the two globs did not pass: exit $RC — $OUT"
elif ! said "6 suite(s) discovered, 6 ran once each"; then
	fail "the run does not report six suites discovered and six run — $OUT"
elif [ "${shape%% *}" != 6 ]; then
	fail "six suites were reported but ${shape%% *} left a mark ($shape)"
elif [ "$(printf '%s' "$shape" | awk '{ print $2 }')" != 0 ]; then
	fail "a suite ran twice: $(printf '%s' "$shape" | awk '{ print $2 }') of them did ($shape)"
elif [ "$(printf '%s' "$shape" | awk '{ print $3 }')" -lt 2 ]; then
	fail "no two suites overlapped, so nothing ran side by side ($shape)"
elif [ "$(printf '%s' "$shape" | awk '{ print $3 }')" -gt 4 ]; then
	fail "$(printf '%s' "$shape" | awk '{ print $3 }') suites ran at once, past the cap of 4 ($shape)"
else
	missing=""
	for n in a b c d e; do
		said "bash scripts/tests/test-$n.test.sh" || missing="$missing test-$n"
	done
	if [ -n "$missing" ]; then
		fail "the run does not report every suite it ran:$missing — $OUT"
	else
		pass "six suites discovered, six ran once each, at most four at a time, one line each"
	fi
fi

# I3. A failing suite fails the gate and is named, with its own output under it — a parallel run
# that reports "something failed" would be slower to read than the serial one it replaced.
reset_case suites-fail
mkdir -p "$REPO/scripts/tests"
printf '#!/usr/bin/env bash\nprintf "ok\\n"\n' >"$REPO/scripts/tool.sh"
printf '#!/usr/bin/env bash\nprintf "good: ok\\n"\n' >"$REPO/scripts/tests/test-good.test.sh"
printf '#!/usr/bin/env bash\nprintf "bad: the thing did not hold\\n" >&2\nexit 3\n' >"$REPO/scripts/tests/test-bad.test.sh"
cat >"$REPO/scripts/tests/pass.test.mjs" <<'TEST'
import { test } from "node:test";
test("pass", () => {});
TEST
cat >"$REPO/Makefile" <<'MAKE'
scripts-test:
	@node --test scripts/tests/*.test.mjs
	@for t in scripts/tests/*.test.sh; do \
		bash "$$t" || exit $$?; \
	done
MAKE
commit_branch "test(scripts): one suite that fails, one that does not"
run "$pf" --only suites --cwd "$REPO" feat/w1
if [ "$RC" = 0 ]; then
	fail "a failing suite passed the gate — $OUT"
elif ! said "test-bad.test.sh"; then
	fail "the failing suite is not named — $OUT"
elif ! said "bad: the thing did not hold"; then
	fail "the failing suite's own output is not shown — $OUT"
elif ! said "FAILED (exit 3)"; then
	fail "the failure does not carry the suite's exit code — $OUT"
elif ! said "test-good.test.sh"; then
	fail "the suites that passed are not reported beside the failing one — $OUT"
else
	pass "a failing suite fails the gate with its name, its exit code and its own output"
fi

# I4. A prose-only diff: nothing compiles, nothing lints, nothing has a test to scrub, and each of
# those says so in its own line instead of the generic one.
reset_case docs-skips
mkdir -p "$REPO/docs"
printf 'the trunk\n\nOne more paragraph of documentation.\n' >"$REPO/README.md"
printf 'notes\n' >"$REPO/docs/notes.md"
commit_branch "docs: a paragraph and a note"
run "$pf" --only syntax,scrub --cwd "$REPO" feat/w1
skips=$(printf '%s\n' "$OUT" | grep -cE '^skip ')
if [ "$RC" != 0 ]; then
	fail "a prose-only diff failed on its fast path: exit $RC — $OUT"
elif [ "$skips" != 2 ]; then
	fail "a prose-only diff produced $skips skip line(s), wanted one for each check — $OUT"
elif ! said "docs-only diff: no changed code file"; then
	fail "the syntax skip does not name the diff as prose — $OUT"
elif ! said "docs-only diff: no changed test file"; then
	fail "the scrub skip does not name the diff as prose — $OUT"
else
	pass "a prose-only diff skips syntax and scrub, each with its own named line"
fi

# --- J. the body gate runs in the checkout that holds the branch -------------------------------

# Three publishes in a row were blocked by a body gate pointed at the wrong tree: it ran in the main
# checkout, which sat on trunk, so the target repo's own `pr-check` — right to refuse a checkout that
# is not on the branch it gates — refused every worker publish, and said so about the wrong tree.
# The gate now runs where the branch is, and every line it prints names that directory. The fixture's
# gate is that shape: it logs the directory it ran in, and refuses a checkout that is not on the
# branch it was handed, so a regression back to the main checkout fails here instead of at publish.
gate_fixture() { # a body gate on trunk: logs where it ran, refuses another branch's checkout
	mkdir -p "$REPO/scripts"
	cat >"$REPO/Makefile" <<'MAKE'
pr-check:
	@bash $(CURDIR)/scripts/body-gate.sh "$(BODY)" "$(BRANCH)"
MAKE
	cat >"$REPO/scripts/body-gate.sh" <<'GATE'
#!/usr/bin/env bash
body=${1:-}
branch=${2:-}
[ -f "$body" ] || { printf 'pr-check: no body file\n' >&2; exit 1; }
[ -z "${GATE_LOG:-}" ] || printf '%s %s\n' "$PWD" "$(git -C "$PWD" rev-parse --short HEAD 2>/dev/null || printf -)" >>"$GATE_LOG"
[ -z "${GATE_REFUSE:-}" ] || { printf 'pr-check: %s\n' "$GATE_REFUSE" >&2; exit 1; }
grep -qE '^Review tier: ' "$body" || { printf 'pr-check: no Review tier: line\n' >&2; exit 1; }
grep -q '^## Evidence' "$body" || { printf 'pr-check: no Evidence section\n' >&2; exit 1; }
if [ -n "$branch" ]; then
	# The shape pi's own pr-gate has: the checkout must be on the branch it gates. A detached
	# checkout of the branch's own commit is the same tree, and that is what a throwaway is.
	here=$(git -C "$PWD" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
	head=$(git -C "$PWD" rev-parse HEAD 2>/dev/null || true)
	want=$(git -C "$PWD" rev-parse --verify --quiet "refs/heads/$branch^{commit}" 2>/dev/null || true)
	[ "$here" = "$branch" ] || [ "$head" = "$want" ] ||
		{ printf 'pr-check: this checkout is on %s, not %s\n' "${here:-a detached HEAD}" "$branch" >&2; exit 1; }
fi
printf 'pr-check: body ok\n'
GATE
	chmod +x "$REPO/scripts/body-gate.sh"
	git -C "$REPO" add -A
	git -C "$REPO" commit -q -m "chore: a body gate that reads the body and its own branch"
	git -C "$REPO" push -q origin main
}

worktrees_held() { git -C "$REPO" worktree list --porcelain | grep -c '^worktree '; }
gate_ran_in() { head -n 1 "$CASE/gate.log" 2>/dev/null | cut -d' ' -f1 || true; }
gate_ran_at() { head -n 1 "$CASE/gate.log" 2>/dev/null | cut -d' ' -f2 || true; }

# J1. The shape every worker publish has: trunk in the main checkout, the branch in a worktree. The
# gate runs in that worktree, passes there, and the line says which directory it used.
reset_case gate-worktree
git -C "$REPO" checkout -q main
gate_fixture
git -C "$REPO" worktree add -q "$CASE/wt-gated" -b feat/gated
printf 'the branch\n' >"$CASE/wt-gated/feature.txt"
git -C "$CASE/wt-gated" add -A
git -C "$CASE/wt-gated" commit -q -m "feat: the branch under gate" -m "Agent-Slug: w1"
SHA=$(git -C "$CASE/wt-gated" rev-parse HEAD)
write_report Medium yes
track_worker_at "$CASE/wt-gated" feat/gated
: >"$CASE/gate.log"
run env GATE_LOG="$CASE/gate.log" "$pf" --only body --slug w1 --cwd "$REPO" feat/gated
if [ "$RC" != 0 ]; then
	fail "a branch in a worktree did not pass its own body gate: exit $RC — $OUT"
elif [ "$(gate_ran_in)" != "$CASE/wt-gated" ]; then
	fail "the body gate ran in '$(gate_ran_in)', not in the worktree that holds the branch — $OUT"
elif ! said "body gate: make -C $CASE/wt-gated pr-check"; then
	fail "the line does not name the directory the gate ran in — $OUT"
elif ! said "body gate: make pr-check passed"; then
	fail "the body gate did not pass in the worktree — $OUT"
else
	pass "a branch in a worktree is gated in that worktree, and the line names it"
fi

# J2. A main checkout that *is* on the branch keeps working: no worktree is made, and nothing is
# moved out from under the caller.
reset_case gate-main-checkout
gate_fixture
printf 'the branch\n' >"$REPO/feature.txt"
commit_branch "feat: the branch under gate, in the main checkout"
write_report Medium yes
track_worker
: >"$CASE/gate.log"
run env GATE_LOG="$CASE/gate.log" "$pf" --only body --slug w1 --cwd "$REPO" feat/w1
if [ "$RC" != 0 ]; then
	fail "a main checkout on the branch stopped passing its own body gate: exit $RC — $OUT"
elif [ "$(gate_ran_in)" != "$REPO" ]; then
	fail "the body gate ran in '$(gate_ran_in)', not in the main checkout that holds the branch — $OUT"
elif [ "$(worktrees_held)" != 1 ]; then
	fail "a checkout on the branch still had a worktree made for it ($(worktrees_held) held) — $OUT"
else
	pass "a main checkout that is on the branch is gated in place, with no worktree made"
fi

# J3. A branch no checkout holds — a ref and nothing else — is gated in a throwaway worktree of it,
# and that worktree is gone afterwards. Asserted from the gate's own log and the repo's worktree
# list: a directory named in a message that is still on disk is the leak this case is for.
reset_case gate-ref-only
git -C "$REPO" checkout -q main
gate_fixture
refonly=$(git -C "$REPO" commit-tree "$(git -C "$REPO" rev-parse "main^{tree}")" -p main \
	-m "feat: a branch no checkout holds" -m "Agent-Slug: w1")
git -C "$REPO" branch feat/refonly "$refonly"
SHA=$refonly
write_report Medium yes
track_worker_at "$REPO" feat/refonly
: >"$CASE/gate.log"
run env GATE_LOG="$CASE/gate.log" "$pf" --only body --slug w1 --cwd "$REPO" feat/refonly
thrown=$(gate_ran_in)
if [ "$RC" != 0 ]; then
	fail "a branch that exists only as a ref did not pass its gate: exit $RC — $OUT"
elif ! said "no checkout holds feat/refonly"; then
	fail "the throwaway checkout was made without saying so — $OUT"
elif [ -z "$thrown" ]; then
	fail "the gate wrote nothing to its log, so it never ran — $OUT"
elif [ -e "$thrown" ]; then
	fail "the throwaway checkout $thrown is still on disk after the gate passed"
elif [ "$(worktrees_held)" != 1 ]; then
	fail "the repo still holds $(worktrees_held) worktrees after the gate: the throwaway was not removed — $OUT"
elif [ "$(gate_ran_at)" != "$(git -C "$REPO" rev-parse --short feat/refonly)" ]; then
	fail "the throwaway checkout was on $(gate_ran_at), not on the branch's own commit — $OUT"
elif ! said "body gate: make -C $thrown pr-check"; then
	fail "the line does not name the throwaway directory the gate ran in — $OUT"
else
	pass "a branch only a ref holds is gated in a throwaway worktree, on its own commit, gone after"
fi

# J4. The same throwaway, with a gate that refuses: the worktree is removed on the failure path too,
# which is the path a trap is for and the path a manual cleanup forgets.
reset_case gate-ref-only-fails
git -C "$REPO" checkout -q main
gate_fixture
refonly=$(git -C "$REPO" commit-tree "$(git -C "$REPO" rev-parse "main^{tree}")" -p main \
	-m "feat: a branch no checkout holds" -m "Agent-Slug: w1")
git -C "$REPO" branch feat/refonly "$refonly"
SHA=$refonly
write_report Medium yes
track_worker_at "$REPO" feat/refonly
: >"$CASE/gate.log"
run env GATE_LOG="$CASE/gate.log" GATE_REFUSE="the body is not good enough" \
	"$pf" --only body --slug w1 --cwd "$REPO" feat/refonly
thrown=$(gate_ran_in)
if [ "$RC" = 0 ]; then
	fail "a gate that refused the body passed the check — $OUT"
elif ! said "the body is not good enough"; then
	fail "the gate's refusal is not shown — $OUT"
elif [ -n "$thrown" ] && [ -e "$thrown" ]; then
	fail "the throwaway checkout $thrown survived a refused gate"
elif [ "$(worktrees_held)" != 1 ]; then
	fail "the repo still holds $(worktrees_held) worktrees after a refused gate — $OUT"
else
	pass "a throwaway checkout is removed after a refused gate, not only after a passing one"
fi

# --- K. a branch cut before a pull request merged ------------------------------------------------

# The #68 shape: the branch and trunk both move the same file, trunk merges after the branch was
# cut, and every check this machine runs on its own would pass. Only `behind` can see it, so the
# assertions are that `finish` names it, prints the rebase, and publishes nothing.
reset_case behind
printf 'the trunk\n\none line from the branch\n' >"$REPO/README.md"
commit_branch "docs(w1): a line the trunk also moves"
git -C "$REPO" checkout -q main
printf 'the trunk\n\nthe line that merged\n' >"$REPO/README.md"
git -C "$REPO" commit -q -am "docs: the line that merged"
git -C "$REPO" push -q origin main
git -C "$REPO" checkout -q feat/w1
write_report Medium yes
track_worker
run "$delegate" finish w1
if [ "$RC" = 0 ]; then
	fail "a branch 1 commit behind a colliding trunk published anyway — $OUT"
elif ! said "behind"; then
	fail "the behind check is not named — $OUT"
elif ! said "1 commit(s) behind origin/main"; then
	fail "the refusal does not say how far behind — $OUT"
elif ! said "README.md"; then
	fail "the colliding path is not named — $OUT"
elif ! said "rebase origin/main"; then
	fail "the refusal does not carry the rebase that fixes it — $OUT"
elif gh_saw '^gh pr (create|edit) ' || [ -n "$(origin_head)" ]; then
	fail "a push or a pull request happened past a branch behind trunk"
elif [ ! -s "$PI_BOSS_ROOT/reports/w1.md" ]; then
	fail "a refused run took the report with it"
elif grep -q 'space.close' "$work/herdr-calls" 2>/dev/null; then
	fail "a refused run closed the space"
else
	pass "a branch behind a colliding trunk is refused with the rebase: no push, report and space kept"
fi

# --- L. the receipts: a second run on an unchanged tree is free ---------------------------------

# The shape every publish has: the worker runs the gate to paste the Evidence block, `delegate
# finish` runs it again before it pushes, on a tree nobody touched in between. Both verdicts are
# wanted; the work is not. What is asserted here is read from a stub suite that appends a line to a
# log outside the tree, so "the check did not run" is a fact about a process, not about a message.
receipt_repo() {
	mkdir -p "$REPO/scripts/tests"
	printf '#!/usr/bin/env bash\nprintf "ok\\n"\n' >"$REPO/scripts/tool.sh"
	cat >"$REPO/scripts/tests/smoke.test.mjs" <<'TEST'
import { test } from "node:test";
test("smoke", () => {});
TEST
	printf '#!/usr/bin/env bash\nsleep 1\n[ -z "${SUITE_LOG:-}" ] || printf "ran\\n" >>"$SUITE_LOG"\n' >"$REPO/scripts/tests/test-log.test.sh"
	: >"$CASE/suite.log"
	export SUITE_LOG=$CASE/suite.log
	commit_branch "test(scripts): a suite that leaves a line behind"
}

reset_cache() { rm -rf "$PI_BOSS_ROOT/state/preflight"; }
suite_runs() { wc -l <"$CASE/suite.log" 2>/dev/null | tr -d ' '; }
receipt_files() { ls "$PI_BOSS_ROOT/state/preflight"/*.json 2>/dev/null | wc -l | tr -d ' '; }
receipt_says() { grep -lF -- "\"check\": \"$1\"" "$PI_BOSS_ROOT/state/preflight"/*.json 2>/dev/null | head -n 1; }
LAST_MS=0
time_run() { # run a command, keep both streams, keep the wall clock in LAST_MS
	local s e
	s=$(date +%s%N)
	run "$@"
	e=$(date +%s%N)
	LAST_MS=$(((e - s) / 1000000))
}

# L1. The second run on the same tree: every verdict reused, no check launched, much faster.
reset_case receipts
reset_cache
receipt_repo
: >"$CASE/suite.log"
time_run env SUITE_LOG="$CASE/suite.log" "$pf" --only suites --cwd "$REPO" feat/w1
first_ms=$LAST_MS
runs_first=$(suite_runs)
time_run env SUITE_LOG="$CASE/suite.log" "$pf" --only suites --cwd "$REPO" feat/w1
second_ms=$LAST_MS
runs_total=$(suite_runs)
if [ "$RC" != 0 ]; then
	fail "the second run on an unchanged tree did not pass: exit $RC — $OUT"
elif [ "$runs_first" != 1 ]; then
	fail "the first run invoked the suite $runs_first time(s), wanted once"
elif [ "$runs_total" != 1 ]; then
	fail "the suite ran $runs_total time(s) across two runs: the second run did the work again"
elif ! said "pass (cached"; then
	fail "the second run does not say the verdict was cached — $OUT"
elif ! said "(1 cached, 0 ran)"; then
	fail "the summary does not count the cached and the run checks — $OUT"
elif [ "$second_ms" -ge $((first_ms / 2)) ] || [ "$first_ms" -lt 1000 ]; then
	fail "the second run was not well under the first (${first_ms}ms then ${second_ms}ms, one suite sleeping 1s)"
elif [ -z "$(receipt_says suites)" ]; then
	fail "no receipt was written for the suites check — $(receipt_files) file(s)"
else
	pass "a second run on the same tree reuses the verdict, runs nothing, and takes ${second_ms}ms against ${first_ms}ms"
fi

# L2. An edit to a tracked file — unstaged, so no commit moved — invalidates it.
printf '#!/usr/bin/env bash\nprintf "ok"\n# an edit nobody committed\n' >"$REPO/scripts/tool.sh"
: >"$CASE/suite.log"
run env SUITE_LOG="$CASE/suite.log" "$pf" --only suites --cwd "$REPO" feat/w1
if [ "$RC" != 0 ]; then
	fail "an unstaged edit made the run fail: exit $RC — $OUT"
elif [ "$(suite_runs)" != 1 ]; then
	fail "an unstaged edit to a tracked file reused the old verdict ($(suite_runs) suite run(s)) — $OUT"
elif said "pass (cached"; then
	fail "a dirty tree read as the tree the verdict came from — $OUT"
else
	pass "an unstaged edit to a tracked file invalidates the receipt"
fi

# L3. A changed check set invalidates: the same tree under a different set is a different run.
: >"$CASE/suite.log"
run env SUITE_LOG="$CASE/suite.log" "$pf" --only suites,syntax --cwd "$REPO" feat/w1
if [ "$RC" != 0 ]; then
	fail "a two-check run failed: exit $RC — $OUT"
elif [ "$(suite_runs)" != 1 ] || said "pass (cached"; then
	fail "a different check set reused the old receipt ($(suite_runs) suite run(s)) — $OUT"
else
	pass "a changed check set invalidates the receipt"
fi

# L4. A changed bin/preflight is a changed gate: the verdict an older gate reached is not its.
mkdir -p "$CASE/pf2"
cp -a "$root/bin" "$CASE/pf2/bin"
printf '\n# a gate that changed after the verdict\n' >>"$CASE/pf2/bin/preflight"
chmod +x "$CASE/pf2/bin/preflight"
: >"$CASE/suite.log"
run env SUITE_LOG="$CASE/suite.log" "$CASE/pf2/bin/preflight" --only suites,syntax --cwd "$REPO" feat/w1
if [ "$RC" != 0 ]; then
	fail "a copied gate did not run: exit $RC — $OUT"
elif [ "$(suite_runs)" != 1 ] || said "pass (cached"; then
	fail "an edited bin/preflight reused a verdict the older gate reached ($(suite_runs) suite run(s)) — $OUT"
else
	pass "a changed bin/preflight invalidates every receipt"
fi

# L5. --fresh ignores every receipt and runs everything, and says so.
: >"$CASE/suite.log"
run env SUITE_LOG="$CASE/suite.log" "$pf" --only suites,syntax --cwd "$REPO" feat/w1
cached_runs=$(suite_runs)
run env SUITE_LOG="$CASE/suite.log" "$pf" --fresh --only suites,syntax --cwd "$REPO" feat/w1
if [ "$RC" != 0 ]; then
	fail "--fresh made the run fail: exit $RC — $OUT"
elif [ "$cached_runs" != 0 ]; then
	fail "the run before --fresh re-ran the suite ($cached_runs) instead of reusing the receipt"
elif [ "$(suite_runs)" != 1 ]; then
	fail "--fresh did not run the check ($(suite_runs) suite run(s)) — $OUT"
elif ! said "--fresh: every receipt is ignored"; then
	fail "--fresh does not say what it does — $OUT"
else
	pass "--fresh ignores every receipt and runs everything"
fi

# L6. A cached FAIL still blocks, and still shows the transcript that failed.
reset_case receipts-fail
reset_cache
receipt_repo
printf '#!/usr/bin/env bash\nprintf "bad: the thing did not hold\\n" >&2\nexit 3\n' >"$REPO/scripts/tests/test-bad.test.sh"
commit_branch "test(scripts): a suite that fails"
: >"$CASE/suite.log"
run env SUITE_LOG="$CASE/suite.log" "$pf" --only suites --cwd "$REPO" feat/w1
first_rc=$RC
: >"$CASE/suite.log"
run env SUITE_LOG="$CASE/suite.log" "$pf" --only suites --cwd "$REPO" feat/w1
if [ "$first_rc" = 0 ]; then
	fail "a failing suite passed the gate, so this case proves nothing — $OUT"
elif [ "$RC" = 0 ]; then
	fail "a cached FAIL passed the gate — $OUT"
elif [ "$(suite_runs)" != 0 ]; then
	fail "the failing suite ran again instead of reading its receipt"
elif ! said "FAIL"; then
	fail "the cached verdict is not shown as a FAIL — $OUT"
elif ! said "bad: the thing did not hold"; then
	fail "the cached FAIL does not show the transcript that failed — $OUT"
elif ! said "exit 1 (cached"; then
	fail "the cached FAIL does not say it was cached — $OUT"
else
	pass "a cached FAIL still blocks, still shows its transcript, and still names itself as cached"
fi

# L7. A receipt older than PI_PREFLIGHT_CACHE_TTL is ignored: a pass is never a pass by staleness.
reset_case receipts-ttl
reset_cache
receipt_repo
: >"$CASE/suite.log"
run env SUITE_LOG="$CASE/suite.log" "$pf" --only suites --cwd "$REPO" feat/w1
cached_runs=$(suite_runs)
sleep 2
: >"$CASE/suite.log"
run env SUITE_LOG="$CASE/suite.log" PI_PREFLIGHT_CACHE_TTL=1s "$pf" --only suites --cwd "$REPO" feat/w1
if [ "$RC" != 0 ]; then
	fail "an expired-receipt run failed: exit $RC — $OUT"
elif [ "$cached_runs" != 1 ]; then
	fail "the fresh run before the TTL case did not run the suite ($cached_runs)"
elif [ "$(suite_runs)" != 1 ]; then
	fail "a receipt past its TTL was reused ($(suite_runs) suite run(s)) — $OUT"
else
	pass "a receipt older than PI_PREFLIGHT_CACHE_TTL is ignored and the check runs"
fi
# L8. A check a fast path skipped leaves no receipt behind: a skip is not a verdict to
# reuse, and a cache that stored one would make the next docs-only run look like it ran something.
reset_case receipts-skip
reset_cache
printf 'the trunk\n\nOne more paragraph of documentation.\n' >"$REPO/README.md"
commit_branch "docs: one more paragraph"
run "$pf" --only syntax,scrub --cwd "$REPO" feat/w1
if [ "$RC" != 0 ]; then
	fail "a run whose checks were all skipped failed: exit $RC — $OUT"
elif [ "$(printf '%s\n' "$OUT" | grep -cE '^skip ')" != 2 ]; then
	fail "the two checks were not both skipped on a docs-only diff — $OUT"
elif [ "$(receipt_files)" != 0 ]; then
	fail "a check skipped by a fast path wrote a receipt anyway ($(receipt_files) file(s))"
else
	pass "a check skipped by a fast path writes no receipt"
fi

# L9. `behind` is answered fresh every time and leaves no receipt: its answer is about origin,
# which moves without this tree moving, so a remembered pass is the CONFLICTING publish it exists
# to stop.
reset_case receipts-behind
reset_cache
receipt_repo
run "$pf" --only behind --cwd "$REPO" feat/w1
first_rc=$RC
first_out=$OUT
run "$pf" --only behind --cwd "$REPO" feat/w1
if [ "$first_rc" != 0 ] || [ "$RC" != 0 ]; then
	fail "behind did not pass on a branch level with its origin: exit $first_rc then $RC — $OUT"
elif ! printf '%s\n' "$first_out" | grep -q 'level with trunk or ahead'; then
	fail "behind did not say what it found on a level branch — $first_out"
elif said "pass (cached"; then
	fail "a behind verdict was reused on the second run — $OUT"
elif [ "$(receipt_files)" != 0 ]; then
	fail "behind wrote $(receipt_files) receipt(s): its answer is about origin, not this tree"
else
	pass "behind is answered fresh on every run and leaves no receipt to reuse"
fi

unset SUITE_LOG

# --- summary -----------------------------------------------------------------------------------

printf '\n'
if [ "$fails" -ne 0 ]; then
	printf '\npreflight: %d case(s) failed, %d skipped\n' "$fails" "$skips" >&2
	exit 1
fi
if [ "$skips" -ne 0 ]; then
	printf 'preflight: ok, %d case(s) skipped by name\n' "$skips"
	exit 0
fi
printf 'preflight: ok\n'
