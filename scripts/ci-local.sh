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
#   bash scripts/ci-local.sh --jobs 2           at most two jobs at a time (default: one per
#                                               selected job, capped at 4; --jobs 1 is serial)
#
# The jobs are independent — none reads another's output — so more than one runs at a time. Their
# output is buffered per job and printed in the order the jobs are listed, never in the order they
# finish, so a transcript reads the same as the serial one. Wall clock per job and for the whole
# run is printed, which is how the win is seen and a slow job is named.
#
# The `offline` job is the expensive one: it runs the repo's own test scripts. Those go through
# bin/receipts.sh, the ledger `bin/preflight` writes, so a script already answered on this tree is
# read instead of run — in either direction, since `preflight`'s `suites` check reads what this
# wrote. The job's line carries the split, and so does the summary:
#
#   pass offline behaviour (no ollama, no herdr-app)   83s  offline behaviour: ok (20 cached, 2 ran)
#   ci-local: 4/4 passed at commit abc1234 (main) in 83700ms, slowest: offline 83s; offline: 20 cached, 2 ran
#
# --fresh bypasses the ledger and empties it, so the next run cannot reuse what this one refused to.
# A `--jobs` that is 0 or not a number is a usage error (exit 2), never a silent serialise, and a
# bare `--only <one job>` stays the serial path: no temp dir, no buffered transcript.
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
	printf 'usage: bash scripts/ci-local.sh [--only JOB]... [--jobs N] [--fresh] [--list]\n' >&2
	printf 'jobs: %s\n' "${job_ids[*]}" >&2
	exit 2
}

selected=()
jobs_cap=""
while [ $# -gt 0 ]; do
	case $1 in
	--list)
		for n in "${job_names[@]}"; do printf '%s\n' "$n"; done
		exit 0
		;;
	--jobs)
		[ $# -ge 2 ] || usage
		jobs_cap=$2
		shift 2
		;;
	--jobs=*)
		jobs_cap=${1#--jobs=}
		shift
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

# One job at a time unless asked otherwise; never more slots than there are jobs to run, never
# more than four, and a bad --jobs is a usage error rather than a silent serialise.
case $jobs_cap in
'' ) [ "${#selected[@]}" -gt 4 ] && jobs_cap=4 || jobs_cap=${#selected[@]} ;;
0 | *[!0-9]*) printf 'ci-local: --jobs wants a positive number, not %s\n' "$jobs_cap" >&2; usage ;;
*) : ;;
esac
[ "$jobs_cap" -gt 4 ] && jobs_cap=4
[ "$jobs_cap" -gt "${#selected[@]}" ] && jobs_cap=${#selected[@]}
[ "$jobs_cap" -lt 1 ] && jobs_cap=1

# start <id> — run one job in the background, its transcript and "<rc> <ms>" into $tmp. Nothing is
# printed until every job has finished, so two jobs can never interleave a line of output.
start() {
	(
		local s e r
		s=$(date +%s%N)
		job_"$1" >"$tmp/$1.out" 2>&1
		r=$?
		e=$(date +%s%N)
		printf '%s %s\n' "$r" "$(((e - s) / 1000000))" >"$tmp/$1.status"
	) &
}

# emit <id> <rc> <ms> <transcript> — one line per check: verdict, job name, its wall clock, then the
# detail that makes it useful. A failure keeps its whole transcript under the line, indented. The
# split the ledger answered is parsed here too, off ci-offline's own last line, so both dispatch
# paths report it: a warm run must not read as a full one.
emit() {
	local id=$1 rc=$2 ms=$3 out=$4
	case $id in
	offline) offline_split=$(printf '%s' "$out" | sed -nE 's/.*\(([0-9]+ cached, [0-9]+ ran)\).*/\1/p') ;;
	esac
	if [ "$rc" = 0 ]; then
		printf '%-4s %-45s %4ss  %s\n' pass "$(name_of "$id")" "$((ms / 1000))" "$out"
	else
		fails=$((fails + 1))
		printf '%-4s %-45s %4ss  %s\n' FAIL "$(name_of "$id")" "$((ms / 1000))" "exit $rc"
		printf '%s\n' "$out" | sed 's/^/  /'
	fi
	time_pairs+=("$ms $id")
}

fails=0
ran=0
time_pairs=()
wall_start=$(date +%s%N)
if [ "$jobs_cap" -le 1 ]; then
	# Serial, exactly as before: one job at a time, its output printed before the next starts. No
	# temp dir: this is the path a small box or `--only` takes, and it needs nothing a bare PATH
	# cannot offer.
	for id in "${selected[@]}"; do
		ran=$((ran + 1))
		s=$(date +%s%N)
		out=$(job_"$id" 2>&1)
		rc=$?
		e=$(date +%s%N)
		emit "$id" "$rc" "$(((e - s) / 1000000))" "$out"
	done
else
	# Every job started together, at most $jobs_cap at a time; a finished job frees its slot.
	tmp=$(mktemp -d) || {
		printf 'ci-local: cannot create a temp dir for the job transcripts\n' >&2
		exit 1
	}
	trap 'rm -rf "$tmp"' EXIT
	pids=()
	for id in "${selected[@]}"; do
		ran=$((ran + 1))
		while [ ${#pids[@]} -ge "$jobs_cap" ]; do
			wait "${pids[0]}" 2>/dev/null || true
			pids=("${pids[@]:1}")
		done
		start "$id"
		pids+=($!)
	done
	for p in "${pids[@]}"; do wait "$p" 2>/dev/null || true; done
	# Printed in the order the jobs are listed, never in the order they finished.
	for id in "${selected[@]}"; do
		rc=1
		ms=0
		[ -f "$tmp/$id.status" ] && read -r rc ms <"$tmp/$id.status"
		out=""
		[ -f "$tmp/$id.out" ] && out=$(cat "$tmp/$id.out")
		emit "$id" "$rc" "$ms" "$out"
	done
fi
wall_end=$(date +%s%N)
wall_ms=$(((wall_end - wall_start) / 1000000))

sha=$(git rev-parse --short HEAD 2>/dev/null || printf 'unknown')
branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || printf 'unknown')
slowest=""
for pair in "${time_pairs[@]}"; do
	[ -z "$slowest" ] && slowest=$pair
	[ "${pair%% *}" -gt "${slowest%% *}" ] && slowest=$pair
done
line="ci-local: $((ran - fails))/$ran passed at commit $sha ($branch) in ${wall_ms}ms"
[ -n "$slowest" ] && line="$line, slowest: ${slowest#* } $(( ${slowest%% *} / 1000 ))s"
# The ledger's answer, when the offline job ran: appended last so "2 ran in 12345ms" can never be
# read as one clause.
line="$line${offline_split:+; offline: $offline_split}"
printf '\n%s\n' "$line"
[ "$fails" = 0 ]
