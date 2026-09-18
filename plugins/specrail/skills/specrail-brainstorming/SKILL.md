---
name: specrail-brainstorming
description: "Use before implementation when a request requires choosing product scope, user-visible behavior, or architecture. Not for fully specified fixes, mechanical refactors, documentation, or configuration-only changes."
---

# Brainstorming

## Brainstorm before you build

- Run this workflow only when implementation depends on an unresolved product or design choice.
- The aim is a validated design, recorded as a spec-graph `task-spec`, not a speculative
  implementation.
- Do not implement until the design is accepted. Acceptance criteria or an explicit design already
  supplied by the user count as approval; do not ask them to approve the same decision again.

## The workflow

1. **Orient.** Use the specrail-spec-graph skill to find relevant recorded boundaries, contracts,
   invariants, and decisions; read code second to confirm implementation details. Do not read
   unrelated specs.
2. **Scope check.** If the request bundles independent product decisions or subsystems, separate them
   rather than blending unrelated decisions into one task-spec.
3. **Open a task-spec.** Once the decision to make is understood, run `specrail create` for a
   `task-spec` at **`.specrail/context/TASK-<slug>.md`** (id, title, status: draft, parent: the
   nearest relevant module). This gitignored file is the one temporary design artifact; update it as
   decisions land.
4. **Clarify only real decisions.** Ask via the assistant's native interactive questioning capability
   only when the answer changes observable behavior or scope and cannot be inferred safely; if the
   assistant has no such capability, ask directly in the conversation. Compose a round per the
   **specrail-asking-user-questions** concept skill. Skipped questions or an assistant without
   interactive questioning are not blockers: record the best assumption as unconfirmed and continue.
5. **Draft the design.** Record the request, recommended design, trade-offs that matter, and explicit
   deferrals. Compare alternatives only when more than one viable approach remains; do not invent
   options after the constraints already select one.
6. **Self-review.** Remove placeholders, contradictions, accidental scope expansion, and ambiguous
   requirements before presenting the design.
7. **Review once.** Present one cohesive design scaled to the decision. Ask for one approval only when
   the user has not already approved the same design through their request or acceptance criteria.
   Revise the task-spec if they adjust it.
8. **Promote.** Read the **specrail-writing-specs** concept skill, then move any settled boundary,
   contract, or decision into the relevant durable `SPEC.md`; use `specrail create` for a new module,
   `specrail update` for frontmatter, and the assistant's file-editing capability for prose. Run
   `specrail validate` after structural changes.
9. **Build.** Implement directly against the accepted design. Before handoff, self-review the task
   diff: no silent lint/type suppressions, duplicated nontrivial derivations, rationale left as code
   comments, or remnants of a replaced pattern. Keep durable specs honest and retire the task-spec
   once the work itself is done.

## What a good task-spec looks like

- Scoped to one decision-bearing piece of work.
- States the request, chosen design and why, real alternatives considered, assumptions, and explicit
  deferrals.
- Promotes settled decisions instead of copying them: durable rationale lives once in the owning
  spec.

## Ending

Once the accepted design is implemented, verified, reflected in durable specs, and its task-spec is
retired, this workflow ends with no successor. PR lifecycle work, if requested, then enters
**specrail-shipping-a-pr** separately.
