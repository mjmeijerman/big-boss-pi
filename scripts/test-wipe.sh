#!/usr/bin/env bash
# test-wipe.sh — `delegate wipe <slug>` asks the five consolidation questions, and a skip is
# written down where every other decision is.
#
# The wipe step is only worth a mandatory slot between features if it costs nothing to use and
# nothing to skip honestly: the checklist has to print without a Herdr space, an unknown slug
# has to fail loudly instead of wiping nothing, and a skip has to land in
# state/decisions.jsonl with the reason attached, or nobody can tell a skipped wipe from a
# forgotten one.
#
# Every case drives the real `delegate wipe`, against a temporary PI_BOSS_ROOT and stub
# herdr-app/hc/jev, the same way scripts/test-placeholders.sh drives `delegate close`.
#
#   bash scripts/test-wipe.sh      exit 0 = every case held
set -uo pipefail

root=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd)
bin=$root/bin

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export PI_BOSS_ROOT=$work/root
mkdir -p "$PI_BOSS_ROOT/reports" "$PI_BOSS_ROOT/state" "$work/stub"
unset PI_MASTER_ROOT

# A herdr-app that always succeeds and records every call: wiping a worker must not need the
# desktop app, and the record proves it did not close the space behind the caller's back.
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s/herdr-calls"\nexit 0\n' "$work" \
	>"$work/stub/herdr-app"
printf '#!/usr/bin/env bash\nexit 0\n' >"$work/stub/hc"
chmod +x "$work/stub/herdr-app" "$work/stub/hc"
export PATH=$work/stub:$PATH

# One tracked worker, so "known" and "unknown" mean something.
printf '{"w1":{"space":"space-w1","cwd":"","branch":""}}\n' >"$PI_BOSS_ROOT/state/delegations.json"
: >"$PI_BOSS_ROOT/state/decisions.jsonl"

fails=0
pass() { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }

# run <args...> — sets OUT and RC from the real delegate.
OUT=""
RC=0
run() {
	local out
	out=$("$bin/delegate" "$@" 2>&1) && RC=0 || RC=$?
	OUT=$out
}

# 1. The checklist is exactly five lines, and they are the five questions: code deleted,
#    duplication, a new feature landing here in 30 minutes, what we learned, and what we would
#    re-implement from scratch. Five lines is the assertion; the anchors keep it honest.
checklist_ok=0
run wipe w1
if [ "$RC" != 0 ]; then
	fail "wipe on a known slug: exit $RC, wanted 0 — $OUT"
else
	lines=$(printf '%s\n' "$OUT" | grep -c .)
	if [ "$lines" != 5 ]; then
		fail "wipe printed $lines non-empty lines, wanted exactly 5 — $OUT"
	else
		anchors="delete duplicat 30 learn scratch"
		missing=""
		for a in $anchors; do
			printf '%s' "$OUT" | grep -qiF -- "$a" || missing="$missing $a"
		done
		if [ -n "$missing" ]; then
			fail "checklist is missing the question(s) about:$missing — $OUT"
		else
			pass "wipe prints the five-line checklist"
			checklist_ok=1
		fi
	fi
fi

# 2. An unknown slug is refused, nonzero, and says which word was wrong. A wipe that silently
#    does nothing is a wipe nobody can trust.
run wipe nosuch-worker
if [ "$RC" = 0 ]; then
	fail "wipe on an unknown slug exited 0, wanted nonzero — $OUT"
elif ! printf '%s' "$OUT" | grep -qF "no such worker"; then
	fail "wipe on an unknown slug did not say 'no such worker' — $OUT"
else
	pass "wipe on an unknown slug refuses (exit $RC)"
fi

# 3. A skip is a decision, so it is recorded like one: one JSON line in state/decisions.jsonl
#    carrying the reason verbatim. Without the reason it is indistinguishable from a forgotten
#    wipe, which is the whole failure this step exists to avoid.
reason="nothing merged since the last wipe; nothing to consolidate yet"
: >"$PI_BOSS_ROOT/state/decisions.jsonl"
run wipe w1 --skip "$reason"
if [ "$RC" != 0 ]; then
	fail "wipe --skip: exit $RC, wanted 0 — $OUT"
else
	if msg=$(node -e '
		const fs = require("fs");
		const [file, want] = process.argv.slice(1);
		const lines = fs.readFileSync(file, "utf8").split("\n").filter(Boolean);
		const rows = lines.map((l) => { try { return JSON.parse(l); } catch { return null; } });
		const hit = rows.filter((r) => r && JSON.stringify(r).includes(want));
		if (!hit.length) { console.log("no decision line carries the reason: " + lines.join(" | ")); process.exit(1); }
		const row = hit[hit.length - 1];
		if (!JSON.stringify(row).includes("\"wipe\"")) { console.log("the line does not name the wipe: " + JSON.stringify(row)); process.exit(1); }
		if ("slug" in row && row.slug !== "w1") { console.log("the line names the wrong slug: " + JSON.stringify(row)); process.exit(1); }
		process.exit(0);' "$PI_BOSS_ROOT/state/decisions.jsonl" "$reason"); then
		pass "a skip lands in state/decisions.jsonl with its reason"
	else
		fail "skip not recorded: $msg"
	fi
fi

# 4. And the wipe itself is offline: no Herdr call, because closing the space is the sweep's
#    job and a wipe that closes things is a wipe nobody runs between features.
if [ "$checklist_ok" = 0 ]; then
	printf '  skip  %s\n' "no herdr-app call — not checked, wipe does not run yet"
elif [ -s "$work/herdr-calls" ]; then
	fail "wipe called herdr-app: $(tr '\n' ';' <"$work/herdr-calls")"
else
	pass "wipe never touches herdr-app"
fi

printf '\n%s\n' "$([ "$fails" = 0 ] && echo "wipe: ok" || echo "wipe: $fails failure(s)")"
[ "$fails" = 0 ]
