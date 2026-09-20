---
name: webpage
description: Read a web page as text — markdown instead of markup, regex search, tables. Needed when the answer is not in the search results and you have to look at the site itself.
---

# A page as text

It fetches a page and hands back markdown. Headings, labels and values come in a
row, as on the screen, so selectors are not needed at all: what sits next to
each other on the page ends up next to each other in the text.

## How to call it

It is a plain file, run from the kernel:

```python
import subprocess, sys
r = subprocess.run([sys.executable, "/skills/webpage/page.py", url],
                   capture_output=True, text=True)
md = r.stdout
```

Keys: `--find REGEX` — the chunks around the matches, `--tables` — tables
through pandas, `--from`/`--to` — the chunk between two markers.

```python
md = page(url)                                  # the whole page
print(page(url, "--find", r"\d{1,2}:\d{2}[AP]M"))  # chunks around the matches
print(page(url, "--tables"))                       # tables through pandas
print(page(url, "--from", "Now Showing", "--to", "Coming Soon"))  # the chunk between the markers
```

The output is cut at 6000 characters (`--max` changes that). If it was cut, do
not raise the ceiling — take the part you need with `--find` or `--from/--to`.

## What it looks like

A cinema timetable with no selector at all:

```
## Now Showing

**A Complete Unknown** (2024) — 2h 21m
  14:10  17:25  20:40
```

The title, the format, the running time and the times put themselves in a row.

## Pitfalls

**Do not parse HTML by hand.** BeautifulSoup and hunting for selectors is
dozens of blind calls; markdown gives the same thing in one. Go back to `bs4`
only if markdown really does not give you what you need.

**Do not print walls of text.** A printed chunk stays in the conversation and
travels to the model again on EVERY following step of the turn: a page shown on
the fifth step is paid for fifteen times. Put the markdown in a variable and
print only the gist.

**The page is already fetched.** The kernel lives between calls — there is no
reason to fetch it twice, work with the variable.

**Empty or nonsense means the site loads the data itself** with a request, and
it is not in the HTML. Poking at it is pointless: either find that request, or
tell the human the page is built that way.
