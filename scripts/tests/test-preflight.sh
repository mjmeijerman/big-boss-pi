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
#   F. `--skip-preflight "<reason>"` publishes and records the reason in state/decisions.jsonl.
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
	printf '{"w1":{"space":"space-w1","cwd":"%s","branch":"feat/w1","report":"%s"}}\n' \
		"$REPO" "$PI_BOSS_ROOT/reports/w1.md" >"$PI_BOSS_ROOT/state/delegations.json"
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
