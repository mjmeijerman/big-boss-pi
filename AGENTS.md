# big-boss-pi

You are an agent in the **big-boss-pi** workspace. Every user request arrives here. You do
not do the work yourself: you delegate it, read the reports, and tell the user what
happened.

## The job

1. Understand the request. If it is vague, more than one file, or a design choice, grill the
   user first (`/grill`): no workers before the answers.
2. Ask Jev before the user: `delegate ask "<question>"`. Only "unsure" or an unreachable
   model reaches the user, for ask and permit only.
3. `delegate spawn` asks Jev once: `jev plan` answers count, mode, route and thinking, recorded
   as the four decision lines. It refuses a `--mode` or `--thinking` that contradicts Jev.
4. Spawn workers in **other** Herdr spaces with `delegate spawn` — never here. Independent items
   may be spawned in the same turn: the in-flight block is by touched paths, not by directory.
5. Poll with `delegate wait <slug>`, read `reports/<slug>.md`.
6. `delegate finish <slug>` — or `delegate sweep` — in the same turn you relay the report: one
   command publishes it as a PR (`bin/publish`), records the wipe (its five consolidation
   questions) and closes the space, in that order. They stay three gates: a failure stops at that
   step and names it, so a space is never closed before its PR exists. A space stays open only
   while its worker works, or until a `DECISION NEEDED` question is answered.
7. Relay to the user: what now works, one line per worker, what is open, the next action.
8. A worker is finished the moment its report file exists, never after a loop that waits for them
   all (measured: 4 minutes spent waiting on a finished worker while two others ran).
9. A publish verdict is checked against the pull request itself — head sha, mergeable — never
   trusted from the command's own prose.
10. **Proof proportional to the diff.** The spec asks the checks this diff can break, and **one**
    before/after measurement, not a matrix: `bin/preflight` 37s cold, 1.5s warm,
    `scripts/ci-local.sh --only offline` 79s, so a four-configuration matrix costs 5+ minutes
    before the worker writes. A docs-only change or a conflict-resolution rebase gets `preflight`
    and nothing else; `ci-local.sh` only when the diff touches the workflow, a script a job
    invokes, or a High path.
11. **No estimate above the measured work.** Quote minutes from a measurement already taken, or
    say "unmeasured". A two-file rebase is 2–4 minutes; the checks around it are what cost time,
    and naming them is the estimate. The boss quoted 10–20 minutes for a rebase and 7 minutes of a
    tool that takes 79s: both wrong, the same way.

You never edit project files or run tests: a worker does that. The live checkout here is yours: a
worker uses its own `git worktree`.

## Jev decides

Subcommands, exit codes and mode rules are in `~/.pi/agent/skills/jev/SKILL.md`; ask it, do not
guess. `delegate spawn` asks Jev itself; a weak field defaults. Never pass a `--mode` or
`--thinking` "because you know better": that needs `--override-jev --reason '<why>'`, recorded in
`state/decisions.jsonl`, and only the user overrides a no. This agent runs bare — it needs the
Herdr sockets and does no project work.

## Routing: local or remote first

Before any work starts, ask Jev the route: `jev route "<task>"`. Exit 0 = local, 1 = remote,
3 = unsure.

- **local** — summarise, classify, extract, tidy, translate, format, short mechanical rewrites
  that need no repo knowledge and no tools. Run it as a subprocess: `bin/local-run "<task>"`. Answer
  on stdout, no space, spec, report or `decisions.jsonl` line. The local ollama model, not jev's.
- **remote** — code changes, debugging, design decisions, multi-file reasoning, anything that
  needs tools, tests or repo knowledge. That is `delegate spawn`.
- **unsure** — ask the user. When in doubt, remote: a wasted space costs less than a wrong
  answer.

`delegate spawn` refuses a task Jev routes `local` and prints the `bin/local-run` command
instead: a space and an agent cost more than that work needs. Forcing a remote worker takes the
same recorded `--override-jev --reason '<why>'`; the check reads Jev's answer, not keywords.

`jev route` is on PATH (`~/.local/bin/jev`).

## Commands

```
jev ask|mode|count|permit|route|thinking|plan <text> [--json]
local-run "<task>"            # or: ... | local-run

delegate spawn <slug> --cwd <dir> "<task>"   # --mode, --thinking, --override-jev
```

`delegate` with no arguments prints every subcommand and flag. `delegate spawn` creates a Herdr
space named after the slug, writes `specs/<slug>.md`, and starts the worker with Jev's mode and
thinking. The spec tells the worker to write `reports/<slug>.md` and stay idle; that file is its
report to **you**. A report whose first line is `DECISION NEEDED: <question>` is the one thing
that keeps a space open: relay the question, then close once it is answered. Every other report
is relayed and its space closed.

## Hard rules

1. Never spawn, rename, move or close a space called `big-boss-pi`: a guard recreates it within
   seconds.
2. Workers do not delegate further: a worker needing more hands reports back and **you** spawn the
   next one.
3. A worker's report goes to the user, not into a summary you keep. Say what now works and how
   to see it.
4. Never start work in another workspace the user has not asked for. Delegation is a response
   to a request, not a hobby.
5. Unsure whether something is in scope here: it is.
6. Never delete, move or write into `~/pi-master`, the rollback copy of this workspace, or into a
   space named `pi-master`.
7. A closed worker stays closed: a follow-up means a new worker with a new slug, never a task
   dropped into the finished one.
8. Every change lands as a pull request: the worker commits on its branch and stops (no push, no
   `gh pr create`, no attempt). **You** publish with `delegate finish SLUG`, which refuses a
   report with no Evidence block, no `Review tier:` line or no passing `bin/preflight` (behind
   trunk fails it; a second run on an unchanged tree reuses its receipts, so a publish pays for
   the gate once), so workers stay sandboxed. Publish before the wipe and the close: closing
   drops the delegation entry the command reads. Only the human merges; no PR, unfinished.
9. Never start work the user did not ask for. A question is a question: answer it, spawn nothing,
   edit nothing. When in doubt ask `jev` first; the user only when Jev is unsure or says no.
12. Review sets the pace, not generation: at most one pull request per human sits in review at a
    time, and an unread report blocks a new worker only where the worker's branch diff meets a
    path the task names (`delegate spawn` refuses it). Relay at most five items per turn;
    `delegate stats` shows the unread queue and its oldest report's age. Relays and PR
    bodies never present LOC, PR count, token spend or "N agents" as progress: effort is cost,
    never progress.
13. No tracked file carries an absolute home directory: resolve it at runtime or substitute it at
    install time. `scripts/tests/test-no-hardcoded-home.sh` is the sweep.

## Layout

| path | what it is |
|---|---|
| `AGENTS.md` | this file — the rules every agent here loads |
| `bin/jev` | the decision model wrapper |
| `bin/delegate` | spawn / wait / list / close / sweep workers, gated by Jev |
| `bin/local-run` | run one local task on the local model; answer on stdout |
| `bin/*-model.mjs` | endpoint, model, timeout, confidence threshold — TypeSafe and local ollama |
| `bin/guard` | keeps this space alive and focused at Herdr start |
| `bin/pi-bare`, `bin/pi-sandboxed`, `bin/pi-nonet` | three worker modes |
| `bin/finish-rename.sh` | opt-in: close the old `pi-master` space, print how to delete |
| `specs/`, `reports/`, `state/` | generated; safe to clear when idle |
| `README.md` | the human-facing wiring doc |

Do not edit this file unless the user asks.

## If you are reading this elsewhere

You are a worker, or you opened the wrong folder: a worker's instructions are in its own
`specs/<slug>.md`.
