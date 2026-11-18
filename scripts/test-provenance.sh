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
elif printf '%s' "$OUT" | grep -qE -- '--merged|patch-id|cherry'; then
	fail "a close with no --merged mentions the escape, so the byte-identical case has grown — $OUT"
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
plan) printf '{"count":1,"mode":"sandboxed","route":"remote","thinking":"low","reason":"one worker","confidence":0.9}\n' ;;
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
elif ! grep -qE '^7\. End every commit message with two trailers' "$spec"; then
	fail "the trailer rule is not its own numbered item in the spawn template"
elif [ "$(grep -cE '^[0-9]+\. ' "$spec")" != 11 ] || ! grep -qE '^11\. ' "$spec"; then
	fail "the spawn template's rule list is not numbered 1 to 11: $(grep -oE '^[0-9]+\. ' "$spec" | tr '\n' ' ')"
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
#    to give: a change that is already in trunk cannot be amended, so the trailer is recorded
#    after the fact instead — and since this repo squash-merges, "already in trunk" has to include
#    the same patch under another sha, or every close after a squash refuses forever.
#
#    The fixture carries real file content rather than empty commits on purpose: every empty commit
#    has the same patch-id, so a repo of those cannot tell a landed change from an unlanded one.
remote=$work/remote.git
merged=$work/merged
mkdir -p "$merged"
git init -q --bare -b trunk "$remote"
git -C "$merged" init -q -b trunk
git -C "$merged" config user.email worker@example.invalid
git -C "$merged" config user.name worker
git -C "$merged" remote add origin "$remote"
printf 'one\ntwo\nthree\n' >"$merged/f"
git -C "$merged" add f
git -C "$merged" commit -q -m "feat: the base"
git -C "$merged" push -q origin trunk
# landed: on origin/trunk, no Agent-Slug trailer
printf 'one\nTWO\nthree\n' >"$merged/f"
git -C "$merged" commit -q -a -m "feat: a change that landed without a trailer"
landed=$(git -C "$merged" rev-parse HEAD)
git -C "$merged" push -q origin trunk
# in-flight: on the branch only, also no trailer, and a different patch
printf 'one\nTWO\nTHREE\n' >"$merged/f"
git -C "$merged" commit -q -a -m "feat: still on the branch"
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

# The cases below accept closes of their own, so they get their wipe lines in one go: a refusal in
# them is about provenance, not about the consolidation checklist.
printf '{"timestamp":"%s","command":"wipe","task":"%s","decision":"done","reason":null,"overridden":false,"slug":"%s"}\n' \
	"$(date -u +%Y-%m-%dT%H:%M:%SZ)" merged-order merged-order \
	"$(date -u +%Y-%m-%dT%H:%M:%SZ)" merged-equiv merged-equiv \
	"$(date -u +%Y-%m-%dT%H:%M:%SZ)" merged-neighbour merged-neighbour \
	"$(date -u +%Y-%m-%dT%H:%M:%SZ)" merged-reverted merged-reverted \
	"$(date -u +%Y-%m-%dT%H:%M:%SZ)" merged-shallow merged-shallow \
	>>"$PI_BOSS_ROOT/state/decisions.jsonl"

# (e) The ordering, proved rather than asserted. The ancestor case is answered by
#     `merge-base --is-ancestor` alone; the patch-id machinery must never be reached on it, or the
#     cheapest test has become the most expensive one. A git on PATH that exits 97 when it is
#     asked for cherry, patch-id or apply makes "never reached" observable — there is no test-only
#     branch in bin/delegate a production run could take instead.
realgit=$(command -v git)
mkdir -p "$work/stub-git"
{
	printf '#!/usr/bin/env bash\n'
	printf 'for a in "$@"; do case $a in cherry|patch-id|apply) printf "%%s\\n" "$*" >>"%s/patch-id-called"; exit 97 ;; esac; done\n' "$work"
	printf 'exec %s "$@"\n' "$realgit"
} >"$work/stub-git/git"
chmod +x "$work/stub-git/git"
mkdir -p "$PI_BOSS_ROOT/reports"
cat >"$PI_BOSS_ROOT/reports/merged-order.md" <<REPORT
# Report

Mission: the cheap ancestor test answers before the patch-id machinery is asked anything.

Commit: $landed

## Evidence

\$ bash scripts/test-provenance.sh — ok
REPORT
printf '{"merged-order":{"space":"space-merged-order","cwd":"%s","branch":""}}\n' "$merged" \
	>"$PI_BOSS_ROOT/state/delegations.json"
out=$(PATH=$work/stub-git:$PATH "$bin/delegate" close merged-order --merged 63 2>&1) && rc=0 || rc=$?
if [ -s "$work/patch-id-called" ]; then
	fail "the ancestor case reached the patch-id machinery: $(head -n 3 "$work/patch-id-called")"
elif [ "$rc" != 0 ]; then
	fail "the ancestor case through a patch-id-hostile git: exit $rc, wanted 0 — $out"
elif ! printf '%s' "$out" | grep -qF "is already in origin/trunk"; then
	fail "the ancestor case: the warning stopped saying the commit is already in trunk — $out"
else
	pass "the ancestor case closes on merge-base alone: cherry, patch-id and apply are never called"
fi

# (f) The case this repo actually produces. A worker's own commit is never an ancestor of
#     origin/trunk, because the branch is squash-merged: the landed commit has another sha and the
#     same patch. The close has to accept it, and say which two commits are the same change — in
#     the warning and in the row, because the row is what a later reader checks.
equiv=$work/equiv
git init -q --bare -b trunk "$work/remote-equiv.git"
mkdir -p "$equiv"
git -C "$equiv" init -q -b trunk
git -C "$equiv" config user.email worker@example.invalid
git -C "$equiv" config user.name worker
git -C "$equiv" remote add origin "$work/remote-equiv.git"
printf 'alpha\nbeta\ngamma\n' >"$equiv/f"
git -C "$equiv" add f
git -C "$equiv" commit -q -m "feat: the base"
git -C "$equiv" push -q origin trunk
git -C "$equiv" checkout -q -b feat
printf 'alpha\nBETA\ngamma\n' >"$equiv/f"
git -C "$equiv" commit -q -a -m "feat: a change that lands as a squash"
equiv_sha=$(git -C "$equiv" rev-parse HEAD)
git -C "$equiv" checkout -q trunk
git -C "$equiv" cherry-pick feat >/dev/null 2>&1
git -C "$equiv" commit -q --amend -m "feat: a change that lands as a squash (#65)"
equiv_landed=$(git -C "$equiv" rev-parse HEAD)
git -C "$equiv" push -q origin trunk
git -C "$equiv" fetch -q --prune origin
run_close_in merged-equiv "$equiv" --merged 65 <<REPORT
# Report

Mission: a squash-merged change closes its worker without a hand-edit of the report.

Commit: $equiv_sha

## Evidence

\$ bash scripts/test-provenance.sh — ok
REPORT
equiv_short=$(git -C "$equiv" rev-parse --short "$equiv_sha")
equiv_landed_short=$(git -C "$equiv" rev-parse --short "$equiv_landed")
row=$(grep '"slug":"merged-equiv"' "$PI_BOSS_ROOT/state/decisions.jsonl" | tail -n 1)
if [ "$RC" != 0 ]; then
	fail "patch-equivalent squash: exit $RC, wanted 0 — $OUT"
elif ! printf '%s' "$OUT" | grep -qF "$equiv_short"; then
	fail "patch-equivalent squash: the warning does not name the report's sha $equiv_short — $OUT"
elif ! printf '%s' "$OUT" | grep -qF "$equiv_landed_short"; then
	fail "patch-equivalent squash: the warning does not name the landed sha $equiv_landed_short — $OUT"
elif ! printf '%s' "$OUT" | grep -qF "PR #65"; then
	fail "patch-equivalent squash: the warning does not name the PR — $OUT"
elif [ -z "$row" ]; then
	fail "patch-equivalent squash: no row for the slug in state/decisions.jsonl"
elif ! node -e '
		const r=JSON.parse(process.argv[1]);
		if(r.command!=="provenance"||r.slug!=="merged-equiv")process.exit(1);
		if(r.sha!==process.argv[2]||r.landed!==process.argv[3])process.exit(1);
		if(r.pr!=="#65"||r.trunk!=="origin/trunk"||!r.reason)process.exit(1);' \
	"$row" "$equiv_sha" "$equiv_landed" 2>/dev/null; then
	fail "patch-equivalent squash: the row does not name both shas, the PR and the reason — $row"
else
	pass "patch-equivalent squash closes, and the warning and the row name both shas and the PR"
fi

# (g) A squash that also touched neighbouring lines moves the patch-id while the content goes in.
#     git will not certify it, so the close refuses — with its own message and its own two fixes,
#     because amending the branch commit and recording the merge by hand are different moves from
#     "it never landed".
neigh=$work/neighbour
git init -q --bare -b trunk "$work/remote-neighbour.git"
mkdir -p "$neigh"
git -C "$neigh" init -q -b trunk
git -C "$neigh" config user.email worker@example.invalid
git -C "$neigh" config user.name worker
git -C "$neigh" remote add origin "$work/remote-neighbour.git"
printf 'l1\nl2\nl3\n' >"$neigh/f"
git -C "$neigh" add f
git -C "$neigh" commit -q -m "feat: the base"
git -C "$neigh" push -q origin trunk
git -C "$neigh" checkout -q -b feat
printf 'l1\nL2\nl3\n' >"$neigh/f"
git -C "$neigh" commit -q -a -m "feat: L2"
neigh_sha=$(git -C "$neigh" rev-parse HEAD)
git -C "$neigh" checkout -q trunk
printf 'l1\nL2\nl3\nl4\n' >"$neigh/f"
git -C "$neigh" commit -q -a -m "feat: L2 and a neighbouring line (#66)"
git -C "$neigh" push -q origin trunk
git -C "$neigh" fetch -q --prune origin
run_close_in merged-neighbour "$neigh" --merged 66 <<REPORT
# Report

Mission: a squash that moved the patch-id is refused in its own words, not as never-landed.

Commit: $neigh_sha

## Evidence

\$ bash scripts/test-provenance.sh — ok
REPORT
row=$(grep '"command":"provenance"' "$PI_BOSS_ROOT/state/decisions.jsonl" | grep '"slug":"merged-neighbour"' | tail -n 1)
if [ "$RC" != 1 ]; then
	fail "neighbouring-line squash: exit $RC, wanted 1 — $OUT"
elif ! printf '%s' "$OUT" | grep -qF "neighbouring lines"; then
	fail "neighbouring-line squash: the refusal does not say a squash moved the patch-id — $OUT"
elif printf '%s' "$OUT" | grep -qF "is not an ancestor of origin/trunk, so it has not landed"; then
	fail "neighbouring-line squash: refused as plain not-in-trunk, so the fix it offers is the wrong one — $OUT"
elif [ -n "$row" ]; then
	fail "neighbouring-line squash: a provenance row was written for a refused close — $row"
else
	pass "a squash that also touched neighbouring lines is refused, in a message of its own"
fi

# (h) A landing that was later reverted is still reachable from trunk, so git cherry still marks the
#     patch `-`. Provenance must not accept it: the content is gone, so nothing landed. The refusal
#     names the landing commit, which is what a human needs to check the revert.
revd=$work/reverted
git init -q --bare -b trunk "$work/remote-reverted.git"
mkdir -p "$revd"
git -C "$revd" init -q -b trunk
git -C "$revd" config user.email worker@example.invalid
git -C "$revd" config user.name worker
git -C "$revd" remote add origin "$work/remote-reverted.git"
printf 'one\ntwo\nthree\n' >"$revd/f"
git -C "$revd" add f
git -C "$revd" commit -q -m "feat: the base"
git -C "$revd" push -q origin trunk
git -C "$revd" checkout -q -b feat
printf 'one\nTWO\nthree\n' >"$revd/f"
git -C "$revd" commit -q -a -m "feat: a change that lands and is backed out"
revd_sha=$(git -C "$revd" rev-parse HEAD)
git -C "$revd" checkout -q trunk
git -C "$revd" cherry-pick feat >/dev/null 2>&1
git -C "$revd" commit -q --amend -m "feat: a change that lands and is backed out (#67)"
revd_landed=$(git -C "$revd" rev-parse HEAD)
git -C "$revd" push -q origin trunk
printf 'one\ntwo\nthree\n' >"$revd/f"
git -C "$revd" commit -q -a -m "revert: back the change out"
git -C "$revd" push -q origin trunk
git -C "$revd" fetch -q --prune origin
run_close_in merged-reverted "$revd" --merged 67 <<REPORT
# Report

Mission: a reverted landing is not a landed change, and the close refuses it.

Commit: $revd_sha

## Evidence

\$ bash scripts/test-provenance.sh — ok
REPORT
revd_landed_short=$(git -C "$revd" rev-parse --short "$revd_landed")
row=$(grep '"command":"provenance"' "$PI_BOSS_ROOT/state/decisions.jsonl" | grep '"slug":"merged-reverted"' | tail -n 1)
if [ "$RC" != 1 ]; then
	fail "reverted landing: exit $RC, wanted 1 — $OUT"
elif ! printf '%s' "$OUT" | grep -qF "reverted"; then
	fail "reverted landing: the refusal does not say the change was reverted — $OUT"
elif ! printf '%s' "$OUT" | grep -qF "$revd_landed_short"; then
	fail "reverted landing: the refusal does not name the landing commit $revd_landed_short — $OUT"
elif [ -n "$row" ]; then
	fail "reverted landing: a provenance row was written for a reverted change — $row"
else
	pass "a landing that was later reverted is refused, and the refusal names the landing commit"
fi

# (i) A commit whose history was never fetched has no parent to diff against, and `git cherry`
#     answers that with silence. Silence is not "not upstream": the close must say fetch, because
#     "git could not look" and "the change is not there" are different findings.
shallow=$work/shallow
git init -q --bare -b trunk "$work/remote-shallow.git"
mkdir -p "$work/shallow-origin"
git -C "$work/shallow-origin" init -q -b trunk
git -C "$work/shallow-origin" config user.email worker@example.invalid
git -C "$work/shallow-origin" config user.name worker
git -C "$work/shallow-origin" remote add origin "$work/remote-shallow.git"
printf 'x\ny\n' >"$work/shallow-origin/f"
git -C "$work/shallow-origin" add f
git -C "$work/shallow-origin" commit -q -m "feat: the base"
git -C "$work/shallow-origin" push -q origin trunk
git -C "$work/shallow-origin" checkout -q -b side
printf 'x\nY\n' >"$work/shallow-origin/f"
git -C "$work/shallow-origin" commit -q -a -m "feat: a change on a side branch"
git -C "$work/shallow-origin" push -q origin side
git clone -q --depth 1 --no-single-branch "file://$work/remote-shallow.git" "$shallow"
git -C "$shallow" config user.email worker@example.invalid
git -C "$shallow" config user.name worker
side_sha=$(git -C "$shallow" rev-parse refs/remotes/origin/side)
run_close_in merged-shallow "$shallow" --merged 68 <<REPORT
# Report

Mission: an unfetched commit is met with "fetch first", not with a guess about trunk.

Commit: $side_sha

## Evidence

\$ bash scripts/test-provenance.sh — ok
REPORT
if [ "$RC" != 1 ]; then
	fail "unfetched commit: exit $RC, wanted 1 — $OUT"
elif ! printf '%s' "$OUT" | grep -qiF "fetch"; then
	fail "unfetched commit: the refusal does not say to fetch first — $OUT"
elif printf '%s' "$OUT" | grep -qF "is not an ancestor of origin/trunk"; then
	fail "unfetched commit: refused as plain not-in-trunk, so a missing ref read as an answer — $OUT"
else
	pass "a commit whose history was not fetched is refused as \"fetch first\", never as not-upstream"
fi

printf '\n%s\n' "$([ "$fails" = 0 ] && echo "provenance: ok" || echo "provenance: $fails failure(s)")"
[ "$fails" = 0 ]
