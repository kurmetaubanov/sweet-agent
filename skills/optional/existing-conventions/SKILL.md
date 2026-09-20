---
name: existing-conventions
description: Editing an unfamiliar repository — how to write so the edit does not stand out: the style of the neighbouring code, whether the library is there, how dense the comments are, editing an existing file instead of adding a new one. Editing an unfamiliar codebase, following project conventions.
---

# Existing conventions

A change that reads like the code around it is reviewed once. A change that
reads like a different author is reviewed three times and rewritten.

## Read before you write

Open the neighbouring files first — the module you are editing, the one that
calls it, the closest test. You are looking for how THIS project does things,
not how it is usually done:

* naming: `user_id` or `userId`, `fetch_` or `get_`, plural or singular;
* structure: where a new function goes, how errors travel, what returns
  `{:ok, _}` and what raises;
* comment density and purpose (see below);
* how the same kind of problem was already solved here once.

## Never assume a library is available

Do not import a package because it is the obvious choice. Check that the
project already uses it: the manifest (`mix.exs`, `package.json`,
`pyproject.toml`, `requirements.txt`, `go.mod`) and the existing imports. If
it is not there, either use what is, or say plainly that the work needs a new
dependency — that is the human's decision, not a side effect of your edit.

The same holds for tools: a project with a `Makefile` or documented commands
is run through those, not through commands you invent.

## Comments: match the house, and the house here explains WHY

Comment density is a convention like any other — copy the surrounding level.
In these repositories the convention is strong and unusual: a comment says
**why** the code is the way it is, what was tried before, what broke, what
would break again if it were changed back. That is the most valuable text in
the file. Do not thin it out, and do not replace it with a restatement of what
the code does.

Two rules that follow:

* do not write a comment that only names the operation the line already shows;
* when you change behaviour a comment describes, update the comment in the
  same edit — a comment that lies is worse than no comment.

## Prefer editing over creating

A new file is a new place to look. Put the change where its neighbours live
unless the file is genuinely a new unit. The same goes for helpers: a second
similar call site is not yet an abstraction.

## Do not reformat on the way past

Whitespace, import order, quote style, line wrapping — leave them as they are,
even where the project is inconsistent. A diff should contain the change and
nothing else; formatting noise hides the part that matters.

If the project has a formatter and it is already applied to the file, run it —
that IS the convention.

## When the conventions conflict with your instructions

Explicit instructions from the human win over what the code does. The code
wins over your own preference. Say it out loud when you see the conflict
instead of quietly picking one.
