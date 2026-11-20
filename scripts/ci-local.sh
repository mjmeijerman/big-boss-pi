#!/usr/bin/env bash
# ci-local.sh — run the four jobs of .github/workflows/ci.yml against this checkout.
#
# GitHub Actions cannot start a job on this repo (account billing), so the four checks in that
# workflow only happen when a person types them. This is that person, as one command: same file
# lists, same commands, same verdicts, non-zero when any job fails.
#
# This script is the *copy*. The `git ls-files` lists below mirror the ones in
# .github/workflows/ci.yml; if the workflow's list changes, this script is the thing that must
# change with it. Do not grow a second copy of the list anywhere else.
#
#   bash scripts/ci-local.sh                    all four jobs, exit 0 only when all pass
#   bash scripts/ci-local.sh --only lint        one job (repeatable, or comma-separated)
#   bash scripts/ci-local.sh --fresh            ignore every receipt, empty the ledger
#   bash scripts/ci-local.sh --list             the four job names, nothing run
#
# The `offline` job is the expensive one: it runs the repo's own test scripts. Those go through
# bin/receipts.sh, the ledger `bin/preflight` writes, so a script already answered on this tree is
# read instead of run — in either direction, since `preflight`'s `suites` check reads what this
# wrote. The job's line carries the split, and so does the summary:
#
#   pass offline behaviour (no ollama, no herdr-app)    offline behaviour: ok (20 cached, 2 ran)
#   ci-local: 4/4 passed at commit abc1234 (main); offline: 20 cached, 2 ran
#
# --fresh bypasses the ledger and empties it, so the next run cannot reuse what this one refused to.
#
# No colour, no progress bars: the output is meant to be pasted into a report.
set -uo pipefail

root=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd)
cd -- "$root" || exit 1

agents_md_limit=${AGENTS_MD_LIMIT:-8192}
fresh=0
offline_split=""

# The same two lists the workflow builds. Kept here, deliberately, in one place.
bash_files() { git ls-files 'bin/*' 'scripts/*.sh' ':!bin/*.mjs'; }
esm_files() { git ls-files 'bin/*.mjs'; }

first_lines() { head -n "${1:-3}" | sed 's/^/    /'; }

# --- job: syntax (bash -n, node --check) -------------------------------------------------------

job_syntax() {
	local f out rc=0 nb=0 nm=0
	local -a files mods
	mapfile -t files < <(bash_files)
	mapfile -t mods < <(esm_files)
	for f in "${files[@]}"; do
		nb=$((nb + 1))
		if ! out=$(bash -n "$f" 2>&1); then
			rc=1
			printf '%s:\n%s\n' "$f" "$(printf '%s\n' "$out" | first_lines 3)"
		fi
	done
	for f in "${mods[@]}"; do
		nm=$((nm + 1))
		if ! out=$(node --check "$f" 2>&1); then
			rc=1
			printf '%s:\n%s\n' "$f" "$(printf '%s\n' "$out" | first_lines 3)"
		fi
	done
	[ "$rc" = 0 ] && printf 'bash -n: %d files, node --check: %d files\n' "$nb" "$nm"
	return $rc
}

# --- job: lint (shellcheck) --------------------------------------------------------------------

job_lint() {
	local f out rc=0 version
	local -a files
	mapfile -t files < <(bash_files)
	if ! command -v shellcheck >/dev/null 2>&1; then
		# The workflow treats absent shellcheck as a skip and stays green; here it must not,
		# or a machine without the linter reads as a passing lint.
		printf 'shellcheck is not on PATH: lint SKIPPED, not passed (install it: apt-get install shellcheck)\n'
		return 1
	fi
	version=$(shellcheck --version 2>/dev/null | awk '/^version:/ { print $2; exit }')
	if ! out=$(shellcheck --severity=error "${files[@]}" 2>&1); then
		rc=1
		printf '%s\n' "$out" | first_lines 12
	fi
	[ "$rc" = 0 ] && printf 'shellcheck %s, --severity=error, %d files\n' "${version:-?}" "${#files[@]}"
	return $rc
}

# --- job: offline behaviour (no ollama, no herdr-app) ------------------------------------------

job_offline() {
	local out rc last
	local -a extra=()
	# Only an explicit --fresh is forwarded: `fresh=0` is a set variable, and a bare `${fresh:+…}`
	# would have handed the offline suite --fresh on every ordinary run.
	[ "$fresh" = 1 ] && extra=(--fresh)
	if [ ! -f scripts/ci-offline.sh ]; then
		printf 'scripts/ci-offline.sh is missing\n'
		return 1
	fi
	out=$(bash scripts/ci-offline.sh ${extra[@]+"${extra[@]}"} 2>&1)
	rc=$?
	last=$(printf '%s\n' "$out" | tail -n 1)
	if [ "$rc" != 0 ]; then
		printf '%s\n' "$out" | grep -E '^  FAIL|failure' | first_lines 12
		[ -n "$out" ] && printf 'last lines:\n%s\n' "$(printf '%s\n' "$out" | tail -n 5 | sed 's/^/    /')"
	else
		printf '%s\n' "$last"
	fi
	return $rc
}

# --- job: docs budget (AGENTS.md size) ---------------------------------------------------------

job_docs() {
	local bytes
	if [ ! -f AGENTS.md ]; then
		printf 'AGENTS.md is missing\n'
		return 1
	fi
	bytes=$(wc -c <AGENTS.md | tr -d '[:space:]')
	printf 'AGENTS.md: %s B / %s B\n' "$bytes" "$agents_md_limit"
	[ "$bytes" -le "$agents_md_limit" ]
}

# --- dispatch ---------------------------------------------------------------------------------

job_ids=(syntax lint offline docs)
job_names=(
	"syntax (bash -n, node --check)"
	"lint (shellcheck)"
	"offline behaviour (no ollama, no herdr-app)"
	"docs budget (AGENTS.md size)"
)

name_of() {
	local i
	for i in "${!job_ids[@]}"; do
		[ "${job_ids[$i]}" = "$1" ] && { printf '%s' "${job_names[$i]}"; return 0; }
	done
	return 1
}

# resolve <selector> — job id, or the workflow's job key, or the job name.
resolve() {
	local s=$1 i
	for i in "${!job_ids[@]}"; do
		[ "$s" = "${job_ids[$i]}" ] && { printf '%s' "${job_ids[$i]}"; return 0; }
		[ "$s" = "${job_names[$i]}" ] && { printf '%s' "${job_ids[$i]}"; return 0; }
	done
	[ "$s" = docs-budget ] && { printf 'docs'; return 0; }
	return 1
}

usage() {
	printf 'usage: bash scripts/ci-local.sh [--only JOB]... [--fresh] [--list]\n' >&2
	printf 'jobs: %s\n' "${job_ids[*]}" >&2
	exit 2
}

selected=()
while [ $# -gt 0 ]; do
	case $1 in
	--list)
		for n in "${job_names[@]}"; do printf '%s\n' "$n"; done
		exit 0
		;;
	--only)
		[ $# -ge 2 ] || usage
		IFS=, read -r -a parts <<<"$2"
		for p in "${parts[@]}"; do
			[ -n "$p" ] || continue
			id=$(resolve "$p") || {
				printf 'ci-local: no such job: %s\n' "$p" >&2
				usage
			}
			selected+=("$id")
		done
		shift 2
		;;
	--only=*)
		IFS=, read -r -a parts <<<"${1#--only=}"
		for p in "${parts[@]}"; do
			[ -n "$p" ] || continue
			id=$(resolve "$p") || {
				printf 'ci-local: no such job: %s\n' "$p" >&2
				usage
			}
			selected+=("$id")
		done
		shift
		;;
	--fresh) fresh=1; shift ;;
	-h | --help) usage ;;
	*) usage ;;
	esac
done

if [ ${#selected[@]} -eq 0 ]; then
	selected=("${job_ids[@]}")
fi

fails=0
ran=0
for id in "${selected[@]}"; do
	ran=$((ran + 1))
	out=$(job_"$id" 2>&1)
	rc=$?
	# What the ledger answered and what it did not, read off ci-offline's own last line — the job
	# runs in a subshell here, so the split is parsed here and the summary repeats it: a warm run
	# must not read as a full one.
	case $id in
	offline) offline_split=$(printf '%s' "$out" | sed -nE 's/.*\(([0-9]+ cached, [0-9]+ ran)\).*/\1/p') ;;
	esac
	if [ "$rc" = 0 ]; then
		verdict=pass
		detail=$out
	else
		verdict=FAIL
		fails=$((fails + 1))
		detail="see below"
	fi
	# One line per check: verdict, job name, then the detail that makes it useful.
	if [ "$verdict" = pass ]; then
		printf '%-4s %-45s %s\n' "$verdict" "$(name_of "$id")" "$detail"
	else
		printf '%-4s %-45s %s\n' "$verdict" "$(name_of "$id")" "exit $rc"
		printf '%s\n' "$out" | sed 's/^/  /'
	fi
done

sha=$(git rev-parse --short HEAD 2>/dev/null || printf 'unknown')
branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || printf 'unknown')
printf '\n%s\n' "ci-local: $((ran - fails))/$ran passed at commit $sha ($branch)${offline_split:+; offline: $offline_split}"
[ "$fails" = 0 ]
