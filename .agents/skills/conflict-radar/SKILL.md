---
name: conflict-radar
description: >-
  Agent-only conflict radar for concurrent ship waves.
  Load at ship intake when the project already has an in-flight ship; on a heartbeat wake when a project has more than one in-flight ship; when a ship reports its pipeline handoff or PR-ready done before firstmate registers the PR; and on any Azure DevOps or GitHub conflict report for a task PR.
user-invocable: false
metadata:
  internal: true
---

# Conflict radar

The matrix flags candidates and the hunks decide whether edits actually conflict.
Firstmate never edits a project to resolve a conflict except under hard rule 1's concrete operation approval.
The script observes paths and retains short project-local memory; it never steers workers or changes landing order itself.
Its header and `--help` own invocation, classification, measurement limits and memory reconciliation.
An unmeasured worktree or forge read is missing evidence, never proof of no overlap.

## Intake

Run the radar for the project before briefing another ship into an existing wave.
Use the registry ledger list and observed ledger candidates to identify shared verification ledgers, documentation indexes and cross-task summaries that do not belong to the individual feature.
Keep those wave-wide ledger edits out of the task brief and carry their combined accurate updates in one wave-closing documentation PR under `md-conflict-fastpath`.
Keep feature-specific documentation with its feature when separating it would leave behavior undocumented or make validation inaccurate; do not suppress required evidence or manufacture a pass.
Do not classify a task's code change as mechanical merely because it lives in JSON or a manifest.
Treat documentation-named text ledgers and dependency text manifests according to the script's classification policy, not a blanket text-file rule.

## Heartbeat and pre-registration handoff

Run the radar during the wave and at either implementation handoff or PR-ready done, before registering the PR.
Read shared paths, participants and unmeasured sources against the previous observation, including recently completed PR paths still associated with tracked tasks.
For a ledger candidate, inspect both edits and steer the later worker through `fm-send` to drop only the redundant wave-wide edit and preserve the required update for the wave-closing documentation PR.
For a mechanical candidate, compare intended dependency or setting changes and plan the later worker's restore-and-rerun on the settled base; never assume two manifest edits commute.
For a code candidate, inspect the hunks and semantic dependency before deciding whether a steer, landing order or explicit dependency is necessary.
Same-path editing is not itself a reason to serialize isolated implementation.
While both workers are live, choose the order that avoids unnecessary rework and give the later worker the specific paths and intended reconciliation.
Active validation custody and gate handling remain owned by `validation-supervision`; do not ask a worker to hand-edit while its pipeline owns the branch.
Do not blindly remove evidence retained after a failed read; refresh it when the source becomes measurable.

## Landing and conflict reports

Complete non-overlapping PRs first, subject to the merge authority and green-check guards in `ship-landing`.
For an overlapping ledger pair, inspect the hunks and prepare the forge-side resolution with `md-conflict-fastpath`'s `resolve-md-conflict.py` before the first completion, using that skill's supported forge and safety procedure.
On an Azure DevOps or GitHub conflict report, refresh the matrix before selecting that procedure; a classification alone never authorizes a forge write or waives validation.
`md-conflict-fastpath` owns documentation conflict resolution, and `ship-landing` owns registration, landing and teardown.
If the companion fastpath is not installed or does not support the forge, retain the evidence and use the existing delivery path rather than inventing a resolver.
Automatic fleet-view and wake-drain integration are not provided by this skill.
