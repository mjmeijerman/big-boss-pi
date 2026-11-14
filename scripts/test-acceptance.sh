#!/usr/bin/env bash
# test-acceptance.sh — the second opinion is a mode, not a sentence in a spec.
#
# `delegate spawn SLUG --acceptance --cwd DIR specs/some-spec.md` is supposed to produce a worker
# that writes failing acceptance tests and never sees the implementation. That only holds if the
# flag is accepted, the generated spec actually says "never open the implementation", and the mode
# is recorded where a later reader can audit it. All three are asserted here against a temporary
# PI_BOSS_ROOT and stubbed herdr-app, hc, jev and runner: no model, no desktop app, no real space.
#
#   bash scripts/test-acceptance.sh      exit 0 = all three behaviours held
set -uo pipefail

root=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd)
bin=$root/bin

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export PI_BOSS_ROOT=$work/root
unset PI_MASTER_ROOT
mkdir -p "$PI_BOSS_ROOT/bin" "$PI_BOSS_ROOT/specs" "$PI_BOSS_ROOT/reports" "$PI_BOSS_ROOT/state" "$work/stub"
export HOME=$work/home
mkdir -p "$HOME"

# jev answers remote, sandboxed, one worker, low effort: nothing in this test is about the
# decisions, so they are fixed and the stub is cheap.
cat >"$PI_BOSS_ROOT/bin/jev" <<'STUB'
#!/usr/bin/env bash
case $1 in
route) printf '{"route":"remote","reason":"code work"}\n'; exit 1 ;;
mode) printf '{"mode":"sandboxed","reason":"repo work"}\n' ;;
count) printf '{"count":1,"reason":"one worker"}\n' ;;
thinking) printf '{"thinking":"low","reason":"mechanical"}\n' ;;
*) printf '{"reason":"stub"}\n' ;;
esac
exit 0
STUB
# herdr-app answers with a space id for space.new and with a focusable space for status, so a
# spawn gets all the way through and writes its state line.
cat >"$work/stub/herdr-app" <<'STUB'
#!/usr/bin/env bash
printf '{"space":"s1","tab":"t1","pane":"p1","terminal":"term1"}\n'
exit 0
STUB
# hc prints the banner marker immediately: the spawn's wait loop exits on its first read.
cat >"$work/stub/hc" <<'STUB'
#!/usr/bin/env bash
printf 'escape interrupt\n'
exit 0
STUB
printf '#!/usr/bin/env bash\nexit 0\n' >"$PI_BOSS_ROOT/bin/pi-sandboxed"
chmod +x "$PI_BOSS_ROOT/bin/jev" "$PI_BOSS_ROOT/bin/pi-sandboxed" "$work/stub/herdr-app" "$work/stub/hc"

# The spec under test. Any spec file will do; this one is small on purpose.
cat >"$PI_BOSS_ROOT/specs/example.md" <<'SPEC'
# Feature `example`

- **Mission**: a person can run `bin/example` and see it refuse a bad slug with exit 1.
SPEC

fails=0
pass() { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }

out=$(PATH=$work/stub:$PATH timeout 60 "$bin/delegate" spawn second-opinion --acceptance \
	--cwd "$work" "specs/example.md" 2>&1) && rc=0 || rc=$?

# 1. The flag is accepted: the spawn completes and says so in its result line.
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q '"acceptance":true'; then
	pass "--acceptance is accepted and the spawn result carries acceptance:true"
else
	fail "--acceptance spawn: exit $rc — $out"
fi

# 2. The generated spec carries the instruction that makes the mode worth anything: the worker
#    must not open the implementation, and must report a decision instead of guessing.
spec=$PI_BOSS_ROOT/specs/second-opinion.md
if [ -f "$spec" ] && grep -qi "never open the implementation files" "$spec" &&
	grep -qE 'DECISION NEEDED' "$spec" && grep -qi "commit only test files" "$spec"; then
	pass "generated spec: never sees the implementation, DECISION NEEDED, tests only"
else
	fail "generated spec is missing the acceptance instructions: $(ls "$PI_BOSS_ROOT/specs" 2>&1)"
fi

# 3. The mode is recorded, so a later reader can tell a second opinion from an implementer
#    without reading either spec.
if grep -q '"acceptance": true' "$PI_BOSS_ROOT/state/delegations.json" 2>/dev/null; then
	pass "acceptance:true recorded in state/delegations.json"
else
	fail "no acceptance:true in state/delegations.json"
fi

# 4. The mode is a refusal, not a suggestion: without a spec file it stops before asking jev.
out=$(PATH=$work/stub:$PATH timeout 60 "$bin/delegate" spawn second-opinion --acceptance \
	--cwd "$work" "add a feature" 2>&1) && rc=0 || rc=$?
if [ "$rc" = 1 ] && printf '%s' "$out" | grep -q "needs a spec file under specs/"; then
	pass "--acceptance without a spec file refuses"
else
	fail "--acceptance without a spec file: exit $rc — $out"
fi

printf '\n%s\n' "$([ "$fails" = 0 ] && echo "acceptance mode: ok" || echo "acceptance mode: $fails failure(s)")"
[ "$fails" = 0 ]
