---
name: websearch
description: Search the internet through Google (SerpBase API). Needed when the answer is not in the context: fresh news, versions, documentation, courses, any fact from after the model was trained.
---

# Web search

It searches Google through SerpBase and prints the result as text: the featured
snippet, the results with titles and links, the news, and "people also ask".

## How to call it

A plain file, run from the kernel:

```python
import subprocess, sys
r = subprocess.run(
        [sys.executable, "/skills/websearch/search.py", "what to search for"],
        capture_output=True, text=True)
print(r.stdout)
```

Keys: `--num N` — how many results (5 by default), `--json` — the raw API
response, if you need to pick the fields apart yourself.

The result can go straight into a variable, so the same thing is not searched
twice.

## The key

`SERPBASE_API_KEY` sits in the environment and it is a **mask** — a
deliberately non-working string. The real key lives in the egress-filter
container and is pasted into the header on the way out, only for
`api.serpbase.dev`.

Hence two rules:

- **do not check the key and do not "fix" it.** It looks non-working because it
  is non-working; that does not affect the search;
- if the search says there is no key at all, only a human can set it up, in the
  stack `.env`. Say so and do not try to get around it.

## Pitfalls

**An error is an answer.** If SerpBase returned an error or an empty result
list, say just that. Reworking the wording of the query ten times costs more
than asking.

**Open the links separately.** The search gives only snippets. If you need the
whole page, fetch it with `httpx` and parse it with `beautifulsoup4`; both are
already installed.
