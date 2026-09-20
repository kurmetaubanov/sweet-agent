# sweet skills

Instructions the agent slips into its own prompt according to what the question
is about. One folder per skill, a `SKILL.md` inside with front matter:

```markdown
---
name: short-name
description: one sentence on what the skill is good for and when it is needed
---

# Heading

The body of the instruction.
```

The format matches prime-agent on purpose: skills should carry over between
agents without being rewritten.

## Two folders

    always/     mandatory: always in the prompt, never searched for
    optional/   the rest: they get in by what the question is about

A mandatory skill is a rule, not a find: there is nothing to search for, it
rides in the system part of the prompt on every turn, ordered by name. The
others are embedded and ranked together with the memory paragraphs.

## How it works

Only `name`, `description` and the path to the file reach the prompt — the
agent reads the body itself, with a plain `open()`, and only when it really
needs the skill. The description is embedded and ranked together with the
memory paragraphs by closeness to the question; there are no thresholds, the
first ones from the shared queue get in. That is how `optional/` works; on
`always/`, see above.

Hence the requirement on `description`: it must say **when** the skill is
needed, not only what it does. That is what admits it.

## Who edits it

The folder is mounted into the agent **read-only**. A separate curator edits
it: whoever uses an instruction should not be able to rewrite it — otherwise
the agent bends the instruction to fit its own failure instead of the other
way round.

History exists for exactly this: the curator's edit can be looked at and rolled
back. Without it the first bad edit would wipe the working text without a
trace.

## What makes the text good

Learned from live experience, not invented:

- **write from the facts of the environment, not from memory of a
  conversation.** The first version of `git-push` confidently advised `git add`
  when there was no `git` in the container at all. The instruction sounded
  plausible and did not work;
- **the pitfalls matter more than the order of commands.** The model knows the
  order by itself; what it does not know is that a commit message has to be
  passed as a file here, or the shell eats dollars and quotes;
- **keep it short.** The body is read whole, and a page of text costs context.
