---
name: specrail-asking-user-questions
description: "Use when composing an interactive question round inside a workflow, or when a workflow skill names it at a question step. Shared norms for asking the user questions — not a workflow, nothing to execute."
---

# Asking User Questions

The workflow family's shared norms for asking the user questions through the assistant's native
interactive questioning ability (or, where the assistant has none, by asking directly in the
conversation): how to compose rounds, shape options, and degrade when answers don't come. Process
skills name this concept at the steps that ask; *when* to ask — and where the answers get recorded —
stays with the referencing skill.

## Rounds, not chat turns

- One call = one **round**: up to 4 questions, 2–4 options each. Group everything the current step
  needs into a single round — never chain a second call straight after for a trivial follow-up.
- **The call ends your turn.** The questionnaire is shown and your run stops; the answers arrive as the
  next user message (a structured message carrying the user's answers). Don't keep working on the
  blocked step after calling, and don't assume an answer until it arrives — whether that is seconds
  later or days later.
- If the user replies with a free-form message instead of answering the questions, that reply **supersedes**
  the round — treat it as their answer, and re-ask only what is still genuinely undecided.
- Resolve the round, act on what you learned, and open a new round only when the answers raised a
  genuinely new question.

## Options

- Recommended option first, label suffixed "(Recommended)", plus a one-line reason saying why you
  recommend it over the alternatives (shown inline under the option as a `Why:` line).
- Every option: a concise label (1–5 words, ≤ 60 chars) + a description carrying the trade-off or
  consequence of choosing it. Tailor options to the work at hand — never generic placeholders.
- Options must be **decidable by the asked user**: frame them as observable behavior or outcomes
  ("collapsing a project stays collapsed after a rename"), never as implementation mechanics
  ("semantic guard", "activation ref"). If candidate options differ only internally — identical
  observable behavior — don't ask: decide yourself and record the reasoning in the workflow's
  artifact.
- Never author your own "Other", free-text, or escape options — the question UI adds a free-text row to
  every question and an always-available Skip, and reserved labels are rejected. This holds under
  multiple selection too: the free-text row stays and is *additive* — a typed answer arrives alongside
  the checked options, it does not replace them.
- Enable multiple selection when several answers are valid at once (feature checklists); single-select
  when confirming something or choosing one path.
- Offer an option preview (markdown) when a concrete artifact — code, a config, a mockup — is clearer
  shown than described. Single-select only.
- The question header is a short chip, ≤ 16 characters.

## Confirming an inference

When you have inferred something and need a yes/adjust rather than an open answer: the inferred
statement *is* the question text, with "Looks right" as the first option (description: "accurate as
written") and a genuine rejection option second (e.g. "Off base — ask me directly"). Edits arrive
through the question UI's automatic free-text row — do not author an edit option. Read the response as:

- **"Looks right"** → the inference holds; continue unchanged.
- **Free-text tweak** (one fact changes) → update that field only; don't re-derive anything else.
- **Substantial rewrite** → re-derive every inference that came from that statement before continuing.
- **Rejection** → discard the inference entirely and ask an open-ended question instead.

## Degradation

- Skipped, declined, or unanswered questions are not blockers: proceed on best-guess assumptions,
  explicitly recorded as unconfirmed in the workflow's artifact (the referencing skill says where).
- If the assistant reports no interactive questioning UI, state your assumptions the same way instead
  of blocking.
- "I don't know / help me understand" is a mis-framing signal, not a missing-knowledge one: re-explain
  from user-visible behavior in plain language, then re-ask with behavior-framed options — don't
  repeat the same technical options with more detail.
