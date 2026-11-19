#!/usr/bin/env bash
# test-guard-windows.sh — the guard as the thing that creates the space, under Git Bash on Windows.
#
# `bin/guard` has never run on Windows, and it is the only thing that makes the big-boss-pi space
# there. It cannot be run on this Linux host, so this suite drives the real script against stub
# binaries and pins the parts that only exist at a platform boundary:
#
#   1. on a simulated win32 shell the space is created with `--folder` and `--argv` in the spelling
#      a native app can read: --folder is the native path (`C:/...`), --argv is JSON whose exec
#      target is still the POSIX path, absolute and one single-quoted word;
#   2. `hc` absent: creation still succeeds, and the log says why the kickoff did not go twice;
#   3. `hc` present: the kickoff is sent to the terminal `space.new` answered with;
#   4. a root with a space in it survives the round trip: --folder keeps the space, the shell line
#      keeps it inside its quotes, and the state file lands in the right place;
#   5. a root handed in already in native spelling (`C:/...`) is normalised once at the top for the
#      shell and written back native at the boundary;
#   6. the polling loop writes the state file once, and a guard started again sees the space it
#      made and does not create a second one;
#   7. the same script on a POSIX shell creates the space in the old spelling — the only shape
#      change there is the quoting, which sh reads the same way;
#   8. no `/proc` and no `flock` outside the boot-id file: the resume ledger's boot key falls back
#      to node's uptime instead of reading a file Windows does not have.
#
#   bash scripts/test-guard-windows.sh      exit 0 = every case held
#
# It is argv-level proof, not a Windows run: nothing here touches a real Herdr.
set -uo pipefail

root=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/stub" "$work/stub-hc" "$work/home"
# A real Windows spelling (C:/tmp/...) is not a path this Linux node can open, which would make the
# simulation lie about the very boundary it is here to check. A symlink named `C:` pointing at `/`,
# with every guard run started inside `$work`, lets `C:/tmp/...` resolve to `/tmp/...` for real.
ln -s / "$work/C:"

fails=0
pass() { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }

# --- the fake desktop app ----------------------------------------------------
# Every call is recorded with its argv, one "<n>\t<arg>" per line in $FAKE/call<N>, so a test can
# compare the exact argument a native app received — spaces, quotes and all, not a log line about
# it. `ls` reports the spaces this fake was asked to create, each with one tab holding a live pi,
# so a second poll of the guard is a healthy space and not a repair.
cat >"$work/stub/herdr-app" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
st=$FAKE
c=$(cat "$st/counter" 2>/dev/null || printf 0)
c=$((c + 1))
printf '%s' "$c" >"$st/counter"
i=0
for a in "$@"; do
	i=$((i + 1))
	printf '%d\t%s\n' "$i" "$a" >>"$st/call$c"
done
case ${1:-} in
ls)
	printf '{"spaces":['
	sep=""
	if [ -s "$st/spaces" ]; then
		while IFS='|' read -r id name; do
			[ -n "$id" ] || continue
			printf '%s{"id":"%s","name":"%s","tabs":[{"id":"tab-%s","name":"master","terminals":[{"id":"term-%s","app":"pi"}]}]}' \
				"$sep" "$id" "$name" "$id" "$id"
			sep=","
		done <"$st/spaces"
	fi
	printf ']}\n'
	;;
status) printf '{"space":"s1","tab":"tab-s1"}\n' ;;
do)
	shift
	case ${1:-} in
	space.new)
		name=""
		while [ $# -gt 0 ]; do
			[ "$1" = --name ] && name=$2
			shift
		done
		printf 's1|%s\n' "$name" >>"$st/spaces"
		printf '{"space":"s1","terminal":"term-s1"}\n'
		;;
	*) printf '{}\n' ;;
	esac
	;;
*) printf '{}\n' ;;
esac
STUB

# The fake cygpath: the two conversions the guard may ask for, with the shape the real one gives —
# `-m` prefixes the drive letter and keeps slashes, `-u` strips it.
cat >"$work/stub/cygpath" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
case ${1:-} in
-m)
	p=${2:-}
	case $p in
	[A-Za-z]:*) printf '%s' "$p" ;;
	*) printf 'C:%s' "$p" ;;
	esac
	;;
-u)
	p=${2:-}
	printf '%s' "${p#[A-Za-z]:}"
	;;
*) exit 1 ;;
esac
STUB

# The fake `hc`: `get` answers for the terminal this fake knows, `send` records the line.
cat >"$work/stub-hc/hc" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >>"$FAKE/hc-calls"
case ${1:-} in
get) printf '{"state":"live","foreground":{"argv":["sh","-lc","exec /x/bin/pi-bare"],"pid":4}}\n' ;;
send)
	t=${2:-}
	shift 2
	printf '%s\t%s\n' "$t" "$*" >>"$FAKE/hc-sends"
	;;
esac
STUB
chmod +x "$work/stub/herdr-app" "$work/stub/cygpath" "$work/stub-hc/hc"

# bin/guard reaches node at every JSON boundary (the argv it hands the app, the space snapshot,
# the state files), so node belongs on the simulated PATH by name and not by luck: the host PATH
# is not what CI runs, and that inheritance is exactly the bug that made this suite red on a
# runner while it was green on a laptop. Resolved to its own directory rather than stubbed — a
# stub that printed JSON would be a second implementation of what case 1 is checking, and the
# guard's contract is about what *its* node prints. PI_TEST_NO_NODE=1 leaves node off on purpose:
# that is how the missing-command failure below is shown instead of asserted against empty strings.
coreutils=/usr/bin:/bin
node_dir=""
if [ -z "${PI_TEST_NO_NODE:-}" ]; then
	node_real=$(command -v node 2>/dev/null || true)
	[ -n "$node_real" ] && node_dir=$(dirname -- "$(readlink -f -- "$node_real")")
else
	# PI_TEST_NO_NODE=1 asks for the runner's shape on a host where /usr/bin happens to have node
	# too: one directory of the coreutils the suite needs, linked by hand, with no node in it.
	coreutils=$work/core
	mkdir -p "$coreutils"
	for c in sh uname dirname readlink sed grep awk date tr tail stat sleep timeout cat; do
		src=$(command -v "$c" 2>/dev/null || true)
		[ -n "$src" ] && ln -sf "$src" "$coreutils/$c"
	done
fi
node_bin=${node_dir:+$node_dir/node}

# $work/stub is the Windows-shaped PATH: herdr-app and cygpath, no hc. A second dir adds hc.
path_win=$work/stub${node_dir:+:$node_dir}:$coreutils
path_win_hc=$work/stub-hc:$path_win
path_posix=$work/stub${node_dir:+:$node_dir}:$coreutils

# A stub PATH is a set of promises, and a scenario that reaches a command its PATH cannot reach
# fails far from the cause: a missing `node` meant pi_argv printed nothing, --argv arrived empty,
# and every later comparison failed on ''. Name the first missing command and stop.
need() { # need <path> <command>...
	local p=$1 c
	shift
	for c in "$@"; do
		PATH=$p command -v "$c" >/dev/null 2>&1 && continue
		printf 'guard-windows: missing stub: %s — not on PATH=%s\n' "$c" "$p" >&2
		printf 'guard-windows: 1 case(s) failed (setup)\n' >&2
		exit 1
	done
}
# What bin/guard reaches on any run: node for each JSON boundary, the app and cygpath for the space,
# bash (the suite starts the guard with the scenario PATH already in force) and the coreutils it uses
# for paths, stamps, the snapshot tables and the log.
need_common=(node herdr-app cygpath bash sh uname dirname readlink sed grep awk date tr tail stat \
	sleep timeout)
need "$path_win" "${need_common[@]}"
need "$path_posix" "${need_common[@]}"
need "$path_win_hc" "${need_common[@]}" hc

new_fake() {
	case_no=$((case_no + 1))
	fake=$work/case$case_no
	mkdir -p "$fake/root/state" "$fake/root/bin" "$fake/root/reports" "$fake/root/specs" \
		"$fake/entries" "$fake/logs"
	: >"$fake/spaces"
	: >"$fake/counter"
}
case_no=0

# guard_run <fake> <path> [env assignments...] — one guard process, bounded, quiet.
guard_run() {
	local f=$1 p=$2
	shift 2
	(
		cd "$work" || exit 1
		exec timeout 25 env "$@" PATH="$p" FAKE="$f" HOME="$work/home" \
			PI_BOSS_RESUME_SCRIPT=$work/no-resume-script.sh PI_BOSS_RESUME_DIR="$f/entries" \
			bash "$root/bin/guard"
	) >"$f/out" 2>&1
}
# guard_loop <fake> <path> <seconds> [env...] — the polling loop, for the state-file case.
guard_loop() {
	local f=$1 p=$2 secs=$3
	shift 3
	(
		cd "$work" || exit 1
		exec timeout "$secs" env "$@" PATH="$p" FAKE="$f" HOME="$work/home" \
			PI_BOSS_RESUME_SCRIPT=$work/no-resume-script.sh PI_BOSS_RESUME_DIR="$f/entries" \
			bash "$root/bin/guard"
	) >"$f/out" 2>&1
}

argn() { awk -F'\t' -v i="$1" '$1==i{print $2; exit}' "$2"; }
last_call() { ls -1v "$fake"/call* 2>/dev/null | tail -n 1; }
space_new_calls() {
	local f n=0
	for f in "$fake"/call*; do
		[ -f "$f" ] || continue
		[ "$(argn 2 "$f")" = space.new ] && n=$((n + 1))
	done
	printf '%s' "$n"
}
call_of() { # call_of <arg1> <arg2> — the newest recorded call with that leading pair, or nothing
	local f hit=""
	for f in $(ls -1v "$fake"/call* 2>/dev/null); do
		[ -f "$f" ] || continue
		[ "$(argn 1 "$f")" = "$1" ] && [ "$(argn 2 "$f")" = "$2" ] && hit=$f
	done
	[ -n "$hit" ] && printf '%s' "$hit"
}
space_new_call() {
	local f
	for f in $(ls -1v "$fake"/call* 2>/dev/null); do
		[ -f "$f" ] || continue
		[ "$(argn 2 "$f")" = space.new ] && {
			printf '%s' "$f"
			return 0
		}
	done
	return 1
}
logged() { grep -qF "$1" "$fake/root/state/guard.log" 2>/dev/null; }

win_env=(PI_PLATFORM=win32 MSYS=1 OSTYPE=msys)
# What the guard will resolve `sh` to under the fake cygpath: the sh on the scenario PATH,
# drive-prefixed. Asked of that PATH, not of ours — they are not the same list any more.
want_shell="C:$(PATH=$path_win command -v sh)"

# 1. win32, no hc: the space is made, and the two arguments that leave the script are spelled for
#    the consumer they leave to — a native path for --folder, a POSIX single-quoted word inside the
#    JSON argv for the shell the tab will run.
new_fake
r=$fake/root
guard_run "$fake" "$path_win" "${win_env[@]}" PI_BOSS_ONCE=1 PI_BOSS_ROOT="$r" \
	PI_BOSS_SPACE=big-boss-pi PI_BOSS_GUARD_INTERVAL=300
f=$(space_new_call)
folder=$(argn 6 "$f")
argv=$(argn 10 "$f")
want_argv="[\"$want_shell\",\"-lc\",\"exec '$r/bin/pi-bare' -a\"]"
json=no
"$node_bin" -e 'JSON.parse(process.argv[1])' "$argv" >/dev/null 2>&1 && json=yes
if [ "$(space_new_calls)" = 1 ] && [ "$folder" = "C:$r" ] && [ "$argv" = "$want_argv" ] && [ "$json" = yes ]; then
	pass "win32: --folder is native (C:$r), --argv is JSON with the POSIX path as one quoted word"
else
	fail "expected one space.new with a native --folder and a POSIX --argv (got $(space_new_calls), '$folder', '$argv', json $json)"
	cat "$fake/out"
fi
# A space the guard created has never been on screen: on a clean install nothing has selected it, and
# "Herdr opened empty" is the symptom that starts this whole task. Selected once, by the id it wrote.
sel=$(call_of do space.select)
if [ -n "$sel" ] && [ "$(argn 4 "$sel")" = s1 ] && logged "selected big-boss-pi (s1)"; then
	pass "win32: the space it created is selected, so a fresh Herdr is not left on an empty screen"
else
	fail "expected one space.select s1 after creation (got '$(argn 4 "${sel:-/dev/null}")')"
	cat "$fake/out"
fi
# The app that spawns the tab does not inherit this shell's PATH, so the shell itself has to be an
# absolute native path, and the tab runs the POSIX `pi-bare`, not the `.cmd` shim.
shell=$("$node_bin" -e 'process.stdout.write(JSON.parse(process.argv[1])[0])' "$argv")
case $shell in
[A-Za-z]:/*sh) pass "win32: the tab's shell is the absolute native sh this guard resolved ($shell)" ;;
*) fail "the tab's shell is not an absolute native path: '$shell'" ;;
esac
case $argv in
*"pi-bare' -a"* | *"pi-bare'") pass "win32: the tab runs the POSIX pi-bare, not pi-bare.cmd" ;;
*) fail "the tab's exec target is not the POSIX pi-bare: $argv" ;;
esac
if [ -f "$r/state/space.json" ] && grep -q '"space":"s1"' "$r/state/space.json" &&
	grep -Eq '"created":"[0-9]{4}-[0-9]{2}-[0-9]{2}T' "$r/state/space.json"; then
	pass "win32: state/space.json written once with the space id and an ISO stamp"
else
	fail "space.json missing or malformed: $(cat "$r/state/space.json" 2>/dev/null)"
fi

# 2. no hc on PATH: the space still comes up, and the log names hc rather than pretending the
#    terminal was missing — the reason is what the next person reads first.
if logged "hc is not on PATH"; then
	pass "no hc: creation succeeded and the log says the kickoff went in with --task only"
else
	fail "expected the hc line in guard.log: $(cat "$r/state/guard.log" 2>/dev/null)"
fi

# 3. hc present: the kickoff reaches the terminal space.new answered with. KICKOFF_WAIT=0 because
#    the wait exists for a real pi to boot, not for this test.
new_fake
r=$fake/root
guard_run "$fake" "$path_win_hc" "${win_env[@]}" PI_BOSS_ONCE=1 PI_BOSS_ROOT="$r" \
	PI_BOSS_SPACE=big-boss-pi PI_BOSS_GUARD_INTERVAL=300 PI_BOSS_KICKOFF_WAIT=0
if [ "$(space_new_calls)" = 1 ] && grep -q '^term-s1' "$fake/hc-sends" 2>/dev/null &&
	logged "kickoff sent to term-s1"; then
	pass "hc present: the kickoff was sent to term-s1 and logged"
else
	fail "expected a kickoff send to term-s1 (sends: $(cat "$fake/hc-sends" 2>/dev/null))"
	cat "$fake/out"
fi

# 4. a root with a space in it. The space has to survive both spellings: --folder is one argument,
#    and the shell line keeps the path inside its single quotes so it stays one word.
new_fake
r="$work/pi test/root"
mkdir -p "$r/state" "$r/bin"
guard_run "$fake" "$path_win" "${win_env[@]}" PI_BOSS_ONCE=1 PI_BOSS_ROOT="$r" \
	PI_BOSS_SPACE=big-boss-pi PI_BOSS_GUARD_INTERVAL=300
f=$(space_new_call)
folder=$(argn 6 "$f")
argv=$(argn 10 "$f")
want_argv="[\"$want_shell\",\"-lc\",\"exec '$r/bin/pi-bare' -a\"]"
if [ "$folder" = "C:$r" ] && [ "$argv" = "$want_argv" ] && [ -f "$r/state/space.json" ]; then
	pass "a root with a space: --folder and --argv both keep it, and the state lands under it"
else
	fail "expected the spaced root to survive ('$folder', '$argv')"
	cat "$fake/out"
fi

# 5. a root handed in already in native spelling is normalised once, for the shell, and written
#    back native at the boundary: one deliberate spelling per consumer, not two half-converted.
new_fake
r_posix="$work/native/root"
mkdir -p "$r_posix/state" "$r_posix/bin"
guard_run "$fake" "$path_win" "${win_env[@]}" PI_BOSS_ONCE=1 "PI_BOSS_ROOT=C:$r_posix" \
	PI_BOSS_SPACE=big-boss-pi PI_BOSS_GUARD_INTERVAL=300
f=$(space_new_call)
folder=$(argn 6 "$f")
argv=$(argn 10 "$f")
want_argv="[\"$want_shell\",\"-lc\",\"exec '$r_posix/bin/pi-bare' -a\"]"
if [ "$folder" = "C:$r_posix" ] && [ "$argv" = "$want_argv" ] &&
	[ -f "$r_posix/state/space.json" ]; then
	pass "a native-spelled root: normalised for the shell, native again at the boundary"
else
	fail "expected C:$r_posix back with a POSIX exec line (got '$folder', '$argv')"
	cat "$fake/out"
fi

# 6. the polling loop: create once, then live with what it made. A guard started again reads the
#    space from the app and does not create a second one, and the state file is not rewritten.
new_fake
r=$fake/root
guard_loop "$fake" "$path_win" 4 "${win_env[@]}" PI_BOSS_ROOT="$r" \
	PI_BOSS_SPACE=big-boss-pi PI_BOSS_GUARD_INTERVAL=1 PI_BOSS_KICKOFF_WAIT=0
first=$(space_new_calls)
stamp=$(stat -c %Y "$r/state/space.json" 2>/dev/null || echo none)
sleep 1
guard_run "$fake" "$path_win" "${win_env[@]}" PI_BOSS_ONCE=1 PI_BOSS_ROOT="$r" \
	PI_BOSS_SPACE=big-boss-pi PI_BOSS_GUARD_INTERVAL=1
second=$(space_new_calls)
again=$(stat -c %Y "$r/state/space.json" 2>/dev/null || echo none)
if [ "$first" = 1 ] && [ "$second" = 1 ] && [ "$stamp" = "$again" ] && [ "$stamp" != none ]; then
	pass "loop: one space.new across both guards, space.json written once (mtime kept)"
else
	fail "expected one creation and one state write (first $first, second $second, $stamp -> $again)"
	cat "$fake/out"
fi

# 7. POSIX regression: no PI_PLATFORM, no MSYS. --folder is the plain POSIX root and the exec line
#    is the same shape as on Windows, so there is one argv to reason about and not two.
new_fake
r=$fake/root
guard_run "$fake" "$path_posix" PI_BOSS_ONCE=1 PI_BOSS_ROOT="$r" \
	PI_BOSS_SPACE=big-boss-pi PI_BOSS_GUARD_INTERVAL=300
f=$(space_new_call)
folder=$(argn 6 "$f")
argv=$(argn 10 "$f")
want_argv="[\"sh\",\"-lc\",\"exec '$r/bin/pi-bare' -a\"]"
if [ "$folder" = "$r" ] && [ "$argv" = "$want_argv" ] && [ -f "$r/state/space.json" ]; then
	pass "POSIX: --folder unchanged, argv the same shape, space made"
else
	fail "expected the POSIX spelling (got '$folder', '$argv')"
	cat "$fake/out"
fi

# 8. Windows has no /proc and no flock. The boot key the resume ledger is kept on must not depend
#    on /proc: with that file missing it comes from node's uptime, and it is the same value twice
#    within a boot. And nothing else in the script reaches for /proc or a lock.
new_fake
ask_boot() { # ask_boot <boot-id-file> — source the guard (it only dispatches when executed) and ask
	env PI_BOSS_ROOT="$fake/root" PI_BOSS_BOOT_ID_FILE="$1" bash -c '
		source "$1/bin/guard"
		boot_id' _ "$root"
}
one=$(ask_boot "$work/no-such-boot-id")
two=$(ask_boot "$work/no-such-boot-id")
printf 'linux-boot-id\n' >"$work/boot-id"
linux=$(ask_boot "$work/boot-id")
if [ "$one" = "$two" ] && printf '%s' "$one" | grep -Eq '^boot[0-9]+$' && [ "$linux" = linux-boot-id ]; then
	pass "no /proc: the boot key falls back to node's uptime ($one), stable, and /proc is used when there"
else
	fail "expected a stable boot<minutes> fallback (one '$one', two '$two', file '$linux')"
fi
stray=$(grep -n '/proc/' "$root/bin/guard" | grep -v 'BOOT_ID_FILE=' || true)
if ! grep -q 'flock' "$root/bin/guard" && [ -z "$stray" ] &&
	grep -q 'BOOT_ID_FILE=${PI_BOSS_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}' "$root/bin/guard"; then
	pass "no flock anywhere, and /proc appears only as the overridable boot-id file"
else
	fail "/proc or flock appeared somewhere new: $(grep -n 'flock\|/proc/' "$root/bin/guard" | tr '\n' ' ')"
fi

if [ "$fails" -eq 0 ]; then
	printf 'guard-windows: ok\n'
	exit 0
fi
printf 'guard-windows: %s case(s) failed\n' "$fails"
exit 1
