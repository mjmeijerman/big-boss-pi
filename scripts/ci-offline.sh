#!/usr/bin/env bash
# ci-offline.sh — prove the harness fails loud without ollama and without herdr-app.
#
# The interesting half of CI for this repo, because the two things every script talks to
# (a local ollama model, the Herdr desktop app) do not exist on a GitHub runner. So instead
# of mocking them, this runs the real scripts against a closed port and an empty PATH and
# checks that they refuse loudly, with the right exit code, instead of hanging or guessing.
#
# Everything runs against a temporary HOME and a temporary PI_BOSS_ROOT: no real workspace,
# no real systemd, no real state/ directory is touched. Guard is the one that could otherwise
# create a real Herdr space, so herdr-app is stripped from PATH for every case.
#
#   bash scripts/ci-offline.sh      exit 0 = all behaviours held
set -uo pipefail

root=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd)
bin=$root/bin

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export HOME=$work/home
export PI_BOSS_ROOT=$work/root
mkdir -p "$HOME" "$PI_BOSS_ROOT"
unset PI_MASTER_ROOT JEV_MODEL JEV_TIMEOUT

# PATH minus every directory that ships herdr-app, so guard and delegate cannot find it even
# on a machine (like a laptop) where it is installed.
safe_path=""
IFS=: read -r -a dirs <<<"${PATH:-/usr/local/bin:/usr/bin:/bin}"
for d in "${dirs[@]}"; do
	[ -x "$d/herdr-app" ] && continue
	safe_path+=${safe_path:+:}$d
done
if PATH=$safe_path command -v herdr-app >/dev/null 2>&1; then
	printf 'setup: herdr-app still on PATH; the guard test would create a real space\n' >&2
	exit 2
fi

# A port nothing listens on: 127.0.0.1:9 is the discard port and is closed on the runner.
closed=http://127.0.0.1:9/api/chat

fails=0
pass() { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }

# expect <name> <want-code> <want-text|-> -- <command...>
expect() {
	local name=$1 want=$2 text=$3
	shift 4 # name, code, text, --
	local out rc
	out=$(timeout 30 "$@" 2>&1) && rc=0 || rc=$?
	if [ "$rc" != "$want" ]; then
		fail "$name: exit $rc, wanted $want — $out"
	elif [ "$text" != - ] && ! printf '%s' "$out" | grep -qF -- "$text"; then
		fail "$name: no '$text' in output — $out"
	else
		pass "$name (exit $want)"
	fi
}

# 1. The model client: an unreachable model is exit 3 and says so. Exit 3 is the whole point
#    — it is the code that sends the question to the user instead of answering it.
expect "jev ask, model down" 3 "decision model unreachable" -- \
	env JEV_ENDPOINT=$closed "$bin/jev" ask "ship it?"
expect "jev route, model down" 3 "decision model unreachable" -- \
	env JEV_ENDPOINT=$closed "$bin/jev" route "summarise this"
# thinking is the newest decision kind and the one a spawn cannot do without: an unreachable
# model must stop the spawn, never fall back to a default level.
expect "jev thinking, model down" 3 "decision model unreachable" -- \
	env JEV_ENDPOINT=$closed "$bin/jev" thinking "rename a helper"
# local-run reports on stderr and exits 1: no answer is not the same as "ask the user".
expect "local-run, model down" 1 "local model unreachable" -- \
	env JEV_ENDPOINT=$closed "$bin/local-run" "say hi"
expect "jev with no question" 2 "needs the question text" -- \
	env JEV_ENDPOINT=$closed "$bin/jev" ask ""
expect "jev with no subcommand" 2 "usage: jev" -- \
	env JEV_ENDPOINT=$closed "$bin/jev"

# 2. delegate refuses a bad slug before it reaches out to anything. The slug check comes
#    before the herdr-app check, so a malformed slug must not mention herdr at all.
expect "delegate, bad slug" 1 "slug must match" -- \
	env PATH=$safe_path "$bin/delegate" spawn "Bad_Slug" --cwd "$work" "do a thing"
expect "delegate, missing --cwd" 1 "spawn needs --cwd" -- \
	env PATH=$safe_path "$bin/delegate" spawn "good-slug" "do a thing"
expect "delegate, no such directory" 1 "no such directory" -- \
	env PATH=$safe_path "$bin/delegate" spawn "good-slug" --cwd "$work/nope" "do a thing"
expect "delegate, bad thinking level" 1 "thinking must be off" -- \
	env PATH=$safe_path "$bin/delegate" spawn "good-slug" --cwd "$work" --thinking louder "do a thing"
expect "delegate, no subcommand" 1 "usage: delegate" -- \
	env PATH=$safe_path "$bin/delegate"

# 3. Without herdr-app, delegate says which binary is missing and stops. Nothing is spawned
#    and nothing is written into the temporary root's state directory.
expect "delegate spawn, herdr-app absent" 1 "herdr-app is not on PATH" -- \
	env PATH=$safe_path "$bin/delegate" spawn "good-slug" --cwd "$work" "do a thing"
[ -f "$PI_BOSS_ROOT/state/delegations.json" ] &&
	fail "delegate wrote state before it had a space" ||
	pass "no state/delegations.json written"

# 4. guard exits instead of looping or creating a space. It is silent on stdout — the reason
#    goes to its log — so this one is a code check plus a look at the log.
expect "guard, herdr-app absent" 0 - -- \
	env PATH=$safe_path "$bin/guard"
if grep -qF "herdr-app not on PATH; exiting" "$PI_BOSS_ROOT/state/guard.log" 2>/dev/null; then
	pass "guard said why in state/guard.log, in the temporary root"
else
	fail "guard wrote no 'herdr-app not on PATH; exiting' line to the temporary root"
fi

# 5. The temporary root is honoured, not read through to the real one.
expect "delegate list, empty temp root" 0 "no workers" -- \
	env PATH=$safe_path "$bin/delegate" list

printf '\n%s\n' "$([ "$fails" = 0 ] && echo "offline behaviour: ok" || echo "offline behaviour: $fails failure(s)")"
[ "$fails" = 0 ]
