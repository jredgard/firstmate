===== PR 900: multi-round run, both findings eventually fixed =====
## no-mistakes review — recorded findings (full texts)

### Review summary

- Run ID: `run-demo`
- Reviewed head: `head-r3`
- Review rounds: 3
- Round 1: trigger `initial`; outcome: 2 findings; reviewed head: `head-r1`
  - `stale-cache-key-omits-tenant` (warning): The cache key is built from the repo slug alone, so two tenants sharing a repo name read each other's cached review verdicts. Multi-line prose with odd spacing should collapse to one readable line.; fixed in round 2: namespaced the cache key by tenant id and added a cross-tenant regression test
  - `retry-loop-never-backs-off` (info): The push retry loop re-issues the request immediately on HTTP 429 instead of honoring Retry-After.; fixed in round 3: added exponential backoff honoring Retry-After to the push retry loop
- Round 2: trigger `auto_fix`; outcome: 1 finding; reviewed head: `head-r2`
  - `retry-loop-never-backs-off` (info): The push retry loop re-issues the request immediately on HTTP 429 instead of honoring Retry-After.; fixed in round 3: added exponential backoff honoring Retry-After to the push retry loop
- Round 3: trigger `auto_fix`; outcome: no findings; reviewed head: `head-r3`
- Verdict: **no residual findings.**


===== PR 901: flapping finding (fixed in round 2, reappears in round 3) =====
## no-mistakes review — recorded findings (full texts)

### Review summary

- Run ID: `run-flap`
- Reviewed head: `head-f3`
- Review rounds: 3
- Round 1: trigger `initial`; outcome: 1 finding; reviewed head: `head-f1`
  - `flappy-timeout-config` (warning): The CI polling timeout reappears after the round-2 fix regressed it.
- Round 2: trigger `auto_fix`; outcome: no findings; reviewed head: `head-f2`; fix attempted: raised the CI polling timeout to 90s
- Round 3: trigger `auto_fix`; outcome: 1 finding; reviewed head: `head-f3`
  - `flappy-timeout-config` (warning): The CI polling timeout reappears after the round-2 fix regressed it.
- Verdict: **1 finding remains.**

The PR description keeps the attestation and a one-line-per-step summary (Azure DevOps truncates descriptions at 4000 characters), so the review's recorded findings live here in full. Run `run-flap`.

### flappy-timeout-config — warning `bin/fm-ci.sh:12`

The CI polling timeout reappears after the round-2 fix regressed it.


===== PR 902: failed fix attempt (findings persist, one id-less) =====
## no-mistakes review — recorded findings (full texts)

### Review summary

- Run ID: `run-failedfix`
- Reviewed head: `head-x2`
- Review rounds: 2
- Round 1: trigger `initial`; outcome: 2 findings; reviewed head: `head-x1`
  - `guard-check-races-writer` (warning): The guard reads the lock file before the writer flushes it, so concurrent runs slip past the guard.
  - `unnamed-finding` (info): An id-less informational note that persists across rounds.
- Round 2: trigger `auto_fix`; outcome: 2 findings; reviewed head: `head-x2`; fix attempted: attempted flock-based serialization around the guard check
  - `guard-check-races-writer` (warning): The guard reads the lock file before the writer flushes it, so concurrent runs slip past the guard.
  - `unnamed-finding` (info): An id-less informational note that persists across rounds.
- Verdict: **2 findings remain.**

The PR description keeps the attestation and a one-line-per-step summary (Azure DevOps truncates descriptions at 4000 characters), so the review's recorded findings live here in full. Run `run-failedfix`.

### guard-check-races-writer — warning `bin/fm-guard.sh:30`

The guard reads the lock file before the writer flushes it, so concurrent runs slip past the guard.

### None — info `bin/fm-guard.sh:55`

An id-less informational note that persists across rounds.

