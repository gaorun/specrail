---
name: specrail-spec-graph
description: "Use when locating, reading, creating, updating, or validating project specs, or when work is governed by or may alter a documented boundary, contract, invariant, behavior, or architecture decision."
---

# Spec graph

## Specs are the ground truth

- Specs describe the architecture, decisions, contracts, and boundaries behind the code — the intent
  that the code alone does not reveal. Treat them as authoritative.
- **Consult the owning spec when it governs the work.** When work depends on, checks, explains, or
  may alter a documented boundary, contract, invariant, behavior, or architecture decision, use
  `specrail grep` / `specrail show` / `specrail graph` to find the applicable record and align with it. If a change contradicts a recorded
  decision, surface and reconcile the contradiction rather than silently diverging.
- **Keep lookup proportional.** Specs are the map for decisions and boundaries; code confirms the
  implementation. A localized fix, explanation, or check that changes no documented decision may
  inspect only the files it needs without reading unrelated specs.
- **Keep them honest.** A change that moves or blurs a boundary, or overturns a decision, updates the
  spec as part of the same change. Specs that drift from the code stop being ground truth.

## What a spec is

- A durable, declarative document. It states the world as it is — the intent, decisions, contracts, and
  boundaries behind the code — not plans, tasks, phases, or a work journey.
- Concise and readable. It captures what is *not* obvious from the code; it never restates the code.
- The bar: reading the relevant specs should be enough to understand an area and to formulate a task to
  improve it.

### Keep specs lean

- **Explain intent, not inventory.** Describe what a module is for, what it owns, and where its boundaries
  are — not a file-by-file transcript of its directory. The reader can see the files; the spec exists for
  what the files *don't* say.
- **Record the edges that matter.** State the module's boundary (allowed / forbidden deps) and the
  dependency edges between its sub-modules. List a part only when its role or its edges aren't obvious from
  its name — e.g. a small table that carries a real dependency DAG earns its place; a table that just
  pairs `foo.ts` with "the foo tool" is noise, so say it in a sentence instead.
- **Say each thing once.** A fact lives in exactly one spec; others link to it by `id` rather than restate
  it. If a paragraph is being copied between specs, move it to the spec that owns the concept and point at
  it. Duplicated prose drifts and turns into contradictions.
- **Prefer prose to exhaustive tables**, and cut anything that only paraphrases code, filenames, or a
  sibling spec.

## The graph

- `parent` links form a hierarchy that mirrors the code structure: a `SPEC.md` sits beside the module it
  describes (fractal — a package and its sub-directories each have one), and root documents sit at the
  repository root.
- `depends-on`, `references`, and `implements` form a dependency layer across the tree.

## Frontmatter

- Required: `id` (a unique slug), `type`, `title`.
- Optional: `status` (lifecycle), `parent` (single link), `depends-on` / `references` / `implements`
  (link lists), `covers`, `tags`.
- A file is a spec when its frontmatter carries `id` and `type`.
- `status` tracks a spec's lifecycle: `draft` (being written) → `active` (in force), then `stale` (drifting
  from the code), `done`, or `deprecated`. It's optional, but keep it current as a spec firms up or ages.
- Types:
  - `goal-and-requirements` — the product goal and scope; the root of the graph.
  - `architecture-design` — system-wide topology, cross-cutting decisions, and invariants.
  - `module-design` — a package or module's responsibility and boundary.
  - `submodule-design` — the same, for a directory-level module inside a package.
  - `task-spec` — a temporary working document for a piece of work; not durable, and removed once the
    work lands.

## Tools

Read:
- `specrail grep` — search within specs (content, narrowed by metadata filters).
- `specrail show` — a spec's frontmatter, its resolved links, and its path. Read the body with your
  normal file read tool using that path.
- `specrail graph` — a bounded slice of the graph: a subtree, ancestors, or a node's neighbors, to a depth.

Manage:
- `specrail create` — a new spec with scaffolded frontmatter and headings.
- `specrail update <id> --set K=V` (also `--remove K`, `--add-list K=V`, `--remove-list K=V`) — a spec's
  frontmatter (fields and links). It does not touch the body. Fields are edited with flags only; a bare
  `K=V` positional is rejected.
- `specrail delete` — remove a spec.
- `specrail validate` — report dangling links, duplicate ids, and parent cycles.

Prose is written and edited with your normal write and edit tools; the `specrail` commands own frontmatter
and structure.

## Working with specs

1. **Orient when specs govern the work.** From a known root or the module you are touching, use
   `specrail graph` for the neighborhood, `specrail show` for a node's metadata, and your normal file
   read tool for its body. Use `specrail grep` to find specs by content.
2. **Align.** Reconcile the change with the decisions and contracts the specs record; surface
   contradictions before diverging.
3. **Update.** When the change alters a boundary, contract, or decision, update the spec — frontmatter
   (including `status`, e.g. `specrail update <id> --set status=done`) with `specrail update`, prose with
   your normal edit tool — and use
   `specrail create` for a new module.
4. **Check.** Run `specrail validate` after structural changes.
