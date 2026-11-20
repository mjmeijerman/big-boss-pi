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
#  11. fake hc reports a live terminal with no foreground argv for one look, then a shell -> the
#      guard waits and types exactly once (a slow recovered shell is still resumed);
#
# And the incident this suite gained its last cases from: a guard resume typed an
# `exec … --session <path>` line into a pi that was already running, because a pi that is still
# starting reads as `unattached` and `wait_attached` used to answer `attached` after the bound.
# The rule now: the line goes only into a terminal that shows a shell prompt, looked at again in
# the last instant before the send.
#
#  19. `unattached` on every look, then pi appears -> nothing typed at all, and the log says why;
#  20. pi already running with the entry's own session in its argv -> skipped, not typed into;
#  21. pi already running on a different session -> skipped too;
#  22. a real dead tab (shell, no pi) -> resumed exactly once, as before;
#  23. a live pi the app has not reported and no entry -> left alone, never closed or reopened.
#
#   bash scripts/test-guard-resume.sh      exit 0 = every case held
#
# And the tabs the guard has no business repairing. herdr-core hands the space back with a shell in
# every parked tab, so "no pi here" once meant "repair it", and a terminal the person had just
# opened was turned into a fresh pi within five seconds. The classification is kept on disk:
#
#  12. a terminal opened while the guard runs -> no pi, no close, no hc send, logged as the person's;
#  13. a parked tab holding a recovered shell, no entry -> still repaired, as before;
#  14. the person's tab survives a guard restart -> the class came from disk, not from memory;
#  15. the guard's own reopened tab loses pi -> reopened, and rate-limited to one a minute;
#  16. a parked tab the person has turned into their own shell -> left alone, said so in the log;
#  17. the person's own tab that does carry a resume entry -> resumed, because that is a conversation;
#  18. a `tab.new` that `ls` has not caught up with -> the tab it lands in is still the guard's own.
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
# $FAKE_HIDE_NEW=1 hides the tabs `tab.new` made, the way a real `ls` lags a tab it has just opened.
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
		if [ "${FAKE_HIDE_NEW:-0}" = 1 ] && [ "$name" = extra ]; then continue; fi
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
# `get <t> --json` answers from $FAKE/hc-json/<t> (raw JSON, verbatim), $FAKE/hc-seq/<t> (a queue of
# states, one consumed per look; a line starting with `{` is raw JSON) or $FAKE/hc-fg/<t>
# (shell | none | pi | launch | other:<cmd>), and only for a terminal listed in $FAKE/hc-known;
# `send` records the line, makes that terminal pi, and flips the tab to pi so herdr-app reports it
# too. $FAKE/hc-calls counts both, so a test can see a retry. `launch` is the recovered shell the
# guard (or herdr-resume) started: an interactive shell whose argv carries the exec line, which is
# what tells it apart from the person's own shell.
cat >"$work/stub/hc" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
st=$FAKE
printf '%s\n' "$*" >>"$st/hc-calls"
case ${1:-} in
get)
	t=${2:-}
	grep -qx "$t" "$st/hc-known" 2>/dev/null || exit 1
	if [ -f "$st/hc-json/$t" ]; then
		cat "$st/hc-json/$t"
		exit 0
	fi
	if [ -f "$st/hc-seq/$t" ] && [ -s "$st/hc-seq/$t" ]; then
		fg=$(head -n 1 "$st/hc-seq/$t")
		tail -n +2 "$st/hc-seq/$t" >"$st/hc-seq/$t.tmp" && mv "$st/hc-seq/$t.tmp" "$st/hc-seq/$t"
	else
		fg=$(cat "$st/hc-fg/$t" 2>/dev/null || echo shell)
	fi
	case $fg in
	'{'*) printf '%s\n' "$fg" ;;
	none) printf '{"state":"live","foreground":{}}\n' ;;
	shell) printf '{"state":"live","foreground":{"argv":["/bin/bash"],"pid":1},"argv":["/bin/bash"]}\n' ;;
	pi) printf '{"state":"live","foreground":{"argv":["/opt/pnpm/bin/pi/cli.js"],"pid":2}}\n' ;;
	launch) printf '{"state":"live","foreground":{"argv":["sh","-lc","exec /opt/boss/bin/pi-bare"],"pid":4}}\n' ;;
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
	mkdir -p "$fake/entries" "$fake/root/state" "$fake/root/bin" "$fake/root/reports" "$fake/root/specs" "$fake/hc-fg" "$fake/hc-json" "$fake/hc-seq"
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
	mkdir -p "$fake/entries" "$fake/root/state" "$fake/root/bin" "$fake/root/reports" "$fake/root/specs" "$fake/hc-fg" "$fake/hc-json" "$fake/hc-seq"
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
closed_tabs() {
	if [ -f "$fake/calls" ]; then grep -c '^do tab.close' "$fake/calls" || true; else echo 0; fi
}
# Every hc send, not only the exec line: a person's tab must not be typed into at all.
hc_sends_any() {
	if [ -f "$fake/hc-sends" ]; then wc -l <"$fake/hc-sends"; else echo 0; fi
}
tab_class_of() {
	awk -v t="$1" '$2==t {print $3; exit}' "$fake/root/state/tab-classes" 2>/dev/null
}

# guard_once <space> [resume-script-succeeds] [resume-script-busy] [hide-new-tabs] — one poll of
# the guard, bounded.
guard_once() {
	timeout 15 env \
		PI_BOSS_ONCE=1 \
		FAKE=$fake \
		FAKE_HIDE_NEW=${4:-0} \
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

# 7. the resume script's own verdict on that terminal: it said "busy (no program)" on 2026-11-15
#    because a live foreground with no argv looked busy. The guard must not end in a fresh tab over
#    that: the terminal shows a shell prompt, so the guard types the session itself. (A terminal
#    that shows no prompt at all is case 19, and it is never typed into.)
setup_case 'tab1|master|1|t1|sh'
hc_knows t1
printf shell >"$fake/hc-fg/t1"
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

# 11. a slow shell is still resumed: hc answers "no foreground argv yet" for one look, then a real
#     shell argv. The wait is what makes the difference here, so the guard types exactly once.
#     (The first look in a pass is `terminal_runs_pi`, so the queue is none, none, shell.)
setup_case 'tab1|master|1|tzzz|sh'
hc_knows tX
printf 'none\nnone\nshell\n' >"$fake/hc-seq/tX"
entry e11 "{\"terminal\":\"tX\",\"tab\":\"tab1\",\"session_path\":\"$(session s11.jsonl)\",\"argv\":[\"pi\"],\"updated_at\":\"2026-11-15T09:00:00.000Z\"}"
guard_once boss 0 1
if [ "$(hc_gets)" -ge 2 ] && [ "$(hc_sends)" = 1 ] && [ "$(opened_tab)" = 0 ] && [ "$(tabs_app)" = pi ]; then
	pass "no foreground argv for one look, then a shell: waited ($(hc_gets) hc get calls) and typed once"
else
	fail "expected hc gets then one send (gets $(hc_gets), sends $(hc_sends), tab.new $(opened_tab))"
	cat "$fake/root/state/guard.log" 2>/dev/null
fi

# 12. a terminal the person opened while the guard runs: a shell, no resume entry, no pi. That is
#     not a lost agent, it is their tab. Two polls: the first seeds the parked tabs, the second is a
#     tab that appeared while the guard was running. No pi is opened in it, nothing is closed, no
#     key is typed into it, and the log says whose it is.
setup_case 'tab1|master|1|t1|pi'
guard_once boss
printf 'tab2|Terminal 2|2|t2|sh\n' >>"$fake/tabs"
hc_knows t2
printf shell >"$fake/hc-fg/t2"
rm -f "$fake/calls" "$fake/hc-calls" "$fake/hc-sends"
guard_once boss
if [ "$(opened_tab)" = 0 ] && [ "$(closed_tabs)" = 0 ] && [ "$(hc_sends_any)" = 0 ] &&
	! logged 'opened a new pi' && logged "tab Terminal 2 (tab2) is the person's"; then
	pass "a terminal opened while the guard runs: no pi, no close, no hc send, logged as the person's"
else
	fail "expected the person's tab untouched (tab.new $(opened_tab), close $(closed_tabs), hc sends $(hc_sends_any))"
	cat "$fake/root/state/guard.log" 2>/dev/null
fi

# 13. a tab that was in the first snapshot with a shell in it and no entry is still a parked tab
#     (herdr-core handed it back without its pi), and the recovered shell it holds is the guard's
#     own launch, not the person's: repaired as before.
setup_case 'tab1|master|1|t1|sh'
hc_knows t1
printf launch >"$fake/hc-fg/t1"
guard_once boss
if [ "$(opened_tab)" = 1 ] && [ "$(closed_tabs)" = 1 ] && logged 'opened a new pi in tab master'; then
	pass "parked recovered shell, no entry: still repaired (one tab.new, one tab.close)"
else
	fail "expected a repaired parked tab (tab.new $(opened_tab), close $(closed_tabs))"
	cat "$fake/root/state/guard.log" 2>/dev/null
fi

# 14. the same person's tab, then the guard restarts. The class has to come from state/tab-classes,
#     not from what this guard process saw: a restart must not turn their tab into a repair again.
setup_case 'tab1|master|1|t1|pi'
guard_once boss
printf 'tab2|Terminal 2|2|t2|sh\n' >>"$fake/tabs"
hc_knows t2
printf shell >"$fake/hc-fg/t2"
guard_once boss
rm -f "$fake/calls" "$fake/hc-calls" "$fake/hc-sends"
guard_once boss
if [ "$(opened_tab)" = 0 ] && [ "$(closed_tabs)" = 0 ] && [ "$(hc_sends_any)" = 0 ] &&
	[ "$(tab_class_of tab2)" = person ] && grep -q '^tab2|Terminal 2|2|t2|sh$' "$fake/tabs"; then
	pass "guard restart: the person's tab kept its class on disk, still untouched ($(tab_class_of tab2))"
else
	fail "expected tab2 to stay the person's across a restart (class '$(tab_class_of tab2)', tab.new $(opened_tab), close $(closed_tabs))"
	cat "$fake/root/state/guard.log" 2>/dev/null
fi

# 15. the guard's own replacement tab is marked as its own, so a pi that dies in it is reopened —
#     rate-limited to one a minute, as before.
setup_case 'tab1|master|1|t1|sh'
guard_once boss
new_tab=$(awk -F'|' '$5=="pi"{print $1; exit}' "$fake/tabs")
if [ "$(opened_tab)" = 1 ] && [ "$(tab_class_of "$new_tab")" = guard ]; then
	pass "the tab the guard opened is marked as its own ($new_tab)"
else
	fail "expected the reopened tab to be classified guard (class '$(tab_class_of "$new_tab")', tab.new $(opened_tab))"
fi
sed -i 's/|pi$/|sh/' "$fake/tabs"
rm -f "$fake/calls"
guard_once boss
reopened=$(opened_tab)
rm -f "$fake/calls"
guard_once boss
again=$(opened_tab)
if [ "$reopened" = 1 ] && [ "$again" = 0 ]; then
	pass "pi died in the guard's own tab: reopened once ($reopened), then rate-limited ($again)"
else
	fail "expected one reopen and then the rate limit (first $(reopened), second $(again))"
	cat "$fake/root/state/guard.log" 2>/dev/null
fi

# 16. a parked tab whose terminal now holds the person's own interactive shell: no recovered-launch
#     argv, so it is theirs. A pi typed there would take their shell away.
setup_case 'tab1|master|1|t1|sh'
hc_knows t1
printf shell >"$fake/hc-fg/t1"
guard_once boss
if [ "$(opened_tab)" = 0 ] && [ "$(closed_tabs)" = 0 ] && [ "$(hc_sends_any)" = 0 ] &&
	logged "left alone: it is the person's tab"; then
	pass "a parked tab the person turned into their own shell: left alone, and the log says why"
else
	fail "expected the person's shell to be left alone (tab.new $(opened_tab), close $(closed_tabs), hc sends $(hc_sends_any))"
	cat "$fake/root/state/guard.log" 2>/dev/null
fi

# 17. a tab the person opened, ran pi in and quit: it has a resume entry, so the session is the
#     reason to touch it, and the guard resumes rather than treating it as theirs and walking past.
setup_case 'tab1|master|1|t1|pi'
guard_once boss
printf 'tab3|Terminal 3|2|t3|sh\n' >>"$fake/tabs"
hc_knows t3
printf shell >"$fake/hc-fg/t3"
entry e17 "{\"terminal\":\"t3\",\"tab\":\"tab3\",\"session_path\":\"$(session s17.jsonl)\",\"argv\":[\"pi\"],\"updated_at\":\"2026-11-15T09:00:00.000Z\"}"
rm -f "$fake/calls" "$fake/hc-calls" "$fake/hc-sends"
guard_once boss 1
if [ "$(opened_tab)" = 0 ] && [ "$(hc_sends_any)" = 0 ] && [ "$(tab_class_of tab3)" = person ] &&
	logged "resumed terminal \`t3\` in tab Terminal 3"; then
	pass "the person's tab with a resume entry: resumed from the entry, nothing opened"
else
	fail "expected a resume of tab3 (tab.new $(opened_tab), hc sends $(hc_sends_any))"
	cat "$fake/root/state/guard.log" 2>/dev/null
fi

# 18. `tab.new` answered with a terminal, and `ls` does not show the tab it landed in yet. A tab
#     nobody classified is the person's, so without the terminal ledger the guard's own replacement
#     would be untouchable: remembered, then read as the guard's at the next snapshot.
setup_case 'tab1|master|1|t1|sh'
guard_once boss 0 0 1
new_tab=$(awk -F'|' '$5=="pi"{print $1; exit}' "$fake/tabs")
remembered=$(grep -c 'tnew' "$fake/root/state/guard-terminals" 2>/dev/null || true)
rm -f "$fake/calls"
guard_once boss
if [ "${remembered:-0}" -ge 1 ] && [ "$(tab_class_of "$new_tab")" = guard ] && [ "$(opened_tab)" = 0 ]; then
	pass "a tab.new that ls lagged: remembered by terminal, then classified guard, not the person's"
else
	fail "expected the new tab to be remembered and then classified guard (remembered ${remembered:-0}, class '$(tab_class_of "$new_tab")')"
	cat "$fake/root/state/guard.log" 2>/dev/null
fi

# 19. the incident: hc says live with no foreground argv on every look — a pi that is still
#     starting reads exactly like that — and pi appears afterwards. Nothing is typed: no exec line,
#     no retry, and the tab is not reopened either. This is the case `wait_attached` used to answer
#     `attached` for after the bound, and the reason a resume line once landed inside a running pi.
setup_case 'tab1|master|1|t1|sh'
hc_knows t1
printf 'none\nnone\nnone\npi\n' >"$fake/hc-seq/t1"
entry e19 "{\"terminal\":\"t1\",\"tab\":\"tab1\",\"session_path\":\"$(session s19.jsonl)\",\"argv\":[\"pi\"],\"updated_at\":\"2026-11-15T09:00:00.000Z\"}"
guard_once boss 0 1
if [ "$(hc_sends)" = 0 ] && [ "$(hc_sends_any)" = 0 ] && [ "$(opened_tab)" = 0 ] && [ "$(closed_tabs)" = 0 ] &&
	! grep -q 'exec' "$fake/hc-calls" 2>/dev/null &&
	logged 'has no shell prompt yet (foreground has no program); not typing into it'; then
	pass "no shell prompt on every look (a pi still starting): nothing typed, nothing reopened, the log says why"
else
	fail "expected no typing and no reopen (hc sends $(hc_sends_any), tab.new $(opened_tab), close $(closed_tabs))"
	cat "$fake/root/state/guard.log" 2>/dev/null
fi

# 20. pi is already there and its argv carries this very session. Typing the exec line again would
#     be a second pi on one conversation, so the tab is skipped and the log names the session.
setup_case 'tab1|master|1|t1|sh'
hc_knows t1
s20=$(session s20.jsonl)
printf '{"state":"live","foreground":{"argv":["sh","-lc","exec pi --session %s"],"pid":7}}\n' "$s20" >"$fake/hc-json/t1"
entry e20 "{\"terminal\":\"t1\",\"tab\":\"tab1\",\"session_path\":\"$s20\",\"argv\":[\"pi\"],\"updated_at\":\"2026-11-15T09:00:00.000Z\"}"
guard_once boss 0 1
if [ "$(hc_sends_any)" = 0 ] && [ "$(opened_tab)" = 0 ] && [ "$(closed_tabs)" = 0 ] &&
	! grep -q 'exec' "$fake/hc-calls" 2>/dev/null &&
	logged "already has pi running (session $s20); nothing to resume"; then
	pass "pi already running on this session: skipped, one log line, no hc send at all"
else
	fail "expected no hc send and no reopen (hc calls: $(grep -c . "$fake/hc-calls" 2>/dev/null || echo 0))"
	cat "$fake/root/state/guard.log" 2>/dev/null
fi

# 21. pi running on a different session is still a live pi in that tab: never typed into, never
#     closed or reopened over.
setup_case 'tab1|master|1|t1|sh'
hc_knows t1
printf '{"state":"live","foreground":{"argv":["/opt/pnpm/bin/pi/cli.js","--session","/tmp/other.jsonl"],"pid":8}}\n' >"$fake/hc-json/t1"
entry e21 "{\"terminal\":\"t1\",\"tab\":\"tab1\",\"session_path\":\"$(session s21.jsonl)\",\"argv\":[\"pi\"],\"updated_at\":\"2026-11-15T09:00:00.000Z\"}"
guard_once boss 0 1
if [ "$(hc_sends_any)" = 0 ] && [ "$(opened_tab)" = 0 ] && [ "$(closed_tabs)" = 0 ] &&
	! grep -q 'exec' "$fake/hc-calls" 2>/dev/null; then
	pass "pi on a different session: still skipped, nothing typed, nothing opened or closed"
else
	fail "expected the live pi tab untouched (hc sends $(hc_sends_any), tab.new $(opened_tab), close $(closed_tabs))"
	cat "$fake/root/state/guard.log" 2>/dev/null
fi

# 22. the case the refusals must not eat: a real dead tab, a shell and no pi, is resumed exactly
#     once, on its own terminal, with its own session.
setup_case 'tab1|master|1|t1|sh'
hc_knows t1
printf shell >"$fake/hc-fg/t1"
s22=$(session s22.jsonl)
entry e22 "{\"terminal\":\"t1\",\"tab\":\"tab1\",\"session_path\":\"$s22\",\"argv\":[\"pi\"],\"updated_at\":\"2026-11-15T09:00:00.000Z\"}"
guard_once boss 0 1
line22=$(sent_line)
if [ "$(hc_sends)" = 1 ] && [ "$(opened_tab)" = 0 ] && [ "$(closed_tabs)" = 0 ] &&
	[ "$line22" = "exec pi --session $s22" ]; then
	pass "dead tab with a shell prompt: resumed once ($line22), nothing opened or closed"
else
	fail "expected exactly one exec send and no reopen (sends $(hc_sends): $(sent_line))"
	cat "$fake/root/state/guard.log" 2>/dev/null
fi

# 23. same live pi with no resume entry at all: the tab has nothing to resume, but it also has a pi,
#     so the reopen path must walk past it instead of closing a running agent.
setup_case 'tab1|master|1|t1|sh'
hc_knows t1
printf pi >"$fake/hc-fg/t1"
guard_once boss
if [ "$(hc_sends_any)" = 0 ] && [ "$(opened_tab)" = 0 ] && [ "$(closed_tabs)" = 0 ] &&
	logged "already has pi running in terminal \`t1\`; nothing to repair"; then
	pass "live pi, no entry: left alone, not closed, not reopened"
else
	fail "expected the live pi tab untouched (tab.new $(opened_tab), close $(closed_tabs))"
	cat "$fake/root/state/guard.log" 2>/dev/null
fi

if [ "$fails" -gt 0 ]; then
	printf 'guard-resume: %d case(s) failed\n' "$fails"
	exit 1
fi
printf 'guard-resume: ok\n'
