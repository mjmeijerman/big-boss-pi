#!/usr/bin/env bash
# test-ci-local-parallel.sh — scripts/ci-local.sh runs its independent jobs side by side, and a
# transcript still reads as if they had run one after another.
#
# The four jobs share nothing: none reads another's output, each writes only its own line. Serial
# that is the sum of four, and `offline` (79s measured cold) is the long pole. So the claims here
# are about time and order, and they are only worth believing if the jobs are stubs that sleep a
# known amount — never the real offline suite, which would make this suite cost a minute to say
# "two sleeps overlapped":
#
#   A. two jobs that each sleep 1.5s finish in about the slower one, not their sum, while the same
#      two under `--jobs 1` cost the sum;
#   B. the lines come out in job_ids order, not finish order (the first job listed is the last to
#      finish);
#   C. a failing job exits the run non-zero, names itself FAIL, and does not truncate or kill
#      another job's transcript;
#   D. `--jobs 1` is the serial behaviour: no concurrency, one line per job, in order;
#   E. `--fresh` reaches the offline job, and the ledger's own split ("0 cached, N ran") and the
#      run's wall clock are on the summary line of the same `--fresh --jobs 2` run;
#   F. `--jobs 0` and `--jobs banana` are usage errors (exit 2), not a silent serialise.
#
# The stubs are injected into a temporary copy of the script, the way scripts/tests/test-preflight.sh
# stubs its checks: the copy under test is the real dispatch code, only the job bodies are fake.
#
#   bash scripts/tests/test-ci-local-parallel.sh      exit 0 = every case held
set -uo pipefail

root=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/../.." && pwd)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
unset PI_MASTER_ROOT AGENTS_MD_LIMIT

fails=0
pass() { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }

# A throwaway checkout: ci-local.sh asks git for its file lists and its commit, and runs from the
# tree the script lives in, so the copy needs a git repo of its own — not the real checkout.
tree=$work/tree
mkdir -p "$tree/scripts" "$tree/bin"
git -C "$tree" init -q
printf 'tiny\n' >"$tree/AGENTS.md"
printf '#!/usr/bin/env bash\n:\n' >"$tree/scripts/planted.sh"
git -C "$tree" add -A
GIT_AUTHOR_NAME=T GIT_AUTHOR_EMAIL=t@example.com \
	GIT_COMMITTER_NAME=T GIT_COMMITTER_EMAIL=t@example.com \
	git -C "$tree" commit -qm "fixture"

# The script under test, with its four job bodies replaced by stubs that sleep and return what the
# environment says. Inserted before the dispatch section so the later definitions win.
stubs=$work/stubs.sh
cat >"$stubs" <<'STUB'
job_syntax() {
	sleep "${STUB_SLEEP_SYNTAX:-0}"
	printf 'syntax done\n'
	return "${STUB_RC_SYNTAX:-0}"
}
job_lint() {
	sleep "${STUB_SLEEP_LINT:-0}"
	printf 'lint done\n'
	return "${STUB_RC_LINT:-0}"
}
job_offline() {
	sleep "${STUB_SLEEP_OFFLINE:-0}"
	printf 'offline done\n'
	return "${STUB_RC_OFFLINE:-0}"
}
job_docs() {
	sleep "${STUB_SLEEP_DOCS:-0}"
	printf 'docs done\n'
	return "${STUB_RC_DOCS:-0}"
}
STUB
awk -v stubs="$stubs" '
	/^# --- dispatch/ && !done { while ((getline line < stubs) > 0) print line; done = 1 }
	{ print }
' "$root/scripts/ci-local.sh" >"$tree/scripts/ci-local.sh"
chmod +x "$tree/scripts/ci-local.sh"
if ! grep -q 'STUB_RC_SYNTAX' "$tree/scripts/ci-local.sh"; then
	fail "the stub jobs were not injected into the copy"
	printf '%s\n' "test-ci-local-parallel: $fails failed" >&2
	exit 1
fi

out=""
rc=0
wall_ms=0
# run [args...] — one run of the copy, timed end to end.
run() {
	local t0 t1
	t0=$(date +%s%N)
	(cd "$tree" && exec bash scripts/ci-local.sh "$@") >"$work/out.txt" 2>&1
	rc=$?
	t1=$(date +%s%N)
	out=$(cat "$work/out.txt")
	wall_ms=$(((t1 - t0) / 1000000))
}
set_sleeps() { # <syntax> <lint> <offline> <docs>
	export STUB_SLEEP_SYNTAX=$1 STUB_SLEEP_LINT=$2 STUB_SLEEP_OFFLINE=$3 STUB_SLEEP_DOCS=$4
}
line_of() { printf '%s\n' "$out" | grep -n -- "$1" | head -n 1 | cut -d: -f1; }

# --- A. two 1.5s jobs run concurrently --------------------------------------------------------

set_sleeps 1.5 1.5 0.1 0
unset STUB_RC_SYNTAX STUB_RC_LINT STUB_RC_OFFLINE STUB_RC_DOCS
run
if [ "$rc" = 0 ]; then pass "concurrent run exits 0 (exit $rc)"; else fail "concurrent run: exit $rc, wanted 0: $out"; fi
if [ "$wall_ms" -lt 2600 ]; then
	pass "two 1.5s jobs finished in ${wall_ms}ms, closer to the slower one than the 3.1s sum"
else
	fail "two 1.5s jobs took ${wall_ms}ms: not run in parallel"
fi
if printf '%s' "$out" | grep -qE 'syntax .*  1s|syntax .* 2s'; then
	pass "the syntax job's own wall clock is printed"
else
	fail "no per-job wall clock on the syntax line: $out"
fi

# --- D. --jobs 1 keeps the sum ----------------------------------------------------------------

run --jobs 1
if [ "$rc" = 0 ]; then pass "--jobs 1 exits 0 (exit $rc)"; else fail "--jobs 1: exit $rc, wanted 0"; fi
if [ "$wall_ms" -ge 3000 ]; then
	pass "--jobs 1 cost the ${wall_ms}ms sum of the two 1.5s jobs"
else
	fail "--jobs 1 finished in ${wall_ms}ms: it did not serialise"
fi
if printf '%s' "$out" | grep -q 'syntax done' && printf '%s' "$out" | grep -q 'lint done' &&
	printf '%s' "$out" | grep -q 'offline done' && printf '%s' "$out" | grep -q 'docs done'; then
	pass "--jobs 1 still prints every job's transcript"
else
	fail "--jobs 1 lost a transcript: $out"
fi

# --- B. order is job_ids order, not finish order ----------------------------------------------

set_sleeps 0.5 0.1 0.05 0
run
s=$(line_of 'syntax done')
l=$(line_of 'lint done')
o=$(line_of 'offline done')
d=$(line_of 'docs done')
if [ -n "$s" ] && [ -n "$l" ] && [ -n "$o" ] && [ -n "$d" ] && [ "$s" -lt "$l" ] && [ "$l" -lt "$o" ] && [ "$o" -lt "$d" ]; then
	pass "printed syntax (${s}) before lint (${l}) before offline (${o}) before docs (${d}), though syntax finished last"
else
	fail "lines are not in job_ids order (syntax=$s lint=$l offline=$o docs=$d): $out"
fi

# --- C. a failing job does not take the others with it ----------------------------------------

set_sleeps 0 0 0.4 0
export STUB_RC_LINT=1
run
unset STUB_RC_LINT
if [ "$rc" != 0 ]; then pass "a failing job makes the run exit non-zero (exit $rc)"; else fail "lint failed but the run exited 0"; fi
if printf '%s' "$out" | grep -q '^FAIL  *lint'; then
	pass "the summary names the failed job"
else
	fail "no FAIL line naming lint: $out"
fi
if printf '%s' "$out" | grep -q 'offline done'; then
	pass "another job's transcript survives a concurrent failure"
else
	fail "the offline transcript was lost when lint failed: $out"
fi
if printf '%s' "$out" | grep -q 'lint done'; then
	pass "the failed job's own output is still shown"
else
	fail "the failed job's transcript is missing: $out"
fi
if printf '%s' "$out" | grep -q 'ci-local: 3/4 passed'; then
	pass "the summary counts 3/4"
else
	fail "the summary does not count the failure: $out"
fi

# --- E. --fresh and the ledger split, in one parallel run -------------------------------------

# `--fresh` is a flag the real offline job forwards, so a stub cannot prove it: this tree runs the
# script unmodified, with scripts/ci-offline.sh replaced by a stand-in that records the flags it was
# handed and prints the summary line the receipt ledger writes.
fresh_tree=$work/fresh-tree
mkdir -p "$fresh_tree/scripts" "$fresh_tree/bin"
git -C "$fresh_tree" init -q
printf 'tiny\n' >"$fresh_tree/AGENTS.md"
cat >"$fresh_tree/scripts/ci-offline.sh" <<'OFFLINE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$(dirname -- "$0")/flags.log"
printf 'offline behaviour: ok (0 cached, 2 ran)\n'
OFFLINE
cp "$root/scripts/ci-local.sh" "$fresh_tree/scripts/ci-local.sh"
chmod +x "$fresh_tree/scripts/ci-local.sh" "$fresh_tree/scripts/ci-offline.sh"
git -C "$fresh_tree" add -A
GIT_AUTHOR_NAME=T GIT_AUTHOR_EMAIL=t@example.com \
	GIT_COMMITTER_NAME=T GIT_COMMITTER_EMAIL=t@example.com \
	git -C "$fresh_tree" commit -qm "fixture"
flags="$fresh_tree/scripts/flags.log"

fresh_run() { # [args...] — one run of the unmodified copy, its summary line into $summary.
	(cd "$fresh_tree" && bash scripts/ci-local.sh "$@") >"$work/fresh.txt" 2>&1
	rc=$?
	out=$(cat "$work/fresh.txt")
	summary=$(printf '%s\n' "$out" | tail -n 1)
}
summary=""

fresh_run --only offline,docs --fresh --jobs 2
if [ "$rc" = 0 ]; then pass "--fresh --jobs 2 exits 0 (exit $rc)"; else fail "--fresh --jobs 2: exit $rc, wanted 0: $out"; fi
if grep -q -- '--fresh' "$flags" 2>/dev/null; then
	pass "--fresh reached the offline job (flags: $(tr '\n' ';' <"$flags"))"
else
	fail "--fresh never reached the offline job: $(cat "$flags" 2>/dev/null)"
fi
if printf '%s' "$summary" | grep -q '; offline: 0 cached, 2 ran'; then
	pass "the summary repeats the ledger's split: $summary"
else
	fail "no '; offline: 0 cached, 2 ran' on the summary line: $summary"
fi
if printf '%s' "$summary" | grep -qE ' in [0-9]+ms'; then
	pass "the summary carries the run's wall clock"
else
	fail "no wall clock on the summary line: $summary"
fi
if printf '%s' "$summary" | grep -q 'slowest: offline'; then
	pass "the summary names the slowest job"
else
	fail "no 'slowest: offline' on the summary line: $summary"
fi
if printf '%s' "$out" | grep -q 'pass *offline behaviour.*(0 cached, 2 ran)'; then
	pass "the offline job's own line carries the split too"
else
	fail "the offline line lost the split: $out"
fi

# The other direction: without --fresh the flag is not forwarded, and the split is still reported.
: >"$flags"
fresh_run --only offline,docs --jobs 2
if [ "$rc" = 0 ] && ! grep -q -- '--fresh' "$flags"; then
	pass "a run without --fresh forwards no --fresh to the offline job"
else
	fail "a run without --fresh handed the job --fresh: $(cat "$flags")"
fi
if printf '%s' "$summary" | grep -q '; offline: 0 cached, 2 ran'; then
	pass "a warm run still reports the split: $summary"
else
	fail "a run without --fresh dropped the split: $summary"
fi

# --- F. a bad --jobs is a usage error -----------------------------------------------------

set_sleeps 0 0 0 0
unset STUB_RC_SYNTAX STUB_RC_LINT STUB_RC_OFFLINE STUB_RC_DOCS
run --jobs 0
if [ "$rc" = 2 ] && printf '%s' "$out" | grep -q 'usage: bash scripts/ci-local.sh'; then
	pass "--jobs 0 exits 2 with the usage line"
else
	fail "--jobs 0 exited $rc without the usage line: $out"
fi
run --jobs banana
if [ "$rc" = 2 ] && printf '%s' "$out" | grep -q 'wants a positive number'; then
	pass "--jobs banana exits 2 and names the flag"
else
	fail "--jobs banana exited $rc: $out"
fi
run --jobs 9
if [ "$rc" = 0 ]; then pass "--jobs 9 is accepted and capped (exit 0)"; else fail "--jobs 9: exit $rc: $out"; fi

# --- summary ----------------------------------------------------------------------------------

if [ "$fails" = 0 ]; then
	printf '%s\n' "test-ci-local-parallel: all cases held"
	exit 0
fi
printf '%s\n' "test-ci-local-parallel: $fails failed" >&2
exit 1
