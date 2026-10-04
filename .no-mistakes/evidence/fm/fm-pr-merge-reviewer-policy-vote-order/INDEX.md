# Live validation of bin/fm-pr-merge.sh approve/complete (change 95ccaa89 vs base e7cf1551)

The real bin/fm-pr-merge.sh ran from the gate worktree against a marked disposable lab FM_HOME (bin/fm-lab-home.sh create).
Real curl, gh 2.101.0 and gh-axi reached a local TLS-terminating CONNECT proxy (harness/forge_emu.py, throwaway CA) that statefully emulates
dev.azure.com (PR, policy evaluations, reviewer vote PUT, completion PATCH) and api.github.com (GraphQL PR reads and merge mutation, REST reviews, /user, branch/rules).
The emulated ADO 'Minimum number of reviewers' evaluation reads 'queued' until a +10 vote exists, then lags 2 more reads before it reads 'approved'.
Only the az token read is shimmed (harness/az-token-shim), so the operator's Azure login cache is never refreshed.

- 00-baseline-e7cf1551-ado-unvoted-away-refused: exit code: 1   (elapsed 1s)
- 01-ado-unvoted-away-default-approves-then-completes: exit code: 0   (elapsed 4s)
- 02-ado-localized-policy-uppercase-typeid-completes: exit code: 0   (elapsed 3s)
- 03-ado-displayname-collision-unrelated-policy-refused: exit code: 1   (elapsed 1s)
- 04-ado-rejected-build-refused-before-vote: exit code: 1   (elapsed 1s)
- 05-ado-approve-only-votes-without-completing: exit code: 0   (elapsed 1s)
- 06-ado-complete-only-no-reviewer-on-approved-pr: exit code: 0   (elapsed 2s)
- 07-ado-complete-only-queued-refused-no-writes: exit code: 1   (elapsed 1s)
- 08-ado-default-without-reviewer-id-refused: exit code: 1   (elapsed 0s)
- 09-ado-reviewer-policy-stays-queued-times-out: exit code: 1   (elapsed 31s)
- 10-ado-reviewer-id-from-home-config-file: exit code: 0   (elapsed 3s)
- 11-gh-review-required-approves-then-squash-merges: exit code: 0   (elapsed 3s)
- 12-gh-already-approved-no-reviewer-token-merges: exit code: 0   (elapsed 1s)
- 13-gh-changes-requested-default-refused: exit code: 1   (elapsed 2s)
- 14-gh-changes-requested-approve-only-refused: exit code: 1   (elapsed 1s)
- 15b-gh-reviewer-is-author-case-differs-refused: exit code: 1   (elapsed 1s)
- 15-gh-reviewer-is-author-self-approval-refused: exit code: 1   (elapsed 2s)
- 16-gh-approve-only-reviews-without-merging: exit code: 0   (elapsed 1s)
- 17-gh-complete-only-review-required-refused: exit code: 1   (elapsed 1s)
- 18-gh-bot-reviewer-login-approves-and-merges: exit code: 0   (elapsed 3s)
- 19-gh-post-approval-unknown-mergeable-retried-then-merges: exit code: 0   (elapsed 9s)
- 20-gh-review-required-without-reviewer-token-refused: exit code: 1   (elapsed 2s)
- 21-gh-reviewer-token-via-env-var: exit code: 0   (elapsed 2s)
- 22-gh-away-plan-gated-403-rules-still-approves-and-merges: exit code: 0   (elapsed 2s)
- 23-gh-no-review-required-merges-without-reviewer-token: exit code: 0   (elapsed 2s)
