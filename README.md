# big-boss-pi

The delegation hub. Every request goes through the big-boss-pi Herdr space; agents there ask
Jev how many workers a task needs and in which mode, spawn them in their own spaces, and report
back. They do not do project work themselves.

This workspace replaced `pi-master`. The old tree at `/home/mark/pi-master` is the rollback
copy: read-only during the transition, deleted only when the user says so.

## What is wired where

| piece | path | why there |
|---|---|---|
| The rules every agent here loads | `/home/mark/big-boss-pi/AGENTS.md` | Pi loads `AGENTS.md` from the working directory and every parent, on every start, with no project trust needed. New or reloaded agents therefore start with the same knowledge |
| Decision model | `bin/jev` → `~/.local/bin/jev` | local qwen3.8:27b on ollama; decides worker count, mode, route, thinking effort, and permissions |
| Local worker | `bin/local-run` | runs a local task on the same model, headless: prompt in, answer on stdout, no space and no spec; records one line in `state/usage.jsonl` |
| Delegation | `bin/delegate` → `~/.local/bin/delegate` | asks Jev for mode, count, route and thinking effort, creates a Herdr space per worker, writes the spec, records where the report lands, appends every decision to `state/decisions.jsonl`; `delegate sweep` closes the workers that finished |
| Worker modes | `bin/pi-bare`, `bin/pi-sandboxed`, `bin/pi-nonet` | `delegate` picks one from Jev's answer |
| Never-closable space | `bin/guard` → `~/.local/bin/big-boss-pi-guard` + `~/.config/systemd/user/big-boss-pi-guard.service` | polls `herdr-app ls`; recreates the `big-boss-pi` space if it disappears, selects it once when Herdr starts. It never recreates a space named `pi-master` |
| Delegation-only enforcement | `~/.pi/agent/extensions/big-boss-pi-guard.ts` | blocks the `write` and `edit` tools, and shell writes into the directory (`echo x > …`, `rm/mv/cp/tee/sed -i`), when the session's cwd is under `/home/mark/big-boss-pi` **or** `/home/mark/pi-master`; no-ops everywhere else, including for a worker session (`PI_WORKER=1`) |
| Rollback helper | `bin/finish-rename.sh` | closes the old `pi-master` space on request and prints how to delete the old tree. Runs nothing by default |

## Paths and the environment variable

Every script lives on its own tree: it resolves the workspace root from its own location, so it
works from any cwd and when sourced. `PI_BOSS_ROOT` overrides the root; `PI_MASTER_ROOT` is
still accepted as a deprecated fallback.

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

## Is the local model actually used?

`delegate stats` answers that in one line instead of by inference:

```
delegate stats                    # last 7 days, one screen
delegate stats --since 24h        # 24h, 90m, 2w — <number><s|m|h|d|w>
delegate stats --json | jq .      # the same numbers, machine-readable
```

It prints jev calls per command (`ask`, `route`, `mode`, `count`, `thinking`), the route,
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

`state/usage.jsonl` is what the local model did, one line per call from `bin/jev` or
`bin/local-run`: timestamp, kind, subcommand, model id, latency, whether it answered, the
error class when it did not, and the caller's slug or context. **Not** logged: environment
variables, credentials, endpoints, and the whole task text — only the first 200 characters,
with key-shaped tokens redacted. The answer itself is never logged. Recording cannot break a
call: a failed write is swallowed.

## Jev gates every delegation

`delegate spawn` asks Jev four times on every run — `jev count`, `jev mode`, `jev route` and
`jev thinking` — for the exact task text. A `--mode` or `--thinking` from the caller is
accepted only when it matches Jev's answer. A different one aborts the spawn and prints Jev's
answer and its reason; overturning it needs `--override-jev --reason '<why>'`, and the
override is recorded. A `local` route aborts the same way, pointing at `bin/local-run`. If Jev
is unreachable or answers "unsure", the spawn stops instead of guessing, because that call
belongs to the user.

Thinking is split in two, because the two halves are different facts. Jev answers an *effort*
— `low`, `medium` or `high` — which is a fact about the task. Which levels the worker's model
supports is a fact about the model, so `bin/delegate` reads it from your pi config:
`settings.json` names the model a fresh `pi` starts with, and `models.json` or the generated
`models-store.json` carries that model's `reasoning` flag and `thinkingLevelMap` (`null` marks
a level the model does not support). The effort goes to the nearest supported level, ties to
the lower one, and the worker starts with `pi --thinking <level>`. A non-reasoning model gets
`off`; if the catalogue cannot be read the effort name is passed through and pi clamps it.
On this machine `deepseek/deepseek-flash` supports `off`, `low`, `high`, `max`, so
`medium` lands on `low`. The spec header and `delegate list` both show the level.

Each decision is one line in `state/decisions.jsonl`:
`{"timestamp":…,"command":"mode"|"count"|"route"|"thinking"|"ask","task":…,"decision":…,"reason":…,"overridden":true|false,"slug":…}`.
`delegate list` shows Jev's mode, route and thinking level for each worker.

## Ask Jev before you ask the user

The user is the tie-breaker, not the first responder. `delegate ask "<question>"` puts a
question to Jev first and records it in the same audit file:

```
delegate ask "should the retry loop ship as-is?"   # exit 0 yes, 1 no, 3 unsure
```

Exit 0 or 1 is an answer: act on it and do not interrupt the user. Only exit 3 — Jev unsure, or
the model unreachable — belongs to the user, and then it carries Jev's reason in one line:
`jev is unsure — <reason>`. `AGENTS.md` states the rule; the command makes it checkable.

## Worker spaces close themselves

`delegate spawn` guarantees the base before it creates the space. A sandboxed worker cannot `git
fetch` (the sandbox refuses the ssh config's ownership), so its `origin/<trunk>` is whatever was
last fetched on the host — a branch cut from that ships a PR against an old trunk. So the boss
fetches the `--cwd` repo itself, takes the default branch from `origin/HEAD` (falling back to
`trunk`, `main`, `master`), and fast-forwards the local trunk only when it is clean and strictly
behind. A dirty tree, an ahead trunk or a diverged one refuses the spawn and prints the exact
state and the command that fixes it; nothing is reset, rebased or forced. A `--cwd` that is not a
git repo, or has no origin, is skipped with one line.

Every worker branch ends in a pull request: the worker commits on its branch and tries
`git push -u origin <branch>` and `gh pr create --base main` with the review tier in the body,
and never merges it. A sandboxed worker usually has no ssh agent and no gh auth: when either
step fails it stops fighting and says so in the report, with the branch name and the commit sha,
and the boss publishes the branch and opens the PR. The report carries the PR URL so the boss
can relay it. A change with no PR is unfinished, however green it looks locally — merging stays
the human's call.

A worker cuts its own worktree (`git worktree add ../<slug>-worktree -b <branch>`) and never
switches the boss's live checkout: `delegate spawn` records that checkout's branch, and
`delegate close` warns, names both branches and checks the original back out when it moved.

A worker space is not kept around for browsing. The flow is: the worker writes
`reports/<slug>.md` and stays idle, the agent relays the report to the user, and the space is
closed right away — `delegate close <slug>` for one worker, `delegate sweep` for all of them.

One marker overrides that. A report whose first line is `DECISION NEEDED: <question>` means the
worker cannot continue without the user, so the space stays open until the question is answered:

```
DECISION NEEDED: drop the old table or keep it for the migration?
```

`delegate sweep` walks every tracked worker and prints one line each: `closed <slug>` when the
report is plain, `keep   <slug> (still working)` when there is no report yet, and
`keep   <slug> (decision needed, ask the user)` for the marker. It ends with `N closed, M kept`.
`delegate list` shows the same three states in its status column: `working`, `DECISION`,
`reported`.

## Why the space cannot be closed

Herdr has no per-space lock. `space.close` closes a space and ends its terminals, and
`herdr-app` offers no hook to veto it. So the space is self-healing instead: the guard service
checks every 5 seconds and rebuilds `big-boss-pi` (with a fresh agent) if it is gone. Closing
it is possible for a few seconds, then it is back. That is the closest thing to "not closable"
Herdr supports.

## What the write guard does and does not cover

It covers the `write`/`edit` tools and the obvious shell writes into the directory. It is a
rule, not a sandbox: a program the agent runs (a script, a package manager) can still write
there, and the workspace agent runs bare because it must reach the Herdr sockets. The point is
that delegation is the path of least resistance, and a direct file edit fails loudly.

The guard covers the **boss session**, not the worker it spawned. `bin/pi-bare`,
`bin/pi-sandboxed` and `bin/pi-nonet` export `PI_WORKER=1` into the worker's environment, and
the guard returns early for such a session: a worker writes in the workspace it was given,
including `/home/mark/big-boss-pi` and its `specs`/`reports`. A session without `PI_WORKER` is
the boss and stays guarded exactly as before.

## Daily use

```
herdr-app ls                                    # is the space there?
systemctl --user status big-boss-pi-guard       # is the guard alive?
delegate list                                   # workers, their spaces, the last jev decision
delegate stats                                  # is the local model used, and how often
delegate sweep                                  # close the ones that reported, keep the rest
tail -f ~/big-boss-pi/reports/*.md              # what workers reported
tail -2 ~/big-boss-pi/state/decisions.jsonl     # what jev decided
tail -2 ~/big-boss-pi/state/usage.jsonl         # what the local model answered
```

## Changing the rules

Edit `AGENTS.md`. Every agent in this workspace picks it up on its next start (`/reload`
re-reads it in a running session). Rules you add here do not leak into other workspaces —
they are context files of this directory only.

To change how delegation works, edit `bin/delegate`; to change what Jev weighs, edit the
`POLICY` string in `bin/jev.mjs`. Both are plain shell/JS, no build step.

## Turning it off

```
systemctl --user disable --now big-boss-pi-guard   # stop the self-healing
rm ~/.pi/agent/extensions/big-boss-pi-guard.ts     # stop the write guard
```
The space itself stays until you close it. `bin/finish-rename.sh --close-old-space` closes the
old `pi-master` space and prints the command that deletes the old tree.
