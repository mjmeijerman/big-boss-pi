#!/usr/bin/env bash
# test-provenance.sh — a report that names a commit, and a commit that names its worker.
#
# Radar #79 (offline provenance) and #82 (one-shot specs), read as two rules that are only
# worth writing down if something checks them:
#
#   1. `delegate close` refuses a report whose recorded commit sha is not a commit that carries
#      the `Agent-Slug:` trailer. A report is a claim; the trailer is what makes the claim
#      checkable offline, without trusting the worker's prose.
#   2. `delegate wipe` moves the finished spec into specs/archive/, so the next worker in the
#      same area can read what was already decided instead of starting from nothing.
#
# Every case drives the real `delegate close` / `delegate wipe` / `delegate spawn` against a
# temporary PI_BOSS_ROOT, a throwaway git repo and a stub herdr-app, so there is no model, no
# desktop app and no real workspace involved.
#
#   bash scripts/test-provenance.sh      exit 0 = every case held
set -uo pipefail

root=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd)
bin=$root/bin

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export PI_BOSS_ROOT=$work/root
export HOME=$work/home
mkdir -p "$PI_BOSS_ROOT/reports" "$PI_BOSS_ROOT/state" "$PI_BOSS_ROOT/specs" "$PI_BOSS_ROOT/bin" "$work/stub" "$HOME"
unset PI_MASTER_ROOT

# A herdr-app that always succeeds and records its calls, and an hc that prints the banner
# marker immediately, so a spawn gets all the way through without a desktop app.
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s/herdr-calls"\nprintf "{\\"space\\":\\"s1\\",\\"tab\\":\\"t1\\",\\"pane\\":\\"p1\\",\\"terminal\\":\\"term1\\"}\\n"\n' "$work" \
	>"$work/stub/herdr-app"
printf '#!/usr/bin/env bash\nprintf "escape interrupt\\n"\n' >"$work/stub/hc"
chmod +x "$work/stub/herdr-app" "$work/stub/hc"
export PATH=$work/stub:$PATH

fails=0
pass() { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }

# A throwaway repo with one commit: the provenance check resolves the sha the report records.
repo=$work/repo
mkdir -p "$repo"
git -C "$repo" init -q -b main
git -C "$repo" config user.email worker@example.invalid
git -C "$repo" config user.name worker
git -C "$repo" commit -q --allow-empty -m "feat: a change the report will name"
sha=$(git -C "$repo" rev-parse HEAD)

# run_close <slug> <report-body-on-stdin> — writes the report, registers the worker with its
# cwd pointing at the throwaway repo, runs the real close, and sets OUT/RC.
OUT=""
RC=0
case_no=0
run_close() {
	local slug=$1
	case_no=$((case_no + 1))
	mkdir -p "$PI_BOSS_ROOT/reports"
	cat >"$PI_BOSS_ROOT/reports/$slug.md"
	printf '{"%s":{"space":"space-%s","cwd":"%s","branch":""}}\n' "$slug" "$slug" "$repo" \
		>"$PI_BOSS_ROOT/state/delegations.json"
	local out
	out=$("$bin/delegate" close "$slug" 2>&1) && RC=0 || RC=$?
	OUT=$out
}

# 1. A commit with no trailers: the close refuses, names the trailer that is missing, and
#    prints the exact git command that fixes it. A refusal without the command is a dead end.
run_close no-trailer <<REPORT
# Report

Mission: the reader can tell which worker made this change.

Commit: $sha

## Evidence

\$ bash scripts/test-provenance.sh — ok
REPORT
if [ "$RC" != 1 ]; then
	fail "commit without Agent-Slug: exit $RC, wanted 1 — $OUT"
elif ! printf '%s' "$OUT" | grep -qF "Agent-Slug"; then
	fail "commit without Agent-Slug: the refusal does not name the trailer — $OUT"
elif ! printf '%s' "$OUT" | grep -qF -- "--trailer 'Agent-Slug: no-trailer'"; then
	fail "commit without Agent-Slug: the refusal does not print the git fix — $OUT"
else
	pass "commit without an Agent-Slug trailer refuses, and prints the fix (exit 1)"
fi

# 2. A sha that does not resolve in the worker's tree is a report nobody can check either.
run_close bad-sha <<REPORT
# Report

Mission: the reader can resolve the commit the report names.

Commit: ffffffffffffffffffffffffffffffffffffffff

## Evidence

\$ bash scripts/test-provenance.sh — ok
REPORT
if [ "$RC" != 1 ] || ! printf '%s' "$OUT" | grep -qF "does not resolve"; then
	fail "unresolvable sha: exit $RC, wanted 1 with 'does not resolve' — $OUT"
else
	pass "a sha that does not resolve in the worker's tree refuses (exit 1)"
fi

# 3. A report that records no sha at all, from a worker whose cwd is a git repo, cannot be
#    checked either: refuse rather than take the prose on trust.
run_close no-sha <<'REPORT'
# Report

Mission: the reader can check what the report claims.

## Evidence

$ bash scripts/test-provenance.sh — ok
REPORT
if [ "$RC" != 1 ] || ! printf '%s' "$OUT" | grep -qF "records no commit sha"; then
	fail "report without a sha: exit $RC, wanted 1 with 'records no commit sha' — $OUT"
else
	pass "a report recording no sha refuses (exit 1)"
fi

# 4. The same commit, amended to carry both trailers: the close goes through. The wipe step is
#    pre-recorded because this case is about provenance, not about the consolidation checklist.
git -C "$repo" commit -q --amend --allow-empty --no-edit \
	--trailer "Agent-Slug: good-trailer" --trailer "Spec: specs/good-trailer.md"
sha2=$(git -C "$repo" rev-parse HEAD)
printf '{"timestamp":"%s","command":"wipe","task":"good-trailer","decision":"done","reason":null,"overridden":false,"slug":"good-trailer"}\n' \
	"$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$PI_BOSS_ROOT/state/decisions.jsonl"
run_close good-trailer <<REPORT
# Report

Mission: a worker whose commit carries its trailer closes without a fight.

Commit: $sha2

## Evidence

\$ bash scripts/test-provenance.sh — ok
REPORT
if [ "$RC" != 0 ]; then
	fail "commit with both trailers: exit $RC, wanted 0 — $OUT"
else
	pass "a commit carrying Agent-Slug and Spec closes (exit 0)"
fi

# 5. A worker with no git repo in its cwd has nothing to resolve a sha against: the check steps
#    aside instead of refusing every report in a non-repo folder.
printf '{"plain":{"space":"space-plain","cwd":"","branch":""}}\n' >"$PI_BOSS_ROOT/state/delegations.json"
printf '# Report\n\nMission: a folder with no repo is still closable.\n\n## Evidence\n\n$ close — ok\n' \
	>"$PI_BOSS_ROOT/reports/plain.md"
printf '{"timestamp":"%s","command":"wipe","task":"plain","decision":"done","reason":null,"overridden":false,"slug":"plain"}\n' \
	"$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$PI_BOSS_ROOT/state/decisions.jsonl"
out=$("$bin/delegate" close plain 2>&1) && rc=0 || rc=$?
if [ "$rc" != 0 ]; then
	fail "cwd with no git repo: exit $rc, wanted 0 — $out"
else
	pass "a cwd that is not a git repo skips the provenance check (exit 0)"
fi

# 6. Spec continuity: the wipe archives the finished spec, so the next worker in the area can
#    read it instead of re-deciding what was already decided.
printf '{"archivable":{"space":"space-archivable","cwd":"","branch":""}}\n' >"$PI_BOSS_ROOT/state/delegations.json"
printf '# Worker `archivable`\n\n- **Mission**: a finished spec that the next worker can read.\n' \
	>"$PI_BOSS_ROOT/specs/archivable.md"
out=$(PATH=$work/stub:$PATH "$bin/delegate" wipe archivable 2>&1) && rc=0 || rc=$?
if [ "$rc" != 0 ]; then
	fail "wipe, archivable spec: exit $rc, wanted 0 — $out"
elif [ -f "$PI_BOSS_ROOT/specs/archivable.md" ]; then
	fail "wipe left the finished spec in specs/ — $out"
elif [ ! -f "$PI_BOSS_ROOT/specs/archive/archivable.md" ]; then
	fail "wipe did not move the spec to specs/archive/ — $out"
elif ! printf '%s' "$out" | grep -qF "specs/archive/archivable.md"; then
	fail "wipe archived the spec but did not say where — $out"
else
	pass "wipe archives the finished spec into specs/archive/ (exit 0)"
fi

# 7. And the spawn template tells the worker the two things the checks above depend on: read the
#    archived spec in this area first, and end the commit with both trailers. A rule the template
#    does not carry is a rule no worker ever reads.
cat >"$PI_BOSS_ROOT/bin/jev" <<'STUB'
#!/usr/bin/env bash
case $1 in
route) printf '{"route":"remote","reason":"code work"}\n'; exit 1 ;;
mode) printf '{"mode":"sandboxed","reason":"repo work"}\n' ;;
count) printf '{"count":1,"reason":"one worker"}\n' ;;
thinking) printf '{"thinking":"low","reason":"mechanical"}\n' ;;
*) printf '{"reason":"stub"}\n' ;;
esac
exit 0
STUB
printf '#!/usr/bin/env bash\nexit 0\n' >"$PI_BOSS_ROOT/bin/pi-sandboxed"
chmod +x "$PI_BOSS_ROOT/bin/jev" "$PI_BOSS_ROOT/bin/pi-sandboxed"
: >"$PI_BOSS_ROOT/state/delegations.json"
out=$(timeout 60 "$bin/delegate" spawn template-check --cwd "$work" "change one file" 2>&1) && rc=0 || rc=$?
spec=$PI_BOSS_ROOT/specs/template-check.md
if [ "$rc" != 0 ]; then
	fail "spawn for the template check: exit $rc — $out"
elif ! grep -qF "specs/archive/" "$spec"; then
	fail "the spawn template never mentions specs/archive/"
elif ! grep -qF "Agent-Slug: template-check" "$spec" || ! grep -qF "Spec: " "$spec"; then
	fail "the spawn template does not name both trailers: $(grep -n 'Agent-Slug\\|Spec:' "$spec" 2>&1)"
else
	pass "the spawn spec names specs/archive/ and both commit trailers"
fi

# 8. The readability gate lives in a file, so it is checkable: tier, mission, one sentence, and
#    the line that keeps formatting out of the merge decision.
template=$root/.github/pull_request_template.md
missing=""
if [ -f "$template" ]; then
	for anchor in "Review tier" "Mission" "in one sentence" "formatter" "no LOC"; do
		grep -qiF -- "$anchor" "$template" || missing="$missing '$anchor'"
	done
else
	missing=" the file does not exist"
fi
if [ -n "$missing" ]; then
	fail "pull_request_template.md is missing:$missing"
else
	pass "pull_request_template.md carries tier, mission, one sentence and the formatter line"
fi

printf '\n%s\n' "$([ "$fails" = 0 ] && echo "provenance: ok" || echo "provenance: $fails failure(s)")"
[ "$fails" = 0 ]
