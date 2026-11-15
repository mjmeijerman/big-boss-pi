#!/usr/bin/env bash
# test-ci-local.sh — scripts/ci-local.sh runs .github/workflows/ci.yml's four jobs, and says
# so in a way a person can act on.
#
# The claims this pins down, because a checker nobody checks is a checker that can go quiet:
#
#   A. --list names the four jobs and runs nothing.
#   B. A clean tree passes, and the last line names the commit it ran against.
#   C. A planted failure fails: a bash syntax error, an ESM syntax error, and AGENTS.md over
#      the byte budget each exit non-zero and print the offending file and its first lines.
#   D. Lint is a refusal, not a warning: absent shellcheck is SKIPPED plus a non-zero exit,
#      and shellcheck's own findings are printed.
#   E. The offline job is wired to the real script, and its failure is this script's failure.
#
# Every case runs against a throwaway clone under a temporary directory: nothing here touches
# the real checkout, and the offline job is given a stub so this suite cannot recurse into it.
#
#   bash scripts/tests/test-ci-local.sh      exit 0 = every case held
set -uo pipefail

root=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/../.." && pwd)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
unset PI_MASTER_ROOT AGENTS_MD_LIMIT
export HOME=$work/home
mkdir -p "$HOME"

fails=0
pass() { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }

out=""
rc=0
RUN_PATH=${RUN_PATH:-$PATH}
# run <tree> [args...] — run ci-local.sh inside a throwaway checkout.
run() {
	local tree=$1
	shift
	out=$(cd "$tree" && env PATH="$RUN_PATH" bash scripts/ci-local.sh "$@" 2>&1)
	rc=$?
}
want_rc() { # <want> <description>
	if [ "$rc" = "$1" ]; then pass "$2 (exit $rc)"; else fail "$2: exit $rc, wanted $1"; fi
}
want_text() { # <text> <description>
	if printf '%s' "$out" | grep -qF -- "$1"; then
		pass "$2"
	else
		fail "$2: no '$1' in output: $(printf '%s' "$out" | tr '\n' '|')"
	fi
}

# A clean checkout to plant failures in: a clone, so git ls-files sees the fixtures, plus the
# working copy of the script under test — the clone cannot carry a file that is not committed yet.
tree=$work/tree
git clone -q "$root" "$tree"
cp "$root/scripts/ci-local.sh" "$tree/scripts/ci-local.sh"
chmod +x "$tree/scripts/ci-local.sh"
git -C "$tree" config user.email worker@example.invalid
git -C "$tree" config user.name worker
commit() { git -C "$tree" add -A && git -C "$tree" commit -q -m "$1"; }
head_sha=$(git -C "$tree" rev-parse --short HEAD)

# A shellcheck stand-in: the suite must not depend on the reviewer's install, and a linter
# that always says "error" is the only way to prove a finding is printed.
stub=$work/stub
mkdir -p "$stub/clean" "$stub/dirty" "$stub/none"
cat >"$stub/clean/shellcheck" <<'STUB'
#!/usr/bin/env bash
case ${1:-} in --version) echo "version: 0.0.0-stub"; exit 0 ;; esac
exit 0
STUB
cat >"$stub/dirty/shellcheck" <<'STUB'
#!/usr/bin/env bash
case ${1:-} in --version) echo "version: 0.0.0-stub"; exit 0 ;; esac
echo "In scripts/ci-offline.sh line 2:"
echo "  the stub found a real error"
exit 1
STUB
chmod +x "$stub/clean/shellcheck" "$stub/dirty/shellcheck"
# `min`: a PATH with the commands the script needs and no shellcheck at all, so the
# "linter absent" case is a real absence rather than a faked one.
mkdir -p "$stub/min"
for c in bash git node wc tr sed head tail grep awk cat dirname readlink env sort uniq cut; do
	p=$(command -v "$c") || continue
	ln -sf "$p" "$stub/min/$c"
done
if PATH="$stub/min" command -v shellcheck >/dev/null 2>&1; then
	printf 'setup: shellcheck is on the minimal PATH; the absent-linter case proves nothing\n' >&2
	exit 2
fi

# A. --list names the four jobs, and nothing else runs.
run "$tree" --list
want_rc 0 "--list"
want_text "syntax (bash -n, node --check)" "--list names the syntax job"
want_text "lint (shellcheck)" "--list names the lint job"
want_text "offline behaviour (no ollama, no herdr-app)" "--list names the offline job"
want_text "docs budget (AGENTS.md size)" "--list names the docs job"
if [ "$(printf '%s\n' "$out" | grep -c .)" = 4 ]; then
	pass "--list prints four lines and runs nothing"
else
	fail "--list printed $(printf '%s\n' "$out" | grep -c .) lines, wanted 4"
fi

# B. A clean tree passes, and the last line carries the commit.
RUN_PATH=$stub/clean:$PATH
run "$tree" --only syntax,lint,docs
want_rc 0 "clean tree, three jobs"
want_text "pass" "clean tree prints a pass line"
want_text "commit $head_sha" "last line names the commit it ran against"

# C. Planted failures fail, and say where.
printf 'if [ 1 -eq 1 ]; then\n\techo hi\n' >"$tree/bin/broken.sh" # no fi: bash -n refuses it
printf 'const = ;\n' >"$tree/bin/broken.mjs"
commit "fixture: two planted syntax errors"
run "$tree" --only syntax
want_rc 1 "planted bash syntax error exits non-zero"
want_text "bin/broken.sh" "the failing bash file is named"
want_text "syntax error" "bash -n's own error line is shown"
run "$tree" --only syntax
want_text "bin/broken.mjs" "the failing ESM file is named"
git -C "$tree" rm -q bin/broken.sh bin/broken.mjs
commit "fixture: drop the syntax errors"

head -c 9000 /dev/zero | tr '\0' 'x' >"$tree/AGENTS.md"
commit "fixture: AGENTS.md over budget"
run "$tree" --only docs
want_rc 1 "AGENTS.md over budget exits non-zero"
want_text "9000 B / 8192 B" "the byte count and the ceiling are printed"
git -C "$tree" checkout -q -- AGENTS.md

# D. Lint: a finding is shown, and an absent linter is a skip with a non-zero exit.
RUN_PATH=$stub/dirty:$PATH
run "$tree" --only lint
want_rc 1 "shellcheck findings exit non-zero"
want_text "the stub found a real error" "shellcheck's own output is printed"
run "$tree" --only lint
want_text "scripts/ci-offline.sh" "the file shellcheck named is shown"

out=$(cd "$tree" && env PATH="$stub/min" bash scripts/ci-local.sh --only lint 2>&1)
rc=$?
want_rc 1 "shellcheck absent exits non-zero"
want_text "SKIPPED, not passed" "shellcheck absent says SKIPPED, not passed"

# E. The offline job runs the real script and inherits its exit code. The stub is what keeps
#    this suite from running the offline suite, which would run this suite.
RUN_PATH=$PATH
printf '#!/usr/bin/env bash\necho "offline behaviour: ok"\nexit 0\n' >"$tree/scripts/ci-offline.sh"
commit "fixture: stub ci-offline"
run "$tree" --only offline
want_rc 0 "offline job passes when the script passes"
want_text "offline behaviour: ok" "the offline job shows the script's own last line"
printf '#!/usr/bin/env bash\necho "  FAIL  jev ask, model down: exit 0, wanted 3"\nexit 1\n' >"$tree/scripts/ci-offline.sh"
commit "fixture: failing ci-offline"
run "$tree" --only offline
want_rc 1 "offline job fails when the script fails"
want_text "jev ask, model down" "the offline failure line is printed, not just FAIL"

printf '\n%s\n' "$([ "$fails" = 0 ] && echo "ci-local: ok" || echo "ci-local: $fails failure(s)")"
[ "$fails" = 0 ]
