#!/usr/bin/env bash
# test-shell-resolve.sh — which bash runs a bin/ entry point, and what happens when there is none.
#
# The bug this pins: `bin/delegate` starts `#!/usr/bin/env bash` and did nothing to make that true.
# On Windows the command may be started by cmd.exe (the generated `delegate.cmd` shim), PowerShell,
# or a minimal Git Bash where `bash` is not on PATH and only `sh.exe` sits in `usr\bin`; the first
# bash-only line then failed with "command not found" and the script's own message never appeared.
# bin/shell-resolve.sh, sourced at the top of every entry point, re-execs the script under a bash it
# resolved — argv untouched — or says there is none.
#
# The cases, each with its own throwaway copy of bin/ and a PATH that holds only what the case is
# about (a test that inherited the caller's PATH would pass on a laptop and fail on a runner):
#
#   1. run by `sh` (dash) with a real bash on PATH: it re-execs and `delegate list` still answers;
#   2. a PATH with no bash and no PI_GIT_BASH: the one line, exit 127, and nothing of the command
#      ran first;
#   3. PI_GIT_BASH pointing at a stub that records its argv: the stub is used even though a real
#      bash is on PATH;
#   4. a Windows-shaped fixture (`Program Files/Git/bin/bash.exe`, no bash on PATH): the stub is
#      chosen and that native path is what exec receives;
#   5. already under bash: the resolver does not run at all (no second look, no fork) — and under
#      sh, exactly one re-exec, because the marker in the environment stops the second pass;
#   6. a `bash` that is a symlink on PATH: exec gets the real file behind it, not the link;
#   7. a copy with no resolver beside it — what the installer leaves in %USERPROFILE%\.local\bin —
#      still runs when a shim starts it under bash, and is stopped with the honest line (not a
#      "cannot open shell-resolve.sh" from the shell) when something starts it under sh.
#
#   bash scripts/tests/test-shell-resolve.sh      exit 0 = every case held
set -uo pipefail

root=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fails=0
pass() { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }

real_bash=$(command -v bash)
dash=$(command -v dash || command -v sh)
sys_path=/usr/local/bin:/usr/bin:/bin

# A throwaway copy of bin/, so nothing here can be true only because of where this repo sits, and an
# empty PI_BOSS_ROOT so `delegate list` reads no real delegation.
copy=$work/copy
empties=$work/root
mkdir -p "$copy" "$empties"
cp -a "$root/bin" "$copy/bin"

log=$work/exec.log
: >"$log"

# stub_bash <path> — an executable that records the argv exec handed it and then becomes the real
# bash, which is what a resolved bash does. `$0` is logged first: that is the path exec was given,
# so a symlink that was not resolved shows up here.
stub_bash() {
	mkdir -p "$(dirname -- "$1")"
	cat >"$1" <<STUB
#!/bin/sh
printf '%s\n' "\$0 \$*" >>"\$PI_TEST_LOG"
exec $real_bash "\$@"
STUB
	chmod +x "$1"
}

# lonely_path — a PATH with the tools the prelude needs and no bash anywhere on it. `sh` is on it
# on purpose: the whole point is a shell that is not bash.
lonely=$work/lonely
mkdir -p "$lonely"
for tool in sh dirname readlink tr printenv cat; do
	[ -x "/usr/bin/$tool" ] || continue
	ln -sf "/usr/bin/$tool" "$lonely/$tool"
done

# 1. Started by dash: the shebang is a promise only a Linux kernel keeps, so the re-exec is what
#    makes this run at all.
out=$(env -u PI_GIT_BASH -u PI_SHELL_VERBOSE PI_BOSS_ROOT=$empties PATH=$sys_path \
	"$dash" "$copy/bin/delegate" list 2>&1) && rc=0 || rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -qF 'no workers'; then
	pass "run by $dash: re-execs under bash and \`delegate list\` answers"
else
	fail "run by $dash: exit $rc — $out"
fi

# 2. Nothing to resolve: one line naming the override, exit 127, and no half-run command.
out=$(env -u PI_GIT_BASH -u PI_SHELL_VERBOSE PI_BOSS_ROOT=$empties PATH=$lonely \
	"$dash" "$copy/bin/delegate" list 2>&1) && rc=0 || rc=$?
wanted='no bash found — set PI_GIT_BASH=/path/to/bash.exe'
if [ "$rc" != 127 ]; then
	fail "no bash anywhere: exit $rc, wanted 127 — $out"
elif ! printf '%s' "$out" | grep -qF "$wanted"; then
	fail "no bash anywhere: no '$wanted' in the output — $out"
elif printf '%s' "$out" | grep -qF 'no workers'; then
	fail "no bash anywhere: the command ran anyway — $out"
else
	pass "no bash anywhere: 'no bash found' and exit 127, nothing ran first"
fi

# 3. An explicit PI_GIT_BASH wins over a bash on PATH.
stub=$work/gitbash
stub_bash "$stub"
: >"$log"
out=$(env -u PI_SHELL_VERBOSE PI_GIT_BASH=$stub PI_TEST_LOG=$log PI_BOSS_ROOT=$empties PATH=$sys_path \
	"$dash" "$copy/bin/delegate" list 2>&1) && rc=0 || rc=$?
lines=$(grep -c . "$log" 2>/dev/null || true)
if [ "$rc" = 0 ] && [ "${lines:-0}" = 1 ] && grep -qF "$stub" "$log" && grep -qF 'list' "$log"; then
	pass "PI_GIT_BASH: the stub ran once and was handed the original argv"
else
	fail "PI_GIT_BASH: exit $rc, ${lines:-0} exec(s) — $(tr '\n' ';' <"$log" 2>/dev/null) $out"
fi

# 4. The Windows layout: %ProgramFiles%\Git\bin\bash.exe, with no bash on PATH. A directory literally
#    named "Program Files" is the fixture, and the path handed to exec has to be that one.
winbash="$work/Program Files/Git/bin/bash.exe"
stub_bash "$winbash"
: >"$log"
out=$(env -u PI_SHELL_VERBOSE -u PI_GIT_BASH PI_TEST_LOG=$log PI_BOSS_ROOT=$empties PATH=$lonely \
	ProgramFiles="$work/Program Files" "$dash" "$copy/bin/delegate" list 2>&1) && rc=0 || rc=$?
if [ "$rc" = 0 ] && [ "$(grep -c . "$log" 2>/dev/null || true)" = 1 ] && grep -qF "$winbash " "$log"; then
	pass "%ProgramFiles%\\Git\\bin\\bash.exe: chosen with no bash on PATH, and that path is the exec target"
else
	fail "Program Files fixture: exit $rc — $(tr '\n' ';' <"$log" 2>/dev/null) $out"
fi

# 5. Already bash: the resolver is not evaluated at all, so a run under bash is one exec fewer, and
#    a script that sources another (bin/publish sources bin/delegate) does not look twice.
: >"$log"
out=$(env -u PI_SHELL_VERBOSE PI_GIT_BASH=$stub PI_TEST_LOG=$log PI_BOSS_ROOT=$empties PATH=$sys_path \
	"$real_bash" "$copy/bin/delegate" list 2>&1) && rc=0 || rc=$?
under_bash=$(grep -c . "$log" 2>/dev/null || true)
: >"$log"
env -u PI_SHELL_VERBOSE PI_GIT_BASH=$stub PI_TEST_LOG=$log PI_BOSS_ROOT=$empties PATH=$sys_path \
	"$dash" "$copy/bin/delegate" list >/dev/null 2>&1
under_dash=$(grep -c . "$log" 2>/dev/null || true)
if [ "$rc" = 0 ] && [ "${under_bash:-x}" = 0 ] && [ "${under_dash:-x}" = 1 ]; then
	pass "already under bash: 0 execs; under $dash: exactly 1 — no second resolution pass"
else
	fail "exec counts are bash=${under_bash:-?} dash=${under_dash:-?} (wanted 0 and 1), exit $rc"
fi

# 6. A bash that is a link (a pnpm-style ~/.local/bin/bash): exec is handed the file behind it, so a
#    wrapper cannot end up re-execing through a link that points back at a wrapper.
linkbin=$work/linkbin
mkdir -p "$linkbin"
ln -sf "$stub" "$linkbin/bash"
: >"$log"
out=$(env -u PI_SHELL_VERBOSE -u PI_GIT_BASH PI_TEST_LOG=$log PI_BOSS_ROOT=$empties \
	PATH=$linkbin:$sys_path "$dash" "$copy/bin/delegate" list 2>&1) && rc=0 || rc=$?
if [ "$rc" = 0 ] && [ "$(head -n 1 "$log" 2>/dev/null | cut -d' ' -f1)" = "$stub" ]; then
	pass "a linked bash on PATH: the symlink is resolved before exec"
else
	fail "linked bash: exit $rc — $(tr '\n' ';' <"$log" 2>/dev/null) $out"
fi

# 7. The installed copy: the installer copies a wrapper onto PATH on Windows, and a copy sits beside
#    no resolver. Started by the .cmd shim (which names a bash) it must still run; started by sh it
#    must be stopped with the line that says which file is missing, not by the shell's "cannot open".
bare=$work/bare
mkdir -p "$bare/bin"
cp "$root/bin/delegate" "$bare/bin/delegate"
: >"$log"
out=$(env -u PI_SHELL_VERBOSE -u PI_GIT_BASH PI_BOSS_ROOT=$empties PATH=$sys_path \
	"$real_bash" "$bare/bin/delegate" list 2>&1) && rc=0 || rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -qF 'no workers' && ! printf '%s' "$out" | grep -qF 'cannot open'; then
	pass "a copy with no resolver beside it still runs when bash starts it"
else
	fail "a copy with no resolver under bash: exit $rc — $out"
fi
out=$(env -u PI_SHELL_VERBOSE -u PI_GIT_BASH PI_BOSS_ROOT=$empties PATH=$sys_path \
	"$dash" "$bare/bin/delegate" list 2>&1) && rc=0 || rc=$?
if [ "$rc" = 127 ] && printf '%s' "$out" | grep -qF 'no shell-resolve.sh next to' && \
	! printf '%s' "$out" | grep -qF 'no workers'; then
	pass "a copy with no resolver started by $dash: the honest line and exit 127"
else
	fail "a copy with no resolver under $dash: exit $rc — $out"
fi

printf '\n%s\n' "$([ "$fails" = 0 ] && echo "shell-resolve: ok" || echo "shell-resolve: $fails failure(s)")"
[ "$fails" = 0 ]
