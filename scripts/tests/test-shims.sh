#!/usr/bin/env bash
# test-shims.sh — the three shims onto the pi repo forward, fail loudly, and never lie about it.
#
# The tools moved out of this repo (#198, #200, #201): `delegate`, `guard` and `space` live in
# `~/.pi/bin` now and a fix belongs there. `bin/*` keeps the old path working for the scripts, the
# systemd unit and the docs that call it, so the shim itself is the thing that can now break:
#
#   A. the tool is not installed: exit 127, exactly one line on stderr naming the path it looked for,
#      and nothing on stdout. An `exec` alone would say "not found" in the caller's log, which reads
#      like this repo is broken rather than like the pi repo is missing.
#   B. the tool is installed: every argument arrives unchanged (a task with spaces is one argument),
#      the tool's stdout is the shim's stdout, and its exit status is the shim's exit status — the
#      three things a wrapper is allowed to get wrong.
#   C. `bin/delegate --help` still behaves: the shim adds nothing, so what the tool prints is what
#      the caller reads, and a zero from the tool is a zero from the shim.
#   D. the shim does not change the working directory: the tool runs where the caller stands.
#
# No herdr, no model, no real ~/.pi: the "installed" tool is a stub written into a temporary HOME.
#
#   bash scripts/tests/test-shims.sh      exit 0 = every case held
set -uo pipefail

root=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/../.." && pwd)
real_home=$HOME
tools="delegate guard space"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fails=0
pass() { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }

# --- A. no tool in ~/.pi/bin: one line, exit 127, nothing on stdout ----------------------------

export HOME=$work/home-missing
mkdir -p "$HOME"
for tool in $tools; do
	out=$(bash "$root/bin/$tool" list 2>"$work/err"); rc=$?
	err=$(cat "$work/err")
	lines=$(printf '%s\n' "$err" | grep -c . || true)
	if [ "$rc" = 127 ]; then pass "bin/$tool, no tool: exit 127"; else fail "bin/$tool, no tool: exit $rc, wanted 127"; fi
	if [ -z "$out" ]; then pass "bin/$tool, no tool: nothing on stdout"; else fail "bin/$tool, no tool: stdout '$out'"; fi
	if [ "$lines" = 1 ]; then pass "bin/$tool, no tool: one line on stderr"; else fail "bin/$tool, no tool: $lines stderr lines: $err"; fi
	if printf '%s' "$err" | grep -qF "$HOME/.pi/bin/$tool"; then
		pass "bin/$tool, no tool: the line names the path it looked for"
	else
		fail "bin/$tool, no tool: the line does not name $HOME/.pi/bin/$tool — '$err'"
	fi
done

# --- B/C/D. the tool is installed: arguments, stdout, exit status, cwd --------------------------

export HOME=$work/home
mkdir -p "$HOME/.pi/bin" "$work/cwd"
for tool in $tools; do
	cat >"$HOME/.pi/bin/$tool" <<'STUB'
#!/bin/sh
# one line per argument, then the exit status the case asked for in $STUB_EXIT.
printf 'cwd=%s\n' "$(pwd)"
for arg in "$@"; do printf 'arg=%s\n' "$arg"; done
printf 'help: usage of the moved tool\n'
exit "${STUB_EXIT:-0}"
STUB
	chmod +x "$HOME/.pi/bin/$tool"

	cd "$work/cwd" || exit 1
	out=$(STUB_EXIT=0 bash "$root/bin/$tool" --help "a task with spaces" 2>&1); rc=$?
	if [ "$rc" = 0 ]; then pass "bin/$tool, installed --help: exit 0 through the shim"; else fail "bin/$tool, installed --help: exit $rc, wanted 0"; fi
	if printf '%s' "$out" | grep -qxF "arg=--help"; then pass "bin/$tool: --help arrives unchanged"; else fail "bin/$tool: --help did not arrive — '$out'"; fi
	if printf '%s' "$out" | grep -qxF "arg=a task with spaces"; then
		pass "bin/$tool: a task with spaces arrives as one argument"
	else
		fail "bin/$tool: the task was split or dropped — '$out'"
	fi
	if printf '%s' "$out" | grep -qF "help: usage of the moved tool"; then
		pass "bin/$tool: the tool's stdout is the caller's stdout"
	else
		fail "bin/$tool: the tool's stdout did not reach the caller — '$out'"
	fi
	if printf '%s' "$out" | grep -qxF "cwd=$work/cwd"; then
		pass "bin/$tool: the tool runs in the caller's cwd"
	else
		fail "bin/$tool: cwd changed — '$out'"
	fi

	for want in 0 1 3 127; do
		STUB_EXIT=$want bash "$root/bin/$tool" >/dev/null 2>&1; rc=$?
		if [ "$rc" = "$want" ]; then
			pass "bin/$tool: exit $want is passed through"
		else
			fail "bin/$tool: the tool exited $want, the shim exited $rc"
		fi
	done
done
cd "$real_home" || true

# --- the shims are sh, and carry no home directory ---------------------------------------------

for tool in $tools; do
	first=$(head -n 1 "$root/bin/$tool")
	if [ "$first" = "#!/bin/sh" ]; then pass "bin/$tool: a /bin/sh shim"; else fail "bin/$tool: first line '$first'"; fi
	if grep -qF '/home/' "$root/bin/$tool"; then
		fail "bin/$tool: the shim carries an absolute home directory"
	else
		pass "bin/$tool: no absolute home directory in the shim"
	fi
done

printf '\n'
if [ "$fails" = 0 ]; then
	printf 'shims: ok\n'
	exit 0
fi
printf 'shims: %d FAILED\n' "$fails"
exit 1
