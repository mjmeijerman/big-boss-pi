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
| Decision model | `bin/jev` → `~/.local/bin/jev` | local qwen3.8:27b on ollama; decides worker count, mode, route, and permissions |
| Local worker | `bin/local-run` | runs a local task on the same model, headless: prompt in, answer on stdout, no space and no state |
| Delegation | `bin/delegate` → `~/.local/bin/delegate` | asks Jev for mode and count, creates a Herdr space per worker, writes the spec, records where the report lands, appends every decision to `state/decisions.jsonl`; `delegate sweep` closes the workers that finished |
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
  writes nothing. Exit 0 = local, 1 = remote, 3 = unsure, so it drops straight into `if`.
- `remote` — code changes, debugging, design decisions, multi-file reasoning, anything that
  needs tools, tests or a repo. Go through `delegate spawn`.

`delegate spawn` asks the route itself and records it, but only warns when it contradicts the
request: a remote worker for a local task prints the `bin/local-run` alternative and spawns
anyway. The route also lands on the spec header, next to the mode: "Mode: sandboxed (chosen
by jev), route: remote (jev)", so a worker can tell what it was supposed to be.

```
jev route "summarise reports/foo.md in three bullets"   # → local  (exit 0)
markdown notes.txt | bin/local-run                       # the answer on stdout
jev route "add retries to the fetch client"              # → remote (exit 1)
```

## Jev gates every delegation

`delegate spawn` asks Jev three times on every run — `jev count`, `jev mode` and `jev route` —
for the exact task text. A `--mode` from the caller is accepted only when it matches Jev's answer. A different one
aborts the spawn and prints Jev's answer and its reason; overturning it needs
`--override-jev --reason '<why>'`, and the override is recorded. If Jev is unreachable or
answers "unsure", the spawn stops instead of guessing, because that call belongs to the user.

Each decision is one line in `state/decisions.jsonl`:
`{"timestamp":…,"command":"mode"|"count"|"route","task":…,"decision":…,"reason":…,"overridden":true|false,"slug":…}`.
`delegate list` shows the last Jev decision for each worker plus its route.

## Worker spaces close themselves

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
delegate sweep                                  # close the ones that reported, keep the rest
tail -f ~/big-boss-pi/reports/*.md              # what workers reported
tail -2 ~/big-boss-pi/state/decisions.jsonl     # what jev decided
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
