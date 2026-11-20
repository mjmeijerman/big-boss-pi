# big-boss-pi

The delegation hub. Every request goes through the Herdr space that owns the project; the boss
there asks Jev the route and the mode, spawns **one** worker as a tab in its own space, reads the
report, publishes it as a pull request and hands it over to be merged. The boss does not do project
work itself, and a worker never publishes.

This workspace replaced `pi-master`. The old tree at `~/pi-master` is the rollback
copy: read-only during the transition, deleted only when the user says so.

## A space is a project

A space is one project, and it outlives its terminals: the record at
`~/.pi/state/spaces/<slug>/space.json` keeps the name, the project folder and the sessions the tabs
had, so a later worker reopens the tab and reads where the work goes. `bin/space new|list|show|forget`
makes and reads them, and the `durable` mod (`alt-shift-d`) is the same three views: New, Forget,
List. Work for another project is handed back to the person with the space that owns it, never
started here.

```
~/.pi/bin/space new --name harness --project ~/big-boss-pi
```

## What is wired where

| piece | path | why there |
|---|---|---|
| The rules every agent here loads | `$PI_BOSS_ROOT/AGENTS.md` | Pi loads `AGENTS.md` from the working directory and every parent, on every start, with no project trust needed. New or reloaded agents therefore start with the same knowledge |
| Decision model | `bin/jev` → `~/.local/bin/jev` | TypeSafe's Jev on api.typesafe.ai, one typed request with a calibrated probability per question; decides mode, route, thinking effort and permissions (a spawn no longer asks it a worker count: one space, one worker) |
| Local worker | `bin/local-run` | runs a local task on the ollama model (`bin/local-model.mjs`), headless: prompt in, answer on stdout, no space and no spec, no network; records one line in `state/usage.jsonl` |
| Spaces | `bin/space` → shim onto `~/.pi/bin/space` | `new`/`list`/`show`/`forget` over `~/.pi/state/spaces/<slug>/space.json`; `delegate` reads the space from the folder it runs in and refuses in a folder no space claims |
| Delegation | `bin/delegate` → shim onto `~/.pi/bin/delegate` | one jev call for mode, route and thinking effort, one worker as a tab in this space, the spec, where the report lands, and every decision in the space's `decisions.jsonl`; `delegate finish` runs preflight, publish, wipe and close in that order |
| Worker modes | `bin/pi-bare`, `bin/pi-sandboxed`, `bin/pi-nonet` | `delegate` picks one from Jev's answer. All three find pi the same way, at runtime (`bin/pi-resolve.sh`: `$PI_BIN`, `PATH`, `$PNPM_HOME`, `$HOME`, `%APPDATA%`), so none of them carries a home directory; on native Windows the two sandboxed modes refuse with the WSL2 line instead of running bare |
| Preflight | `bin/preflight` | the checks CI would run, on this branch, here: that the branch's base is not behind a just-fetched `origin/<trunk>` (a branch cut before a pull request merged arrives `CONFLICTING`; the check names the count, the colliding paths and the rebase, and an unreachable origin is a named pass), `bash -n`/`node --check` on the changed files, the repo's own suite, semgrep over the changed files, the changed tests under a scrubbed `env -i`, and the body gate on the exact body `bin/publish` would send. `delegate finish` runs it before the publish, and no push happens past a failing check |
| Spaces and the guard | `bin/guard` → shim onto `~/.pi/bin/guard`, started by `systemd/big-boss-pi-guard.service` | one pass every 20 seconds over every recorded space: a vanished space is rebuilt from its record (its own name, project folder and Boss tab name), the Boss tab is resumed from its own session entry, and nothing is ever closed, renamed or moved. A worker's tab is not the guard's business — `delegate wait --forever` restarts a dead worker, and a finished one stays closed. It reports a space whose project folder is gone and names `bin/space forget <slug>`; it never touches a space named `pi-master` |
| Delegation-only enforcement | `~/.pi/agent/extensions/big-boss-pi-guard.ts` | blocks the `write` and `edit` tools, and shell writes into the directory (`echo x > …`, `rm/mv/cp/tee/sed -i`), when the session's cwd is under this workspace **or** under `~/pi-master`; no-ops everywhere else, including for a worker session (`PI_WORKER=1`) |
| Rollback helper | `bin/finish-rename.sh` | closes the old `pi-master` space on request and prints how to delete the old tree. Runs nothing by default |

## Paths and the environment variable

Every script lives on its own tree: it resolves the workspace root from its own location, so it
works from any cwd and when sourced. `PI_BOSS_ROOT` overrides the root; `PI_MASTER_ROOT` is
still accepted as a deprecated fallback.

`bin/publish`, `bin/jev` and `bin/local-run` are bash programs, so they resolve bash at runtime
(`bin/shell-resolve.sh`) and re-exec themselves under it — a shebang is not a promise on Windows.
`bin/delegate`, `bin/guard` and `bin/space` are `/bin/sh` shims: they exec the same-named tool in
`~/.pi/bin` and exit 127 with one line naming it when it is not installed, so a moved tool never
looks like a broken one. `PI_GIT_BASH=/path/to/bash.exe` sets it explicitly, ahead of a `bash` on `PATH`;
with none found they print `no bash found — set PI_GIT_BASH=/path/to/bash.exe` and exit 127.

## Routing: decide before you work

The first question is not "how many workers" but "is this work at all". `jev route "<task>"`
answers `local` or `remote`:

- `local` — summarise, classify, extract, tidy, translate, format, short mechanical rewrites
  with no repo knowledge and no tools. Run `bin/local-run "<task>"`; it prints the answer and
  records one line in `state/usage.jsonl`. Exit 0 = local, 1 = remote, 3 = unsure, so it drops straight into `if`.
- `remote` — code changes, debugging, design decisions, multi-file reasoning, anything that
  needs tools, tests or a repo. Go through `delegate spawn`.

`delegate spawn` asks the route itself and records it. A `local` answer refuses the spawn: it
prints the exact `bin/local-run` command to run instead, and forcing a remote worker needs
`--override-jev --reason '<why this cannot run locally>'`, recorded like any override. The
route also lands on the spec header, next to the mode: "Mode: sandboxed (chosen by jev),
route: remote (jev)", so a worker can tell what it was supposed to be.

```
jev route "summarise reports/foo.md in three bullets"   # → local  (exit 0)
markdown notes.txt | bin/local-run                       # the answer on stdout
jev route "add retries to the fetch client"              # → remote (exit 1)
```

## The decision model: one key, one threshold

`bin/jev` asks TypeSafe's Jev at `https://api.typesafe.ai/v1/systemone` — one typed request per
question, four for a `plan`, each answered with the probability of every option. **It needs
network now**; `bin/local-run` does not, it is still the ollama model on this machine.

- The key: `TYPESAFE_API_KEY`, or the `TYPESAFE_API_KEY=` line of `JEV_KEY_FILE` (default
  `~/.pi/agent/env.secret`) when the variable is unset. It is never printed, never logged, never
  in a URL. A missing key, a 401, a 403, a timeout and a malformed answer are all exit 3 with one
  line on stderr that names the cause and not the key.
- The threshold: `JEV_MIN_CONFIDENCE`, default `0.5`. A Choice acts when the chosen option's
  probability reaches it; a Noul when `|2p−1|` does, which is p outside 0.25..0.75. `0.6` is the
  stricter reading, and it stopped four of eight ordinary tasks as unsure when measured, all on
  count or thinking — the two questions with four and three neighbours.
- The knobs, all env-overridable: `JEV_ENDPOINT`, `JEV_MODEL` (default `jev-latest`), `JEV_TIMEOUT`
  (20000 ms). The local half has its own: `LOCAL_ENDPOINT`, `LOCAL_MODEL`, `LOCAL_TIMEOUT`,
  `LOCAL_KEEP_ALIVE`.

## Is the local model actually used?
`delegate stats` answers that in one line instead of by inference:

```
delegate stats                    # last 7 days, one screen
delegate stats --since 24h        # 24h, 90m, 2w — <number><s|m|h|d|w>
delegate stats --json | jq .      # the same numbers, machine-readable
```

It prints jev calls per command (`ask`, `route`, `mode`, `count`, `thinking`, `plan`), the route,
mode and thinking splits, how often a caller overruled jev and at what rate, the local-run
invocation count with total and median latency, and the line everything else is there for:

```
local work path: 4 invocations (last: 2026-11-13T20:41:02.115Z)
local work path: never used
```

Two append-only files under `state/` feed it, and neither is committed (`state/` is ignored).
`state/decisions.jsonl` is what jev decided, one line per decision, carrying jev's own answer
in `jev` so `overridden` can be checked rather than trusted: it is true only on the line whose
decision `--override-jev` actually overturned. Older rows put that flag on all four lines of
an overridden spawn, so `delegate stats` counts them as legacy instead of re-reading them.

`state/usage.jsonl` is what the models did, one line per call from `bin/jev` or
`bin/local-run`: timestamp, kind, subcommand, model id, latency, whether it answered, the
error class when it did not, and the caller's slug or context. **Not** logged: environment
variables, credentials, endpoints, and the whole task text — only the first 200 characters,
with key-shaped tokens redacted. The answer itself is never logged. Recording cannot break a
call: a failed write is swallowed.

The same screen carries the jev scorecard: per decision kind (`mode`, `count`, `route`,
`thinking`, `permit`) how many rows carry jev's own answer, how many are unknown, how many were
overridden, the override rate, and how many rows carried a field jev defaulted. A row
written before the `jev` field existed is unknown and stays out of the rate — it is never
agreement. The spawn cap — `in-flight` — is not a jev answer at all: the branch diff decides it
(the worker's branch paths against the paths the task names, in `bin/delegate`), so it gets its
own line saying how many cap checks were recorded, what each decided, and how many refused a
spawn. Folded into the table it printed `0/24 … —`, which reads as a guard that never decides.

**There is no agreement rate, and the screen says so.** A spawn that does not pass
`--override-jev` copies jev's answer into the decision, so `decision` equals `jev` on every such
row by construction; a percentage computed from that measures nothing. What the scorecard prints
is the override rate — how often a person overruled jev, out of rows of that kind — plus the rows
where jev filled a field in under the caller (the `defaults` list `delegate spawn` already wrote
and nothing read), plus the `permit` answers, which are logged to `state/decisions.jsonl` by
`bin/jev.mjs` and scored as recorded-but-unscored: permit has no person's counter-answer in the
log yet, so nothing can check it. Below that, every override is listed per slug with its reason
and whether the worker produced a report: **an override that ended with no report ended with no
PR, and that is jev's answer being right**.

## Jev gates every delegation

`delegate spawn` asks Jev once on every run — `jev plan` answers the route, the mode and the thinking
effort together, for the exact task text — and records them as the decision lines it always did. The
worker count is not one of Jev's decisions any more: one spawn starts one worker in one space, and a
task that needs three is three spaces, started when the one before has merged. A `--mode` or
`--thinking` from the caller is accepted only when it matches Jev's answer. A different one aborts the spawn and prints Jev's answer and its reason; overturning it needs
`--override-jev --reason '<why>'`, and the override is recorded on that decision's own line. A `local`
route aborts the same way, pointing at `bin/local-run`. A field Jev answers only weakly takes the
conservative default (mode sandboxed, route remote, thinking medium), the spawn says which field
defaulted and the decision line records it; an unoffered answer or a dead model still stops the spawn
unless `--override-jev` carries a reason.

Review sets the pace. A new worker is refused while a pull request of this space is unmerged — the
PR is named, with the merge that unblocks it — and while an unread report's branch diff meets a path
the new task names. `delegate stats` prints the unread queue and the age of its oldest report.

Thinking is split in two, because the two halves are different facts. Jev answers an *effort* —
`low`, `medium` or `high` — which is a fact about the task. Which levels the worker's model supports
is a fact about the model, so `~/.pi/bin/delegate` reads it from your pi config: `settings.json` names
the model a fresh `pi` starts with, and `models.json` or the generated `models-store.json` carries that
model's `reasoning` flag and `thinkingLevelMap` (`null` marks a level the model does not support). The
effort goes to the nearest supported level, ties to the lower one, and the worker starts with `pi
--thinking <level>`. A non-reasoning model gets `off`; if the catalogue cannot be read the effort name
is passed through and pi clamps it. On this machine `deepseek/deepseek-flash` supports `off`, `low`,
`high`, `max`, so `medium` lands on `low`. The spec header and `delegate list` both show the level.

Each decision is one line in the space's `decisions.jsonl`:
`{"timestamp":…,"command":"mode"|"route"|"thinking"|"ask","task":…,"decision":…,"reason":…,"overridden":true|false,"slug":…}`.
`delegate list` shows Jev's mode, route and thinking level for each worker in this space.

## Ask Jev before you ask the user

The user is the tie-breaker, not the first responder. `delegate ask "<question>"` puts a
question to Jev first and records it in the same audit file:

```
delegate ask "should the retry loop ship as-is?"   # exit 0 yes, 1 no, 3 unsure
```

Exit 0 or 1 is an answer: act on it and do not interrupt the user. Only exit 3 — Jev unsure, or
the model unreachable — belongs to the user, and then it carries Jev's reason in one line:
`jev is unsure — <reason>`. `AGENTS.md` states the rule; the command makes it checkable.

## One worker at a time

A worker is a tab in this space, not a space of its own (`kind: "tab"` in the space's
`delegations.json`). `delegate spawn` refuses a second live worker here: one report is the only
context the boss can read. It also refuses on a git project while one of this space's pull requests
is unmerged, naming the PR.

`delegate spawn` guarantees the base before it starts the tab. A sandboxed worker cannot `git fetch`
(the sandbox refuses the ssh config's ownership), so its `origin/<trunk>` is whatever was last
fetched on the host — a branch cut from that ships a PR against an old trunk. So the boss fetches the
`--cwd` repo itself, takes the default branch from `origin/HEAD` (falling back to `trunk`, `main`,
`master`), and fast-forwards the local trunk only when it is clean and strictly behind. A dirty tree,
an ahead trunk or a diverged one refuses the spawn and prints the exact state and the command that
fixes it; nothing is reset, rebased or forced. A `--cwd` that is not a git repo, or has no origin, is
skipped with one line.

Every worker branch ends in a pull request, and the worker never publishes it: it commits on its
branch and stops, with no push and no `gh pr create`, no fallback and no "try it and see". The report
carries the branch name, the commit sha and the review tier. The boss uploads the branch and opens the
PR against the repo's default branch — `git symbolic-ref --short refs/remotes/origin/HEAD`, `trunk` as
the fallback, never a hardcoded `main`. Because publishing is the boss's job, a worker stays
sandboxed: it needs neither an ssh agent nor `gh` auth. The report carries the PR URL once the boss has
opened it. A change with no PR is unfinished, however green it looks locally — merging stays the
human's call.

A worker cuts its own worktree inside the repo it works in (`git worktree add .worktrees/<slug> -b
<branch>`) and never switches the boss's live checkout: `delegate spawn` records that checkout's
branch, and `delegate close` warns, names both branches and checks the original back out when it
moved. Inside, because the sandbox binds the repo and not its parent: at `../<slug>-worktree` the
directory is created in the sandbox's own filesystem, dies with it, and leaves a `prunable` entry
behind.

The tab is not kept for browsing. The flow is: the worker writes `reports/<slug>.md` and stays idle,
the boss reads it with `delegate wait`, publishes it, and the tab is closed — `delegate finish <slug>`
does preflight, publish, wipe and close in that order. `delegate sweep` closes every worker whose
report is plain.

One marker overrides that. A report whose first line is `DECISION NEEDED: <question>` means the worker
cannot continue without the user, so the tab stays until the question is answered:

```
DECISION NEEDED: drop the old table or keep it for the migration?
```

The wipe step sits between the report and the close. `delegate wipe <slug>` prints five consolidation
questions — what did this feature make unnecessary and is that code deleted, what is duplicated, could
the next feature land in this area in 30 minutes, what did we learn, what would we rebuild from
scratch — and records the run in the space's `decisions.jsonl`. `delegate wipe <slug> --skip "<reason>"`
records why the step does not apply, reason included. A slug nobody spawned is refused, nonzero, and
named: a wipe that quietly does nothing is a wipe nobody can tell apart from a forgotten one.
`delegate close` and `delegate sweep` refuse a worker with no wipe line for it, so a finished feature
stops being a permanent addition by default. The answers belong in the worker's report under
`## Thrown away`.

## Publishing a finished worker

`delegate finish <slug>` is the boss's whole tail in one command: publish, wipe, close, in that
order. Four turns for one intent is where a step gets dropped, so the order is built in — each
step runs only because the one before it succeeded, and a failure stops the run, names the step,
and says which state the worker is in. Closed-but-unpublished is unreachable by construction.

```
delegate finish <slug>                  # publish, wipe, close
delegate finish <slug> --skip "<why>"   # same, with the wipe recorded as not applying
delegate finish <slug> --cwd <repo>     # a worker whose delegations.json entry is already gone
```

Before any of those, step 1 is the preflight: `bin/preflight` on the worker's branch, the
behind, syntax, suite, semgrep, scrub and body checks CI would run, each printed with its elapsed
time and, when one fails, the exact command that reproduces it. A failing check stops the run with
nothing pushed, nothing wiped and the space still open; `--skip-preflight "<why>"` records a
gate that cannot run on this machine, the way `--skip` records a wipe that does not apply.

```
delegate finish <slug> --skip-preflight "<why the gate cannot run here>"
```

The first of those checks is `behind`: a branch cut before a pull request merged publishes a
CONFLICTING one, so the gate fetches `origin` quietly and refuses when the merge base is not the
trunk tip — naming how many commits behind and which of the branch's own touched paths moved, with
the `git rebase origin/<trunk>` to run. It never rebases for you, and an origin it cannot reach is a
named pass ("could not reach origin; behind-ness unchecked"), because a gate that blocks on a
flaky network gets bypassed.

The same tree is checked twice per publish — the worker runs the gate to paste its Evidence block,
`delegate finish` runs it again before the push — so each verdict is recorded in `state/preflight/`
under the hash of everything it came from: the tree, the branch, the checkout, the check set, and
`bin/preflight`'s own hash. A second run on the same inputs prints the verdict, says it is cached,
and runs nothing (the summary counts them: `5/5 passed (3 cached, 2 ran)`); `--fresh` ignores every
receipt and `PI_PREFLIGHT_CACHE_TTL` (default six hours, `0` disables) expires them. A cached FAIL
still blocks and still shows the transcript that failed, `behind` is never cached because its answer
is about origin rather than this tree, and a check a fast path skipped leaves no receipt to reuse.

They stay four gates. The publish is the same `bin/publish` (found on PATH, else next to
`bin/delegate`) with its Evidence and `Review tier:` checks; the wipe is the same `delegate wipe`
and now also refuses a report with no `## Thrown away` block, because a recorded step with no
answers behind it stands for nothing; the close is the same `delegate close` with its provenance
trailer check. Rerunning after a close refusal is clean: the existing PR is printed rather than
opened twice, and a wipe already recorded is kept rather than recorded again.

`bin/publish <slug>` is the one command between a reported worker and a pull request. It reads
the space's `delegations.json` for the slug's tree and report, then builds the PR body out of the report
itself: the Mission line verbatim, the `Review tier:` line reduced to its bare word (`Review
tier: **Medium**` and `Review tier: medium.` both reach the body as `Review tier: Medium`), the
`## Evidence` block,
and the `## Thrown away` section when the worker wrote one. The title is the branch HEAD's
subject. That is why the tier cannot be forgotten — nothing is retyped.

```
bin/publish <slug>
```

The space's `delegations.json` records the branch the boss checkout was on when the worker started, and a
worker cuts its own branch — so for most workers it says `trunk` or `main`. A trunk branch is
never published: `bin/publish` finds the worker's branch instead, by the commit carrying
`Agent-Slug: <slug>` on that branch. One match is the branch; none or several are refused rather
than guessed.

Closing a worker drops its `delegations.json` entry, so the report outlives the record that points
at it — publish first, then wipe, then close. A slug that is already closed still publishes with
`bin/publish <slug> --cwd <repo>`: with no entry to read, the repo comes from `--cwd` (default: the
git repository containing the current directory) and the branch from the same `Agent-Slug: <slug>`
trailer, with the same one-match rule. The report is still `reports/<slug>.md` under the boss root,
so the Evidence and `Review tier:` checks read exactly as they do for a live worker.

```
bin/publish <slug> --cwd <repo>
```

Before anything leaves the machine it runs the target repo's own body gate: `make pr-check
BODY=<file>`, `scripts/pr-gate.sh --body <file>` when only that exists, and it prints a skip when
neither does. When the `pr-check` recipe expands `BRANCH` — detected once with a `make -n` dry run
and a sentinel branch — the call also carries `BRANCH=<the worker's branch>`, because a gate that
diffs a named branch would otherwise compare the checkout (usually trunk) with itself and refuse
with `unverifiable: no changed files`; a recipe that never mentions it is called with `BODY` alone.
A red gate stops the publish. A PR that
already exists for the branch prints its URL instead of failing. Trunk is never pushed, and nothing
is merged — the merge stays yours. A branch a rebase rewrote is re-pushed under
`--force-with-lease` on the sha origin holds, because the `behind` check asks for that rebase; a
branch whose remote tip carries a commit this worker neither has nor rewrote is refused, with that
commit named, rather than forced.

It refuses, naming the reason, when the slug is unknown, the report is missing or has no
Evidence block (the same check `delegate close` uses), the report has no `Review tier:` line or
names a tier that is not High, Medium or Low, the branch carries no `Agent-Slug:` trailer, the
branch is not the one the delegation record names and the trailer did not find it either (both
names are printed, and nothing is pushed), `gh` is not on PATH, or the tree is not a git repo.

The pull request's state is read back, never assumed from the command's own output. The last line
of a publish is `published <slug>: #<n> now at <sha> (<state>, <mergeable>)` — `gh pr view --json
headRefOid,state,mergeable` — and a head sha that is still the old one after a few seconds of
re-read fails the publish, naming both shas, because a push GitHub does not show is not a publish.
A branch origin already holds at the worker's head prints `nothing new to push: #<n> is already at
<sha>` instead and still refreshes the body, and `delegate finish` then ends with `already
published` rather than `published`: a verdict over a branch that did not move is not a publish.

## Review gate

Every change must pass a five-minute comprehension check before it merges: a human reviewer must be able to answer "what does this change do?" in five minutes. If they cannot, the change is too large or too opaque and must be split or clarified.

Review is tiered by risk:

- **High** — `agent/extensions/`, `agent/AGENTS.md`, `.github/`, `git-hooks/`, `sandbox/`, and anything touching auth, secrets, money, or data deletion. Read line by line by the user. Never auto-merged.
- **Medium** — application code, tests, migrations. Diff read with green tests.
- **Low** — docs, comments, formatting, patch bumps. CI green plus a skim.

Formatting and indentation comments are out of scope for review; a formatter owns them, never a gate.

## Running the checks locally

`.github/workflows/ci.yml` has four jobs — `syntax`, `lint`, `offline`, `docs budget` — and when
GitHub Actions cannot start a job (billing, an outage), they otherwise happen only when a person
types them by hand. `bash scripts/ci-local.sh` is that hand: it runs the same four jobs, with the
same file lists and the same commands, against this checkout; it prints one `pass` / `FAIL` line
per job, showing the offending file and its own error output when one fails; it exits non-zero
when any of them fails; and its last line names the commit it ran against, the wall clock of the
run and the slowest job. The four jobs share no output, so a full run starts them together and
prints each job's buffered transcript in job order, with its own wall clock; `--jobs N` caps how
many run at once, and `--jobs 1` is the old serial run. The `offline` job answers from the receipt
ledger `bin/receipts.sh` keeps, and both its line and the summary say how much was reused
(`offline: 20 cached, 2 ran`); `--fresh` ignores that ledger and empties it for one run. `--only lint`
re-runs
one job after a one-line fix, `--list` names the four. It mirrors `.github/workflows/ci.yml` and
is the copy that must be updated when that workflow's file lists change — do not keep a second
copy elsewhere. `bash scripts/tests/test-ci-local.sh` proves it exits non-zero on a planted
failure and zero on a clean tree; `bash scripts/tests/test-ci-local-parallel.sh` proves two jobs
run side by side, print in job order, that a failing one does not lose another's transcript, and
that `--fresh --jobs 2` reports the split and the wall clock in the same run.
`ci-offline.sh` runs the first of those suites, so CI covers it too.

## Why a space cannot be lost

Herdr has no per-space lock: `space.close` ends a space and its terminals, and `herdr-app` offers no
hook to veto it. So the spaces are self-healing instead. `~/.pi/bin/guard` makes one pass every 20
seconds over every recorded space and puts back only what the record says:

- a space missing from `herdr-app ls` is rebuilt with its own name, project folder and Boss tab name;
- a Boss tab that is gone is started from its own resume entry (`~/.pi/agent/herdr-resume/<terminal>.json`,
  `<entry argv> --session <path>`), so the tab keeps its conversation across a restart or a reboot;
- a worker's tab is not the guard's business — `delegate wait --forever` restarts a dead worker, and a
  finished worker's tab stays closed;
- nothing is ever closed, renamed or moved, and a space whose project folder is gone is reported by
  name with `bin/space forget <slug>` as the fix;
- a forgotten space, and a space in Herdr with no record, are left alone: recreating what nobody
  recorded is how a program starts making spaces for people.

The service is `systemd/big-boss-pi-guard.service`; its `ExecStart` is the shim
`%h/big-boss-pi/bin/guard`, which execs `~/.pi/bin/guard`. `--once` runs exactly one pass (`--dry-run`
prints the plan and calls no `herdr-app` at all) and `--space <slug>` limits a pass to one space. The
suite that drives it against a stub `herdr-app` is the pi repo's
`scripts/tests/test-guard-supervisor.sh`.

## What the write guard does and does not cover

It covers the `write`/`edit` tools and the obvious shell writes into the directory. It is a
rule, not a sandbox: a program the agent runs (a script, a package manager) can still write
there, and the workspace agent runs bare because it must reach the Herdr sockets. The point is
that delegation is the path of least resistance, and a direct file edit fails loudly.

The guard covers the **boss session**, not the worker it spawned. `bin/pi-bare`,
`bin/pi-sandboxed` and `bin/pi-nonet` export `PI_WORKER=1` into the worker's environment, and
the guard returns early for such a session: a worker writes in the workspace it was given,
including this workspace root and its `specs`/`reports`. A session without `PI_WORKER` is
the boss and stays guarded exactly as before.

## Daily use

```
~/.pi/bin/space list                            # every space, its project, the guard's last line
~/.pi/bin/space show harness                    # one record: folder, tabs, the delegate command
herdr-app ls                                    # is the space there, and its Boss tab?
systemctl --user status big-boss-pi-guard       # is the supervisor alive?
delegate list                                   # this space's workers and their last jev decision
delegate stats                                  # is the local model used, and how often
delegate sweep                                  # close the ones that reported, keep the rest
tail -f reports/*.md                            # what workers reported
tail -2 state/spaces/<slug>/decisions.jsonl     # what jev decided
tail -2 state/usage.jsonl                       # what the models answered, and how fast
```

## Changing the rules

Edit `AGENTS.md`. Every agent in this space picks it up on its next start (`/reload` re-reads it in a
running session), and `bin/space new` also writes this project's own block between two markers, so a
re-run replaces it instead of growing a second copy. Rules you add here do not leak into other spaces
— they are context files of this directory only.

To change how delegation works, edit `~/.pi/bin/delegate` — a fix behind the shim is a fix that
disappears. To change what Jev weighs, edit the `POLICY` string in `bin/jev.mjs`. Both are plain
shell/JS, no build step.

## Turning it off

```
systemctl --user disable --now big-boss-pi-guard   # stop the self-healing
rm ~/.pi/agent/extensions/big-boss-pi-guard.ts     # stop the write guard
```
The space itself stays until you close it. `bin/finish-rename.sh --close-old-space` closes the
old `pi-master` space and prints the command that deletes the old tree.
