---
name: careful-actions
description: Before anything irreversible — git reset/checkout/restore/clean, rm -rf, tearing down containers and volumes, dropping tables, commit and push, sending files and data to external services. What to check before, not after. Destructive or irreversible action, git reset, force push, delete, publish.
---

# Careful actions

Local, reversible work — editing a file, running a test, reading a log — needs
no ceremony. This skill is about the other kind: actions that are hard to
reverse, reach beyond this machine, or destroy something you did not create.

For those, one rule stands above the rest: **the cost of asking first is a
minute; the cost of an unwanted destruction is someone's work.**

## Before anything that can discard uncommitted work

`git checkout`, `git restore`, `git reset`, `git clean`, `rm -rf` on a repo
path, restoring from a snapshot — run `git status` FIRST, and stash what you
find (`git stash -u`, `-u` for untracked) or commit it. Uncommitted work looks
like nothing in a diff and like everything to the person who wrote it.

Resolve a merge conflict rather than discarding one side of it.

## When staging and committing

After a broad `git add`, run `git status` and read what is actually included.
If you see a file that could hold secrets — even when the name looks innocent
(`config.local`, `notes.txt`, `.env.example`) — open it before pushing.

## Do not make an obstacle go away by force

A failing hook, a failing check, a lock file, a permission error — these are
information. Find the cause.

* Not `--no-verify`, `--force`, `chmod 777`, `sudo` until it passes.
* A lock file exists: find the process holding it, do not delete the file.
* A test fails after your change: the test is the evidence, not the enemy.

## Unfamiliar state is someone's work in progress

Unknown files, an unexpected branch, a config you did not write, a container
you do not recognise — investigate before deleting or overwriting. When you
cannot tell whether it is wanted, prefer a reversible step: move it aside,
rename it, stash it. Files you made yourself this turn (scratch output,
experiment intermediates) are yours to remove freely.

## Deleting

Look at the target before deleting or overwriting it: `ls`, `git status`,
`docker ps -a`, `head` — whatever shows what is actually there. A wildcard
that matched more than you meant is the ordinary way this goes wrong.

## Sending anything outward

Uploading to a third-party tool — a pastebin, a diagram renderer, a gist, an
online converter, any API — publishes it. It may be cached or indexed even
after you delete it. Decide whether the content could be sensitive BEFORE it
leaves, not after.

The same applies to messages that reach people: posting to a chat, opening an
issue, sending mail. Outward-facing and hard to unsend are the same category.

## Before a command that changes system state

Restarts, deletes, config edits, `docker compose down`, dropping a table:
check that your evidence actually supports THIS action on THIS target. A
symptom that pattern-matches a known failure often has another cause, and the
restart that "usually fixes it" destroys the state that would have explained
it.

## And when it is done

Report what you did, not what you intended. If a step was skipped, say so. If
something was destroyed, say exactly what.
