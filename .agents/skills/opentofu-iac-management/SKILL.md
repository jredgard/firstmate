---
name: opentofu-iac-management
description: >-
  Load when scoping, briefing, reviewing or diagnosing an OpenTofu or Terraform release,
  a destroy-and-rollout, a private Key Vault or RBAC prerequisite, or infrastructure smoke testing.
user-invocable: false
metadata:
  internal: true
---

# OpenTofu IaC management

Turn resource declarations into an executable release, not a runbook of missing human steps.
Use the [findings ledger](references/findings.md) when citing why a gate or boundary is required; it records evidence, not a claim that remediation has shipped.
This skill grants no infrastructure mutation, recovery or destroy authority and does not change the selected delivery or approval policy.

## Scope and brief

- Identify the exact root, backend, environment, source revision, protected release identity, lock and allowed resource inventory.
  Separate retained bootstrap resources and external dependencies from release-owned resources; do not treat a historical kept list as an immutable dependency list.
- Define the intended final phase and dependency order from empty state through platform, workloads and authentication, using the project's phase names.
  Set protected seed sources, role-writing authority, image provenance and smoke credentials before the rehearsal begins.
- Require an executable nonsecret prerequisite manifest for each phase, derived from the same definitions as the consuming resources and jobs, not a separately maintained checklist.
  Include canonical secret/key references and versions where pinned, consumer aliases and identities, required roles/scopes, image registry/digests, service admission, private connectivity, and database/realm/job prerequisites.
  Record each prerequisite's producer, verification interface and success receipt so later phases cannot reference a resource their own phase must first create.
- Validate region/SKU/subscription admission before creating dependent workloads; preserve any approved fallback's security and durability limits rather than guessing larger SKUs after refusal.

## One protected orchestration

1. Start at the earliest unmet phase and hold the environment's exclusive release lock across prerequisite mutations, apply and scoped recovery.
   Pin tool/provider versions and locks, source, protected inputs and backend; reject superseded runs and concurrent orchestration.
2. Execute that phase's prerequisite producers and verify their receipts before planning consumers.
   For example, platform creates identities and network resources; subsequent steps install grants, publish images and seed references before workload planning.
   Create bootstrap job infrastructure in an earlier guarded subphase when needed, then execute it before planning or activating its consumers.
3. Run the live prerequisite gate against the complete manifest before creating or publishing the phase plan.
   Missing, disabled, expired or not-yet-valid secrets, wrong roles/scopes, unavailable images, unsuccessful jobs, unknown collisions, denied reads, pagination errors and timeouts fail closed.
   Distinguish missing metadata, authorization, network reachability and identity-resolution failures instead of inferring one cause from a generic provider error.
4. Produce one immutable saved plan per phase or guarded subphase, bound to source revision, run, phase, backend, inputs, prior state and prerequisite receipts.
   Resolve deterministic resource type/name/scope collisions even when provider-generated plan IDs are unknown; enforce existing ownership and deletion boundaries.
   Obtain the required approval, revalidate time-sensitive prerequisites and state freshness, then apply only that saved plan.
   Changed inputs, state, prerequisites, source or recovery require a fresh guarded plan and approval, never an edited or substituted approved plan.
5. Require the phase's structural and runtime gates before progressing automatically to the next phase.
   A failed prerequisite or apply is never success, and a workloads/authentication failure must not fall back to platform-only smoke expectations.
6. Publish redacted source/run/phase, plan/state/manifest digests, execution receipts and failure classification even on failure.
   Resume from verified receipts, then prove a refreshed no-op plan on the completed release and an idempotent rerun without unwanted rotations or duplicate jobs, grants, principals or clients.

## Private vault and identity boundaries

- On Azure, use narrowly scoped ARM secret and initial key creation through `Microsoft.KeyVault/vaults/secrets` and `Microsoft.KeyVault/vaults/keys` for private vault bootstrap.
  These use the control plane rather than the vault data-plane endpoint; hosted orchestration agents must not need vault network access or firewall/IP-rule changes.
  If bootstrap requires a data-plane operation, execute an approved job inside the environment's own network; never assume hub peering or a workstation route exists.
- Supply values through protected secure deployment inputs, not command-line literals, OpenTofu variables, saved plans/state or printed artifacts.
  Keep raw secrets, tokens, session files and seed payloads out of logs and receipts.
  Reuse existing valid versions on resume; initial ARM key creation is not a key-rotation interface.
- Preserve canonical vault names independently of container secret aliases and provider error labels.
  Generate coupled credentials once and verify agreement between their consumers, including application-owned client credentials and the authentication realm that issues them.
- ARM metadata existence/attributes and a declared role assignment are necessary but do not prove an application identity can resolve a reference.
  Verify exact grants for current principal IDs at approved scopes, then run in-network data-plane probes under each intended identity.
  Separate control-plane write authority from runtime secret read and key wrap/unwrap authority.
- Sequence grants after identities/resources exist and before their first consumers are planned or activated, using a protected least-scope role-writing step inside the release, never a workstation grant.
  Retain separation from normal deployment credentials and bounded propagation checks.
  A preview that lists intended grants is not a verifier; zero installed grants must fail readiness.

## Images and executed bootstrap

- Publish or mirror every pinned application, job and initialization image through an approved producer before its consumers' plan.
  Verify the exact digest exists in the destination registry, provenance and pull authorization; prove actual pull under the consuming identity in the runtime gate.
- Execute database principal/schema ownership bootstrap, migrations and seed preparation in dependency order, with bounded waits and success receipts tied to source, inputs and execution IDs.
  A declared manual-trigger job proves only that the job exists, not that it ran or that its database effects succeeded.
- Provision and verify realm/client configuration, callback/logout routes, matching credentials and a dedicated least-role smoke account before the authentication phase.
  Do not use operator or administrator credentials for application smoke, and do not enable anonymous health or public origins to make tests pass.

## Failed-create recovery

Cloud creates are not transactional: a failed stateless create can leave a live shell absent from state.
Before apply, receipt the live inventory and exact create intent; after failure, reconcile live type/name/scope, provisioning status and revisions against that run and state.
Under the same release lock and explicitly authorized recovery contract, remove only failed, revisionless, stateless shells proved absent before that exact release-owned create.
Refuse pre-existing or unknown resources, missing provenance, healthy revisions, stateful resources and unrelated successful resources; do not turn recovery into generic import, adoption, taint or deletion authority.
Retain successful resources and redacted failure/recovery receipts, verify cleanup, then generate a fresh guarded saved plan and obtain its approval.
If ownership or recovery authority is unproved, stop and escalate rather than hand-delete an inconvenient collision.

## Layered verification

| Layer | Required evidence |
| --- | --- |
| Contract tests | Execute native mocked phase/graph outputs and fake cloud interfaces; assert normalized manifest semantics, sequencing, pagination, denied reads, collisions, stale bindings and recovery refusals, not source strings. |
| Live prerequisite gate | Before consumer planning, check actual canonical references, attributes, current identity grants, destination image digests, network posture, admission and required producer receipts. |
| In-network identity probe | From approved isolated environment jobs, use the intended identities to resolve private references and contact required database, cache and messaging dependencies; emit redacted status only. |
| Post-apply structural gate | Read actual inventory, successful provisioning, intended healthy/running revisions, image/traffic bindings and successful bootstrap executions; refuse failed shells and retain a refreshed drift check. |
| Application and auth smoke | Prove dependency operations and real routed health, discovery and least-role sign-in/session behavior through approved ingress; assert unauthorized refusal and always clean up session artifacts. |
| Destroy-and-rollout rehearsal | Explicitly authorized operator destroy, one real protected release through every phase, no-op rerun and approved injected-failure/owned-shell recovery exercise; retain complete redacted receipts. |

Mocked apply is not cloud acceptance; zero drift is not runtime health, and metadata is not identity access.
Never run unmocked `tofu test` against a real release root/backend: it can create and automatically destroy resources outside the release's plan/approval controls.
Use only a separately authorized disposable fixture for unmocked native tests, or the protected release lifecycle for real environment acceptance.
Destroy remains the explicitly authorized human operator step, not an agent convenience; preserve backend/retained resources and tested soft-delete/purge-protection recovery without weakening those protections.
Acceptance is **zero human actions after that destroy other than approvals**.
Any hand-seeded secret, workstation grant, image import, SQL/realm/job command or shell deletion fails acceptance even when the final UI works; only the completed live rehearsal proves the end-to-end claim.
