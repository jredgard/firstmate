---
name: md-conflict-fastpath
description: >-
  Load when an Azure DevOps ship PR reports merge conflicts whose paths may all be documentation; at intake of any documentation-only change or follow-up; or on a mechanical package or lock conflict.
user-invocable: false
metadata:
  internal: true
---

# md-conflict-fastpath

A merge conflict confined to documentation does not justify re-running review, tests, document, lint, push and CI.
The no-mistakes CI monitor auto-rebases a parked green PR when the base branch advances and then re-runs the whole pipeline from review (see `ci_timeout` in `~/.no-mistakes/config.yaml`), so the cheapest fix is to resolve the conflict on the forge, where the PR head never changes and the only thing that re-runs is the build-validation check.

## Captain's standing rule (2026-10-03)

The captain's words: "it skips the no mistakes if its a simple md fix or fast tracks it".
Applied as four tiers, cheapest first:

1. **Conflict on an existing green PR, doc-only** - resolve on the forge (procedure below).
   No pipeline at all.
2. **New or follow-up change that touches only documentation** - ship it `direct-PR` with `yolo` on, even on a project registered `no-mistakes`; record the reason "doc-only, captain md fast-track" in the backlog note.
   The worker pushes and opens the PR; build validation is the only check.
3. **Doc-only conflict where the forge path is unavailable** (for example the worker must rebase because the PR is not open yet) - rerun with `no-mistakes axi run --skip test,lint --intent ...` so only rebase, review, document, push, PR and CI run; review stays because push requires a review-approved head.
   If the trusted repo config refuses the skip, fall back to tier 2 on a fresh branch.

4. **Mechanical conflict** (captain, 2026-10-03, PR 57630: "simple lines in config"): path candidates use the approved .NET package/lock, dependency-text and simple key-value settings subset of [`bin/fm-conflict-radar.sh`](../../../bin/fm-conflict-radar.sh)'s taxonomy, mirrored by the helper, and the hunks are package or version lines, not code.
   Arbitrary `.props`, `.targets` and `.runsettings` files are not eligible.
   The worker aborts the run before the pipeline's own repair reruns review, rebases onto current dev taking dev's package set and keeping its own additions, regenerates every conflicting lock file with `dotnet restore <solution> --force-evaluate` (never hand-merges a lock), builds once, then reruns with `no-mistakes axi run --skip test,document --intent ...` so only rebase, review, lint, push, PR and CI run; CI still runs the bounded tests.
   Review can never be skipped: the push step refuses without a durably review-approved head (observed 2026-10-03 on PR 57630).
   If the pipeline's repair has already passed review, let it finish instead: aborting then costs more than the skip saves.

A change is doc-only when every path in the diff ends in `.md`, `.markdown`, `.rst`, `.txt` or `.adoc`, text files use the helper's known documentation basenames, and none of them is read by code, pipelines or tooling (a manifest, a test fixture, a prompt file).
When in doubt it is not doc-only.
A conflict is mechanical only when `resolve-md-conflict.py list` reports `mechanical` for every path and the shown hunks contain no code; a conflict in a `.cs`, `.ts`, `.tf`, pipeline YAML or Dockerfile is never fast-tracked.

Timing matters more than the tier: the pipeline's CI monitor starts its own repair within a minute of the conflict, so read the conflict list and decide before steering, and never pre-empt a repair without the list in hand (lesson from PR 57623).

## When tier 1 applies

1. The PR reached `done: ... checks green` at its current head.
2. `resolve-md-conflict.py list` reports every conflict as a documentation `editEdit` candidate, and inspection verifies that no code or tooling reads any of those paths.
3. The resolution is a semantic merge of both sides that a reader can verify in one glance.

If any conflict touches code, config, infrastructure, a lockfile, or is not `editEdit`, stop here and use the branch-sync procedure from `validation-supervision` instead.

## Tier 1 procedure

1. **Stop the monitor before it rebases.**
   The worker that owns the run aborts it: `no-mistakes axi abort --run <id>` and confirms with `axi status` that no run is active for the branch.
   An aborted run releases branch custody; nothing is discarded.
2. **Inspect.**
   `FM_HOME=<home> python3 .agents/skills/md-conflict-fastpath/resolve-md-conflict.py list <repo> <pr>` prints each conflict with its three blob files and the three-way diff hunks (`git merge-file`).
   The helper's header owns home-derived Azure DevOps routing and the per-axis `ADO_ORG` / `ADO_PROJECT` overrides; there is no default organization or project.
   The `three-way` file keeps the conflict markers and is an inspection aid only; never apply it as the resolution.
3. **Write the resolution.**
   Save the full resolved file.
   Combine both sides' facts in one line where they describe the same thing (for example `Service Bus, Redis; opt-in PostgreSQL`).
4. **Apply on the forge.**
   The task worker, or firstmate with the captain's explicit word for that PR, runs `resolve-md-conflict.py apply <repo> <pr> <conflictId> <resolved-file>`.
   The helper uses the same home-derived routing or explicit overrides; its header owns PATCH encoding and result polling.
   Resolve each reported remaining conflict before landing; a pending or failed final merge is not ready to land.
5. **Land.**
   Re-cast the vote if the policy dropped it, then `bin/fm-pr-merge.sh <task> <url>` as usual.
   The build-validation policy re-queues one build on the new merge commit; that is the only check that re-runs.

## Authority

Resolving on the forge writes documentation content into the merge commit, so it is a project write.
A crewmate may do it inside its task; firstmate does it only with the captain's explicit word for that PR, and hard rule 1 gains no standing authority from this skill.
The helper's header and usage output own home-derived routing, environment overrides, authentication and conflicts API calls.
