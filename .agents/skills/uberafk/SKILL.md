---
name: uberafk
description: >-
  Enter the afk posture when the captain invokes /uberafk, recording the captain's standing 2026-09-27 PR mandate followed by any words supplied with this invocation.
  Use the afk skill for the lifecycle and return.
user-invocable: true
metadata:
  internal: true
---

# uberafk

This is a thin wrapper over the `afk` skill; follow that skill for entry, supervision, announcement, and return.
The captain created this variant on 2026-09-27 with these words: "lets alter the commands to /afk and /quiet changed to /uberafk and /uberquiet. Where the uber variants comes with full pr authotiry in approve commands and recommended options".
The standing mandate is the captain's 2026-09-27 away entry, quoted verbatim: "pr merge, approve and complete authority for devops and github. Use recommended and sitrep when back. Ensure we move the needle and not wait on 1 pipeline hold".

## Entry

When `/uberafk` is invoked, create a private temporary words file before any other work.
Write the standing mandate above into the file exactly as quoted, without quotation marks, attribution, or an extra trailing newline.
Append any words typed after `/uberafk` verbatim after one newline, in the order given; do not include the command itself.
Run `bin/fm-afk-launch.sh enter --words-file <path>` in the same turn, then remove the temporary file and complete the `afk` skill's entry steps.
The recorded words are the whole mandate; do not translate them into policy fields or expand their authority.

## Announcement and return

Read back the recorded words and state that PR authority applies only to PRs green at their live head.
Red merges and destructive, irreversible, or security-sensitive actions are never pre-authorizable.
Ask-user findings still follow `ask-user-authority` unless the recorded mandate pre-answers the exact decision.
The mandate expires when the away record is archived at return; use the `afk` skill's return procedure and give the requested sitrep.
