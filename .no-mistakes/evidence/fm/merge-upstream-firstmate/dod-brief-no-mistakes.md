# Definition of done
Delivery contract: mode=no-mistakes
Ship branch: fm/demo-task
The task is complete only when committed on your branch.
When you believe it is complete, append `done [at=<epoch>]: {summary}` to the status file and stop.
Firstmate will then instruct you to run /no-mistakes to validate and ship a PR.
That first `done:` is the handoff that starts the pipeline, which owns the push; it is not a request to push from this copy.

You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and `no-mistakes axi run --help` plus the `help` lines in each `axi` response are authoritative and version-matched to the installed binary.
When starting no-mistakes, make `--intent` preserve all relevant content from this brief's `# Task` section plus every later accepted Firstmate requirement, clarification, constraint, exclusion, and supersession, carrying only each requirement's current accepted form; retain direct requirements instead of substituting a diff summary, and exclude generic operational, status, delivery, and other scaffold boilerplate unless it is task-specific.
For a legacy brief with no `## Captain's intent` subsection, lines marked `[captain] ` are the captain's words - keep their substance, excluding that metadata prefix, and never add speaker labels or direct address.
Keep the assembled `--intent` under 900 characters by compressing phrasing, never by dropping requirements: Azure DevOps caps the entire PR description at 4000 characters, and after the What Changed, Risk, and attestation sections an intent beyond ~900 characters evicts the pipeline's visible verification report from the PR body (measured on Mosaiq.Factory PR 54336: a 1373-character intent left 313 of the ~800 the report needs).
Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix.
Once the run reaches checks-passed or completed, branch custody is yours.
For follow-up commits such as verifier-feedback fixes or cosmetic rounds, use plain `git pull --ff-only` and `git push origin <branch>`.
Use `no-mistakes axi sync` only for custody recovery during an active run.

One drive call blocks until the next gate or outcome, which routinely outlives what your harness lets a single command run: Claude Code kills a command at ten minutes maximum, while one fix round is capped around thirty minutes and up to three rounds chain.
So background the drive call instead of sitting in one blocking hold your harness will kill, and read its return when it finishes.
Declare that wait using the brief's status-reporting rule before waiting on the backgrounded drive call.
Where a harness's own command limit is not established, assume it bounds commands and use that same backgrounded shape.
Only a drive call's return reports the green PR: `no-mistakes axi status` shows progress but never reports `checks-passed` while the ci step is still monitoring the PR for merge, so never wait on a status poll for the next gate or outcome.
Whenever a drive call returns without a gate or an outcome - its own wait elapsed, or it was killed or timed out - reattach at once by re-running `no-mistakes axi run` without flags, backgrounded the same way; once checks are green it returns `checks-passed` immediately, and if it refuses because no run is active, read the finished outcome from `no-mistakes axi status`.
A killed or timed-out call is never evidence the daemon died: the daemon accepts your response immediately and runs the round in the background, so the call was only ever waiting for a read while the run kept working.
Reattach and keep going rather than reporting the pipeline blocked; rule 7 owns the checks that decide when a pipeline block is real.

Two firstmate-specific rules layer on top of that guidance:
- ask-user findings are never yours to answer: escalate to firstmate using rule 6's ask-user format and stop.
  Firstmate applies `ask-user-authority` and obtains any required captain decision.
  When the decision comes back, feed it to the gate with `no-mistakes axi respond` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
- NEVER pass `--yes` (or `-y`) to `no-mistakes axi run` or `no-mistakes axi respond`. It is banned fleet-wide.
  It auto-resolves every gate including ask-user findings with no escalation, and answering your own ask-user finding is a hard rule violation.

After /no-mistakes reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge): on a GitHub PR, read the PR back from the forge and confirm it is not a draft (`gh-axi pr view <number>` must print `draft: no`, where <number> is the PR number from your PR URL); if it is a draft, mark it ready with `gh-axi pr ready <number>` - a draft cannot be merged, so a done report on one leaves the merge unasked.
On an Azure DevOps PR, run `fm-pr-report-compact <org-url> <pr-id>` once: Azure DevOps hard-truncates PR descriptions at 4000 characters and refuses edits after merge, so this is the only window to keep the full verification report readable.
The tool posts a closed review-summary comment, with any residual findings in full, on every gated PR, verifies the Build policy, normalizes the visible step board to final passed values, trims prose when needed, and never alters the attestation.
Then append `done [at=<epoch>]: PR {url} checks green` and stop. You are finished.
That CI-ready `done:` is accepted only when this copy's HEAD - your latest commit - is one the /no-mistakes run pushed, so commit nothing after the run; the check tests that commit, not merely that a branch moved.
If you deliberately keep the PR a draft, append `paused [at=<epoch>]: {why the draft is held}` instead of done.
