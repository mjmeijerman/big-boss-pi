#!/usr/bin/env bash
# test-pi-resolve.sh — where the three worker wrappers find pi, and what they start.
#
# The bug this pins: every wrapper carried `/home/<user>/.local/share/pnpm/bin/pi`, so on a Windows
# machine the tab the guard opened died on "no such file or directory" and both Herdr menu entries
# started nothing. The resolution now lives in bin/pi-resolve.sh, built from $PI_BIN, $PATH,
# $PNPM_HOME, $HOME and %APPDATA% at runtime.
#
# The cases, in the order the resolver tries them, each with its own temporary $HOME and a PATH
# that holds nothing but the system tools:
#
#   1. $PI_BIN points at an executable pi — it wins, and it is the absolute path that is printed;
#   2. $PI_BIN_PATH, the old name, still works;
#   3. `pi` on PATH;
#   4. $PNPM_HOME/pi;
#   5. $HOME/.local/share/pnpm/bin/pi;
#   6. $HOME/.local/bin/pi;
#   7. nothing anywhere: exit 127 and one line that names PI_BIN — never the kernel's "not found";
#   8. a Windows shell: %APPDATA%\npm\pi.cmd resolves, and the same file is *not* a source on a
#      POSIX shell (a .cmd there is a file nobody can start);
#   9. bin/pi-bare execs what the resolver chose, with PI_BARE and PI_WORKER exported (a stub pi
#      records its argv and its environment);
#  10. bin/pi-sandboxed execs the sandbox runner with `-- <args>`, and the PATH it exports holds
#      the directory pi was found in, not a literal one;
#  11. bin/pi-nonet does the same with `--no-net`;
#  12. bin/pi-sandboxed on win32 refuses with the exact honest line and exits non-zero — it does
#      not fall back to bare, and it does not die on a missing path;
#  13. no wrapper reaches pi through `exec env`: that is a bare exec, and a .cmd has no shebang.
#
#   bash scripts/tests/test-pi-resolve.sh      exit 0 = every case held
set -uo pipefail

root=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fails=0
pass() { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }

# The system tools the wrappers need, with no pi on it. A test that inherited the caller's PATH
# would pass on a laptop with pnpm installed and fail on a runner for the wrong reason.
sys_path=/usr/local/bin:/usr/bin:/bin
resolver=$root/bin/pi-resolve.sh

home=$work/home
mkdir -p "$home"

stub_pi() { # stub_pi <path>... — an executable that could be pi, and nothing else
	local f
	for f in "$@"; do
		mkdir -p "$(dirname -- "$f")"
		printf '#!/bin/sh\nexit 0\n' >"$f"
		chmod +x "$f"
	done
}

# resolve_case <name> [env assignment...] -- <wanted path|"none">
# Runs the resolver with a temporary HOME and the system PATH only, and compares.
resolve_case() {
	local name=$1 want rc out
	shift
	local -a envs=()
	while [ "$1" != "--" ]; do
		envs+=("$1")
		shift
	done
	shift
	want=$1
	out=$(env -u PI_BIN -u PI_BIN_PATH -u PNPM_HOME -u APPDATA -u PI_PLATFORM \
		HOME=$home PATH=$sys_path "${envs[@]}" bash "$resolver" 2>"$work/err") && rc=0 || rc=$?
	local err
	err=$(cat "$work/err")
	if [ "$want" = none ]; then
		if [ "$rc" = 127 ] && printf '%s' "$err" | grep -qF 'PI_BIN'; then
			pass "$name: exit 127 and the reason names PI_BIN"
		else
			fail "$name: exit $rc, error '$err'"
		fi
		return
	fi
	local wanted
	wanted=$(readlink -f "$want")
	if [ "$rc" = 0 ] && [ "$out" = "$wanted" ]; then
		pass "$name: $out"
	else
		fail "$name: exit $rc, got '$out', wanted '$wanted' — $err"
	fi
}

# --- 1. $PI_BIN ------------------------------------------------------------------------------
stub_pi "$work/explicit/pi"
resolve_case "PI_BIN" PI_BIN="$work/explicit/pi" -- "$work/explicit/pi"

# --- 2. $PI_BIN_PATH, the name the old wrappers used ----------------------------------------
stub_pi "$work/legacy/pi"
resolve_case "PI_BIN_PATH" PI_BIN_PATH="$work/legacy/pi" -- "$work/legacy/pi"

# --- 3. pi on PATH ---------------------------------------------------------------------------
stub_pi "$work/onpath/pi"
resolve_case "pi on PATH" PATH="$work/onpath:$sys_path" -- "$work/onpath/pi"

# --- 4. $PNPM_HOME ---------------------------------------------------------------------------
stub_pi "$work/pnpm/pi"
resolve_case "PNPM_HOME" PNPM_HOME="$work/pnpm" -- "$work/pnpm/pi"

# --- 5. the default pnpm bin dir under the home ---------------------------------------------
stub_pi "$home/.local/share/pnpm/bin/pi"
resolve_case "~/.local/share/pnpm/bin" -- "$home/.local/share/pnpm/bin/pi"
rm -f "$home/.local/share/pnpm/bin/pi"

# --- 6. ~/.local/bin -------------------------------------------------------------------------
stub_pi "$home/.local/bin/pi"
resolve_case "~/.local/bin" -- "$home/.local/bin/pi"
rm -f "$home/.local/bin/pi"

# --- 7. nothing at all ----------------------------------------------------------------------
resolve_case "nothing to find" -- none
# And the miss is one line, not a wall: the kernel's wording must not be the answer.
if grep -qF 'No such file' "$work/err"; then
	fail "the miss prints the kernel's 'No such file or directory' instead of naming PI_BIN"
else
	pass "the miss is one line naming PI_BIN, not the kernel's"
fi

# --- 8. %APPDATA%\npm on Windows -------------------------------------------------------------
mkdir -p "$work/appdata/npm"
printf ':: pi.cmd\r\n' >"$work/appdata/npm/pi.cmd"
chmod 644 "$work/appdata/npm/pi.cmd"
resolve_case "%APPDATA%\\npm\\pi.cmd on win32" PI_PLATFORM=win32 APPDATA="$work/appdata" \
	-- "$work/appdata/npm/pi.cmd"
resolve_case "the same .cmd is not a source on POSIX" APPDATA="$work/appdata" -- none

# --- 9-11. the three wrappers -----------------------------------------------------------------
stub_pi "$work/onpath/pi"
cat >"$work/record-pi" <<'STUB'
#!/usr/bin/env bash
printf 'argv:%s\n' "$*" >>"$RECORD"
printf 'env:PI_BARE=%s PI_WORKER=%s\n' "${PI_BARE:-}" "${PI_WORKER:-}" >>"$RECORD"
STUB
chmod +x "$work/record-pi"
cat >"$work/record-sandbox" <<'STUB'
#!/usr/bin/env bash
printf 'argv:%s\n' "$*" >>"$RECORD"
printf 'path:%s\n' "$PATH" >>"$RECORD"
STUB
chmod +x "$work/record-sandbox"

# 9. pi-bare: the pi the resolver chose, plus the two markers, and no `exec env` in the way.
: >"$work/rec-bare"
env HOME=$home PATH=$work/onpath:$sys_path RECORD="$work/rec-bare" PI_BIN="$work/record-pi" \
	"$root/bin/pi-bare" alpha beta >/dev/null 2>&1
rc=$?
if [ "$rc" != 0 ]; then
	fail "pi-bare exited $rc"
elif ! grep -qxF 'argv:alpha beta' "$work/rec-bare"; then
	fail "pi-bare did not exec the resolved pi with its own argv — $(tr '\n' ';' <"$work/rec-bare")"
elif ! grep -qxF 'env:PI_BARE=1 PI_WORKER=1' "$work/rec-bare"; then
	fail "pi-bare did not export PI_BARE and PI_WORKER — $(tr '\n' ';' <"$work/rec-bare")"
else
	pass "pi-bare execs the resolved pi with PI_BARE=1 PI_WORKER=1 and the caller's argv"
fi

# 10. pi-sandboxed: the sandbox runner, seeded with the workspace's specs and reports, and a PATH
#     that carries the directory pi was found in.
mkdir -p "$work/boss/specs" "$work/boss/reports"
: >"$work/rec-sandbox"
env HOME=$home PATH=$work/onpath:$sys_path RECORD="$work/rec-sandbox" \
	PI_BOSS_ROOT="$work/boss" PI_BOSS_PISANDBOX="$work/record-sandbox" \
	"$root/bin/pi-sandboxed" a-b >/dev/null 2>&1
if ! grep -qxF "argv:--rw $work/boss/specs --rw $work/boss/reports -- a-b" "$work/rec-sandbox"; then
	fail "pi-sandboxed did not hand the seeds and the argv to the runner — $(tr '\n' ';' <"$work/rec-sandbox")"
elif ! grep -F 'path:' "$work/rec-sandbox" | grep -qF "$(readlink -f "$work/onpath")"; then
	fail "pi-sandboxed did not put the resolved pi directory on the sandbox PATH — $(tr '\n' ';' <"$work/rec-sandbox")"
else
	pass "pi-sandboxed execs the runner with the seeds, and the resolved directory on PATH"
fi

# 11. pi-nonet: the same, with --no-net in front.
: >"$work/rec-nonet"
env HOME=$home PATH=$work/onpath:$sys_path RECORD="$work/rec-nonet" \
	PI_BOSS_ROOT="$work/boss" PI_BOSS_PISANDBOX="$work/record-sandbox" \
	"$root/bin/pi-nonet" a-b >/dev/null 2>&1
if grep -qxF "argv:--no-net --rw $work/boss/specs --rw $work/boss/reports -- a-b" "$work/rec-nonet"; then
	pass "pi-nonet asks the runner for no network, with the same seeds"
else
	fail "pi-nonet did not hand --no-net to the runner — $(tr '\n' ';' <"$work/rec-nonet")"
fi

# 12. Native Windows: no sandbox there, and saying so is the whole behaviour.
out=$(env HOME=$home PATH=$sys_path PI_PLATFORM=win32 PI_BOSS_PISANDBOX="$work/record-sandbox" \
	"$root/bin/pi-sandboxed" 2>&1) && rc=0 || rc=$?
wanted='no sandbox on native Windows; run pi under WSL2 (docs/install.md#sandboxing-on-windows)'
if [ "$rc" = 0 ]; then
	fail "pi-sandboxed on win32 exited 0 — a sandbox that silently is not one"
elif ! printf '%s' "$out" | grep -qF "$wanted"; then
	fail "pi-sandboxed on win32 does not print the honest line — $out"
else
	pass "pi-sandboxed on win32 refuses (exit $rc) with the honest line"
fi

# 13. No wrapper may reach pi through `exec env`: env is a bare exec and a .cmd has no shebang.
if grep -nE '^exec env ' "$root"/bin/pi-bare "$root"/bin/pi-sandboxed "$root"/bin/pi-nonet; then
	fail "a wrapper still starts pi through 'exec env', which cannot run a .cmd on Windows"
else
	pass "no wrapper starts pi through 'exec env'"
fi

printf '\n%s\n' "$([ "$fails" = 0 ] && echo "pi-resolve: ok" || echo "pi-resolve: $fails failure(s)")"
[ "$fails" = 0 ]
