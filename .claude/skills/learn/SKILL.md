---
name: learn
description: Self-learning loop. Use whenever something durable was learned in this project — a new fact about code/env, a user preference or correction, an architecture decision, a pitfall, or a repeated workflow worth a skill. Updates AGENTS.md, SPEC.md, docs/decisions.md and .claude/skills/. Run before finishing any task that produced new knowledge.
---

# learn — keep the agent's knowledge current

## When to trigger
- User states a preference/correction ("do X", "don't do Y", "I prefer…").
- A decision is made (stack, library, format, naming, scope, roadmap change).
- You discover a non-obvious fact (env quirk, failing command + fix, hidden coupling, perf finding).
- A feature lands / changes → spec state is outdated.
- You perform the same multi-step workflow a 2nd time → it deserves a skill.

Skip: trivia derivable from code or `git log`, one-off conversation details.

## Where each kind of knowledge goes
| Knowledge | Target |
|---|---|
| Rules, conventions, env facts, user preferences | `AGENTS.md` (Rules / Environment facts / Learned notes) |
| Product features, architecture, roadmap, current state | `SPEC.md` (update the relevant section + "Last update" date) |
| Decision with alternatives & reasoning | `docs/decisions.md` (ADR-lite entry, newest on top) |
| Repeatable procedure | new/updated skill in `.claude/skills/<name>/SKILL.md` |
| Skill was wrong/incomplete | edit that skill in place |

## Procedure
1. Read the target file section first; **edit in place** — merge with existing lines, don't duplicate, delete what became false.
2. Keep entries terse (one line where possible), English, absolute dates (`YYYY-MM-DD`).
3. `AGENTS.md` "Learned notes": append `- YYYY-MM-DD: <fact>`. When >15 notes, fold stable ones into proper sections and prune.
4. New skill: folder `.claude/skills/<kebab-name>/SKILL.md` with frontmatter `name`, `description` (say *when* to use it),
   then concise steps/commands. Add it to the Layout list in `AGENTS.md`.
5. Commit separately: `git add AGENTS.md SPEC.md docs .claude && git commit -m "docs(agent): learn — <summary>"`.
6. Mention in the final report what was learned (one line).

## decisions.md entry template
```
## YYYY-MM-DD — <title>
Context: … | Decision: … | Alternatives: … | Consequences: …
```
