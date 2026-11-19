#!/usr/bin/env bash
# test-guard-iteration.sh — one bad pass does not end the guard.
#
# The symptom this pins: the space was closed and never came back. The guard's job is to rebuild it
# on the next interval, so a single failed iteration — a refused space.new, a tab that cannot be
# opened — must be one line in state/guard.log and then the next poll, in the same process. Each
# pass now runs in a subshell, so even a fatal error inside one pass ends that pass only.
#
# Two cases, one stub herdr-app, one guard process each:
#
#   1. `space.new` fails on the first call and succeeds on the second: the log carries the failure
#      and then the creation, in that order, and the guard is still running when the space exists;
#   2. the space is there but its only tab cannot be replaced (`tab.new` always fails): the guard
#      logs it and keeps polling instead of exiting, and the second attempt is in the log too.
#
#   bash scripts/tests/test-guard-iteration.sh      exit 0 = both cases held
set -uo pipefail

root=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/../.." && pwd)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export HOME=$work/home
export PI_BOSS_ROOT=$work/boss
mkdir -p "$HOME" "$PI_BOSS_ROOT/state" "$work/stub"

fails=0
pass() { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }

# The guard reads its JSON with node, so a PATH without node proves nothing about the guard.
node=$(command -v node 2>/dev/null) || {
	printf 'node is not on PATH; the guard cannot run and this suite cannot judge it\n' >&2
	exit 2
}
node_dir=$(dirname -- "$(readlink -f -- "$node")")

# --- the fake desktop app -------------------------------------------------------------------
# `ls` reports no space until space.new has been answered once, then one healthy tab holding a live
# pi — or, in case 2 ($FAKE/space-only), a tab whose terminal holds a shell instead. `tab.new` and
# `space.new` fail as the case asks, and every call is recorded so the log can be read beside them.
cat >"$work/stub/herdr-app" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
st=$FAKE
printf '%s\n' "$*" >>"$st/calls"
case ${1:-} in
ls)
	if [ ! -f "$st/created" ]; then
		printf '{"spaces":[]}\n'
	elif [ -f "$st/space-only" ]; then
		printf '{"spaces":[{"id":"s1","name":"big-boss-pi","tabs":[{"id":"tab1","name":"master","terminals":[{"id":"t1","app":"sh"}]}]}]}\n'
	else
		printf '{"spaces":[{"id":"s1","name":"big-boss-pi","tabs":[{"id":"tab1","name":"master","terminals":[{"id":"t1","app":"pi"}]}]}]}\n'
	fi
	;;
status) printf '{"space":"s1","tab":"tab1"}\n' ;;
do)
	case ${2:-} in
	space.new)
		n=$(cat "$st/new-count" 2>/dev/null || printf 0)
		n=$((n + 1))
		printf '%s' "$n" >"$st/new-count"
		if [ "$n" -le "${FAKE_FAIL_NEW:-0}" ]; then
			printf 'space.new refused\n'
			exit 1
		fi
		: >"$st/created"
		printf '{"space":"s1"}\n'
		;;
	tab.new)
		n=$(cat "$st/tab-count" 2>/dev/null || printf 0)
		n=$((n + 1))
		printf '%s' "$n" >"$st/tab-count"
		if [ "${FAKE_FAIL_TAB:-0}" = 1 ]; then
			printf 'tab.new refused\n'
			exit 1
		fi
		printf '{"terminal":"t9"}\n'
		;;
	*) printf '{}\n' ;;
	esac
	;;
*) printf '{}\n' ;;
esac
STUB
chmod +x "$work/stub/herdr-app"
export PATH=$work/stub:$node_dir:/usr/local/bin:/usr/bin:/bin
export PI_BOSS_GUARD_INTERVAL=1
export PI_BOSS_KICKOFF_WAIT=1
# No resume entries and no hc: a stale tab is a tab to open, never a session to type into.
export PI_BOSS_RESUME_DIR=$work/no-resume

# start_guard — one guard process, polling every second, killed by the caller.
start_guard() {
	"$root/bin/guard" >"$work/guard.out" 2>&1 &
	guard_pid=$!
}

# await_log <pattern> — wait up to 20s for a line to appear in state/guard.log.
await_log() {
	local i
	for ((i = 0; i < 20; i++)); do
		if grep -qF -- "$1" "$PI_BOSS_ROOT/state/guard.log" 2>/dev/null; then
			return 0
		fi
		sleep 1
	done
	return 1
}

stop_guard() {
	kill "$guard_pid" 2>/dev/null
	wait "$guard_pid" 2>/dev/null
}

# --- case 1: space.new fails once, then succeeds ----------------------------------------------
export FAKE=$work/fake1
mkdir -p "$FAKE"
export FAKE_FAIL_NEW=1
start_guard
if ! await_log "created big-boss-pi"; then
	fail "case 1: the guard never created the space after a refused space.new — $(tail -n 5 "$PI_BOSS_ROOT/state/guard.log" 2>/dev/null | tr '\n' ';')"
else
	if grep -qF "space.new failed: space.new refused" "$PI_BOSS_ROOT/state/guard.log"; then
		pass "case 1: the refused space.new is in the log"
	else
		fail "case 1: no 'space.new failed' line — $(grep -c . "$PI_BOSS_ROOT/state/guard.log") log lines"
	fi
	if grep -qF "could not create big-boss-pi this pass; the next interval tries again" "$PI_BOSS_ROOT/state/guard.log"; then
		pass "case 1: the failed pass says the next interval tries again"
	else
		fail "case 1: the failed pass is not named as one pass"
	fi
	first_fail=$(grep -nF "space.new failed" "$PI_BOSS_ROOT/state/guard.log" | head -n 1 | cut -d: -f1)
	first_ok=$(grep -nF "created big-boss-pi" "$PI_BOSS_ROOT/state/guard.log" | head -n 1 | cut -d: -f1)
	if [ -n "$first_fail" ] && [ -n "$first_ok" ] && [ "$first_fail" -lt "$first_ok" ]; then
		pass "case 1: the failure came first and the creation after it, in one process"
	else
		fail "case 1: the creation is not after the failure (failed line $first_fail, created line $first_ok)"
	fi
	if kill -0 "$guard_pid" 2>/dev/null; then
		pass "case 1: the guard is still running after the failed pass"
	else
		fail "case 1: the guard exited on the failed pass — $(tail -n 3 "$work/guard.out" | tr '\n' ';')"
	fi
fi
stop_guard

# --- case 2: the space is there, its tab cannot be replaced ----------------------------------
rm -rf "$PI_BOSS_ROOT/state"
mkdir -p "$PI_BOSS_ROOT/state"
export FAKE=$work/fake2
mkdir -p "$FAKE"
: >"$FAKE/created"
: >"$FAKE/space-only"
export FAKE_FAIL_TAB=1
start_guard
# Two attempts, a poll apart: the guard repeats the repair instead of giving up for good.
attempts=0
for ((i = 0; i < 20; i++)); do
	attempts=$(grep -cF "could not open a replacement for the stale tab" "$PI_BOSS_ROOT/state/guard.log" 2>/dev/null || printf 0)
	[ "$attempts" -ge 2 ] && break
	sleep 1
done
if [ "$attempts" -ge 2 ]; then
	pass "case 2: a tab that cannot be replaced is retried on the next poll ($attempts attempts)"
else
	fail "case 2: the failed tab repair was not retried — $attempts attempt(s), log: $(tail -n 4 "$PI_BOSS_ROOT/state/guard.log" 2>/dev/null | tr '\n' ';')"
fi
if grep -qF "at least one tab could not be repaired this pass; the next interval tries again" "$PI_BOSS_ROOT/state/guard.log"; then
	pass "case 2: the pass is logged as a failed iteration, not as done"
else
	fail "case 2: no 'could not be repaired this pass' line — $(tail -n 4 "$PI_BOSS_ROOT/state/guard.log" 2>/dev/null | tr '\n' ';')"
fi
if kill -0 "$guard_pid" 2>/dev/null; then
	pass "case 2: the guard is still polling after the failed repairs"
else
	fail "case 2: the guard exited on the failed repairs — $(tail -n 3 "$work/guard.out" | tr '\n' ';')"
fi
stop_guard

printf '\n%s\n' "$([ "$fails" = 0 ] && echo "guard-iteration: ok" || echo "guard-iteration: $fails failure(s)")"
[ "$fails" = 0 ]
