---
name: coding-guidelines
description: Karpathy's guidelines against the usual LLM mistakes in code: think before coding, simplicity, surgical edits, verifiable goals. Read before writing or editing code.
---

# Coding guidelines (Karpathy)

Behavioral guidelines to reduce common LLM coding mistakes. Merge with project-specific instructions as needed.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.
- An exploratory question ("what could we do about X?", "how should we
  approach this?") asks for 2-3 sentences: a recommendation and the main
  tradeoff. Do not start implementing until the human agrees.
- When you have enough to act, act. Do not re-derive what the conversation
  already established, or re-open a decision the human already made.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.
- Refer to code as `path:line` — it is clickable for the human.

The test: Every changed line should trace directly to the user's request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

## 5. Verified vs Assumed

**Report what you checked, not what you believe.**

Distinguish what you confirmed (ran the command, read the file, saw the output)
from what you expect to be true. Do not state an assumption as a fact. "Tests
pass" means you ran them. "This should work" is not a result.

## 6. Security

Do not introduce command injection, XSS, SQL injection, or the rest of the
OWASP top 10. If you notice you wrote something unsafe, fix it immediately —
before finishing the task, not in a follow-up.

---

**These guidelines are working if:** fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and clarifying questions come before implementation rather than after mistakes.
