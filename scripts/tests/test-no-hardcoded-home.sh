#!/usr/bin/env bash
# test-no-hardcoded-home.sh — no tracked file carries an absolute home directory.
#
# Why a test and not a rule: one home path in a script produced five symptoms on a Windows machine
# (a tab that died on "no such file or directory", both Herdr menu entries starting nothing, the
# guard that started the dead tab, an installer that wrote a key nothing could read), and each of
# them was found separately. The class is "a path that is true on one person's laptop", so the
# check is over every tracked file, with no allowlist: a test fixture that needs a directory says
# /tmp/..., never somebody's home.
#
# Two shapes are refused:
#   * a POSIX home: /home/<name> or /Users/<name>, with a real name after it;
#   * a Windows home: C:\Users\<name> or C:/Users/<name>, with a real name after it.
# A placeholder (`/home/<you>`) or a `~`-rooted path is fine: those resolve on the machine that
# runs them, which is the whole point.
#
#   bash scripts/tests/test-no-hardcoded-home.sh      exit 0 = the sweep is clean
set -uo pipefail

root=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/../.." && pwd)
cd "$root" || exit 1

# Assembled from pieces so this file's own text cannot be the hit it reports.
posix_home='/(home|Users)/[A-Za-z0-9_.-]'
windows_home='[A-Za-z]:[\\/]+Users[\\/][A-Za-z0-9_.-]'

# Tracked files plus the ones a worker has written but not committed yet: the sweep is the thing
# that should catch a new file before it lands, not after.
mapfile -t files < <(git ls-files; git ls-files --others --exclude-standard)
hits=$(grep -nIE "$posix_home|$windows_home" "${files[@]}" 2>/dev/null)

if [ -n "$hits" ]; then
	printf 'an absolute home directory is in a tracked file — resolve it at runtime instead:\n'
	printf '%s\n' "$hits" | sed 's/^/  /'
	printf '\nno-hardcoded-home: %s hit(s)\n' "$(printf '%s\n' "$hits" | wc -l)"
	exit 1
fi

printf '  ok    %s files, no absolute home directory\n' "${#files[@]}"
printf '\nno-hardcoded-home: ok\n'
