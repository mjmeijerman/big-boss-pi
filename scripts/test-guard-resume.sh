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
# And the case that cost a conversation on 2026-11-15: after a host reboot herdr-app reports no
# terminal for a parked tab, and the resume script skipped that terminal as "busy (no program)"
# because its foreground had no argv. So the guard has to find the entry by tab id, and has to do
# the typing itself when the script declines. A fake `hc` provides the terminal facts:
#
#   6. terminal absent from herdr-app, entry exists by tab id -> resumed, nothing opened;
#   7. resume script says "busy (no program)" -> still resumed through the entry, not opened fresh;
#   8. two entries for one tab -> the newest `updated_at` wins;
#   9. entry whose session file is gone -> opened fresh, with the old log line;
#  10. entry restored in this boot -> nothing typed a second time, tab left alone;
#  11. fake hc reports a live terminal with no foreground argv -> the guard waits and retries.
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
if [ "${FAKE_RESUME_BUSY:-0}" = 1 ]; then
	# What herdr-resume.mjs printed on 2026-11-15, and why the conversation was lost.
	printf 'skip terminal %s: terminal is busy (no program)\n' tX >>"$FAKE/resume-calls"
	printf 'skip terminal %s: terminal is busy (no program)\n' tX
	printf 'nothing restored: every entry was skipped\n'
	exit 0
fi
[ "${FAKE_RESUME_SUCCEED:-0}" = 1 ] || exit 0
ls "$PI_HERDR_RESUME_DIR"/*.json >/dev/null 2>&1 || exit 0
sed -i 's/|sh$/|pi/' "$FAKE/tabs"
exit 0
STUB

# The fake `hc`: it is the only way the guard can type into a terminal the app does not report.
# `get <t> --json` answers from $FAKE/hc-fg/<t> (shell | none | pi | other:<cmd>) and only for a
# terminal listed in $FAKE/hc-known; `send` records the line, makes that terminal pi, and flips the
# tab to pi so herdr-app reports it too. $FAKE/hc-calls counts both, so a test can see a retry.
cat >"$work/stub/hc" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
st=$FAKE
printf '%s\n' "$*" >>"$st/hc-calls"
case ${1:-} in
get)
	t=${2:-}
	grep -qx "$t" "$st/hc-known" 2>/dev/null || exit 1
	fg=$(cat "$st/hc-fg/$t" 2>/dev/null || echo shell)
	case $fg in
	none) printf '{"state":"live","foreground":{}}\n' ;;
	shell) printf '{"state":"live","foreground":{"argv":["/bin/bash"],"pid":1},"argv":["/bin/bash"]}\n' ;;
	pi) printf '{"state":"live","foreground":{"argv":["/home/mark/.local/share/pnpm/pi/cli.js"],"pid":2}}\n' ;;
	other:*) printf '{"state":"live","foreground":{"argv":["%s"],"pid":3}}\n' "${fg#other:}" ;;
	esac
	;;
send)
	t=${2:-}
	shift 2
	printf '%s\n' "$*" >>"$st/hc-sends"
	printf pi >"$st/hc-fg/$t"
	sed -i 's/|sh$/|pi/' "$st/tabs"
	;;
*) printf '{}\n' ;;
esac
STUB
chmod +x "$work/stub/herdr-app" "$work/stub/resume.sh" "$work/stub/hc"
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
	[ "$entry" = yes ] && {
		: >"$fake/s1.jsonl"
		printf '{"terminal":"t1","session_path":"%s","argv":["pi"],"updated_at":"2026-11-15T09:00:00.000Z"}\n' \
			"$fake/s1.jsonl" >"$fake/entries/t1.json"
	}
	[ "$seed" = yes ] && printf 's1:master:1 %s\n' "$(date +%s)" >"$fake/root/state/repairs"
	# One poll, then out (PI_BOSS_ONCE), so a case costs its repair and not the poll interval.
	timeout 15 env \
		PI_BOSS_ONCE=1 \
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

# hc is the fake above; a kickoff send needs nothing else. A second runner lets a case write its
# own tabs, entries and hc facts instead of the one-tab shape the first five use.
setup_case() { # setup_case <tabs line>
	case_no=$((case_no + 1))
	fake=$work/case$case_no
	mkdir -p "$fake/entries" "$fake/root/state" "$fake/root/bin" "$fake/root/reports" "$fake/root/specs" "$fake/hc-fg"
	: >"$fake/hc-known"
	printf '%s\n' "$1" >"$fake/tabs"
}

hc_knows() { printf '%s\n' "$1" >>"$fake/hc-known"; }
entry() { # entry <file> <json>
	printf '%s\n' "$2" >"$fake/entries/$1.json"
}
session() { # session <name> — a session file that exists
	: >"$fake/$1"
	printf '%s' "$fake/$1"
}
tabs_app() { cut -d'|' -f5 "$fake/tabs" | tr -d '\n'; }

# guard_once <space> [resume-script-succeeds] [resume-script-busy] — one poll of the guard, bounded.
guard_once() {
	timeout 15 env \
		PI_BOSS_ONCE=1 \
		FAKE=$fake \
		PI_BOSS_ROOT=$fake/root \
		PI_BOSS_SPACE=${1:-boss} \
		PI_BOSS_GUARD_INTERVAL=300 \
		PI_BOSS_RESUME_SCRIPT=$work/stub/resume.sh \
		PI_BOSS_RESUME_DIR=$fake/entries \
		PI_BOSS_ATTACH_TRIES=2 \
		PI_BOSS_ATTACH_GAP=1 \
		PI_BOSS_RESUME_START_WAIT=6 \
		FAKE_RESUME_SUCCEED=${2:-0} \
		FAKE_RESUME_BUSY=${3:-0} \
		bash "$root/bin/guard" >"$fake/out" 2>&1
	return 0
}

# Only an `exec` line is a resume; the kickoff message is also an hc send and is not one.
hc_sends() {
	if [ -f "$fake/hc-sends" ]; then grep -c '^exec' "$fake/hc-sends" || true; else echo 0; fi
}
hc_gets() {
	if [ -f "$fake/hc-calls" ]; then grep -c '^get ' "$fake/hc-calls" || true; else echo 0; fi
}
sent_line() { grep '^exec' "$fake/hc-sends" 2>/dev/null | head -n 1; }

# 6. today's first failure: herdr-app has no terminal for the parked tab, the entry is keyed by the
#    tab id, and the resume script declined. The guard has to find it and type it itself.
setup_case 'tab1|Pi (bare)|1|tzzz|sh'
hc_knows tX
printf shell >"$fake/hc-fg/tX"
entry e1 "{\"terminal\":\"tX\",\"tab\":\"tab1\",\"space\":\"s1\",\"session_path\":\"$(session s1.jsonl)\",\"argv\":[\"pi\"],\"updated_at\":\"2026-11-15T09:00:00.000Z\"}"
guard_once boss 0 1
if [ "$(hc_sends)" = 1 ] && [ "$(opened_tab)" = 0 ] && [ "$(tabs_app)" = pi ] &&
	grep -q '^exec pi --session' "$fake/hc-sends" &&
	logged 'resumed terminal `tX` in tab Pi (bare) (tab1) with hc'; then
	pass "terminal unknown, entry by tab: resumed tX through hc, nothing opened or closed"
else
	fail "expected one hc send and no tab.new (hc sends $(hc_sends), tab.new $(opened_tab), apps $(tabs_app))"
	cat "$fake/root/state/guard.log" 2>/dev/null
fi

# 7. the resume script's own verdict on that terminal: "busy (no program)". That must not end in a
#    fresh tab — the guard types the session itself.
setup_case 'tab1|master|1|t1|sh'
hc_knows t1
printf none >"$fake/hc-fg/t1"
entry e2 "{\"terminal\":\"t1\",\"tab\":\"tab1\",\"session_path\":\"$(session s2.jsonl)\",\"argv\":[\"pi\"],\"updated_at\":\"2026-11-15T09:00:00.000Z\"}"
guard_once boss 0 1
if [ "$(grep -c 'busy (no program)' "$fake/resume-calls" || true)" -ge 1 ] &&
	[ "$(hc_sends)" = 1 ] && [ "$(opened_tab)" = 0 ] && [ "$(tabs_app)" = pi ]; then
	pass "resume script said busy: still resumed from the entry, no fresh tab"
else
	fail "expected the script's busy skip and then an hc resume (hc sends $(hc_sends), tab.new $(opened_tab), apps $(tabs_app))"
	cat "$fake/root/state/guard.log" 2>/dev/null
fi

# 8. two entries for one tab: the newest updated_at is the session that was there last.
setup_case 'tab1|master|1|tzzz|sh'
hc_knows tX
printf shell >"$fake/hc-fg/tX"
entry old "{\"terminal\":\"tOld\",\"tab\":\"tab1\",\"session_path\":\"$(session old.jsonl)\",\"argv\":[\"old-pi\"],\"updated_at\":\"2026-11-14T20:00:00.000Z\"}"
entry new "{\"terminal\":\"tX\",\"tab\":\"tab1\",\"session_path\":\"$(session new.jsonl)\",\"argv\":[\"new-pi\"],\"updated_at\":\"2026-11-15T09:00:00.000Z\"}"
guard_once boss 0 0
if [ "$(hc_sends)" = 1 ] && printf '%s' "$(sent_line)" | grep -q 'new-pi'; then
	pass "two entries: the newest updated_at wins ($(sent_line))"
else
	fail "expected the newest entry to be resumed (hc sends $(hc_sends): $(sent_line))"
	cat "$fake/root/state/guard.log" 2>/dev/null
fi

# 9. an entry whose session file is gone is not resumed: there is nothing to resume.
setup_case 'tab1|master|1|tzzz|sh'
hc_knows tX
entry e9 "{\"terminal\":\"tX\",\"tab\":\"tab1\",\"session_path\":\"$fake/gone.jsonl\",\"argv\":[\"pi\"],\"updated_at\":\"2026-11-15T09:00:00.000Z\"}"
guard_once boss 0 0
if [ "$(hc_sends)" = 0 ] && [ "$(opened_tab)" = 1 ] && logged 'has no entry in'; then
	pass "session file gone: opened fresh with the old log line, nothing typed"
else
	fail "expected a fresh tab and the old log line (hc sends $(hc_sends), tab.new $(opened_tab))"
	cat "$fake/root/state/guard.log" 2>/dev/null
fi

# 10. an entry restored in this boot is not typed a second time, and a tab whose pi the person let
#     go is left alone rather than reopened.
setup_case 'tab1|master|1|tzzz|sh'
hc_knows tX
boot=$(tr -d '\n' </proc/sys/kernel/random/boot_id 2>/dev/null || true)
entry e10 "{\"terminal\":\"tX\",\"tab\":\"tab1\",\"session_path\":\"$(session s10.jsonl)\",\"argv\":[\"pi\"],\"updated_at\":\"2026-11-15T09:00:00.000Z\",\"restored_boot_id\":\"$boot\"}"
guard_once boss 0 0
if [ -n "$boot" ] && [ "$(hc_sends)" = 0 ] && [ "$(opened_tab)" = 0 ] && logged 'already had its session resumed in this boot'; then
	pass "restored_boot_id = this boot: nothing typed again, tab left alone"
else
	fail "expected no typing and no fresh tab (hc sends $(hc_sends), tab.new $(opened_tab), boot '${boot}')"
	cat "$fake/root/state/guard.log" 2>/dev/null
fi

# 11. today's second failure: hc says live, foreground has no argv and no pid. That is "not attached
#     yet", not busy: the guard asks again before it concludes anything.
setup_case 'tab1|master|1|tzzz|sh'
hc_knows tX
printf none >"$fake/hc-fg/tX"
entry e11 "{\"terminal\":\"tX\",\"tab\":\"tab1\",\"session_path\":\"$(session s11.jsonl)\",\"argv\":[\"pi\"],\"updated_at\":\"2026-11-15T09:00:00.000Z\"}"
guard_once boss 0 1
if [ "$(hc_gets)" -ge 2 ] && [ "$(hc_sends)" = 1 ] && [ "$(opened_tab)" = 0 ] && [ "$(tabs_app)" = pi ]; then
	pass "foreground has no argv: waited ($(hc_gets) hc get calls) instead of calling it busy, then resumed"
else
	fail "expected hc gets then one send (gets $(hc_gets), sends $(hc_sends), tab.new $(opened_tab))"
	cat "$fake/root/state/guard.log" 2>/dev/null
fi

if [ "$fails" -gt 0 ]; then
	printf 'guard-resume: %d case(s) failed\n' "$fails"
	exit 1
fi
printf 'guard-resume: ok\n'
