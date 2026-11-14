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
elif ! awk '/^[[:space:]]*job, so it never needs/ { if (prev ~ /publishing is the boss.s[[:space:]]*$/) ok = 1 } { prev = $0 } END { exit(ok ? 0 : 1) }' "$spec"; then
	fail "the spawn template still splices the trailer rule into the middle of the publishing sentence"
elif ! grep -qE '^6\. End every commit message with two trailers' "$spec"; then
	fail "the trailer rule is not its own numbered item in the spawn template"
elif [ "$(grep -cE '^[0-9]+\. ' "$spec")" != 10 ] || ! grep -qE '^10\. ' "$spec"; then
	fail "the spawn template's rule list is not numbered 1 to 10: $(grep -oE '^[0-9]+\. ' "$spec" | tr '\n' ' ')"
elif ! grep -qF 'AGENT_SLUG=template-check' "$work/herdr-calls" 2>/dev/null; then
	fail "AGENT_SLUG never reached the runner command: $(grep -o 'AGENT_SLUG=[^ ]*' "$work/herdr-calls" 2>&1 | head -2)"
else
	pass "the spawn spec names both trailers as its own rule, and AGENT_SLUG reaches the runner"
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

# 9. The escape for a commit that is already in trunk. A repo with a real remote, a commit that
#    landed on origin/trunk without the trailer (a squash merge looks exactly like this), and a
#    second commit that is still only on the branch. `delegate close --merged` has one permission
#    to give: a commit that is already in trunk cannot be amended, so the trailer is recorded
#    after the fact instead.
remote=$work/remote.git
merged=$work/merged
mkdir -p "$merged"
git init -q --bare -b trunk "$remote"
git -C "$merged" init -q -b trunk
git -C "$merged" config user.email worker@example.invalid
git -C "$merged" config user.name worker
git -C "$merged" remote add origin "$remote"
git -C "$merged" commit -q --allow-empty -m "feat: the base"
git -C "$merged" push -q origin trunk
# landed: on origin/trunk, no Agent-Slug trailer
printf 'feat: a change that landed without a trailer\n' >"$work/msg-landed"
git -C "$merged" commit -q --allow-empty -F "$work/msg-landed"
landed=$(git -C "$merged" rev-parse HEAD)
git -C "$merged" push -q origin trunk
# in-flight: on the branch only, also no trailer
git -C "$merged" commit -q --allow-empty -m "feat: still on the branch"
inflight=$(git -C "$merged" rev-parse HEAD)
git -C "$merged" fetch -q --prune origin
# A wipe line each, because these cases are about provenance, not about the checklist.
printf '{"timestamp":"%s","command":"wipe","task":"merged-no","decision":"done","reason":null,"overridden":false,"slug":"merged-no"}\n{"timestamp":"%s","command":"wipe","task":"merged-yes","decision":"done","reason":null,"overridden":false,"slug":"merged-yes"}\n' \
	"$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$PI_BOSS_ROOT/state/decisions.jsonl"

# run_close_in <slug> <cwd> [close args...] — the same report and registration as run_close, for
# a worker whose cwd is another repo, with flags.
run_close_in() {
	local slug=$1 dir=$2
	shift 2
	mkdir -p "$PI_BOSS_ROOT/reports"
	cat >"$PI_BOSS_ROOT/reports/$slug.md"
	printf '{"%s":{"space":"space-%s","cwd":"%s","branch":""}}\n' "$slug" "$slug" "$dir" \
		>"$PI_BOSS_ROOT/state/delegations.json"
	local out
	out=$("$bin/delegate" close "$slug" "$@" 2>&1) && RC=0 || RC=$?
	OUT=$out
}

# (a) --merged on a commit that has not landed: refuse, and say the flag does not apply. A flag
#     that quietly does nothing would teach the caller to stop reading the refusal.
run_close_in merged-no "$merged" --merged 63 <<REPORT
# Report

Mission: the trailer is demanded only where it can still be added.

Commit: $inflight

## Evidence

\$ bash scripts/test-provenance.sh — ok
REPORT
if [ "$RC" != 1 ]; then
	fail "--merged on an unmerged commit: exit $RC, wanted 1 — $OUT"
elif ! printf '%s' "$OUT" | grep -qF -- "--merged does not apply"; then
	fail "--merged on an unmerged commit: the refusal does not say the flag does not apply — $OUT"
elif ! printf '%s' "$OUT" | grep -qF "$inflight is not an ancestor of origin/trunk"; then
	fail "--merged on an unmerged commit: the refusal does not name the sha and the trunk — $OUT"
else
	pass "--merged on a commit that is not in origin/trunk refuses, and says the flag does not apply"
fi

# (b) --merged on a commit that is in origin/trunk: close, warn with the short sha and the PR, and
#     leave a row in the decision log. The warning and the row are the whole point: provenance
#     recorded after the fact has to be visible, or it is a silent pass.
run_close_in merged-yes "$merged" --merged 63 <<REPORT
# Report

Mission: a landed commit can close its worker without a rewrite of trunk.

Commit: $landed

## Evidence

\$ bash scripts/test-provenance.sh — ok
REPORT
short=$(git -C "$merged" rev-parse --short "$landed")
row=$(grep '"command":"provenance"' "$PI_BOSS_ROOT/state/decisions.jsonl" | tail -n 1)
if [ "$RC" != 0 ]; then
	fail "--merged on a commit in trunk: exit $RC, wanted 0 — $OUT"
elif ! printf '%s' "$OUT" | grep -qF "warning:"; then
	fail "--merged on a commit in trunk: closed without a warning — $OUT"
elif ! printf '%s' "$OUT" | grep -qF "$short"; then
	fail "--merged on a commit in trunk: the warning does not name the short sha $short — $OUT"
elif ! printf '%s' "$OUT" | grep -qF "PR #63"; then
	fail "--merged on a commit in trunk: the warning does not name the PR — $OUT"
elif [ -z "$row" ]; then
	fail "--merged on a commit in trunk: no provenance row in state/decisions.jsonl"
elif ! node -e '
		const r=JSON.parse(process.argv[1]);
		if(r.slug!=="merged-yes"||r.sha!==process.argv[2]||r.pr!=="#63"||!r.reason||r.command!=="provenance")process.exit(1);' \
	"$row" "$landed" 2>/dev/null; then
	fail "--merged on a commit in trunk: the row does not carry slug, sha, pr and a reason — $row"
else
	pass "--merged on a commit in origin/trunk closes, warns with the short sha and the PR, and records the row"
fi

# (c) --merged needs a PR reference. A branch name is not evidence that anything was merged, and
#     guessing one would make the whole exception unfalsifiable.
run_close_in merged-yes "$merged" --merged "some-branch" <<REPORT
# Report

Mission: the escape names the PR it stands on.

Commit: $landed

## Evidence

\$ bash scripts/test-provenance.sh — ok
REPORT
if [ "$RC" != 1 ] || ! printf '%s' "$OUT" | grep -qF -- "--merged needs a PR number"; then
	fail "--merged with a non-PR argument: exit $RC, wanted 1 naming the flag — $OUT"
else
	pass "--merged with a branch name instead of a PR refuses (exit 1)"
fi

# (d) The standard row shape survives the extras, and `delegate stats` still parses the file: a
#     row it cannot read would be counted as unreadable, which is exactly what this checks.
if ! node -e '
		const fs=require("fs");
		const rows=fs.readFileSync(process.argv[1],"utf8").split("\n").filter(Boolean).map(l=>JSON.parse(l));
		const want=["timestamp","command","task","decision","overridden","slug"];
		for(const r of rows)for(const k of want)if(!(k in r))process.exit(1);' "$PI_BOSS_ROOT/state/decisions.jsonl"; then
	fail "a row written by the close lost one of the standard fields"
else
	stats=$("$bin/delegate" stats --json 2>&1) && src=0 || src=$?
	if [ "$src" != 0 ]; then
		fail "delegate stats exits $src after a merged close — $(printf '%s' "$stats" | head -n 3)"
	elif ! printf '%s' "$stats" | node -e '
		let d="";
		process.stdin.on("data",c=>d+=c).on("end",()=>{
			let j={};try{j=JSON.parse(d)}catch{process.exit(1)}
			const dec=j.decisions||{};
			process.exit(dec.unreadable===0&&(dec.by_command||{}).provenance===1?0:1);
		});'; then
		fail "delegate stats does not read the log after a merged close (unreadable != 0, or provenance not counted): $(printf '%s' "$stats" | head -n 3)"
	else
		pass "every row keeps the standard fields and delegate stats parses the log (0 unreadable, provenance counted)"
	fi
fi

printf '\n%s\n' "$([ "$fails" = 0 ] && echo "provenance: ok" || echo "provenance: $fails failure(s)")"
[ "$fails" = 0 ]
