---
name: git-push
description: Commit and push to GitHub from /workspace. The token is pasted in by the filter on the way out; all you have is a mask, and it needs no fixing.
---

# Commit and push to GitHub

`git` is present in the container (so are `curl`, `ripgrep`, `jq`, `sqlite3`).
Repositories live in `/workspace`. There is no root, `apt-get` will not work —
there is nothing to install and no way to install it.

## The token

`GITHUB_TOKEN` sits in the environment and it is a **mask** — a deliberately
non-working string. The real token lives in the egress-filter container and is
pasted into the header on the way out, only for `github.com` and
`api.github.com`.

Hence two rules:

- **do not check the token and do not "fix" it.** It looks non-working because
  it is non-working: the mask is a trap for a stock copy of the skill, nothing
  more. As long as `GITHUB_TOKEN` or `GITHUB_TOKEN_MASK` is set in the
  environment, the mask is in its place and the push will go through;
- if the environment has no token at all, the repository is not connected to
  egress or the real token is not in `secrets/`. This is fixed only in
  `/workspace/.egress/secrets` or in the egress config, and a `git` command
  cannot fix it — say so to the human and do not look for a way around;
- if the push failed on access, the token is not the problem. Show the error
  to the human.

## The order

    cd /workspace/<repository>
    git add -A
    git status --short          # see what is going out

The commit message goes **as a file**:

    git commit -F /tmp/msg.txt
    git push origin HEAD

## Pitfalls

**The message only as a file, never `-m "..."`.** The shell eats dollars,
backticks and some of the quotes — the history keeps a mangled text while the
code stays intact, and it is hard to notice. Learned from a live commit.

**Before committing, check that you are not carrying secrets out:**

    git diff --cached --name-only | xargs grep -lE "ghp_|sk-[a-f0-9]{32}"

The output has to be empty.

**Something downloaded as a tarball is not a repository.** If the folder came
from `api.github.com/.../tarball`, there is no history in it: `.git` is absent
and there is nothing to commit to. You need `git clone`.

**The name and the email may be missing.** Then `git commit` refuses to work
and says so plainly. Set them locally, for this repository:

    git -C /workspace/<repository> config user.name "sweet"
    git -C /workspace/<repository> config user.email "sweet@localhost"

## What not to do

Do not push without an explicit "go ahead" from the human. Building the commit,
showing what is going out and asking is cheaper than rolling back someone
else's history.
