#!/usr/bin/env bash
# test-receipts.sh — bin/receipts.sh is one ledger for every gate, so a verdict is reached once
# and read next time instead of re-run. The claims this pins down:
#
#   A. A cold `bin/preflight --only suites` runs the suites; a warm one runs nothing and says it
#      answered from receipts.
#   B. `ci-local --only offline` on the same tree runs no test script either: the suite preflight
#      reported is the suite ci-local would have re-run.
#   C. A changed tracked file invalidates every receipt (the tree is part of the key) — an unstaged
#      edit is enough, the key is `git rev-parse HEAD` plus `git status --porcelain`.
#   D. A changed gate invalidates every receipt with the tree held equal: the copy carries the same
#      HEAD, the same clean status, and one edited gate file, and it re-runs.
#   E. A cached FAIL is still a FAIL: it blocks, it prints the transcript that failed, and it is
#      never run again into a pass.
#   F. `--fresh` on either command ignores the other's receipts and re-runs everything.
#   G. Reuse is symmetric: a receipt `scripts/ci-offline.sh` wrote answers `bin/preflight`'s suites
#      check, which is the direction the old single-ledger cache could not do.
#
# Every case runs in one throwaway checkout under a temporary directory (D takes the one copy it
# needs), with every test script ci-offline.sh runs replaced by a stub that appends its name to
# $STUBLOG. What the suite proves is then a line count, not a transcript, and one run costs a
# process instead of a suite.
#
# The fixture is paid for once and only the cases that need a cold gate get one: this file runs a
# gate six times over, so a second full copy, a commit per case, or a fourth `ci-offline.sh` merely
# to read a verdict the ledger already holds is time the case cannot spend on the box CI gives it.
#
#   bash scripts/tests/test-receipts.sh      exit 0 = every case held
set -uo pipefail

root=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/../.." && pwd)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
unset PI_MASTER_ROOT AGENTS_MD_LIMIT PI_PREFLIGHT_CACHE_TTL PI_RECEIPT_DIR PI_RECEIPT_FRESH
# PI_RECEIPT_FRESH is the flag `--fresh` exports to the cases it starts. A case whose subject is
# reuse must not inherit "trust nothing" from the run that asked for it, or a cold run of this job
# reports the ledger as broken when the parent turned it off.
export HOME=$work/home
mkdir -p "$HOME"
export STUBLOG=$work/stub.log
: >"$STUBLOG"
unset STUB_FAIL

fails=0
pass() { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }

out=""
rc=0
# runs — how many stubs have run since the log was last emptied.
runs() {
	if [ -s "$STUBLOG" ]; then wc -l <"$STUBLOG" | tr -d ' '; else printf 0; fi
}
said() { printf '%s' "$out" | grep -qF -- "$1"; }
want_rc() {
	if [ "$rc" = "$1" ]; then pass "$2 (exit $1)"; else fail "$2: exit $rc, wanted $1 — $out"; fi
}
want_text() {
	if said "$1"; then pass "$2"; else fail "$2: no '$1' in — $out"; fi
}
want_runs() {
	local n
	n=$(runs)
	if [ "$n" = "$1" ]; then pass "$2 ($n script run(s))"; else fail "$2: $n script run(s), wanted $1"; fi
}

# --- the fixture -----------------------------------------------------------------------------
# A copy of this checkout's tracked files, boss shape (scripts/ci-local.sh is what makes it that),
# with every script ci-offline.sh runs replaced by a stub. Each stub prints the line ci-offline
# expects from it, so the case passes for the reason the real script would; it appends its own name
# to $STUBLOG first, so a cached case is visible as an absent line; and it fails on purpose when
# its name is in $STUB_FAIL.
fx=$work/repo
mkdir -p "$fx"
git -C "$root" ls-files -z | (cd "$root" && xargs -0 tar -cf -) | tar -xf - -C "$fx"

stubs=0
while IFS=$'\t' read -r text rel; do
	[ -n "$rel" ] && [ -f "$fx/$rel" ] || continue
	cat >"$fx/$rel" <<EOF
#!/usr/bin/env bash
# fixture stub: what this suite proves is the ledger, not the suite
printf 'ran $rel\n' >>"\${STUBLOG:?}"
if [ -n "\${STUB_FAIL:-}" ] && printf '%s\n' "\$STUB_FAIL" | grep -qx '$rel'; then
	printf 'boom: $rel is broken on purpose\n' >&2
	exit 1
fi
printf '%s\n' '$text'
EOF
	chmod +x "$fx/$rel"
	stubs=$((stubs + 1))
done < <(sed -nE 's/^expect_script "[^"]*" [0-9]+ "([^"]*)" ([^ ]+)( --budget [0-9]+)?$/\1\t\2/p' "$fx/scripts/ci-offline.sh")
# What "every suite" means is ci-offline's own list, read from its source: a case added there is a
# case counted here, and this suite never has to be told the number again. A case that carries its
# own ceiling (`--budget`) is still a case, and the ceiling is not a reason to stub it differently.
suites=$(grep -c '^expect_script ' "$fx/scripts/ci-offline.sh")
if [ "$stubs" != "$suites" ]; then
	printf 'setup: %s stub(s) written, wanted %s — ci-offline.sh changed shape\n' "$stubs" "$suites" >&2
	exit 2
fi

# A cold preflight here is one ci-local job, the offline one, because the ledger lives in that job:
# syntax, lint and docs write no receipt, and shellcheck over a whole checkout on its own outlasts
# the job this file is about — the wall of the case would then be lint, not reuse.
sed -i.bak 's/^job_ids=(syntax lint offline docs)$/job_ids=(offline)/' "$fx/scripts/ci-local.sh"
rm -f "$fx/scripts/ci-local.sh.bak"
if ! grep -qx 'job_ids=(offline)' "$fx/scripts/ci-local.sh"; then
	printf 'setup: ci-local.sh no longer declares job_ids on one line — this fixture cannot shape it\n' >&2
	exit 2
fi

git -C "$fx" init -q -b main
git -C "$fx" add -A
git -C "$fx" -c user.name=fixture -c user.email=fixture@example.invalid \
	commit -qm "fixture: this tree, with stub suites"
git -C "$fx" checkout -q -b feat/fixture
printf '# a comment the branch adds: a code path changes, and a comment cannot fail a check\n' >>"$fx/scripts/prune-refs.sh"
git -C "$fx" add -A
git -C "$fx" -c user.name=fixture -c user.email=fixture@example.invalid \
	commit -qm "feat: a tracked change the branch makes"

pf() { (cd "$fx" && env PI_BOSS_ROOT="$fx" "$fx/bin/preflight" --cwd "$fx" "$@" 2>&1); }
cio() { (cd "$fx" && bash scripts/ci-offline.sh "$@" 2>&1); }

# A. Cold, then warm: the second run on an unchanged tree answers from receipts and starts nothing.
: >"$STUBLOG"
out=$(pf --only suites)
rc=$?
want_rc 0 "a cold suites check passes"
want_runs "$suites" "a cold suites check runs every suite once"
: >"$STUBLOG"
out=$(pf --only suites)
rc=$?
want_rc 0 "the same tree passes again"
want_text "1 cached, 0 ran" "the second run says it answered from a receipt"
want_runs 0 "the second run starts no suite"

# B. The point of the exercise: the offline job does not re-run the scripts the suites check just
#    ran. A full list of lines here would be the 79s that made this worth doing.
: >"$STUBLOG"
out=$(cio)
rc=$?
want_rc 0 "the offline suite passes"
want_text "offline behaviour: ok ($suites cached, 0 ran)" "the offline job answers from the ledger"
want_runs 0 "the offline job runs no test script the suites check already ran"

# C. A changed tracked file is a different tree: nothing may answer for it. The reverted read is
#    taken through preflight, which is the same ledger for 70ms where ci-offline.sh is 4s: what the
#    step proves is that the receipts are valid again, not which gate reads them.
printf 'an unstaged edit is a different tree\n' >>"$fx/scripts/prune-refs.sh"
: >"$STUBLOG"
out=$(cio)
rc=$?
want_rc 0 "a dirty tree still passes"
want_runs "$suites" "an unstaged edit invalidates every receipt"
git -C "$fx" checkout -- scripts/prune-refs.sh
: >"$STUBLOG"
out=$(pf --only suites)
rc=$?
want_runs 0 "and reverting the edit makes the receipts valid again"

# D. A changed gate is a different ledger entry even when the tree is identical: the copy has the
#    same HEAD and a clean status, and one gate file differs. assume-unchanged is what keeps the
#    tree hash honest while the blob changes, so this case isolates the gate dimension.
fx2=$work/repo2
cp -a "$fx" "$fx2"
rm -rf "$fx2/state"
printf '# a gate that changed without a commit\n' >>"$fx2/bin/preflight"
git -C "$fx2" update-index --assume-unchanged bin/preflight
if [ "$(git -C "$fx" rev-parse HEAD)" != "$(git -C "$fx2" rev-parse HEAD)" ] || [ -n "$(git -C "$fx2" status --porcelain)" ]; then
	fail "the gate case needs one tree and two gates, and the trees differ"
else
	: >"$STUBLOG"
	out=$(cd "$fx2" && env PI_RECEIPT_DIR="$fx/state/preflight" bash scripts/ci-offline.sh 2>&1)
	rc=$?
	want_rc 0 "a changed gate still passes when the work is sound"
	want_runs "$suites" "a changed gate reuses nothing, even on an unchanged tree"
fi

# E. A cached FAIL blocks, keeps its transcript, and is not run again hoping for a pass. The fail
#    is made by ci-offline.sh and read back through preflight: one ledger, so a receipt one gate
#    wrote is a verdict the other honours — and a receipt that must not be re-run into a pass is
#    exactly where a re-read is cheap and a second gate run is not.
export STUB_FAIL=scripts/test-wipe.sh
: >"$STUBLOG"
out=$(cio --fresh)
rc=$?
want_rc 1 "a failing suite still fails the gate"
want_text "wipe checklist, refusal and skip log: exit 1, wanted 0" "the failing case is named"
: >"$STUBLOG"
out=$(pf --only suites)
rc=$?
want_rc 1 "the cached FAIL still fails"
want_text "cached" "the cached FAIL says it came from a receipt"
want_text "boom: scripts/test-wipe.sh is broken on purpose" "the cached FAIL still shows the transcript that failed"
want_runs 0 "the cached FAIL is not run again"
unset STUB_FAIL

# F. --fresh on either command ignores the other's receipts: a run that refuses to trust the ledger
#    must not leave a verdict behind that the next run trusts either.
: >"$STUBLOG"
out=$(pf --fresh --only suites)
rc=$?
want_rc 0 "preflight --fresh passes"
want_text "0 from receipts" "preflight --fresh reads no receipt"
want_runs "$suites" "preflight --fresh runs every suite again"
: >"$STUBLOG"
out=$(pf --only suites)
rc=$?
want_runs 0 "the receipts the fresh run wrote are reused next time"

# G. Symmetry: ci-offline --fresh forgets the tree's verdicts, re-runs and writes its own; the
#    suites check that follows has no receipt of its own and must still find the scripts already
#    answered — the direction the check-level cache could never do.
: >"$STUBLOG"
out=$(cio --fresh)
rc=$?
want_rc 0 "ci-offline --fresh passes"
want_text "offline behaviour: ok (0 cached, $suites ran)" "ci-offline --fresh reads no receipt"
want_runs "$suites" "ci-offline --fresh runs every test script again"
: >"$STUBLOG"
out=$(pf --only suites)
rc=$?
want_rc 0 "the suites check passes on receipts it did not write"
want_text "(0 cached, 1 ran)" "the suites check itself had no receipt and ran"
want_text "0 from receipts" "the suites it discovered had no receipt of their own"
want_runs 0 "a receipt written by ci-offline answers preflight's suites check"

printf '\n%s\n' "$([ "$fails" = 0 ] && echo "receipts: ok" || echo "receipts: $fails failure(s)")"
[ "$fails" = 0 ]
