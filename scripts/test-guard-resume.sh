#!/usr/bin/env bash
# test-guard-resume.sh — a repaired tab keeps its conversation when it can.
#
# Radar Vol. 35: blip 20 (stateful guardrails) — a rule nothing checks is a rule that is gone.
# The guard now has two repair paths and picking the wrong one is silent history loss, so each
# path is driven here against a fake herdr-app, a fake resume map and a fake resume script:
#
#   1. a terminal with a resume entry is resumed, and no tab is opened or closed;
#   2. a terminal with no entry never held pi, so it is opened fresh;
#   3. a resume that does not put pi back falls back to opening a fresh tab;
#   4. the per-tab rate limit still holds a tab that was just repaired;
#   5. a space called pi-master is not touched at all.
#
#   bash scripts/test-guard-resume.sh      exit 0 = every case held
set -uo pipefail

root=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export HOME=$work/home
mkdir -p "$HOME" "$work/stub"

fails=0
pass() { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }

# --- the fake desktop app ----------------------------------------------------
# One space s1 with one tab tab1 named master, whose terminal t1 runs a parked shell. `ls` reads
# $FAKE/tabs (tab|name|index|terminal|app, one per line) and prints it as JSON, so a fake resume
# can "start pi" by rewriting that file — the guard has to read the app, not the script's opinion.
cat >"$work/stub/herdr-app" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
st=$FAKE
printf '%s\n' "$*" >>"$st/calls"
case ${1:-} in
ls)
	printf '{"spaces":[{"id":"s1","name":"boss","tabs":['
	sep=""
	while IFS='|' read -r tab name index terminal app; do
		[ -n "${tab:-}" ] || continue
		printf '%s{"id":"%s","name":"%s","terminals":[{"id":"%s","app":"%s"}]}' \
			"$sep" "$tab" "$name" "$terminal" "$app"
		sep=","
	done <"$st/tabs"
	printf ']}]}\n'
	;;
status) printf '{"space":"s1","tab":"tab1"}\n' ;;
do)
	shift
	case ${1:-} in
	tab.new)
		n=$(($(wc -l <"$st/tabs") + 1))
		printf 'tabnew%d|extra|%d|tnew%d|pi\n' "$n" "$n" "$n" >>"$st/tabs"
		printf '{"terminal":"tnew%d"}\n' "$n"
		;;
	tab.close)
		id=""
		while [ $# -gt 0 ]; do [ "$1" = --id ] && id=$2; shift; done
		grep -v "^$id|" "$st/tabs" >"$st/tabs.tmp" || true
		mv "$st/tabs.tmp" "$st/tabs"
		printf '{}\n'
		;;
	*) printf '{}\n' ;;
	esac
	;;
*) printf '{}\n' ;;
esac
STUB

# The fake resume script: record the call, and start pi only when asked to AND an entry exists.
# Its flags are the real script's (none); the entry folder arrives in PI_HERDR_RESUME_DIR.
cat >"$work/stub/resume.sh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
printf 'resume %s (dir %s)\n' "$*" "${PI_HERDR_RESUME_DIR:-unset}" >>"$FAKE/resume-calls"
[ "${FAKE_RESUME_SUCCEED:-0}" = 1 ] || exit 0
ls "$PI_HERDR_RESUME_DIR"/*.json >/dev/null 2>&1 || exit 0
sed -i 's/|sh$/|pi/' "$FAKE/tabs"
exit 0
STUB
chmod +x "$work/stub/herdr-app" "$work/stub/resume.sh"
export PATH=$work/stub:/usr/local/bin:/usr/bin:/bin
# hc must not be on PATH: a kickoff send would need a real core.
command -v hc >/dev/null 2>&1 && printf 'note: hc on PATH; kickoff send is still skipped (no terminal there)\n'

# --- one guard run -----------------------------------------------------------
case_no=0
run_guard() { # run_guard <space> [entry: yes|no] [succeed: 0|1] [seed repairs: yes|no]
	local space=$1 entry=${2:-yes} succeed=${3:-0} seed=${4:-no}
	case_no=$((case_no + 1))
	fake=$work/case$case_no
	mkdir -p "$fake/entries" "$fake/root/state" "$fake/root/bin" "$fake/root/reports" "$fake/root/specs"
	printf 'tab1|master|1|t1|sh\n' >"$fake/tabs"
	[ "$entry" = yes ] && printf '{"terminal":"t1","session_path":"/tmp/s.jsonl","argv":["pi"]}\n' \
		>"$fake/entries/t1.json"
	[ "$seed" = yes ] && printf 's1:master:1 %s\n' "$(date +%s)" >"$fake/root/state/repairs"
	# 6s of timeout is the loop's own bound; the guard polls once, then sleeps the interval.
	timeout 6 env \
		FAKE=$fake \
		PI_BOSS_ROOT=$fake/root \
		PI_BOSS_SPACE=$space \
		PI_BOSS_GUARD_INTERVAL=300 \
		PI_BOSS_RESUME_SCRIPT=$work/stub/resume.sh \
		PI_BOSS_RESUME_DIR=$fake/entries \
		FAKE_RESUME_SUCCEED=$succeed \
		bash "$root/bin/guard" >"$fake/out" 2>&1
	return 0
}
resume_calls() { [ -f "$fake/resume-calls" ] && wc -l <"$fake/resume-calls" || echo 0; }
opened_tab() {
	[ -f "$fake/calls" ] || {
		echo 0
		return 0
	}
	local n
	n=$(grep -c '^do tab.new' "$fake/calls" || true)
	echo "${n:-0}"
}
logged() { grep -qF "$1" "$fake/root/state/guard.log" 2>/dev/null; }

# 1. resume is preferred: an entry means the tab can keep its conversation.
run_guard boss yes 1
if [ "$(resume_calls)" = 1 ] && [ "$(opened_tab)" = 0 ] && logged "resumed terminal \`t1\` in tab master"; then
	pass "entry exists: resumed t1, nothing opened, guard.log says which path it took"
else
	fail "expected a resume and no tab.new (resume calls $(resume_calls), tab.new $(opened_tab))"
	cat "$fake/root/state/guard.log" 2>/dev/null
fi

# 2. no entry: a tab that never held pi is opened fresh, and no resume is attempted.
run_guard boss no 0
if [ "$(resume_calls)" = 0 ] && [ "$(opened_tab)" = 1 ] &&
	logged "has no entry in" && logged "opened a new pi in tab master"; then
	pass "no entry: opened a new pi, never ran the resume script"
else
	fail "expected no resume and one tab.new (resume calls $(resume_calls), tab.new $(opened_tab))"
	cat "$fake/root/state/guard.log" 2>/dev/null
fi

# 3. a resume that starts nothing falls back to opening the tab, or the person keeps a dead tab.
run_guard boss yes 0
if [ "$(resume_calls)" = 1 ] && [ "$(opened_tab)" = 1 ] && logged "could not resume terminal \`t1\`"; then
	pass "failed resume: fell back to opening a new pi, and said why"
else
	fail "expected resume then tab.new (resume calls $(resume_calls), tab.new $(opened_tab))"
	cat "$fake/root/state/guard.log" 2>/dev/null
fi

# 4. the rate limit counts the resume path too: a tab repaired a moment ago is left for a minute.
run_guard boss yes 1 yes
if [ "$(resume_calls)" = 0 ] && [ "$(opened_tab)" = 0 ]; then
	pass "rate limit: a tab repaired moments ago is not touched again, resume included"
else
	fail "rate limit did not hold (resume calls $(resume_calls), tab.new $(opened_tab))"
fi

# 5. the old workspace's space is not ours: no app call, no repair, exit 0.
run_guard pi-master yes 1
if [ ! -f "$fake/calls" ] && [ "$(resume_calls)" = 0 ]; then
	pass "pi-master: guard exited without one herdr-app call"
else
	fail "pi-master was touched: $(cat "$fake/calls" 2>/dev/null | head -3)"
fi

if [ "$fails" -gt 0 ]; then
	printf 'guard-resume: %d case(s) failed\n' "$fails"
	exit 1
fi
printf 'guard-resume: ok\n'
