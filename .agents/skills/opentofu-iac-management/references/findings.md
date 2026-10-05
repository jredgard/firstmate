# OpenTofu release findings ledger

These findings distill the 2026-10-04/05 release audit into reusable rules, not shipped-remediation or new live-test claims.
Use the stable finding IDs when citing a lesson.
Private evidence pointers below are source filenames and section/row locators, intentionally not links to private hosts or projects.
Tenant/subscription identifiers, resource/secret names, credentials and project-specific commands are omitted.
The scout's direct observations supersede ambiguous operator-log attributions; recommendations and predicted blockers remain labeled as such.

## IAC-001 - 2026-10-05 - Prerequisites must be executable

- Evidence: `infra-failure-scout/report.md`, root cause 1 and remediation item 1; `qa-rebuild-manual-steps-log.md`, rows 12 and 15.
  Observed: a static precondition check made no cloud reads, and independently maintained seed lists omitted a referenced secret.
- Rule: derive complete per-phase prerequisite manifests from consuming definitions and verify live readiness before their plan.
- Anti-pattern: call a static graph check or a secret count a release readiness gate.

## IAC-002 - 2026-10-05 - Aliases are not vault identities

- Evidence: `infra-failure-scout/report.md`, root cause 1, canonical-name correction; `qa-rebuild-manual-steps-log.md`, rows 12, 15 and 16.
  Observed: provider errors used a container alias differing from the actual vault reference; the log also confused an application-issued client credential with an external service key.
- Rule: preserve canonical references, aliases and credential producer/consumer provenance as distinct manifest fields.
- Anti-pattern: seed a vault name copied from an error label or mint a credential independently of its issuing realm.

## IAC-003 - 2026-10-04 - Private bootstrap must not open the vault

- Evidence: `qa-rebuild-manual-steps-log.md`, row 7; `infra-failure-scout/report.md`, root cause 2 and remediation items 3 and 9.
  Recorded operator evidence: seeding temporarily changed public access; observed architecture had no assumed hub route.
  ARM metadata succeeded privately; secure ARM secret/key creation was proposed, not live-accepted by this audit.
- Rule: use protected control-plane creation, separating in-network data-plane verification from hosted orchestration.
- Anti-pattern: open a firewall or add peering to accommodate a hosted agent or workstation.

## IAC-004 - 2026-10-05 - Metadata cannot prove identity access

- Evidence: `infra-failure-scout/report.md`, root causes 1, 2 and 4 and layered test strategy 2-3.
  Observed: enabled-secret metadata was readable while a missing runtime identity grant blocked deployment.
- Rule: distinguish existence, attributes, grants, private connectivity and actual intended-identity resolution.
- Anti-pattern: interpret ARM listing success or a generic fetch error as conclusive data-plane evidence.

## IAC-005 - 2026-10-04 - Grants belong before consumers

- Evidence: `qa-rebuild-manual-steps-log.md`, rows 5, 10, 11 and 13; `learnings.md`, 2026-10-04 delivery-identity key-role entry; `infra-failure-scout/report.md`, root cause 4.
  Recorded and observed: rollout preceded effective grants; a later bootstrap grant allowed the same-source deployment to succeed.
- Rule: sequence least-scope grants for current principals inside the release, with separate role-writing authority and effective-access verification.
- Anti-pattern: merge a consumer change and ask an operator to install its prerequisite afterward.

## IAC-006 - 2026-10-05 - Preview is not verification

- Evidence: `infra-failure-scout/report.md`, root cause 4, executable zero-assignment replay.
  Observed: the grant preview exited successfully with zero assignments and no assignment-list calls.
- Rule: readiness verification must query actual assignments and fail when required identity/scope grants are absent.
- Anti-pattern: name a preview a probe and accept its zero exit status as installed-access evidence.

## IAC-007 - 2026-10-04 - Images need publication receipts

- Evidence: `qa-rebuild-manual-steps-log.md`, row 6; `infra-failure-scout/report.md`, root cause 5.
  Recorded operator evidence: a pinned image was imported by hand; observed omission: no release publication/pull-readiness gate.
  Sampled apply errors were secret failures, not proved image-pull failures.
- Rule: publish and verify every destination digest before its consumers' plan and prove the runtime identity can pull it.
- Anti-pattern: assume a pinned digest proves registry presence or pull permission.

## IAC-008 - 2026-10-04 - Admission and fallback are design inputs

- Evidence: `qa-rebuild-manual-steps-log.md`, row 3; `learnings.md`, 2026-10-04 managed-cache refusal and platform-completion entries; `infra-failure-scout/report.md`, root cause 5.
  Observed: two managed-service SKU attempts were refused in the selected subscription/region; a container fallback then completed platform provisioning.
- Rule: validate admission and document approved fallback security/durability limits before dependent creation.
- Anti-pattern: keep guessing SKUs or generalize a scoped refusal into global service unavailability.

## IAC-009 - 2026-10-05 - Failed creates leave real shells

- Evidence: `infra-failure-scout/report.md`, root cause 3 and remediation item 2; `qa-rebuild-manual-steps-log.md`, rows 8, 14 and 15.
  Observed: three failed-create/rerun pairs left resources outside state; an unknown plan ID bypassed collision detection, then the provider refused the next create.
- Rule: preflight deterministic type/name/scope collisions and recover only receipted release-owned failed stateless shells under lock.
- Anti-pattern: expect rollback, broadly import unknown resources, or hand-delete collisions without provenance and a fresh approved plan.

## IAC-010 - 2026-10-05 - Declared bootstrap has not run

- Evidence: `infra-failure-scout/report.md`, root cause 6 and remediation items 6-7.
  Observed omission: database and migration jobs were declared with manual triggers but not executed by the release; realm setup remained an operator prerequisite.
  These were predicted later blockers, not failures reached in the sampled runs.
- Rule: execute and receipt database ownership, migrations, realm/client configuration and least-role smoke setup before activating consumers.
- Anti-pattern: accept a job resource or application configuration as proof of completed bootstrap.

## IAC-011 - 2026-10-05 - Phases need one bound orchestration

- Evidence: `qa-rebuild-manual-steps-log.md`, row 9; `learnings.md`, 2026-10-04 superseded-run and platform-completion entries; `infra-failure-scout/report.md`, remediation item 7 and rehearsal checklist.
  Observed: phase switches required source changes, while existing guards rejected superseded runs; the audit proposed preserving plan binding within automatic phase progression.
- Rule: progress through dependent phases in one protected orchestration with immutable source/run/state-bound plans and required approvals.
- Anti-pattern: launch independent runs, change defaults per phase, reuse stale approvals or treat a skipped prerequisite as success.

## IAC-012 - 2026-10-05 - Mock green is not acceptance

- Evidence: `infra-failure-scout/report.md`, existing-suite proof and layered test strategy sections.
  Observed: mocked native graph tests and 211 behavior tests passed with one database integration skipped, immediately before a real apply collision.
- Rule: layer contracts, live prerequisite checks, in-network identity probes, structural gates, application/auth smoke and a real rebuild rehearsal.
- Anti-pattern: equate mocked apply or zero drift with working infrastructure, or run unmocked native tests against the real release root to manufacture proof.

## IAC-013 - 2026-10-05 - Destroy/rebuild is the acceptance boundary

- Evidence: `qa-rebuild-manual-steps-log.md`, repeat-test requirement and rows 1-16; `learnings.md`, 2026-10-04 retained-backend and retired-backend entries; `infra-failure-scout/report.md`, destroy-and-rollout checklist.
  Recorded: the previous rebuild needed out-of-band seeding, grants, image import and cleanup; later evidence corrected an obsolete retained-resource assumption.
- Rule: keep destroy operator-authorized, verify the current retained set and protection semantics, then require zero post-destroy human actions except approvals.
- Anti-pattern: claim automation because the UI eventually works after manual repairs or retain/purge resources from stale inventory assumptions.

## IAC-014 - 2026-10-05 - Classify red evidence before changing IaC

- Evidence: `infra-failure-scout/report.md`, executive conclusion and root causes 7-8.
  Observed: rejected approvals made no mutations, obsolete scheduled checks repeated noise, and a test-host crash prevented deployment; the crash cause remained unproved.
- Rule: distinguish approval outcome, stale monitor, in-flight deployment, test failure and provisioning failure using stage-level evidence.
- Anti-pattern: count every red run as a separate infrastructure incident or suppress a failed test process because its executed-test counters look green.
