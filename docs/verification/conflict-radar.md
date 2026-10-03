# Conflict radar verification

`bin/fm-conflict-radar.sh`'s header owns the read-only observation and retained-memory contract.
The repeatable public-interface suite is `tests/fm-conflict-radar.test.sh`.
Forge fixture checks prove request construction and response handling, not current Azure credentials or service availability.

## Refresh commands

```sh
bash bin/fm-test-run.sh tests/fm-conflict-radar.test.sh tests/fm-task-delivery.test.sh --jobs 1
bash bin/fm-lint.sh bin/fm-conflict-radar.sh bin/fm-project-mode.sh tests/fm-conflict-radar.test.sh
bash bin/fm-doc-audience-check.sh
bash bin/fm-test-run.sh --check-coverage
```

The radar suite covers committed, staged, unstaged and untracked paths, all three classes, documentation-named text ledgers, dependency text manifests, explicit registry ledgers, disjoint changes, index preservation, unreadable and empty worktrees, task/PR deduplication, GitHub and Azure pagination, rename-source paths, completion retention, teardown pruning, failed-read retention, local origin/HEAD bases, HTTPS userinfo normalization, bounded Git calls and corrupt-memory refusal.
The existing delivery suite checks that the registry query preserves delivery, forge and branch behavior.

## Observed result

On 2026-10-03, Bash 5.3.15, Git 2.55.0, jq 1.8.2 and pinned ShellCheck 0.11.0 passed these commands.
The targeted behavior runner reported `FM_TEST_SUMMARY total=2 failed=0 skipped_gate=0`.
The audience check and coverage guard reported `ok`, and full source-aware lint emitted no findings.
A live GitHub read using gh-axi 0.1.35, with radar state confined to a disposable fixture home, reported `unmeasured=0`.
That live observation exercised the installed gh-axi envelope and open-PR listing; no open PR file-list response was present, so changed-file pagination remains fixture-proven.
Azure changed-file reads are fixture-proven, including bearer delivery through a private file descriptor, latest-iteration selection, base comparison and continuation offsets.
No live Azure availability claim is made.
