# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

**Layout: single-context.** One `CONTEXT.md` at the repo root; ADRs (if any are ever written) under
`Docs/adr/`. Note this repo capitalises `Docs/` — match it. On a case-insensitive filesystem
`docs/` resolves to the same directory, but git tracks `Docs/`, so writing lowercase creates
inconsistent paths.

## Before exploring, read these

- **`CONTEXT.md`** at the repo root.
- **`Docs/adr/`**: read ADRs that touch the area you're about to work in. This directory does not
  exist yet; that is fine.

If any of these files don't exist, **proceed silently**. Don't flag their absence; don't suggest
creating them upfront. The `/domain-modeling` skill creates them lazily when terms or decisions
actually get resolved.

Beyond these, this repo's rationale lives in `Docs/<Subsystem>.md` (e.g. `Docs/MacAppContract.md`,
`Docs/Tests.md`, `Docs/Lifecycle.md`) and its session-to-session state in `Docs/BuildLog.md`. Those
are not ADRs, but they are where a decision's reasoning is usually recorded.

## `CONTEXT.md` is hand-edited — never write to it

**This is a hard local rule and it overrides any skill that would edit the glossary.**
`CONTEXT.md`'s first line states it is *"a hand-edited (never AI-edited) file."* Agents may **read**
it and may **propose** wording in chat or in a plan, but must not create, edit, or reformat the
file. If a term is missing, say so and offer draft wording for a human to accept, edit, or reject.

## Use the glossary's vocabulary

`AGENTS.md` already binds every agent to this:

> USE CONTEXT.md to describe objects and relationships for this specific codebase when explaining
> designs. Besides general SWE concepts, don't make up or arbitrarily decide on words to explain
> objects or relationships in this codebase.

So when your output names a domain concept — in an issue title, a refactor proposal, a hypothesis, a
plan, a test name — use the term as `CONTEXT.md` defines it. Don't drift to synonyms.

Prefer the codebase's own vocabulary over invented terms even when the concept isn't in
`CONTEXT.md` yet: read the doc comments and symbol names first. A real example of getting this
wrong: an agent coined "barrier" for the quit-time wait on in-flight draft writes, when the
codebase already had its own name for it (today: **drain** — `drainPendingWork()`,
`StowerTerminationDrain`) — and had to sweep 32 occurrences back out.

If the concept you need genuinely isn't named anywhere, that's a signal: either you're inventing
language the project doesn't use (reconsider) or there's a real gap (note it for a human to add to
`CONTEXT.md`).

## Flag ADR conflicts

If your output contradicts an existing ADR, surface it explicitly rather than silently overriding:

> _Contradicts ADR-0007 (event-sourced orders), but worth reopening because…_
